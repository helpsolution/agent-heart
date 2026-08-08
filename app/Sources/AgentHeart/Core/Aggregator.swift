import Foundation

/// Сводит плоский список вызовов в агрегаты вкладки «Обзор».
/// Дешёвая операция (десятки тысяч записей), поэтому смена диапазона дат
/// пересчитывается на лету, без повторного чтения файлов.
enum Aggregator {

    static let projectLimit = 30
    static let modelLimit = 20

    static func snapshot(
        records: [CallRecord],
        pool: StringPool,
        prices: PriceTable?,
        bounds: (start: Double, end: Double)?,
        granularity: Granularity = .day,
        projectPaths: [Int32: String] = [:]
    ) -> OverviewSnapshot {
        var snap = OverviewSnapshot()
        snap.granularity = granularity

        var priceCache: [Int32: ModelPrice?] = [:]
        var byProject: [String: GroupRow] = [:]
        var byModel: [Int32: GroupRow] = [:]
        var byKind: [Bool: GroupRow] = [:]
        var byBucket: [Int: GroupRow] = [:]
        var sessions = Set<Int32>()
        var unpriced = Set<Int32>()

        let tz = TimeZone.current
        let calendar = Calendar.current
        let labelFormatter = DateFormatter()
        labelFormatter.dateFormat = granularity.labelFormat
        labelFormatter.timeZone = tz
        labelFormatter.locale = Locale(identifier: "ru_RU")
        // Записи отсортированы по времени, поэтому корзина почти всегда та же,
        // что у предыдущей записи — Calendar и DateFormatter дёргаем только
        // на переходах, а не на каждой из десятков тысяч записей.
        var lastDayIndex = Int.min
        var lastMonthIndex = Int.min
        var lastBucketKey = Int.min
        var lastBucketLabel = ""
        var lastBucketStart = Date(timeIntervalSince1970: 0)

        for r in records {
            if let b = bounds, r.timestamp < b.start || r.timestamp >= b.end { continue }

            let price: ModelPrice?
            if let cached = priceCache[r.model] {
                price = cached
            } else {
                price = prices?.price(for: pool[r.model])
                priceCache[r.model] = price
            }
            let cost = prices?.cost(of: r, price: price) ?? 0
            if price == nil { unpriced.insert(r.model) }

            snap.overall.add(r, cost: cost)
            sessions.insert(r.session)

            // Имя кладём позже: короткое имя проекта зависит от того, есть ли
            // у него тёзки среди других путей.
            let projectPath = projectPaths[r.project] ?? pool[r.project]
            byProject[projectPath, default: GroupRow(
                id: projectPath, name: projectPath, totals: Totals()
            )].totals.add(r, cost: cost)
            byProject[projectPath]!.sessions.insert(r.session)

            byModel[r.model, default: GroupRow(
                id: "m\(r.model)", name: modelName(pool[r.model]), totals: Totals()
            )].totals.add(r, cost: cost)

            byKind[r.isSidechain, default: GroupRow(
                id: r.isSidechain ? "subagent" : "main",
                name: r.isSidechain ? "сабагенты" : "главный цикл",
                totals: Totals()
            )].totals.add(r, cost: cost)

            let date = Date(timeIntervalSince1970: r.timestamp)
            let localSeconds = r.timestamp + Double(tz.secondsFromGMT(for: date))
            let dayIndex = Int((localSeconds / 86_400).rounded(.down))
            if dayIndex != lastDayIndex {
                lastDayIndex = dayIndex
                let comps = calendar.dateComponents([.year, .month], from: date)
                lastMonthIndex = (comps.year ?? 0) * 12 + (comps.month ?? 0)
            }

            let bucketKey: Int
            switch granularity {
            case .hour:  bucketKey = Int((localSeconds / 3_600).rounded(.down))
            case .day:   bucketKey = dayIndex
            case .month: bucketKey = lastMonthIndex
            }
            if bucketKey != lastBucketKey {
                lastBucketKey = bucketKey
                lastBucketStart = bucketStart(of: date, granularity: granularity,
                                              calendar: calendar)
                // Именно от начала корзины, а не от даты записи: иначе час
                // подписывается временем первого вызова в нём («13:07»).
                lastBucketLabel = labelFormatter.string(from: lastBucketStart)
            }
            byBucket[bucketKey, default: GroupRow(
                id: "b\(bucketKey)", name: lastBucketLabel, totals: Totals(),
                date: lastBucketStart
            )].totals.add(r, cost: cost)
        }

        snap.sessionCount = sessions.count
        snap.projectCount = byProject.count

        let labels = shortLabels(for: byProject.values.map(\.name))
        var projectRows = byProject.values.sorted { $0.totals.total > $1.totals.total }
        for i in projectRows.indices {
            projectRows[i] = GroupRow(
                id: projectRows[i].id,
                name: labels[projectRows[i].name] ?? projectRows[i].name,
                totals: projectRows[i].totals,
                sessions: projectRows[i].sessions
            )
        }
        snap.projects = Array(projectRows.prefix(projectLimit))
        snap.models = Array(byModel.values.sorted { $0.totals.total > $1.totals.total }
            .prefix(modelLimit))
        snap.kinds = byKind.values.sorted { $0.totals.total > $1.totals.total }
        snap.buckets = byBucket.keys.sorted().compactMap { byBucket[$0] }
        snap.modelsWithoutPrice = unpriced.map { pool[$0] }.sorted()
        return snap
    }

    /// Начало корзины, к которой относится момент времени.
    private static func bucketStart(of date: Date, granularity: Granularity,
                                    calendar: Calendar) -> Date {
        switch granularity {
        case .hour:
            return calendar.dateInterval(of: .hour, for: date)?.start ?? date
        case .day:
            return calendar.startOfDay(for: date)
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start
                ?? calendar.startOfDay(for: date)
        }
    }

    /// Только итоговые суммы — для сравнения с предыдущим периодом не нужны
    /// группировки, поэтому не платим за них.
    static func totals(
        records: [CallRecord],
        pool: StringPool,
        prices: PriceTable?,
        bounds: (start: Double, end: Double)
    ) -> Totals {
        var priceCache: [Int32: ModelPrice?] = [:]
        var totals = Totals()
        for r in records {
            if r.timestamp < bounds.start || r.timestamp >= bounds.end { continue }
            let price: ModelPrice?
            if let cached = priceCache[r.model] {
                price = cached
            } else {
                price = prices?.price(for: pool[r.model])
                priceCache[r.model] = price
            }
            totals.add(r, cost: prices?.cost(of: r, price: price) ?? 0)
        }
        return totals
    }

    /// Короткие подписи проектов: обычно достаточно имени папки, но у тёзок
    /// (`.../acme/orderprocessing` и `.../legacy/orderprocessing`) добавляем
    /// столько родительских сегментов, сколько нужно для различимости.
    static func shortLabels(for paths: [String]) -> [String: String] {
        let segments = Dictionary(uniqueKeysWithValues: paths.map {
            ($0, $0.split(separator: "/").map(String.init))
        })
        var result: [String: String] = [:]
        var unresolved = Set(paths)
        var depth = 1

        while !unresolved.isEmpty {
            var candidates: [String: [String]] = [:]   // подпись -> пути
            for path in unresolved {
                let parts = segments[path] ?? []
                let label = parts.isEmpty ? path : parts.suffix(depth).joined(separator: "/")
                candidates[label, default: []].append(path)
            }
            var stillAmbiguous = Set<String>()
            for (label, group) in candidates {
                if group.count == 1 {
                    result[group[0]] = label
                } else {
                    // Глубже уже некуда — пути совпадают целиком, различать нечем.
                    let canGoDeeper = group.contains { (segments[$0]?.count ?? 0) > depth }
                    if canGoDeeper {
                        stillAmbiguous.formUnion(group)
                    } else {
                        group.forEach { result[$0] = label }
                    }
                }
            }
            unresolved = stillAmbiguous
            depth += 1
        }
        return result
    }

    /// `claude-opus-4-5-20251001` → `opus-4-5`
    private static func modelName(_ model: String) -> String {
        model
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-20251001", with: "")
    }
}
