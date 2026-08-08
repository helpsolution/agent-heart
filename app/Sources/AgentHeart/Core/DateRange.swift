import Foundation

/// Выбранный период. Границы считаются по локальному календарю — «сегодня»
/// должно означать сегодня у пользователя, а не в UTC.
enum RangePreset: String, CaseIterable, Identifiable, Codable {
    case today
    case last7
    case last30
    case thisMonth
    case all
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today:     return "Сегодня"
        case .last7:     return "7 дней"
        case .last30:    return "30 дней"
        case .thisMonth: return "Этот месяц"
        case .all:       return "Все время"
        case .custom:    return "Период…"
        }
    }
}

/// Шаг разбивки для графика и таблицы. Зависит от длины периода: за сутки
/// нужны часы, за месяц — дни, за все время — месяцы.
enum Granularity {
    case hour
    case day
    case month

    var chartUnit: Calendar.Component {
        switch self {
        case .hour:  return .hour
        case .day:   return .day
        case .month: return .month
        }
    }

    /// Формат подписи в таблице. Моноширинный столбец, поэтому фиксированная
    /// ширина важнее красоты.
    var labelFormat: String {
        switch self {
        case .hour:  return "HH:mm"
        case .day:   return "yyyy-MM-dd"
        case .month: return "yyyy-MM"
        }
    }

    var chartTitle: String {
        switch self {
        case .hour:  return "Расход по часам"
        case .day:   return "Расход по дням"
        case .month: return "Расход по месяцам"
        }
    }

    var tableTitle: String {
        switch self {
        case .hour:  return "По часам"
        case .day:   return "По дням"
        case .month: return "По месяцам"
        }
    }

    var columnHeader: String {
        switch self {
        case .hour:  return "час"
        case .day:   return "дата"
        case .month: return "месяц"
        }
    }

    /// «в среднем 12M …»
    var averageSuffix: String {
        switch self {
        case .hour:  return "в час"
        case .day:   return "в день"
        case .month: return "в месяц"
        }
    }

}

struct DateRange: Equatable {
    var preset: RangePreset
    /// Включительно, начало суток.
    var customStart: Date
    /// Включительно, разворачивается до конца этих суток.
    var customEnd: Date

    static func `default`() -> DateRange {
        let now = Date()
        let cal = Calendar.current
        return DateRange(
            preset: .all,
            customStart: cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!,
            customEnd: now
        )
    }

    /// nil — фильтровать не нужно (все время).
    /// Иначе полуинтервал [start, end): end — начало следующих после конечных суток.
    func bounds(now: Date = Date(), calendar: Calendar = .current) -> (start: Double, end: Double)? {
        let today = calendar.startOfDay(for: now)
        // Конец «сегодня» берем с запасом: записи могут прийти с часами вперед,
        // если системное время уплыло, и терять их не хочется.
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: today)!

        switch preset {
        case .all:
            return nil
        case .today:
            return (today.timeIntervalSince1970, endOfToday.timeIntervalSince1970)
        case .last7:
            let start = calendar.date(byAdding: .day, value: -6, to: today)!
            return (start.timeIntervalSince1970, endOfToday.timeIntervalSince1970)
        case .last30:
            let start = calendar.date(byAdding: .day, value: -29, to: today)!
            return (start.timeIntervalSince1970, endOfToday.timeIntervalSince1970)
        case .thisMonth:
            let comps = calendar.dateComponents([.year, .month], from: today)
            let start = calendar.date(from: comps) ?? today
            return (start.timeIntervalSince1970, endOfToday.timeIntervalSince1970)
        case .custom:
            let lo = calendar.startOfDay(for: min(customStart, customEnd))
            let hiDay = calendar.startOfDay(for: max(customStart, customEnd))
            let hi = calendar.date(byAdding: .day, value: 1, to: hiDay)!
            return (lo.timeIntervalSince1970, hi.timeIntervalSince1970)
        }
    }

    /// Такой же по длине период, вплотную перед текущим — для сравнения
    /// «стало / было». Для «все время» сравнивать не с чем.
    func previousBounds(now: Date = Date(), calendar: Calendar = .current)
        -> (start: Double, end: Double)? {
        guard let b = bounds(now: now, calendar: calendar) else { return nil }
        let span = b.end - b.start
        guard span > 0 else { return nil }
        return (b.start - span, b.start)
    }

    /// Шаг разбивки под текущий период. Для произвольного диапазона считаем
    /// по его длине: сутки-двое — часы, до квартала — дни, дальше — месяцы.
    func granularity(now: Date = Date(), calendar: Calendar = .current) -> Granularity {
        switch preset {
        case .today:
            return .hour
        case .last7, .last30, .thisMonth:
            return .day
        case .all:
            return .month
        case .custom:
            guard let b = bounds(now: now, calendar: calendar) else { return .day }
            let days = (b.end - b.start) / 86_400
            if days <= 2 { return .hour }
            if days <= 92 { return .day }
            return .month
        }
    }

    /// Предыдущий период, пригодный для сравнения. Возвращает nil, если он
    /// начинается раньше первых данных: там «пусто» означает «учета еще не
    /// было», и рост вида +999% был бы враньем.
    func comparableBounds(earliestRecord: Double?,
                          now: Date = Date(),
                          calendar: Calendar = .current) -> (start: Double, end: Double)? {
        guard let prev = previousBounds(now: now, calendar: calendar),
              let earliest = earliestRecord,
              prev.start >= earliest else { return nil }
        return prev
    }

    /// Человекочитаемая подпись под заголовком.
    func subtitle(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let b = bounds(now: now, calendar: calendar) else { return "за все время" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM yyyy"
        let start = Date(timeIntervalSince1970: b.start)
        let lastDay = calendar.date(byAdding: .day, value: -1,
                                    to: Date(timeIntervalSince1970: b.end)) ?? start
        if calendar.isDate(start, inSameDayAs: lastDay) {
            return f.string(from: start)
        }
        return "\(f.string(from: start)) — \(f.string(from: lastDay))"
    }
}
