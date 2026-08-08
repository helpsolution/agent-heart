import Foundation

/// `AgentHeart --selftest` — печатает те же итоги, что и analyzer/cc_dashboard.py.
/// Нужен, чтобы расхождение движков ловилось сразу, а не глазами по дашборду.
enum SelfTest {

    static func run(argument dayFilter: String?) {
        var cache = ScanCache.load()
        let result = TranscriptLoader.scan(using: &cache)
        cache.save()

        let prices: PriceTable?
        do {
            prices = try PriceTable.load()
            print("прайс-лист: \(prices!.sourcePath)")
        } catch {
            prices = nil
            print("ПРАЙС-ЛИСТ НЕ ЗАГРУЖЕН: \(error.localizedDescription)")
        }

        // projectPaths намеренно пустой: сверяемся с Python «как есть», без
        // схлопывания подпапок в репозитории — иначе счетчик проектов разойдется
        // не из-за ошибки, а из-за более умной группировки в приложении.
        let snap = Aggregator.snapshot(records: result.records, pool: result.pool,
                                       prices: prices, bounds: nil)

        print(String(format: "файлов: %d · разбор: %.0f мс",
                     result.fileCount, result.duration * 1000))
        print("""
        вызовов: \(snap.overall.calls)
        сессий: \(snap.sessionCount)
        проектов: \(snap.projectCount)
        токенов: \(snap.overall.total)
        стоимость: \(String(format: "%.2f", snap.overall.cost))
        input=\(snap.overall.input) cw5=\(snap.overall.cacheWrite5m) \
        cw1h=\(snap.overall.cacheWrite1h) cr=\(snap.overall.cacheRead) out=\(snap.overall.output)
        """)
        let titled = Set(result.customTitles.keys)
            .union(result.aiTitles.keys).union(result.firstPrompts.keys)
        var byTool: [Int32: Int] = [:]
        for e in result.tools { byTool[e.tool, default: 0] += 1 }
        let top = byTool.sorted { $0.value > $1.value }.prefix(5)
            .map { "\(result.pool[$0.key]) \($0.value)" }
        print("""
        названий: \(titled.count) из \(snap.sessionCount) сессий \
        (свои \(result.customTitles.count), авто \(result.aiTitles.count), \
        промпт \(result.firstPrompts.count))
        обращений к инструментам: \(result.tools.count) из \(result.rawToolCount) сырых \
        (отброшено дублей: \(result.rawToolCount - result.tools.count))
        топ: \(top.joined(separator: ", "))
        """)

        if !snap.modelsWithoutPrice.isEmpty {
            print("без прайса: \(snap.modelsWithoutPrice.joined(separator: ", "))")
        }

        // Проверка пути проваливания: ключ проекта в «Обзоре» должен совпадать
        // с тем, по которому ищутся сессии, иначе список молча окажется пустым.
        let projectPaths = ProjectResolver.canonicalPaths(
            pool: result.pool, indices: Set(result.records.map(\.project)))
        let grouped = Aggregator.snapshot(records: result.records, pool: result.pool,
                                          prices: prices, bounds: nil,
                                          projectPaths: projectPaths)
        if let top = grouped.projects.first {
            let titles = TitleIndex(custom: result.customTitles, ai: result.aiTitles,
                                    prompts: result.firstPrompts)
            let sessions = SessionAggregator.sessions(
                records: result.records, pool: result.pool, prices: prices, bounds: nil,
                titles: titles, projectPath: top.id, projectPaths: projectPaths)
            print("\nпроект «\(top.name)»: \(sessions.count) сессий")
            for s in sessions.prefix(3) {
                print("  • \(s.title.prefix(60)) [\(s.titleSource.badge)] "
                      + "\(Fmt.tokens(s.totals.total)) · \(s.durationText)")
            }
            if let first = sessions.first,
               let detail = SessionAggregator.detail(
                    session: first.id, records: result.records, tools: result.tools,
                    pool: result.pool, prices: prices, titles: titles,
                    projectPaths: projectPaths) {
                let tools = detail.tools.prefix(4)
                    .map { "\($0.name) \($0.totals.calls)" }.joined(separator: ", ")
                print("  инструменты верхней сессии: \(tools.isEmpty ? "нет" : tools)")
            }
        }

        if let dayFilter {
            if let row = snap.buckets.first(where: { $0.name == dayFilter }) {
                print("\(dayFilter): токенов=\(row.totals.total) вызовов=\(row.totals.calls) "
                      + String(format: "$%.2f", row.totals.cost))
            } else {
                print("\(dayFilter): записей нет")
            }
        }
    }
}
