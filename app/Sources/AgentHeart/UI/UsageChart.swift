import SwiftUI
import Charts

/// График расхода по времени. Шаг разбивки задается снаружи: за сутки это
/// часы, за месяц — дни, за все время — месяцы.
struct UsageChart: View {
    let buckets: [GroupRow]
    let granularity: Granularity
    var showAverageHint = true
    @State private var selectedDate: Date?

    private var selectedRow: GroupRow? {
        guard let selectedDate else { return nil }
        let cal = Calendar.current
        return buckets.first { row in
            guard let date = row.date else { return false }
            return cal.isDate(date, equalTo: selectedDate, toGranularity: granularity.chartUnit)
        }
    }

    /// Средний расход на корзину — показывается подписью над графиком.
    private var average: Double {
        guard !buckets.isEmpty else { return 0 }
        var sum = 0
        for row in buckets { sum += row.totals.total }
        return Double(sum) / Double(buckets.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            readout
            chart
        }
    }

    private var readout: some View {
        HStack(spacing: 14) {
            if let row = selectedRow {
                Text(row.name)
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(Theme.accent2)
                Text("\(Fmt.tokens(row.totals.total)) токенов")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.text)
                Text(Fmt.money(row.totals.cost))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.text)
                Text("\(Fmt.count(row.totals.calls)) вызовов")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.muted)
            } else if showAverageHint {
                Text("в среднем \(Fmt.tokens(Int(average))) \(granularity.averageSuffix)"
                     + " · наведи на столбец для точных цифр")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted2)
            }
            Spacer()
        }
        .frame(height: 16)
    }

    private var chart: some View {
        Chart {
            ForEach(buckets) { row in
                if let date = row.date {
                    BarMark(
                        x: .value("период", date, unit: granularity.chartUnit),
                        y: .value("токены", row.totals.total)
                    )
                    .foregroundStyle(isSelected(row) ? Theme.accent2 : Theme.accent)
                    .cornerRadius(2)
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text(Fmt.tokens(v))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.muted2)
                    }
                }
            }
        }
        .chartXAxis {
            if granularity == .month {
                // Автоделения на месячном графике подписываются днями
                // («13 июля»), что для столбца-месяца бессмысленно.
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine().foregroundStyle(Theme.line.opacity(0.6))
                    AxisValueLabel(format: .dateTime.month(.abbreviated).year())
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.muted2)
                }
            } else {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.line.opacity(0.6))
                    AxisValueLabel()
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.muted2)
                }
            }
        }
        .frame(height: 190)
        .padding(.top, 4)
    }

    private func isSelected(_ row: GroupRow) -> Bool {
        guard let selectedDate, let date = row.date else { return false }
        return Calendar.current.isDate(date, equalTo: selectedDate,
                                       toGranularity: granularity.chartUnit)
    }
}
