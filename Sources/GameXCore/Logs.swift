import Foundation

/// Accesso ai file di log di Game-X (M5).
public enum Logs {

    /// File di log della CLI (una riga per invocazione).
    public static func commandLog(config: Config) -> URL {
        config.resolvedPaths().logsRoot.appendingPathComponent("gx.log")
    }

    /// Elenca i file di log (ricorsivo), più recenti per primi.
    public static func list(config: Config) -> [URL] {
        let root = config.resolvedPaths().logsRoot
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return [] }

        var files: [(URL, Date)] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }
        return files.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    /// Ultime `lines` righe di un file.
    public static func tail(_ url: URL, lines: Int) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Un trailing newline produce un ultimo elemento vuoto: scartalo.
        if all.last == "" { all.removeLast() }
        guard lines > 0, all.count > lines else { return all }
        return Array(all.suffix(lines))
    }
}
