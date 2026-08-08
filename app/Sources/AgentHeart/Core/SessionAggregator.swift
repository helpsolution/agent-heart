import Foundation

/// Названия сессий с приоритетом: заданное руками важнее автоматического,
/// автоматическое важнее первого промпта.
struct TitleIndex {
    var custom: [Int32: String] = [:]
    var ai: [Int32: String] = [:]
    var prompts: [Int32: String] = [:]

    func title(for session: Int32) -> (text: String, source: TitleSource) {
        if let t = custom[session] { return (t, .custom) }
        if let t = ai[session]     { return (t, .ai) }
        if let t = prompts[session] { return (t, .prompt) }
        return ("без названия", .none)
    }
}

/// Разбор одного проекта: какие в нем были сессии и что в них происходило.
enum SessionAggregator {

    /// Сессии проекта за выбранный период, свежие сверху.
    /// Сортировка по началу сессии — то есть по той же дате, которая видна
    /// в строке. Возобновленная сессия живет неделями, и если сортировать по
    /// последней активности, порядок разойдется с показанными датами.
    static func sessions(
        records: [CallRecord],
        pool: StringPool,
        prices: PriceTable?,
        bounds: (start: Double, end: Double)?,
        titles: TitleIndex,
        projectPath: String,
        projectPaths: [Int32: String]
    ) -> [SessionRow] {
        var totals: [Int32: Totals] = [:]
        var first: [Int32: Double] = [:]
        var last: [Int32: Double] = [:]
        var models: [Int32: [Int32: Int]] = [:]
        var sidechain: Set<Int32> = []
        var priceCache: [Int32: ModelPrice?] = [:]

        for r in records {
            if let b = bounds, r.timestamp < b.start || r.timestamp >= b.end { continue }
            guard (projectPaths[r.project] ?? pool[r.project]) == projectPath else { continue }

            let price: ModelPrice?
            if let cached = priceCache[r.model] {
                price = cached
            } else {
                price = prices?.price(for: pool[r.model])
                priceCache[r.model] = price
            }
            totals[r.session, default: Totals()].add(r, cost: prices?.cost(of: r, price: price) ?? 0)

            if first[r.session] == nil || r.timestamp < first[r.session]! {
                first[r.session] = r.timestamp
            }
            if last[r.session] == nil || r.timestamp > last[r.session]! {
                last[r.session] = r.timestamp
            }
            models[r.session, default: [:]][r.model, default: 0] += Int(r.input) + Int(r.output)
            if r.isSidechain { sidechain.insert(r.session) }
        }

        return totals.map { session, t in
            let (text, source) = titles.title(for: session)
            let top = models[session]?.max { $0.value < $1.value }?.key
            return SessionRow(
                id: session,
                title: text,
                titleSource: source,
                totals: t,
                first: Date(timeIntervalSince1970: first[session] ?? 0),
                last: Date(timeIntervalSince1970: last[session] ?? 0),
                topModel: top.map { modelName(pool[$0]) } ?? "—",
                hasSubagents: sidechain.contains(session)
            )
        }
        .sorted { $0.first > $1.first }
    }

    /// Полная карточка одной сессии. Период здесь не применяется: если уж
    /// открыли конкретную сессию, показываем ее целиком.
    static func detail(
        session: Int32,
        records: [CallRecord],
        tools: [ToolEvent],
        pool: StringPool,
        prices: PriceTable?,
        titles: TitleIndex,
        projectPaths: [Int32: String]
    ) -> SessionDetail? {
        var totals = Totals()
        var byModel: [Int32: GroupRow] = [:]
        var byKind: [Bool: GroupRow] = [:]
        var byBucket: [Int: GroupRow] = [:]
        var priceCache: [Int32: ModelPrice?] = [:]
        var firstTs: Double?
        var lastTs: Double?
        var projectPath = "—"
        var sidechain = false

        let tz = TimeZone.current
        let calendar = Calendar.current
        let labelFormatter = DateFormatter()
        labelFormatter.dateFormat = "dd.MM HH:mm"
        labelFormatter.timeZone = tz
        labelFormatter.locale = Locale(identifier: "ru_RU")

        for r in records where r.session == session {
            let price: ModelPrice?
            if let cached = priceCache[r.model] {
                price = cached
            } else {
                price = prices?.price(for: pool[r.model])
                priceCache[r.model] = price
            }
            let cost = prices?.cost(of: r, price: price) ?? 0

            totals.add(r, cost: cost)
            projectPath = projectPaths[r.project] ?? pool[r.project]
            if r.isSidechain { sidechain = true }
            if firstTs == nil || r.timestamp < firstTs! { firstTs = r.timestamp }
            if lastTs == nil || r.timestamp > lastTs! { lastTs = r.timestamp }

            byModel[r.model, default: GroupRow(
                id: "m\(r.model)", name: modelName(pool[r.model]), totals: Totals()
            )].totals.add(r, cost: cost)

            byKind[r.isSidechain, default: GroupRow(
                id: r.isSidechain ? "subagent" : "main",
                name: r.isSidechain ? "сабагенты" : "главный цикл",
                totals: Totals()
            )].totals.add(r, cost: cost)

            let date = Date(timeIntervalSince1970: r.timestamp)
            let local = r.timestamp + Double(tz.secondsFromGMT(for: date))
            let key = Int((local / 3_600).rounded(.down))
            let start = calendar.dateInterval(of: .hour, for: date)?.start ?? date
            byBucket[key, default: GroupRow(
                id: "b\(key)", name: labelFormatter.string(from: start),
                totals: Totals(), date: start
            )].totals.add(r, cost: cost)
        }

        guard totals.calls > 0, let firstTs, let lastTs else { return nil }

        // Инструменты: чем занималась сессия, а не сколько съела.
        var byTool: [Int32: Int] = [:]
        for e in tools where e.session == session { byTool[e.tool, default: 0] += 1 }
        let toolRows = byTool
            .map { GroupRow(id: "t\($0.key)", name: pool[$0.key],
                            totals: Totals(calls: $0.value)) }
            .sorted { $0.totals.calls > $1.totals.calls }

        let (text, source) = titles.title(for: session)
        let row = SessionRow(
            id: session, title: text, titleSource: source, totals: totals,
            first: Date(timeIntervalSince1970: firstTs),
            last: Date(timeIntervalSince1970: lastTs),
            topModel: byModel.values.max { $0.totals.total < $1.totals.total }?.name ?? "—",
            hasSubagents: sidechain
        )

        return SessionDetail(
            row: row,
            project: projectPath,
            models: byModel.values.sorted { $0.totals.total > $1.totals.total },
            kinds: byKind.values.sorted { $0.totals.total > $1.totals.total },
            tools: toolRows,
            buckets: byBucket.keys.sorted().compactMap { byBucket[$0] },
            granularity: .hour
        )
    }

    /// `claude-opus-4-5-20251001` → `opus-4-5`
    static func modelName(_ model: String) -> String {
        model
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-20251001", with: "")
    }
}
