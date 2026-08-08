import SwiftUI

/// Плитка KPI. Дельта считается к такому же по длине предыдущему периоду;
/// для «всего времени» сравнивать не с чем, поэтому она просто не рисуется.
struct KPITile: View {
    let value: String
    let label: String
    var delta: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let delta { deltaBadge(delta) }
            }
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                // Место под две строки резервируется всегда: иначе плитки с
                // длинной подписью выше соседних и ряд разъезжается.
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.line2, lineWidth: 1))
    }

    /// Рост расхода — не «хорошо» и не «плохо», поэтому цвет нейтрально-
    /// информативный: теплый на рост, холодный на снижение.
    private func deltaBadge(_ delta: Double) -> some View {
        let up = delta >= 0
        // Кратный рост процентами не читается: «×12» понятнее, чем «+1150%».
        let text: String
        if delta >= 1 {
            text = String(format: "×%.1f", delta + 1)
        } else {
            text = String(format: "%.0f%%", abs(delta) * 100)
        }
        return HStack(spacing: 1) {
            Image(systemName: up ? "arrow.up" : "arrow.down")
                .font(.system(size: 8, weight: .bold))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(up ? Color.orange.opacity(0.95) : Theme.accent2)
        .help(up ? "больше, чем за предыдущий такой же период"
                 : "меньше, чем за предыдущий такой же период")
    }
}

/// Заголовок секции — аналог <h2> в дашборде.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .regular))
            .tracking(1.1)
            .foregroundStyle(Theme.muted)
            .padding(.top, 26)
            .padding(.bottom, 8)
    }
}

/// Строка «из чего состоит вход»: подпись, число, полоса.
struct MeterRow: View {
    let label: String
    let value: Int
    let fraction: Double

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .frame(width: 130, alignment: .leading)
            Text(Fmt.count(value))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(width: 110, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule().fill(Theme.accent)
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 10)
        }
    }
}

/// Колонка таблицы, описанная данными, — чтобы не плодить почти одинаковые вьюхи.
struct TableColumn: Identifiable {
    let id = UUID()
    let title: String
    let width: CGFloat?
    let alignment: Alignment
    let value: (GroupRow) -> String

    init(_ title: String, width: CGFloat? = nil, alignment: Alignment = .trailing,
         value: @escaping (GroupRow) -> String) {
        self.title = title
        self.width = width
        self.alignment = alignment
        self.value = value
    }
}

/// Таблица со встроенной полосой доли — основной строительный блок «Обзора».
struct BucketTable: View {
    let rows: [GroupRow]
    let nameHeader: String
    let columns: [TableColumn]
    var monospacedName = false
    /// Если задан — строки кликабельны и проваливают вглубь.
    var onSelect: ((GroupRow) -> Void)?

    private var maxTotal: Int {
        max(rows.map(\.totals.total).max() ?? 1, 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let stripe = index.isMultiple(of: 2) ? Color.clear : Theme.rowHover
                if let onSelect {
                    Button { onSelect(row) } label: {
                        rowView(row, clickable: true).background(stripe)
                    }
                    .buttonStyle(.plain)
                } else {
                    rowView(row).background(stripe)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(nameHeader.uppercased())
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("ТОКЕНЫ").frame(width: 80, alignment: .trailing)
            Color.clear.frame(width: 120, height: 1)
            ForEach(columns) { col in
                Text(col.title.uppercased())
                    .frame(width: col.width ?? 80, alignment: col.alignment)
            }
            if onSelect != nil { Color.clear.frame(width: 12, height: 1) }
        }
        .font(.system(size: 11, weight: .medium))
        .tracking(0.6)
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panel)
    }

    private func rowView(_ row: GroupRow, clickable: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(row.name)
                .font(monospacedName
                      ? .system(size: 13).monospaced()
                      : .system(size: 13))
                .foregroundStyle(monospacedName ? Theme.muted : Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.name)

            Text(Fmt.tokens(row.totals.total))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(width: 80, alignment: .trailing)

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line).frame(height: 8)
                Capsule().fill(Theme.accent)
                    .frame(width: 120 * min(1, Double(row.totals.total) / Double(maxTotal)),
                           height: 8)
            }
            .frame(width: 120)

            ForEach(columns) { col in
                Text(col.value(row))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.text)
                    .frame(width: col.width ?? 80, alignment: col.alignment)
            }
            if clickable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.muted2)
                    .frame(width: 12)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Полоса-предупреждение (нет прайса, не найден prices.json и т.п.).
struct NoticeBanner: View {
    let text: String
    var isError = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(isError ? Color.orange : Theme.muted)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isError ? Color.orange.opacity(0.4) : Theme.line2, lineWidth: 1))
    }
}
