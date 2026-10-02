import Foundation

/// Livelli di log.
public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0, info, warn, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(_ raw: String) {
        switch raw.lowercased() {
        case "debug": self = .debug
        case "warn", "warning": self = .warn
        case "error": self = .error
        default: self = .info
        }
    }
}

/// Logger semplice con colori opzionali e scrittura su file.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let lock = NSLock()
    private var level: LogLevel = .info
    private var consoleThreshold: LogLevel = .warn
    private var fileHandle: FileHandle?

    private init() {}

    /// - Parameters:
    ///   - level: soglia per il file di log.
    ///   - logFile: file di destinazione (opzionale).
    ///   - verboseConsole: se `true`, la console mostra anche info/debug;
    ///     altrimenti solo warn/error (per non sporcare l'output dei comandi).
    public func configure(level: LogLevel, logFile: URL? = nil, verboseConsole: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.level = level
        self.consoleThreshold = verboseConsole ? level : max(level, .warn)
        if let logFile {
            try? FileManager.default.createDirectory(
                at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logFile.path) {
                FileManager.default.createFile(atPath: logFile.path, contents: nil)
            }
            fileHandle = try? FileHandle(forWritingTo: logFile)
            fileHandle?.seekToEndOfFile()
        }
    }

    public func log(_ level: LogLevel, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        let stamp = Self.timestamp()
        if level >= self.level {
            let line = "[\(stamp)] \(level.tag): \(message)\n"
            fileHandle?.write(Data(line.utf8))
        }
        if level >= consoleThreshold {
            let line = "[\(stamp)] \(level.tag): \(message)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    public func debug(_ m: String) { log(.debug, m) }
    public func info(_ m: String) { log(.info, m) }
    public func warn(_ m: String) { log(.warn, m) }
    public func error(_ m: String) { log(.error, m) }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}

private extension LogLevel {
    var tag: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO "
        case .warn: return "WARN "
        case .error: return "ERROR"
        }
    }
}
