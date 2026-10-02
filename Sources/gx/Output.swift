import Foundation
import GameXCore

/// Output di terminale con colori opzionali.
enum Out {
    static let color = isatty(STDOUT_FILENO) == 1

    static func print(_ text: String = "") { Swift.print(text) }

    static func styled(_ text: String, _ code: String) -> String {
        color ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text
    }

    static func bold(_ text: String) -> String { styled(text, "1") }
    static func green(_ text: String) -> String { styled(text, "32") }
    static func yellow(_ text: String) -> String { styled(text, "33") }
    static func red(_ text: String) -> String { styled(text, "31") }
    static func dim(_ text: String) -> String { styled(text, "2") }

    static func field(_ label: String, _ value: String) {
        print("  \(bold(label.padding(toLength: 16, withPad: " ", startingAt: 0))): \(value)")
    }
}

/// Exit code del CLI (DESIGN §7.1).
enum ExitCode: Int32 {
    case ok = 0
    case generic = 1
    case usage = 2
    case runtimeNotFound = 3
    case prefixNotFound = 4
    case notInstalled = 5
    case wineCommandFailed = 6
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case runtimeNotFound(String)
    case prefixNotFound(String)
    case notInstalled(String)
    case denied(String)

    var description: String {
        switch self {
        case .usage(let m): return m
        case .runtimeNotFound(let m): return m
        case .prefixNotFound(let m): return m
        case .notInstalled(let m): return m
        case .denied(let m): return m
        }
    }

    var exitCode: ExitCode {
        switch self {
        case .usage: return .usage
        case .runtimeNotFound: return .runtimeNotFound
        case .prefixNotFound: return .prefixNotFound
        case .notInstalled: return .notInstalled
        case .denied: return .generic
        }
    }
}
