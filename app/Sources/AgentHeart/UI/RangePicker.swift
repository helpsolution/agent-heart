import SwiftUI

/// Выбор периода: пресеты на каждый день + произвольный диапазон,
/// когда нужно посмотреть конкретные даты.
struct RangePicker: View {
    @Binding var range: DateRange

    private let presets: [RangePreset] = [.today, .last7, .last30, .thisMonth, .all]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(presets) { preset in
                    presetButton(preset)
                }
                Divider().frame(height: 18).overlay(Theme.line2)
                presetButton(.custom)
            }

            if range.preset == .custom {
                HStack(spacing: 10) {
                    DatePicker("с", selection: $range.customStart, displayedComponents: .date)
                    DatePicker("по", selection: $range.customEnd, displayedComponents: .date)
                    Spacer()
                }
                .datePickerStyle(.field)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: 460)
            }
        }
    }

    private func presetButton(_ preset: RangePreset) -> some View {
        let selected = range.preset == preset
        return Button {
            range.preset = preset
        } label: {
            Text(preset.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.text : Theme.muted)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(selected ? Theme.panel : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Theme.line2 : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
