import Foundation
import Darwin

/// Tetto di log per un lancio: dove scrivere e quanti byte al massimo.
///
/// Il caso reale (2026-10-15): `WINEDEBUG=+d3d11,+dxgi` su un 3D ha prodotto
/// **26 GB** in una run. Il tetto è obbligatorio per un lancio con `--winedebug`;
/// `capBytes == 0` significa "nessun tetto" e richiede una dichiarazione esplicita
/// (`--max-log-mb 0`, con avviso rumoroso lato CLI).
public struct LogCap: Sendable, Equatable {
    public let path: URL
    public let capBytes: Int64

    public init(path: URL, capBytes: Int64) {
        self.path = path
        self.capBytes = capBytes
    }

    /// Contatore monotono di processo: due `default` nello **stesso secondo**
    /// devono avere nomi diversi (D1). Il lock lo rende atomico fra i thread.
    private static let sequenceLock = NSLock()
    private static var sequence: UInt64 = 0

    private static func nextSequence() -> UInt64 {
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        sequence += 1
        return sequence
    }

    /// Tetto di default: `<logsRoot>/dxmf/<box>-<timestamp>-p<pid>-<n>.log` con il
    /// cap di `config.dxmfLogCapMB` (default 512). Il timestamp ha granularità di
    /// un secondo, quindi l'unicità viene da `pid` + contatore monotono: due run
    /// concorrenti nello stesso secondo non scrivono lo stesso file (D1). Il
    /// percorso non è mai scelto in silenzio: è quello stampato dal CLI.
    public static func `default`(config: Config, box: String) -> LogCap {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let safeBox = box.replacingOccurrences(of: "/", with: "_")
        let dir = config.resolvedPaths().logsRoot.appendingPathComponent("dxmf")
        let name = "\(safeBox)-\(stamp)-p\(getpid())-\(nextSequence()).log"
        return LogCap(path: dir.appendingPathComponent(name),
                      capBytes: Int64(max(0, config.dxmfLogCapMB)) * 1_048_576)
    }
}

/// Esecuzione di un processo con stdout+stderr **uniti** su file e con un tetto.
///
/// Vincoli (dal caso dei 26 GB):
/// - non si bufferizza **mai** in memoria: si legge a blocchi e si scrive;
/// - il processo **non** viene ucciso quando si supera il tetto (si taglia il log,
///   non il gioco);
/// - superato il tetto il file viene troncato (si conserva la testa fino al cap),
///   si scrive **una** riga marcatore (`=== gx: log truncated at <N> MB ===`) e si
///   scarta l'output successivo: il file resta limitato;
/// - `onCap` è chiamato la **prima** volta che si supera il tetto;
/// - `truncated == true` solo se si è tagliato davvero;
/// - `written` = byte scritti in totale (anche quelli scartati dalla troncatura).
public enum LaunchLog {

    public struct Outcome: Sendable {
        public let exit: Int32
        public let written: Int64
        public let duBytes: Int64
        public let truncated: Bool
        public let capBytes: Int64

        public init(exit: Int32, written: Int64, duBytes: Int64,
                    truncated: Bool, capBytes: Int64) {
            self.exit = exit
            self.written = written
            self.duBytes = duBytes
            self.truncated = truncated
            self.capBytes = capBytes
        }
    }

    /// Esegue `executable` con `args`, unendo stdout e stderr sul file di `cap`.
    @discardableResult
    public static func run(
        _ executable: String,
        _ args: [String],
        environment: [String: String],
        cap: LogCap,
        onCap: (Int64) -> Void = { _ in }
    ) throws -> Outcome {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessError.executableNotFound(executable)
        }
        try FileManager.default.createDirectory(
            at: cap.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Creazione **esclusiva**: `O_CREAT|O_EXCL` non tronca mai un file
        // esistente. Se il path c'è già si **rifiuta per nome** (D1), invece di
        // lasciare che il primo log sparisca in silenzio.
        let fd = open(cap.path.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else {
            if errno == EEXIST {
                throw ProcessError.logPathExists(cap.path.path)
            }
            throw ProcessError.launchFailed(
                executable,
                "cannot create the log file \(cap.path.path) (errno \(errno))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe   // unito: preserva l'ordine, un solo file

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(executable, error.localizedDescription)
        }

        let reader = pipe.fileHandleForReading
        let capBytes = cap.capBytes
        var written: Int64 = 0
        var fileBytes: Int64 = 0
        var truncated = false

        // `availableData` ritorna vuoto a EOF (stessa forma di
        // `ProcessRunner.runStreaming`), quindi non si perde l'ultimo blocco.
        while true {
            let data = reader.availableData
            if data.isEmpty { break }
            written += Int64(data.count)
            if truncated { continue }   // già tagliato: si drena e si scarta
            if capBytes > 0, fileBytes + Int64(data.count) > capBytes {
                // conserva la testa fino al cap, poi marca il taglio e smette di scrivere
                let keep = min(capBytes, fileBytes)
                try? handle.truncate(atOffset: UInt64(keep))
                try? handle.seek(toOffset: UInt64(keep))
                let mb = Int((Double(capBytes) / 1_048_576).rounded())
                let marker = "=== gx: log truncated at \(mb) MB ===\n"
                try? handle.write(contentsOf: Data(marker.utf8))
                fileBytes = keep + Int64(marker.utf8.count)
                truncated = true
                onCap(written)
                continue
            }
            try? handle.write(contentsOf: data)
            fileBytes += Int64(data.count)
        }
        process.waitUntilExit()

        return Outcome(
            exit: process.terminationStatus,
            written: written,
            duBytes: du(cap.path),
            truncated: truncated,
            capBytes: capBytes)
    }

    /// Dimensione **reale** su disco (`/usr/bin/du -sk`), non una stima.
    public static func du(_ url: URL) -> Int64 {
        guard let result = try? ProcessRunner.run("/usr/bin/du", ["-sk", url.path]),
              result.success else { return 0 }
        let token = result.stdout
            .split(whereSeparator: { $0 == "\t" || $0 == " " })
            .first.map(String.init) ?? ""
        guard let kb = Int64(token) else { return 0 }
        return kb * 1024
    }
}
