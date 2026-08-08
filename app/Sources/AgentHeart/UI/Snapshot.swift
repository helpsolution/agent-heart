import SwiftUI
import AppKit

/// `AgentHeart --snapshot out.png [--range last30]` — рендерит вкладку «Обзор»
/// в файл без открытия окна. Нужно, чтобы проверять верстку в автоматическом
/// режиме и прикладывать картинку к отчетам.
@MainActor
enum SnapshotRenderer {

    static func run(path: String, presetName: String?, forceToolCosts: Bool = false,
                    width: CGFloat = 1180) {
        var cache = ScanCache.load()
        let result = TranscriptLoader.scan(using: &cache)
        cache.save()

        var priceError: String?
        var prices: PriceTable?
        do { prices = try PriceTable.load() }
        catch { priceError = error.localizedDescription }

        var range = DateRange.default()
        if let presetName, let preset = RangePreset(rawValue: presetName) {
            range.preset = preset
        }

        let projectPaths = ProjectResolver.canonicalPaths(
            pool: result.pool, indices: Set(result.records.map(\.project)))
        let snapshot = Aggregator.snapshot(records: result.records, pool: result.pool,
                                           prices: prices, bounds: range.bounds(),
                                           granularity: range.granularity(),
                                           projectPaths: projectPaths)
        let previous = range.comparableBounds(earliestRecord: result.earliest).map {
            Aggregator.totals(records: result.records, pool: result.pool,
                              prices: prices, bounds: $0)
        }

        // Снимок показывает то же, что и окно. Настройку читаем из тех же
        // UserDefaults, но голый бинарник запускается без Info.plist и попадает
        // в другой домен, чем бандл, — поэтому есть явный флаг --tool-costs.
        let showToolCosts = forceToolCosts
            || UserDefaults.standard.bool(forKey: "showToolCosts")
        let toolCosts = showToolCosts
            ? ToolCostEstimator.estimate(records: result.records, tools: result.tools,
                                         pool: result.pool, prices: prices)
            : ToolCostEstimator.Result()
        let titles = TitleIndex(custom: result.customTitles, ai: result.aiTitles,
                                prompts: result.firstPrompts)

        let content = OverviewContent(
            snapshot: snapshot,
            previous: previous,
            range: .constant(range),
            status: ScanStatus(isScanning: false, fileCount: result.fileCount,
                               duration: result.duration, priceError: priceError),
            toolCosts: ToolCostEstimator.summary(toolCosts.attributions, pool: result.pool,
                                                 bounds: range.bounds()),
            toolCostCoverage: toolCosts.coverage,
            topToolCalls: ToolCostEstimator
                .topCalls(toolCosts.attributions, bounds: range.bounds(), limit: 12)
                .map { a in
                    ExpensiveCall(
                        id: "\(a.session)-\(a.timestamp)-\(a.tool)",
                        tool: result.pool[a.tool], tokens: a.addedTokens, cost: a.cost,
                        session: a.session,
                        sessionTitle: titles.title(for: a.session).text,
                        threadLength: a.threadLength, remainingTurns: a.remainingTurns,
                        date: Date(timeIntervalSince1970: a.timestamp))
                },
            toolCostByLength: ToolCostEstimator.byLength(toolCosts.attributions,
                                                         bounds: range.bounds())
        )
        .frame(width: width)
        .background(Theme.bg)
        .environment(\.colorScheme, .dark)
        // Та же локаль, что и в окне, иначе снимок врет про оформление осей.
        .environment(\.locale, Locale(identifier: "ru_RU"))

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("не удалось отрендерить снимок\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("снимок: \(path) (\(Int(image.size.width))×\(Int(image.size.height)) pt, "
                  + "период: \(range.preset.rawValue))")
        } catch {
            FileHandle.standardError.write(Data("не записан \(path): \(error)\n".utf8))
            exit(1)
        }
    }
}
