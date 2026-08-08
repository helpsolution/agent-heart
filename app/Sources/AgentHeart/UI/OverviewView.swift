import SwiftUI

/// Строка статуса в шапке.
struct ScanStatus {
    var isScanning = false
    var fileCount = 0
    var duration: TimeInterval = 0
    var priceError: String?
}

/// Окно приложения.
/// Куда провалились с «Обзора».
enum Route: Hashable {
    case project(String)
    case session(Int32)
}

struct OverviewView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
        }
        .background(Theme.bg)
    }

    private var root: some View {
        ScrollView {
            OverviewContent(
                snapshot: store.snapshot,
                previous: store.previous,
                range: $store.range,
                showDeltaBadges: settings.showDeltaBadges,
                showAverageHint: settings.showAverageHint,
                status: ScanStatus(
                    isScanning: store.isScanning,
                    fileCount: store.fileCount,
                    duration: store.lastScanDuration,
                    priceError: store.priceError
                ),
                toolCosts: settings.showToolCosts ? store.toolCostSummary() : [],
                toolCostCoverage: store.toolCostCoverage,
                topToolCalls: settings.showToolCosts ? store.topToolCalls() : [],
                toolCostByLength: settings.showToolCosts ? store.toolCostByLength() : [],
                onOpenSession: { path.append(.session($0)) },
                onOpenProject: { path.append(.project($0)) }
            )
        }
        .background(Theme.bg)
        .navigationTitle("Расход токенов")
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .project(let projectPath):
            ProjectDetailView(projectPath: projectPath, store: store) {
                path.append(.session($0))
            }
            .navigationTitle((projectPath as NSString).lastPathComponent)
        case .session(let session):
            if let detail = store.detail(forSession: session) {
                SessionDetailView(detail: detail)
                    .navigationTitle(detail.row.title)
            } else {
                // Сессия могла исчезнуть между открытием и перерисовкой:
                // транскрипты живые, кеш мог обновиться.
                Text("Сессия не найдена")
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg)
            }
        }
    }
}

/// Содержимое вкладки «Обзор». Зависит только от данных, поэтому его можно
/// отрендерить и без окна — см. `--snapshot`.
struct OverviewContent: View {
    let snapshot: OverviewSnapshot
    var previous: Totals?
    @Binding var range: DateRange
    var showDeltaBadges = true
    var showAverageHint = true
    var status = ScanStatus()
    var toolCosts: [GroupRow] = []
    var toolCostCoverage = ToolCostCoverage()
    var topToolCalls: [ExpensiveCall] = []
    var toolCostByLength: [GroupRow] = []
    var onOpenSession: ((Int32) -> Void)?
    /// nil — строки проектов не кликабельны (например, в режиме --snapshot).
    var onOpenProject: ((String) -> Void)?

    private var snap: OverviewSnapshot { snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            RangePicker(range: $range).padding(.top, 14)

            if let priceError = status.priceError {
                NoticeBanner(text: priceError + " Токены считаются, деньги — нет.", isError: true)
                    .padding(.top, 16)
            }

            if snap.isEmpty {
                emptyState
            } else {
                kpis
                chartSection
                inputBreakdown
                projects
                toolCostSection
                models
                kinds
                bucketsTable
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 22)
        .padding(.bottom, 50)
        .frame(maxWidth: 1250, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Расход токенов Claude Code")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(range.subtitle())
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted2)
            }
            Spacer()
            statusBadge
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            if status.isScanning {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("считаю…")
            } else {
                Circle().fill(Color.green.opacity(0.8)).frame(width: 6, height: 6)
                Text("\(status.fileCount) файлов · "
                     + String(format: "%.0f мс", status.duration * 1000))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.muted2)
        .help("Данные обновляются сами, как только Claude Code дописывает транскрипты")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(status.isScanning ? "Читаю транскрипты…" : "За выбранный период вызовов нет")
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
            if !status.isScanning {
                Text("Попробуй другой диапазон дат.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: - KPI

    /// Один ряд на всю ширину. LazyVGrid с адаптивными колонками при широком
    /// окне нарезал больше колонок, чем плиток, и ряд не добирал до края —
    /// поэтому здесь явный HStack с равными долями.
    private var kpis: some View {
        HStack(spacing: 12) {
            KPITile(value: Fmt.tokens(snap.overall.total),
                    label: "всего токенов",
                    delta: delta(\.total))
            KPITile(value: Fmt.money(snap.overall.cost, decimals: 0),
                    label: "оценка по API-прайсу",
                    delta: deltaCost)
            KPITile(value: Fmt.count(snap.overall.calls),
                    label: "API-вызовов",
                    delta: delta(\.calls))
            KPITile(value: Fmt.count(snap.sessionCount), label: "сессий")
            KPITile(value: Fmt.count(snap.projectCount), label: "проектов")
            KPITile(value: String(format: "%.0f%%", snap.cacheShare),
                    label: "доля кеш-чтений во входе")
        }
        .padding(.top, 20)
    }

    /// nil — сравнивать не с чем (режим «все время», пустой прошлый период)
    /// или значки выключены в настройках.
    private func delta(_ keyPath: KeyPath<Totals, Int>) -> Double? {
        guard showDeltaBadges, let previous else { return nil }
        let before = previous[keyPath: keyPath]
        guard before > 0 else { return nil }
        let now = snap.overall[keyPath: keyPath]
        return Double(now - before) / Double(before)
    }

    private var deltaCost: Double? {
        guard showDeltaBadges, let previous, previous.cost > 0 else { return nil }
        return (snap.overall.cost - previous.cost) / previous.cost
    }

    // MARK: - Секции

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: snap.granularity.chartTitle)
            UsageChart(buckets: snap.buckets, granularity: snap.granularity,
                       showAverageHint: showAverageHint)
        }
    }

    private var inputBreakdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Из чего состоит вход")
            VStack(spacing: 7) {
                ForEach(breakdownRows, id: \.0) { label, value in
                    MeterRow(label: label, value: value, fraction: fraction(value))
                }
            }
            .frame(maxWidth: 760, alignment: .leading)

            Text("вход/выход ≈ \(String(format: "%.0f", snap.inputToOutputRatio)) : 1. "
                 + "Доля cache read \(String(format: "%.1f", snap.cacheShare))% — "
                 + "чем выше, тем дешевле обходится контекст (кеш не рвется).")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.top, 14)

            if !snap.modelsWithoutPrice.isEmpty {
                NoticeBanner(text: "нет прайса для: "
                             + snap.modelsWithoutPrice.joined(separator: ", ")
                             + " — токены учтены, деньги нет.")
                    .padding(.top, 12)
                    .frame(maxWidth: 820, alignment: .leading)
            }
        }
    }

    private func fraction(_ value: Int) -> Double {
        let total = snap.overall.total
        return total > 0 ? Double(value) / Double(total) : 0
    }

    private var breakdownRows: [(String, Int)] {
        [("input (свежий)", snap.overall.input),
         ("cache write 5m", snap.overall.cacheWrite5m),
         ("cache write 1h", snap.overall.cacheWrite1h),
         ("cache read", snap.overall.cacheRead),
         ("output", snap.overall.output)]
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "По проектам")
            BucketTable(
                rows: snap.projects,
                nameHeader: "проект",
                columns: [
                    TableColumn("$") { Fmt.money($0.totals.cost) },
                    TableColumn("вызовов") { Fmt.count($0.totals.calls) },
                    TableColumn("сессий") { Fmt.count($0.sessions.count) },
                ],
                // id строки проекта — это полный путь, он же ключ группировки.
                onSelect: onOpenProject.map { open in { row in open(row.id) } }
            )
        }
    }

    /// Эксперимент: во что обходятся инструменты. Прямой цены у них нет —
    /// платят за токены, которые их результаты тащат через всю сессию.
    @ViewBuilder
    private var toolCostSection: some View {
        if !toolCosts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Во что обошлись инструменты · оценка")
                BucketTable(
                    rows: Array(toolCosts.prefix(15)),
                    nameHeader: "инструмент",
                    columns: [
                        TableColumn("$") { Fmt.money($0.totals.cost) },
                        TableColumn("вызовов") { Fmt.count($0.totals.calls) },
                        TableColumn("$/вызов", width: 90) {
                            $0.totals.calls > 0
                                ? Fmt.money($0.totals.cost / Double($0.totals.calls))
                                : "—"
                        },
                    ]
                )
                expensiveCalls
                lengthBreakdown
                NoticeBanner(text: methodNote)
                    .padding(.top, 16)
                    .frame(maxWidth: 820, alignment: .leading)
            }
        }
    }

    /// Решения принимаются по выбросам, а не по средним: медианный вызов
    /// стоит доли цента, верхний процент дает четверть всех денег.
    @ViewBuilder
    private var expensiveCalls: some View {
        if !topToolCalls.isEmpty {
            SectionHeader(title: "Самые дорогие вызовы")
            VStack(spacing: 0) {
                ForEach(Array(topToolCalls.enumerated()), id: \.element.id) { index, call in
                    let stripe = index.isMultiple(of: 2) ? Color.clear : Theme.rowHover
                    if let onOpenSession {
                        Button { onOpenSession(call.session) } label: {
                            ExpensiveCallRow(call: call, clickable: true).background(stripe)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ExpensiveCallRow(call: call).background(stripe)
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Второй множитель стоимости: чем длиннее сессия, тем дольше живет
    /// каждый результат и тем чаще его перечитывают.
    @ViewBuilder
    private var lengthBreakdown: some View {
        if toolCostByLength.count > 1 {
            SectionHeader(title: "Стоимость и длина сессии")
            BucketTable(
                rows: toolCostByLength,
                nameHeader: "длина сессии",
                columns: [
                    TableColumn("$") { Fmt.money($0.totals.cost) },
                    TableColumn("вызовов") { Fmt.count($0.totals.calls) },
                    TableColumn("$/вызов", width: 90) {
                        $0.totals.calls > 0
                            ? Fmt.money($0.totals.cost / Double($0.totals.calls))
                            : "—"
                    },
                ]
            )
            Text("«$/вызов» здесь важнее суммы: он показывает, во сколько раз "
                 + "дороже обходится тот же вызов, если сделан в длинной сессии. "
                 + "Результат живет до конца сессии и перечитывается на каждом "
                 + "ее запросе.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.top, 10)
        }
    }

    private var methodNote: String {
        let pct = Int((toolCostCoverage.share * 100).rounded())
        return """
        Считается косвенно: у инструментов нет своей цены, платят за токены. \
        Результат вызова оседает в контексте и перечитывается на каждом \
        следующем запросе сессии — «токены» это его размер, «$» — запись в \
        кеш плюс все перечитывания до конца сессии. Размер результата в \
        транскрипте не записан, он выводится из прироста контекста между \
        соседними вызовами.
        Оценено \(pct)% вызовов (\(Fmt.count(toolCostCoverage.attributed)) из \
        \(Fmt.count(toolCostCoverage.total))). Не попали: вызовы сабагентов — \
        у них свой контекст, и прирост через границу потока не значит ничего; \
        последний ход сессии — не с чем сравнить; компактизация контекста не \
        учитывается, поэтому длинные сессии скорее завышены.
        """
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "По моделям")
            BucketTable(
                rows: snap.models,
                nameHeader: "модель",
                columns: [
                    TableColumn("$") { Fmt.money($0.totals.cost) },
                    TableColumn("вызовов") { Fmt.count($0.totals.calls) },
                ]
            )
        }
    }

    /// График показывает форму расхода, таблица — точные цифры по каждой
    /// корзине. Порядок хронологический, как на графике.
    private var bucketsTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: snap.granularity.tableTitle)
            BucketTable(
                rows: snap.buckets,
                nameHeader: snap.granularity.columnHeader,
                columns: [
                    TableColumn("$") { Fmt.money($0.totals.cost) },
                    TableColumn("вызовов") { Fmt.count($0.totals.calls) },
                ],
                monospacedName: true
            )
        }
    }

    private var kinds: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Главный цикл vs сабагенты")
            BucketTable(
                rows: snap.kinds,
                nameHeader: "тип",
                columns: [
                    TableColumn("$") { Fmt.money($0.totals.cost) },
                    TableColumn("вызовов") { Fmt.count($0.totals.calls) },
                ]
            )
        }
    }
}
