import Foundation

/// Splits a command line string into arguments, respecting single/double quotes.
/// Handy for the GUI "Run program" field and for `box exec` style input.
public enum CommandLineTokens {
    public static func split(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var hasToken = false

        for ch in line {
            if ch == "'" && !inDouble {
                inSingle.toggle(); hasToken = true; continue
            }
            if ch == "\"" && !inSingle {
                inDouble.toggle(); hasToken = true; continue
            }
            if (ch == " " || ch == "\t" || ch == "\n") && !inSingle && !inDouble {
                if hasToken { tokens.append(current); current = ""; hasToken = false }
                continue
            }
            current.append(ch)
            hasToken = true
        }
        if hasToken { tokens.append(current) }
        return tokens
    }
}
