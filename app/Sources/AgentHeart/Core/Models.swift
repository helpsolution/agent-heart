import Foundation

/// Пул строк: проекты, сессии и модели повторяются в десятках тысяч записей,
/// поэтому храним их один раз, а в записях — индексы.
struct StringPool: Codable {
    private(set) var values: [String] = []
    private var index: [String: Int32] = [:]

    enum CodingKeys: String, CodingKey { case values }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        values = try c.decode([String].self, forKey: .values)
        index = Dictionary(uniqueKeysWithValues: values.enumerated().map { ($1, Int32($0)) })
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(values, forKey: .values)
    }

    mutating func intern(_ s: String) -> Int32 {
        if let i = index[s] { return i }
        let i = Int32(values.count)
        values.append(s)
        index[s] = i
        return i
    }

    subscript(_ i: Int32) -> String {
        i >= 0 && Int(i) < values.count ? values[Int(i)] : "—"
    }
}

/// Один оплачиваемый вызов API. Записей десятки тысяч, а не миллионы, поэтому
/// держим их все в памяти целиком — это позволяет пересчитать любой диапазон
/// дат мгновенно и без повторного разбора файлов.
struct CallRecord: Codable {
    var timestamp: Double        // epoch seconds
    var project: Int32
    var session: Int32
    var model: Int32
    var isSidechain: Bool
    var input: Int32
    var cacheWrite5m: Int32
    var cacheWrite1h: Int32
    var cacheRead: Int32
    var output: Int32
    /// Хэш пары (message.id, requestId) для сквозного дедупа между файлами.
    /// 0 — у записи не было ни того, ни другого, дедуп к ней не применяем.
    var dedupKey: UInt64
}

/// Суммы по произвольной группе вызовов.
struct Totals {
    var input = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0
    var output = 0
    var calls = 0
    var cost = 0.0

    var total: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }
    /// Всё, что тарифицируется как вход (без output).
    var billedInput: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }

    mutating func add(_ r: CallRecord, cost c: Double) {
        input += Int(r.input)
        cacheWrite5m += Int(r.cacheWrite5m)
        cacheWrite1h += Int(r.cacheWrite1h)
        cacheRead += Int(r.cacheRead)
        output += Int(r.output)
        calls += 1
        cost += c
    }
}

/// Строка сгруппированной таблицы (проект / модель / тип цикла / день).
struct GroupRow: Identifiable {
    let id: String
    let name: String
    var totals: Totals
    var sessions: Set<Int32> = []
    /// Заполняется только для дневных строк — нужна оси графика.
    var date: Date?
}

/// Готовые агрегаты под выбранный диапазон — всё, что рисует вкладка «Обзор».
struct OverviewSnapshot {
    var overall = Totals()
    var projects: [GroupRow] = []
    var models: [GroupRow] = []
    var kinds: [GroupRow] = []
    /// Разбивка по времени — часы, дни или месяцы, см. `granularity`.
    var buckets: [GroupRow] = []
    var granularity: Granularity = .day
    var sessionCount = 0
    var projectCount = 0
    var modelsWithoutPrice: [String] = []

    var isEmpty: Bool { overall.calls == 0 }

    /// Доля кеш-чтений во входе — чем выше, тем дешевле обходится контекст.
    var cacheShare: Double {
        let billed = overall.billedInput
        return billed > 0 ? Double(overall.cacheRead) / Double(billed) * 100 : 0
    }

    var inputToOutputRatio: Double {
        Double(overall.billedInput) / Double(max(overall.output, 1))
    }
}
