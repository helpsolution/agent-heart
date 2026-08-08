import Foundation

struct ModelPrice {
    let input: Double
    let cacheWrite5m: Double
    let cacheRead: Double
    let output: Double
}

enum PricingError: LocalizedError {
    case notFound([String])
    case malformed(String, String)

    var errorDescription: String? {
        switch self {
        case .notFound(let tried):
            return "Прайс-лист shared/prices.json не найден. Искал: " + tried.joined(separator: ", ")
        case .malformed(let path, let detail):
            return "Прайс-лист \(path) не разобран: \(detail)"
        }
    }
}

/// Прайс-лист моделей, общий с Python-анализатором (shared/prices.json).
/// Сознательно не содержит зашитых значений: молча разойтись с анализатором
/// хуже, чем честно сказать, что файла нет.
struct PriceTable {
    /// Отсортирован по длине ключа убыв. — как в Python, чтобы «opus-4-5»
    /// выигрывал у «opus-4».
    private let entries: [(key: String, price: ModelPrice)]
    let sourcePath: String

    static func load() throws -> PriceTable {
        var tried: [String] = []

        if let url = Bundle.main.url(forResource: "prices", withExtension: "json") {
            tried.append(url.path)
            if FileManager.default.fileExists(atPath: url.path) {
                return try PriceTable(contentsOf: url)
            }
        }
        if let env = ProcessInfo.processInfo.environment["AGENT_HEART_PRICES"] {
            tried.append(env)
            let url = URL(fileURLWithPath: env)
            if FileManager.default.fileExists(atPath: url.path) {
                return try PriceTable(contentsOf: url)
            }
        }
        // Дев-режим (`swift run`): поднимаемся от бинарника до корня репозитория.
        var dir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("shared/prices.json")
            tried.append(candidate.path)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try PriceTable(contentsOf: candidate)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw PricingError.notFound(tried)
    }

    init(contentsOf url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw PricingError.malformed(url.path, error.localizedDescription) }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PricingError.malformed(url.path, "верхний уровень не объект JSON")
        }
        guard let models = root["models"] as? [String: [String: Any]], !models.isEmpty else {
            throw PricingError.malformed(url.path, "нет непустой секции models")
        }

        var parsed: [(String, ModelPrice)] = []
        for (key, raw) in models {
            guard let input = raw["input"] as? Double,
                  let cw = raw["cacheWrite5m"] as? Double,
                  let cr = raw["cacheRead"] as? Double,
                  let out = raw["output"] as? Double else {
                throw PricingError.malformed(url.path, "битая запись модели '\(key)'")
            }
            parsed.append((key.lowercased(),
                           ModelPrice(input: input, cacheWrite5m: cw, cacheRead: cr, output: out)))
        }
        entries = parsed.sorted { $0.0.count > $1.0.count }
        sourcePath = url.path
    }

    /// Матчинг подстрокой, как в анализаторе: «claude-opus-4-5-20251101» → «opus-4-5».
    func price(for model: String) -> ModelPrice? {
        let m = model.lowercased()
        for e in entries where m.contains(e.key) { return e.price }
        return nil
    }

    /// nil — для модели нет прайса (например `<synthetic>`); токены считаем,
    /// деньги — нет.
    func cost(of r: CallRecord, price p: ModelPrice?) -> Double? {
        guard let p else { return nil }
        let input: Double = Double(r.input) * p.input
        let write5m: Double = Double(r.cacheWrite5m) * p.cacheWrite5m
        // 1h-запись тарифицируется как input × 2 — отдельной цены у неё нет.
        let write1h: Double = Double(r.cacheWrite1h) * p.input * 2
        let read: Double = Double(r.cacheRead) * p.cacheRead
        let output: Double = Double(r.output) * p.output
        return (input + write5m + write1h + read + output) / 1_000_000
    }
}
