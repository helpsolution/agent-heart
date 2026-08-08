import Foundation

/// Разбор транскриптов Claude Code (`~/.claude/projects/**/*.jsonl`).
/// Логика намеренно повторяет analyzer/cc_dashboard.py — дедуп, разбивка
/// cache-write на 5m/1h и отбрасывание пустых вызовов должны совпадать.
enum TranscriptScanner {

    // MARK: - Расположение данных

    static func roots() -> [URL] {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            for part in env.split(separator: ",") {
                let p = String(part).trimmingCharacters(in: .whitespaces)
                guard !p.isEmpty else { continue }
                candidates.append(URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
                    .appendingPathComponent("projects"))
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent(".claude/projects"))
        candidates.append(home.appendingPathComponent(".config/claude/projects"))

        var seen = Set<String>()
        return candidates.filter { url in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue, seen.insert(url.path).inserted else { return false }
            return true
        }
    }

    static func transcriptFiles() -> [URL] {
        var out: [URL] = []
        for root in roots() {
            guard let it = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in it where url.pathExtension == "jsonl" {
                out.append(url)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// `-Users-alice-Projects-app` → `/Users/alice/Projects/app`
    static func decodeSlug(_ slug: String) -> String {
        guard slug.hasPrefix("-") else { return slug }
        return "/" + slug.drop(while: { $0 == "-" }).replacingOccurrences(of: "-", with: "/")
    }

    // MARK: - Разбор файла

    struct FileParse {
        var records: [CallRecord]
        var tools: [ToolEvent] = []
        /// Названия сессий: pool-индекс сессии → текст. Побеждает последнее
        /// в файле — Claude Code переписывает автоназвание по ходу работы.
        var customTitles: [Int32: String] = [:]
        var aiTitles: [Int32: String] = [:]
        var firstPrompts: [Int32: String] = [:]
        /// Смещение после последней полной строки — точка дозаписи при следующем скане.
        var parsedBytes: Int64
    }

    /// Разбирает `url` начиная с байта `offset`. Файлы append-only, поэтому
    /// при инкрементальном скане достаточно дочитать хвост.
    static func parse(url: URL, from offset: Int64, pool: inout StringPool) -> FileParse {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return FileParse(records: [], parsedBytes: offset)
        }
        let fallbackProject = decodeSlug(url.deletingLastPathComponent().lastPathComponent)
        let fallbackSession = url.deletingPathExtension().lastPathComponent

        var out = FileParse(records: [], parsedBytes: offset)
        var consumed = Int(clamping: offset)
        guard consumed <= data.count else {
            return FileParse(records: [], parsedBytes: 0)
        }

        var localPool = pool
        // Первый промпт нужен только как запасное название, и лежит он в начале
        // файла — как только нашли, перестаем разбирать user-сообщения.
        var needFirstPrompt = offset == 0

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let bytes = raw.bindMemory(to: UInt8.self)
            var lineStart = consumed
            var i = consumed
            while i < bytes.count {
                if bytes[i] == 0x0A {   // \n
                    parseLine(base: base, start: lineStart, end: i, bytes: bytes,
                              fallbackProject: fallbackProject,
                              fallbackSession: fallbackSession,
                              needFirstPrompt: &needFirstPrompt,
                              pool: &localPool, into: &out)
                    lineStart = i + 1
                }
                i += 1
            }
            consumed = lineStart
        }
        pool = localPool
        out.parsedBytes = Int64(consumed)
        return out
    }

    private static func parseLine(
        base: UnsafeRawPointer,
        start: Int,
        end: Int,
        bytes: UnsafeBufferPointer<UInt8>,
        fallbackProject: String,
        fallbackSession: String,
        needFirstPrompt: inout Bool,
        pool: inout StringPool,
        into out: inout FileParse
    ) {
        var s = start, e = end
        while s < e, bytes[s] == 0x20 || bytes[s] == 0x09 || bytes[s] == 0x0D { s += 1 }
        while e > s, bytes[e - 1] == 0x20 || bytes[e - 1] == 0x09 || bytes[e - 1] == 0x0D { e -= 1 }
        guard e - s > 2, bytes[s] == 0x7B else { return }   // должен начинаться с '{'

        // Дешевый префильтр: полностью разбираем только те строки, которые
        // могут нас заинтересовать. Пока не нашли первый промпт — пускаем и
        // user-сообщения, но они лежат в начале файла, так что это дешево.
        let interesting = contains(bytes, s, e, Pattern.usage)
            || contains(bytes, s, e, Pattern.title)
            || (needFirstPrompt && contains(bytes, s, e, Pattern.typeUser))
        guard interesting else { return }

        let lineData = Data(bytes: base.advanced(by: s), count: e - s)
        guard let rec = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        else { return }

        let sessionId = (rec["sessionId"] as? String) ?? fallbackSession
        let type = rec["type"] as? String

        // Названия сессии лежат отдельными записями, без usage.
        if type == "custom-title" {
            if let t = cleanTitle(rec["customTitle"] as? String) {
                out.customTitles[pool.intern(sessionId)] = t
            }
            return
        }
        if type == "ai-title" {
            if let t = cleanTitle(rec["aiTitle"] as? String),
               t.lowercased() != "unknown session content" {
                out.aiTitles[pool.intern(sessionId)] = t
            }
            return
        }

        guard let msg = rec["message"] as? [String: Any] else { return }

        if needFirstPrompt, type == "user" {
            if let t = cleanTitle(promptText(msg["content"])) {
                out.firstPrompts[pool.intern(sessionId)] = String(t.prefix(90))
                needFirstPrompt = false
            }
        }

        guard let usage = msg["usage"] as? [String: Any] else { return }

        let cc = usage["cache_creation"] as? [String: Any] ?? [:]
        let cw1h = intVal(cc["ephemeral_1h_input_tokens"])
        let cwAll = intVal(usage["cache_creation_input_tokens"])
        var cw5 = max(cwAll - cw1h, 0)
        if cwAll == 0 { cw5 = intVal(cc["ephemeral_5m_input_tokens"]) }

        let input = intVal(usage["input_tokens"])
        let cacheRead = intVal(usage["cache_read_input_tokens"])
        let output = intVal(usage["output_tokens"])
        guard let ts = parseTimestamp(rec["timestamp"] as? String) else { return }

        let sessionIndex = pool.intern(sessionId)

        let messageKey = dedupKey(messageId: msg["id"] as? String,
                                  requestId: rec["requestId"] as? String)

        // Обращения к инструментам лежат в том же assistant-сообщении, что и
        // usage, так что достаются попутно и почти бесплатно.
        if let content = msg["content"] as? [[String: Any]] {
            var slot: Int16 = 0
            for part in content where part["type"] as? String == "tool_use" {
                guard let name = part["name"] as? String else { continue }
                out.tools.append(ToolEvent(timestamp: ts, session: sessionIndex,
                                           tool: pool.intern(name),
                                           dedupKey: messageKey, slot: slot))
                slot += 1
            }
        }

        guard input + cw5 + cw1h + cacheRead + output > 0 else { return }

        let model = (msg["model"] as? String) ?? "unknown"
        let project = (rec["cwd"] as? String) ?? fallbackProject

        out.records.append(CallRecord(
            timestamp: ts,
            project: pool.intern(project),
            session: sessionIndex,
            model: pool.intern(model),
            isSidechain: (rec["isSidechain"] as? Bool) ?? false,
            input: Int32(clamping: input),
            cacheWrite5m: Int32(clamping: cw5),
            cacheWrite1h: Int32(clamping: cw1h),
            cacheRead: Int32(clamping: cacheRead),
            output: Int32(clamping: output),
            dedupKey: messageKey
        ))
    }

    /// Текст первого пользовательского сообщения — запасное название сессии.
    private static func promptText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        guard let parts = content as? [[String: Any]] else { return nil }
        let texts = parts.compactMap { part -> String? in
            part["type"] as? String == "text" ? part["text"] as? String : nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }

    /// Отбрасывает служебный мусор, который названием быть не может.
    private static func cleanTitle(_ text: String?) -> String? {
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
        else { return nil }
        if let first = t.first, "</[".contains(first) { return nil }
        if t.contains("Caveat:") || t.contains("system-reminder") { return nil }
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return t.isEmpty ? nil : t
    }

    private enum Pattern {
        static let usage = Array("usage".utf8)
        static let title = Array("itle".utf8)          // customTitle / aiTitle / *-title
        static let typeUser = Array("\"type\":\"user\"".utf8)
    }

    /// Поиск подстроки в строке файла без создания String — этим отсеиваются
    /// сотни тысяч неинтересных строк до дорогого разбора JSON.
    @inline(__always)
    private static func contains(_ bytes: UnsafeBufferPointer<UInt8>,
                                 _ from: Int, _ to: Int, _ pattern: [UInt8]) -> Bool {
        let n = pattern.count
        guard to - from >= n else { return false }
        let head = pattern[0]
        var i = from
        let last = to - n
        while i <= last {
            if bytes[i] == head {
                var j = 1
                while j < n, bytes[i + j] == pattern[j] { j += 1 }
                if j == n { return true }
            }
            i += 1
        }
        return false
    }

    @inline(__always)
    private static func intVal(_ any: Any?) -> Int {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }

    /// FNV-1a: нужен детерминированный хэш — штатный Hasher переслучайно
    /// засеивается на каждый запуск и ломал бы дедуп при чтении из кеша.
    private static func dedupKey(messageId: String?, requestId: String?) -> UInt64 {
        guard messageId != nil || requestId != nil else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ s: String?) {
            for b in (s ?? "").utf8 {
                hash ^= UInt64(b)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            hash ^= 0x01
            hash = hash &* 0x0000_0100_0000_01B3
        }
        mix(messageId)
        mix(requestId)
        return hash == 0 ? 1 : hash   // 0 зарезервирован под «дедуп не применим»
    }

    // MARK: - Время

    private static let fallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Быстрый разбор `2026-08-08T16:57:12.345Z` без DateFormatter.
    static func parseTimestamp(_ s: String?) -> Double? {
        guard let s, s.count >= 19 else { return nil }
        let u = Array(s.utf8)

        func num(_ from: Int, _ len: Int) -> Int? {
            var v = 0
            for i in from..<(from + len) {
                guard i < u.count, u[i] >= 0x30, u[i] <= 0x39 else { return nil }
                v = v * 10 + Int(u[i] - 0x30)
            }
            return v
        }
        guard u[4] == 0x2D, u[7] == 0x2D, (u[10] == 0x54 || u[10] == 0x20),
              u[13] == 0x3A, u[16] == 0x3A,
              let year = num(0, 4), let month = num(5, 2), let day = num(8, 2),
              let hour = num(11, 2), let minute = num(14, 2), let second = num(17, 2),
              (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second <= 60
        else { return fallbackFormatter.date(from: s)?.timeIntervalSince1970 }

        var idx = 19
        var fraction = 0.0
        if idx < u.count, u[idx] == 0x2E {
            idx += 1
            var scale = 0.1
            while idx < u.count, u[idx] >= 0x30, u[idx] <= 0x39 {
                fraction += Double(u[idx] - 0x30) * scale
                scale /= 10
                idx += 1
            }
        }

        var offsetSeconds = 0
        if idx < u.count {
            let c = u[idx]
            if c == 0x5A || c == 0x7A {          // Z
                offsetSeconds = 0
            } else if c == 0x2B || c == 0x2D {   // +HH:MM / -HH:MM
                guard let oh = num(idx + 1, 2), let om = num(idx + 4, 2) else {
                    return fallbackFormatter.date(from: s)?.timeIntervalSince1970
                }
                offsetSeconds = (oh * 3600 + om * 60) * (c == 0x2D ? -1 : 1)
            } else {
                return fallbackFormatter.date(from: s)?.timeIntervalSince1970
            }
        }

        let days = daysFromCivil(year: year, month: month, day: day)
        let epoch = Double(days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds)
        return epoch + fraction
    }

    /// Дней от 1970-01-01 по алгоритму Howard Hinnant (civil_from_days наоборот).
    @inline(__always)
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
