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
        // схлопывания подпапок в репозитории — иначе счётчик проектов разойдётся
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
        if !snap.modelsWithoutPrice.isEmpty {
            print("без прайса: \(snap.modelsWithoutPrice.joined(separator: ", "))")
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
