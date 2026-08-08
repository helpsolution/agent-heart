import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot = OverviewSnapshot()
    /// Итоги предыдущего периода такой же длины. nil для «все время».
    @Published private(set) var previous: Totals?
    @Published private(set) var isScanning = false
    @Published private(set) var fileCount = 0
    @Published private(set) var lastScanDuration: TimeInterval = 0
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var priceError: String?

    @Published var range = DateRange.default() {
        didSet { if range != oldValue { recompute() } }
    }

    private var records: [CallRecord] = []
    private var tools: [ToolEvent] = []
    private var toolCosts = ToolCostEstimator.Result()
    private var titles = TitleIndex()

    /// Доля вызовов, для которых стоимость удалось оценить.
    var toolCostCoverage: ToolCostCoverage { toolCosts.coverage }
    private var earliest: Double?
    private var projectPaths: [Int32: String] = [:]
    private var pool = StringPool()
    private var prices: PriceTable?
    private var cache = ScanCache()
    private var watcher: DirectoryWatcher?
    private let scanQueue = DispatchQueue(label: "agent-heart.scan", qos: .userInitiated)
    private var scanInFlight = false
    private var rescanQueued = false

    init() {
        do {
            prices = try PriceTable.load()
        } catch {
            priceError = error.localizedDescription
        }
    }

    /// AGENT_HEART_DEBUG=1 — печатать в stderr, когда и почему пересчитываем.
    private static let debug = ProcessInfo.processInfo.environment["AGENT_HEART_DEBUG"] == "1"

    private static func log(_ message: String) {
        guard debug else { return }
        FileHandle.standardError.write(Data("[agent-heart] \(message)\n".utf8))
    }

    func start() {
        refresh()
        let paths = TranscriptScanner.roots().map(\.path)
        Self.log("слежу за: \(paths.joined(separator: ", "))")
        watcher = DirectoryWatcher(paths: paths) { [weak self] in
            Self.log("транскрипты изменились → пересчет")
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Перечитывает изменившиеся транскрипты. Пока скан идет, повторные
    /// вызовы схлопываются в один отложенный — FSEvents может дергать часто.
    func refresh() {
        guard !scanInFlight else { rescanQueued = true; return }
        scanInFlight = true
        isScanning = true

        var working = cache
        scanQueue.async { [weak self] in
            let result = TranscriptLoader.scan(using: &working)
            working.save()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cache = working
                self.records = result.records
                self.tools = result.tools
                self.titles = TitleIndex(custom: result.customTitles,
                                         ai: result.aiTitles,
                                         prompts: result.firstPrompts)
                self.pool = result.pool
                self.earliest = result.earliest
                self.projectPaths = ProjectResolver.canonicalPaths(
                    pool: result.pool, indices: Set(result.records.map(\.project)))
                self.toolCosts = ToolCostEstimator.estimate(
                    records: result.records, tools: result.tools,
                    pool: result.pool, prices: self.prices)
                self.fileCount = result.fileCount
                self.lastScanDuration = result.duration
                self.lastUpdated = Date()
                self.isScanning = false
                self.scanInFlight = false
                self.recompute()
                Self.log(String(format: "пересчет готов: %d вызовов, %.0f мс",
                                self.snapshot.overall.calls, result.duration * 1000))
                if self.rescanQueued {
                    self.rescanQueued = false
                    self.refresh()
                }
            }
        }
    }

    // MARK: - Проваливание в проект и сессию

    /// Сессии проекта за выбранный период.
    func sessions(inProject projectPath: String) -> [SessionRow] {
        SessionAggregator.sessions(
            records: records, pool: pool, prices: prices, bounds: range.bounds(),
            titles: titles, projectPath: projectPath, projectPaths: projectPaths)
    }

    func detail(forSession session: Int32) -> SessionDetail? {
        SessionAggregator.detail(
            session: session, records: records, tools: tools, pool: pool,
            prices: prices, titles: titles, projectPaths: projectPaths)
    }

    /// Инструменты по оценочной стоимости за выбранный период.
    func toolCostSummary(session: Int32? = nil) -> [GroupRow] {
        ToolCostEstimator.summary(toolCosts.attributions, pool: pool,
                                  bounds: session == nil ? range.bounds() : nil,
                                  session: session)
    }

    /// Самые дорогие отдельные вызовы за период — с названием сессии,
    /// чтобы можно было провалиться и посмотреть, что там произошло.
    func topToolCalls(limit: Int = 12) -> [ExpensiveCall] {
        ToolCostEstimator.topCalls(toolCosts.attributions, bounds: range.bounds(), limit: limit)
            .map { a in
                ExpensiveCall(
                    id: "\(a.session)-\(a.timestamp)-\(a.tool)",
                    tool: pool[a.tool],
                    tokens: a.addedTokens,
                    cost: a.cost,
                    session: a.session,
                    sessionTitle: titles.title(for: a.session).text,
                    threadLength: a.threadLength,
                    remainingTurns: a.remainingTurns,
                    date: Date(timeIntervalSince1970: a.timestamp))
            }
    }

    /// Стоимость в разрезе длины сессии.
    func toolCostByLength() -> [GroupRow] {
        ToolCostEstimator.byLength(toolCosts.attributions, bounds: range.bounds())
    }

    /// Итоги проекта за период — шапка его карточки.
    func totals(forProject projectPath: String) -> Totals {
        snapshot.projects.first { $0.id == projectPath }?.totals ?? Totals()
    }

    private func recompute() {
        snapshot = Aggregator.snapshot(
            records: records, pool: pool, prices: prices,
            bounds: range.bounds(), granularity: range.granularity(),
            projectPaths: projectPaths
        )
        previous = range.comparableBounds(earliestRecord: earliest).map {
            Aggregator.totals(records: records, pool: pool, prices: prices, bounds: $0)
        }
    }
}
