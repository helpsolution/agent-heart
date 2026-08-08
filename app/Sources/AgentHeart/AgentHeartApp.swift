import SwiftUI

/// Точка входа. Кроме окна умеет headless-самопроверку — она сверяет движок
/// с analyzer/cc_dashboard.py без запуска GUI.
@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            let next = args[i + 1]
            return next.hasPrefix("--") ? nil : next
        }

        if args.contains("--selftest") {
            SelfTest.run(argument: value(after: "--selftest"))
            return
        }
        if let path = value(after: "--snapshot") {
            // ImageRenderer живёт на главном акторе и требует поднятого NSApp.
            NSApplication.shared.setActivationPolicy(.prohibited)
            MainActor.assumeIsolated {
                SnapshotRenderer.run(path: path, presetName: value(after: "--range"))
            }
            return
        }
        AgentHeartApp.main()
    }
}

struct AgentHeartApp: App {
    @StateObject private var store = UsageStore()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup("agent-heart") {
            OverviewView(store: store, settings: settings)
                .frame(minWidth: 900, minHeight: 640)
                .preferredColorScheme(.dark)
                // Интерфейс русский — оси графика и даты тоже должны быть
                // русскими и 24-часовыми, независимо от языка системы.
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .task { store.start() }
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Обновить") { store.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        // Штатное меню «agent-heart → Настройки…» (⌘,)
        Settings {
            SettingsView(settings: settings)
                .preferredColorScheme(.dark)
                .environment(\.locale, Locale(identifier: "ru_RU"))
        }
    }
}
