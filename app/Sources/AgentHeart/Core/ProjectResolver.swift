import Foundation

/// Приводит рабочие директории к проектам.
///
/// В транскриптах лежит `cwd`, а не проект, поэтому один репозиторий
/// рассыпается на строки вида `agent-heart`, `app`, `analyzer`. Плюс на
/// case-insensitive APFS один и тот же путь встречается в разном регистре
/// (`myproject` и `MyProject`) и попадает в две разные строки.
///
/// Решение: поднимаемся до корня git-репозитория и схлопываем регистр.
enum ProjectResolver {

    /// pool-индекс рабочей директории → канонический путь проекта.
    static func canonicalPaths(pool: StringPool, indices: some Sequence<Int32>) -> [Int32: String] {
        var rootCache: [String: String] = [:]
        // lowercase-ключ → выбранный вариант написания
        var canonical: [String: String] = [:]
        var result: [Int32: String] = [:]

        for index in indices {
            let cwd = pool[index]
            let root: String
            if let cached = rootCache[cwd] {
                root = cached
            } else {
                root = repositoryRoot(of: cwd) ?? cwd
                rootCache[cwd] = root
            }

            let key = root.lowercased()
            if let existing = canonical[key] {
                result[index] = existing
            } else {
                canonical[key] = root
                result[index] = root
            }
        }
        return result
    }

    /// Ближайший вверх по дереву каталог с `.git`. Останавливаемся на домашней
    /// директории: выше нее «проектов» не бывает, а лишние stat-ы ни к чему.
    static func repositoryRoot(of path: String) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var current = URL(fileURLWithPath: path).standardizedFileURL

        for _ in 0..<24 {
            let p = current.path
            guard p.count > 1, p != home else { return nil }
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return p
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != p else { return nil }
            current = parent
        }
        return nil
    }
}
