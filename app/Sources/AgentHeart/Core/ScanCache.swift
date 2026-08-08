import Foundation

/// Кеш разбора: транскрипты append-only, поэтому при повторном скане читаем
/// только хвосты изменившихся файлов. Полный разбор 250 МБ занимает ~секунду,
/// инкрементальный — десятки миллисекунд.
struct ScanCache: Codable {
    static let currentVersion = 1

    struct FileEntry: Codable {
        var size: Int64
        var modified: Double
        var parsedBytes: Int64
        var records: [CallRecord]
    }

    var version: Int = ScanCache.currentVersion
    var pool = StringPool()
    var files: [String: FileEntry] = [:]

    // MARK: - Хранилище

    static var url: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AgentHeart/scan-cache.plist")
    }

    static func load() -> ScanCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? PropertyListDecoder().decode(ScanCache.self, from: data),
              cache.version == currentVersion else {
            return ScanCache()
        }
        return cache
    }

    func save() {
        let url = Self.url
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            // Кеш — ускорение, а не источник правды: без него приложение
            // просто разберёт всё заново.
            FileHandle.standardError.write(
                Data("agent-heart: не удалось сохранить кеш: \(error)\n".utf8))
        }
    }
}

/// Результат полного прохода по транскриптам.
struct ScanResult {
    var records: [CallRecord]
    var pool: StringPool
    var fileCount: Int
    var duration: TimeInterval
    /// Время самого раннего вызова. Раньше него сравнивать периоды нельзя —
    /// «пусто» там означает «не было учёта», а не «не тратили».
    var earliest: Double?
}

enum TranscriptLoader {

    /// Возвращает дедуплицированный список вызовов и обновляет кеш на диске.
    static func scan(using cache: inout ScanCache) -> ScanResult {
        let started = Date()
        let files = TranscriptScanner.transcriptFiles()
        let fm = FileManager.default
        var pool = cache.pool
        var fresh: [String: ScanCache.FileEntry] = [:]
        fresh.reserveCapacity(files.count)

        for url in files {
            let path = url.path
            guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let cached = cache.files[path]

            if let cached, cached.size == size, cached.modified == modified {
                fresh[path] = cached                      // файл не трогали
                continue
            }
            if let cached, size > cached.size, cached.parsedBytes <= size {
                let parse = TranscriptScanner.parse(url: url, from: cached.parsedBytes, pool: &pool)
                fresh[path] = ScanCache.FileEntry(
                    size: size, modified: modified,
                    parsedBytes: parse.parsedBytes,
                    records: cached.records + parse.records)   // дочитали хвост
                continue
            }
            let parse = TranscriptScanner.parse(url: url, from: 0, pool: &pool)
            fresh[path] = ScanCache.FileEntry(
                size: size, modified: modified,
                parsedBytes: parse.parsedBytes, records: parse.records)
        }

        cache.files = fresh
        cache.pool = pool

        // Дедуп сквозной по всем файлам: один и тот же вызов встречается
        // в транскриптах резюмированных сессий.
        var seen = Set<UInt64>()
        var records: [CallRecord] = []
        records.reserveCapacity(fresh.values.reduce(0) { $0 + $1.records.count })
        for path in fresh.keys.sorted() {
            for r in fresh[path]!.records {
                if r.dedupKey != 0, !seen.insert(r.dedupKey).inserted { continue }
                records.append(r)
            }
        }
        records.sort { $0.timestamp < $1.timestamp }

        return ScanResult(records: records, pool: pool, fileCount: files.count,
                          duration: Date().timeIntervalSince(started),
                          earliest: records.first?.timestamp)
    }
}
