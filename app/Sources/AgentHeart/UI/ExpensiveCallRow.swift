import SwiftUI

/// Строка списка самых дорогих вызовов. Показывает не только цену, но и то,
/// из чего она сложилась: размер результата и сколько ходов он потом жил.
struct ExpensiveCallRow: View {
    let call: ExpensiveCall
    var clickable = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(call.tool)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(Self.dateFormatter.string(from: call.date))
                    Text("·")
                    Text(call.sessionTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(Fmt.count(call.tokens))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(width: 90, alignment: .trailing)
                .help("размер результата в токенах")

            Text("×\(Fmt.count(call.remainingTurns))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.muted)
                .frame(width: 70, alignment: .trailing)
                .help("столько раз результат перечитывался до конца сессии "
                      + "(в потоке всего \(call.threadLength) вызовов)")

            Text(Fmt.money(call.cost))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(width: 80, alignment: .trailing)

            if clickable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.muted2)
                    .frame(width: 12)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
