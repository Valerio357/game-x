import Foundation

/// Risultato di un processo eseguito.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var success: Bool { exitCode == 0 }
}

/// Errore di esecuzione processo.
public enum ProcessError: Error, CustomStringConvertible {
    case executableNotFound(String)
    case launchFailed(String, String)
    case timedOut(String)

    public var description: String {
        switch self {
        case .executableNotFound(let p): return "executable not found: \(p)"
        case .launchFailed(let p, let m): return "launch failed (\(p)): \(m)"
        case .timedOut(let p): return "timeout: \(p)"
        }
    }
}

/// Esegue processi esterni catturando stdout/stderr ed exit code.
public enum ProcessRunner {

    /// Avvia un comando **senza attendere** (ritorna il `Process`). Output scartato.
    /// Utile per monitorare un processo lungo (es. Steam).
    public static func spawn(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil
    ) throws -> Process {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessError.executableNotFound(executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw ProcessError.launchFailed(executable, error.localizedDescription)
        }
        return process
    }

    /// Esegue un comando e attende la fine.
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        stdin: Data? = nil
    ) throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessError.executableNotFound(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(executable, error.localizedDescription)
        }

        // Legge i dati prima di waitUntilExit per evitare deadlock sui pipe pieni.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// Esegue e restituisce solo la prima riga non vuota di stdout+stderr (utile per `--version`).
    public static func firstLine(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil
    ) -> String? {
        guard let result = try? run(executable, arguments, environment: environment) else { return nil }
        let combined = (result.stdout + "\n" + result.stderr)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return combined
    }

    /// Esegue un comando attraverso `arch -x86_64` (Rosetta).
    public static func runRosetta(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        try run("/usr/bin/arch", ["-x86_64", executable] + arguments, environment: environment)
    }

    /// Esegue un comando mostrando l'output in tempo reale (stdout+stderr uniti)
    /// e, opzionalmente, scrivendolo su file. Ritorna l'exit code.
    ///
    /// Adatto a comandi lunghi come `winetricks`: evita il buffer infinito di `run`.
    @discardableResult
    public static func runStreaming(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        logFile: URL? = nil
    ) throws -> Int32 {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessError.executableNotFound(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe   // unito: preserva l'ordine, niente doppio pipe

        var sink: FileHandle?
        if let logFile {
            try? FileManager.default.createDirectory(
                at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
            sink = try? FileHandle(forWritingTo: logFile)
            sink?.seekToEndOfFile()
        }
        defer { try? sink?.close() }

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(executable, error.localizedDescription)
        }

        let reader = pipe.fileHandleForReading
        while true {
            let data = reader.availableData
            if data.isEmpty { break }
            FileHandle.standardOutput.write(data)
            sink?.write(data)
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
