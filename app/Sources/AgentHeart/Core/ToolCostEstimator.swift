import Foundation

/// Во что обошелся один вызов инструмента.
struct ToolAttribution {
    var timestamp: Double
    var session: Int32
    var tool: Int32
    /// Сколько токенов результат добавил в контекст.
    var addedTokens: Int
    /// Запись в кеш плюс все последующие перечитывания до конца сессии.
    var cost: Double
    /// Длина потока в вызовах — множитель, из-за которого один и тот же
    /// результат в длинной сессии стоит кратно дороже.
    var threadLength: Int
    /// Сколько ходов результату еще предстоит прожить.
    var remainingTurns: Int
}

/// Длина сессии как фактор стоимости. Один и тот же результат в сессии на
/// 900 ходов перечитывается на порядок чаще, чем в сессии на 90.
enum LengthBucket: Int, CaseIterable {
    case short, medium, long, marathon

    static func of(_ turns: Int) -> LengthBucket {
        switch turns {
        case ..<50:   return .short
        case ..<200:  return .medium
        case ..<500:  return .long
        default:      return .marathon
        }
    }

    var title: String {
        switch self {
        case .short:    return "до 50 вызовов"
        case .medium:   return "50–200"
        case .long:     return "200–500"
        case .marathon: return "500 и больше"
        }
    }
}

/// Насколько результату можно верить.
struct ToolCostCoverage {
    var attributed = 0
    var total = 0

    var share: Double { total > 0 ? Double(attributed) / Double(total) : 0 }
}

/// Оценивает, во что обходятся вызовы инструментов.
///
/// Прямой цены у инструмента нет — платят только за токены. Но результат
/// вызова попадает в контекст и **перечитывается на каждом последующем
/// запросе сессии**. Прочитал файл на десятом ходу из девятисот — заплатил
/// за него девятьсот раз. Это и есть настоящая стоимость инструмента.
///
/// Размер результата в транскрипте не записан, поэтому выводится:
///
///     прирост контекста между соседними вызовами − output предыдущего
///
/// Отсюда оговорки, которые нельзя прятать от пользователя:
///
/// 1. Вызовы сабагентов не оцениваются: у них свой контекст, и разность
///    через границу потока не значит ничего.
/// 2. Прирост включает и текст пользователя, если тот писал в этот ход,
///    так что отдельные вызовы завышены.
/// 3. Модель считает, что контекст не компактился. После компактизации
///    перечитываний меньше, чем здесь насчитано.
/// 4. Ход с несколькими вызовами сразу разделить нельзя — такие
///    пропускаются (в текущих данных не встречаются).
///
/// Доля оцененных вызовов возвращается в `coverage`, разбивка причин —
/// в полях `skipped*`. Это оценка с понятной методикой, а не бухгалтерия.
enum ToolCostEstimator {

    struct Result {
        var attributions: [ToolAttribution] = []
        var coverage = ToolCostCoverage()
        /// Почему вызов остался без оценки — для диагностики методики.
        var skippedNoRecord = 0     // у сообщения с вызовом нет записи о токенах
        var skippedSidechain = 0    // вызов сделан сабагентом
        var skippedLast = 0         // последний ход потока, не с чем сравнить
        var skippedNoGrowth = 0     // контекст не вырос — компактизация или обрыв
        var skippedParallel = 0     // несколько вызовов в ходе, не разделить
    }

    static func estimate(
        records: [CallRecord],
        tools: [ToolEvent],
        pool: StringPool,
        prices: PriceTable?
    ) -> Result {
        guard !tools.isEmpty else { return Result() }

        // Связь вызовов с записями — по хэшу сообщения, а не по времени.
        // Claude Code дописывает одно assistant-сообщение в транскрипт
        // несколько раз по мере генерации: у копий разные таймстемпы, вызовы
        // появляются только в последней, а usage у всех одинаковый. Дедуп
        // оставляет первую копию как запись и последнюю как источник вызовов,
        // поэтому связывать их по времени нельзя — хэш сообщения общий.
        var byMessage: [UInt64: [Int32]] = [:]
        var unjoinable = 0
        for e in tools {
            guard e.dedupKey != 0 else { unjoinable += 1; continue }
            byMessage[e.dedupKey, default: []].append(e.tool)
        }

        // Записи по потокам, а не просто по сессиям. У сабагентов свой
        // контекст, и их записи перемешаны с главным циклом по времени —
        // разность через границу потока не значит ничего. Считаем только
        // главный цикл; вызовы сабагентов остаются неоцененными, и это
        // видно в покрытии.
        var bySession: [Int32: [Int]] = [:]
        for (i, r) in records.enumerated() where !r.isSidechain {
            bySession[r.session, default: []].append(i)
        }

        var priceCache: [Int32: ModelPrice?] = [:]
        func price(_ model: Int32) -> ModelPrice? {
            if let cached = priceCache[model] { return cached }
            let p = prices?.price(for: pool[model])
            priceCache[model] = p
            return p
        }

        var out = Result()
        out.coverage.total = tools.count

        out.skippedNoRecord = unjoinable

        var eligible = Set<UInt64>()
        var lastOfThread = Set<UInt64>()
        var sidechainTurns = Set<UInt64>()
        for r in records where r.dedupKey != 0 {
            if r.isSidechain { sidechainTurns.insert(r.dedupKey) }
            else { eligible.insert(r.dedupKey) }
        }

        for (_, indices) in bySession {
            let n = indices.count
            guard n > 1 else { continue }

            // Суффиксные суммы цены cache read: сколько стоит один токен,
            // пронесенный от хода i до конца сессии.
            var carry = [Double](repeating: 0, count: n + 1)
            for j in stride(from: n - 1, through: 0, by: -1) {
                let cr = price(records[indices[j]].model)?.cacheRead ?? 0
                carry[j] = carry[j + 1] + cr / 1_000_000
            }

            lastOfThread.insert(records[indices[n - 1]].dedupKey)

            for i in 0..<(n - 1) {
                let cur = records[indices[i]]
                let next = records[indices[i + 1]]

                guard let called = byMessage[cur.dedupKey] else { continue }
                guard called.count == 1 else {
                    out.skippedParallel += called.count
                    continue
                }

                let added = contextSize(next) - contextSize(cur) - Int(cur.output)
                guard added > 0 else {
                    out.skippedNoGrowth += 1
                    continue
                }

                // Токены впервые попадают в контекст на следующем запросе
                // (там их пишут в кеш), дальше перечитываются до конца сессии.
                let write = (price(next.model)?.cacheWrite5m ?? 0) / 1_000_000
                let cost = Double(added) * (write + carry[i + 2])

                out.attributions.append(ToolAttribution(
                    timestamp: cur.timestamp, session: cur.session,
                    tool: called[0], addedTokens: added, cost: cost,
                    threadLength: n, remainingTurns: n - i - 2))
                out.coverage.attributed += 1
            }
        }

        for (key, called) in byMessage {
            if sidechainTurns.contains(key) { out.skippedSidechain += called.count }
            else if !eligible.contains(key) { out.skippedNoRecord += called.count }
            else if lastOfThread.contains(key) { out.skippedLast += called.count }
        }

        out.attributions.sort { $0.timestamp < $1.timestamp }
        return out
    }

    /// Все, что тарифицируется как вход, — это и есть размер контекста запроса.
    private static func contextSize(_ r: CallRecord) -> Int {
        Int(r.input) + Int(r.cacheWrite5m) + Int(r.cacheWrite1h) + Int(r.cacheRead)
    }

    /// Самые дорогие отдельные вызовы. Решения принимаются по выбросам,
    /// а не по средним: медианный вызов стоит доли цента, а верхний процент
    /// дает около четверти всех денег.
    static func topCalls(
        _ attributions: [ToolAttribution],
        bounds: (start: Double, end: Double)?,
        limit: Int
    ) -> [ToolAttribution] {
        attributions
            .filter { a in bounds.map { a.timestamp >= $0.start && a.timestamp < $0.end } ?? true }
            .sorted { $0.cost > $1.cost }
            .prefix(limit)
            .map { $0 }
    }

    /// Стоимость в разрезе длины сессии — проверка тезиса «длинные сессии
    /// дороже» на собственных данных, а не на слово.
    static func byLength(
        _ attributions: [ToolAttribution],
        bounds: (start: Double, end: Double)?
    ) -> [GroupRow] {
        var buckets: [LengthBucket: (tokens: Int, cost: Double, calls: Int)] = [:]
        for a in attributions {
            if let b = bounds, a.timestamp < b.start || a.timestamp >= b.end { continue }
            let key = LengthBucket.of(a.threadLength)
            buckets[key, default: (0, 0, 0)].tokens += a.addedTokens
            buckets[key]!.cost += a.cost
            buckets[key]!.calls += 1
        }
        return LengthBucket.allCases.compactMap { bucket in
            guard let v = buckets[bucket] else { return nil }
            return GroupRow(id: "len\(bucket.rawValue)", name: bucket.title,
                            totals: Totals(input: v.tokens, calls: v.calls, cost: v.cost))
        }
    }

    /// Сводка по инструментам за период, по убыванию стоимости.
    static func summary(
        _ attributions: [ToolAttribution],
        pool: StringPool,
        bounds: (start: Double, end: Double)?,
        session: Int32? = nil
    ) -> [GroupRow] {
        var byTool: [Int32: (tokens: Int, cost: Double, calls: Int)] = [:]
        for a in attributions {
            if let b = bounds, a.timestamp < b.start || a.timestamp >= b.end { continue }
            if let session, a.session != session { continue }
            byTool[a.tool, default: (0, 0, 0)].tokens += a.addedTokens
            byTool[a.tool]!.cost += a.cost
            byTool[a.tool]!.calls += 1
        }
        return byTool
            .map { tool, v in
                GroupRow(id: "tc\(tool)", name: pool[tool],
                         totals: Totals(input: v.tokens, calls: v.calls, cost: v.cost))
            }
            .sorted { $0.totals.cost > $1.totals.cost }
    }
}
