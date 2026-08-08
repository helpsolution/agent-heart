import SwiftUI

/// Карточка проекта: какие в нем были сессии за выбранный период.
/// Период наследуется с «Обзора» — открыл проект в режиме «7 дней»,
/// видишь сессии за 7 дней.
struct ProjectDetailView: View {
    let projectPath: String
    @ObservedObject var store: UsageStore
    let onOpenSession: (Int32) -> Void

    private var sessions: [SessionRow] {
        store.sessions(inProject: projectPath)
    }

    private var totals: Totals {
        var t = Totals()
        for s in sessions {
            t.input += s.totals.input
            t.cacheWrite5m += s.totals.cacheWrite5m
            t.cacheWrite1h += s.totals.cacheWrite1h
            t.cacheRead += s.totals.cacheRead
            t.output += s.totals.output
            t.calls += s.totals.calls
            t.cost += s.totals.cost
        }
        return t
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                kpis
                SectionHeader(title: "Сессии")
                if sessions.isEmpty {
                    Text("За выбранный период в этом проекте вызовов не было.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .padding(.vertical, 40)
                        .frame(maxWidth: .infinity)
                } else {
                    sessionList
                }
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
        VStack(alignment: .leading, spacing: 3) {
            Text((projectPath as NSString).lastPathComponent)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(projectPath)
                .font(.system(size: 12).monospaced())
                .foregroundStyle(Theme.muted2)
                .textSelection(.enabled)
            Text(store.range.subtitle())
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted2)
                .padding(.top, 2)
        }
    }

    private var kpis: some View {
        HStack(spacing: 12) {
            KPITile(value: Fmt.tokens(totals.total), label: "токенов")
            KPITile(value: Fmt.money(totals.cost, decimals: 0), label: "оценка по API-прайсу")
            KPITile(value: Fmt.count(totals.calls), label: "API-вызовов")
            KPITile(value: Fmt.count(sessions.count), label: "сессий")
        }
        .padding(.top, 20)
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                Button { onOpenSession(session.id) } label: {
                    SessionRowView(session: session, maxTotal: sessions[0].totals.total)
                        .background(index.isMultiple(of: 2) ? Color.clear : Theme.rowHover)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Одна строка списка сессий.
struct SessionRowView: View {
    let session: SessionRow
    let maxTotal: Int

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if session.titleSource != .none {
                        Text(session.titleSource.badge)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.muted2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.line, in: RoundedRectangle(cornerRadius: 3))
                    }
                    if session.hasSubagents {
                        Image(systemName: "person.2")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.muted2)
                            .help("в сессии работали сабагенты")
                    }
                }
                HStack(spacing: 8) {
                    Text(Self.dateFormatter.string(from: session.first))
                    Text("·")
                    Text(session.durationText)
                    Text("·")
                    Text(session.topModel)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted2)
                // Возобновленная сессия живет неделями, поэтому «152 ч» — это
                // не время работы, а размах от первого вызова до последнего.
                .help("начало сессии · от первого вызова до последнего · основная модель")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(Fmt.tokens(session.totals.total))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(width: 80, alignment: .trailing)

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line).frame(height: 8)
                Capsule().fill(Theme.accent)
                    .frame(width: 120 * min(1, Double(session.totals.total) / Double(max(maxTotal, 1))),
                           height: 8)
            }
            .frame(width: 120)

            Text(Fmt.money(session.totals.cost))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(width: 80, alignment: .trailing)

            Text(Fmt.count(session.totals.calls))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.muted)
                .frame(width: 70, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.muted2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}
