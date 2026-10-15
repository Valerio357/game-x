import Foundation
import Darwin

/// Igiene dei processi prima di un lancio.
///
/// Il caso reale (2026-10-15): 723 `winedbg --auto` orfani, process table
/// esaurita, 3 misure invalidate. Il rilevamento legge `ps -eo pid,command`
/// **una volta sola** (mai un `for` di `pgrep`) e non uccide **niente**: solo
/// `sweepWinedbg()` uccide, e ritorna quanti.
public enum Orphans {

    public struct Report: Sendable, Equatable {
        public let winedbg: [Int32]        // pid dei `winedbg --auto` orfani
        public let totalProcesses: Int
        public let softLimit: Int?         // `kern.maxprocperuid`, se leggibile
        public var isCrowded: Bool         // totalProcesses vicino al limite

        public init(winedbg: [Int32], totalProcesses: Int, softLimit: Int?, isCrowded: Bool) {
            self.winedbg = winedbg
            self.totalProcesses = totalProcesses
            self.softLimit = softLimit
            self.isCrowded = isCrowded
        }
    }

    /// Soglia di "affollato": ≥ 80% del limite soft per uid. Euristica
    /// dichiarata, non un valore inventato: il limite arriva da `sysctl`.
    private static let crowdedRatioNumerator = 4
    private static let crowdedRatioDenominator = 5

    /// Funzione pura, testabile: estrae i pid delle righe in cui compare la
    /// coppia di token adiacenti `winedbg --auto`. Una riga che contiene solo
    /// `winedbg` (o `winedbg` con altri argomenti) **non** è un orfano `--auto`.
    public static func parse(_ psOutput: String) -> [Int32] {
        var pids: [Int32] = []
        for rawLine in psOutput.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2, let pid = Int32(parts[0]) else { continue }
            let command = Array(parts.dropFirst())
            guard let i = command.firstIndex(where: {
                ($0 as NSString).lastPathComponent == "winedbg"
            }), i + 1 < command.count, command[i + 1] == "--auto" else { continue }
            pids.append(pid)
        }
        return pids
    }

    /// Conta le righe che iniziano con un pid (salta l'header `PID COMMAND`).
    static func countProcesses(_ psOutput: String) -> Int {
        var count = 0
        for rawLine in psOutput.split(separator: "\n") {
            let parts = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if let first = parts.first, Int32(first) != nil { count += 1 }
        }
        return count
    }

    /// `kern.maxprocperuid`: il limite soft reale, non un numero inventato.
    static func softLimit() -> Int? {
        guard let result = try? ProcessRunner.run("/usr/sbin/sysctl", ["-n", "kern.maxprocperuid"])
        else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isCrowded(total: Int, softLimit: Int?) -> Bool {
        guard let softLimit, softLimit > 0 else { return false }
        return total * crowdedRatioDenominator >= softLimit * crowdedRatioNumerator
    }

    /// Una sola `ps`, nessun `pgrep`, nessun `kill`.
    public static func scan() -> Report {
        let result = try? ProcessRunner.run("/bin/ps", ["-eo", "pid,command"])
        let output = result?.stdout ?? ""
        let winedbg = parse(output)
        let total = countProcesses(output)
        let soft = softLimit()
        return Report(
            winedbg: winedbg,
            totalProcesses: total,
            softLimit: soft,
            isCrowded: isCrowded(total: total, softLimit: soft)
        )
    }

    /// Uccide i `winedbg --auto` rilevati e ritorna quanti ne ha raggiunti.
    /// Unico punto che uccide: `scan()` non uccide mai.
    @discardableResult
    public static func sweepWinedbg() -> Int {
        var killed = 0
        for pid in scan().winedbg {
            if kill(pid, SIGTERM) == 0 { killed += 1 }
        }
        return killed
    }
}
