import SwiftUI

/// Настройки приложения. Хранятся в UserDefaults, переживают перезапуск.
///
/// Сюда выносится то, что вопрос вкуса, а не правильности: если непонятно,
/// нужен элемент или мешает, у него должен быть выключатель, а не спор.
@MainActor
final class AppSettings: ObservableObject {

    /// Значки роста/падения к предыдущему периоду на плитках («×2.0», «+81%»).
    @AppStorage("showDeltaBadges") var showDeltaBadges = true

    /// Подпись «в среднем … в день» над графиком.
    @AppStorage("showAverageHint") var showAverageHint = true

    /// Эксперимент: во что обходятся инструменты. По умолчанию выключен —
    /// это оценка по косвенным данным, а не измерение, и полезность ее
    /// пока не доказана.
    @AppStorage("showToolCosts") var showToolCosts = false
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Сравнение с предыдущим периодом", isOn: $settings.showDeltaBadges)
                Text("Значки «×2.0» и «+81%» на плитках. Сравнение идет с таким же "
                     + "по длине периодом перед выбранным. Для «всего времени» и когда "
                     + "предыдущий период старше первых данных не показывается в любом случае.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Плитки")
            }

            Section {
                Toggle("Подпись со средним", isOn: $settings.showAverageHint)
                Text("Строка «в среднем … в день» над графиком.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("График")
            }

            Section {
                Toggle("Стоимость инструментов", isOn: $settings.showToolCosts)
                Text("Три секции в «Обзоре»: во что обошлись инструменты, самые "
                     + "дорогие отдельные вызовы и стоимость в разрезе длины сессии.\n"
                     + "Это оценка по косвенным данным, а не измерение: у инструментов "
                     + "нет своей цены, размер их результатов в транскрипте не записан "
                     + "и выводится из прироста контекста. Методика и доля оцененных "
                     + "вызовов показаны под таблицей.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Эксперименты")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
