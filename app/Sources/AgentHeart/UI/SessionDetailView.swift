import SwiftUI

/// Карточка одной сессии: что в ней происходило.
/// Период тут не применяется — открыли сессию, показываем ее целиком.
struct SessionDetailView: View {
    let detail: SessionDetail

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMMM yyyy, HH:mm"
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()

    private var totals: Totals { detail.row.totals }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                kpis
                toolsSection
                timelineSection
                inputBreakdown
                modelsSection
                kindsSection
            }
            .padding(.horizontal, 30)
            .padding(.top, 22)
            .padding(.bottom, 50)
            .frame(maxWidth: 1250, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(detail.row.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if detail.row.titleSource != .none {
                    Text(detail.row.titleSource.badge)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.muted2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Theme.line, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            Text("\(Self.dateFormatter.string(from: detail.row.first)) · "
                 + "\(detail.row.durationText) · \((detail.project as NSString).lastPathComponent)")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted2)
        }
    }

    private var kpis: some View {
        HStack(spacing: 12) {
            KPITile(value: Fmt.tokens(totals.total), label: "токенов")
            KPITile(value: Fmt.money(totals.cost, decimals: 2), label: "оценка по API-прайсу")
            KPITile(value: Fmt.count(totals.calls), label: "API-вызовов")
            KPITile(value: Fmt.count(toolCalls), label: "обращений к инструментам")
        }
        .padding(.top, 20)
    }

    private var toolCalls: Int {
        detail.tools.reduce(0) { $0 + $1.totals.calls }
    }

    /// Главное на этом экране: чем сессия занималась, а не сколько съела.
    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Чем занималась")
            if detail.tools.isEmpty {
                Text("Инструменты не вызывались — сессия только переписывалась.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted2)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 7) {
                    ForEach(detail.tools) { tool in
                        MeterRow(label: tool.name, value: tool.totals.calls,
                                 fraction: Double(tool.totals.calls) / Double(max(topToolCalls, 1)))
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
    }

    private var topToolCalls: Int { detail.tools.first?.totals.calls ?? 1 }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Ход сессии по часам")
            UsageChart(buckets: detail.buckets, granularity: .hour, showAverageHint: false)
        }
    }

    private var inputBreakdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Из чего состоит вход")
            VStack(spacing: 7) {
                ForEach(breakdownRows, id: \.0) { label, value in
                    MeterRow(label: label, value: value,
                             fraction: totals.total > 0
                                ? Double(value) / Double(totals.total) : 0)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var breakdownRows: [(String, Int)] {
        [("input (свежий)", totals.input),
         ("cache write 5m", totals.cacheWrite5m),
         ("cache write 1h", totals.cacheWrite1h),
         ("cache read", totals.cacheRead),
         ("output", totals.output)]
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "По моделям")
            BucketTable(
                rows: detail.models,
                nameHeader: "модель",
                columns: [
                    TableColumn("$") { Fmt.money($0.totals.cost) },
                    TableColumn("вызовов") { Fmt.count($0.totals.calls) },
                ]
            )
        }
    }

    private var kindsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Главный цикл vs сабагенты")
            BucketTable(
                rows: detail.kinds,
                nameHeader: "тип",
                columns: [
                    TableColumn("$") { Fmt.money($0.totals.cost) },
                    TableColumn("вызовов") { Fmt.count($0.totals.calls) },
                ]
            )
        }
    }
}
