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
