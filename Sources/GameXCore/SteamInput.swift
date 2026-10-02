import Foundation

/// Attiva **Steam Input** per i giochi di una box, scrivendo l'override per-app
/// in `userdata/<id>/config/localconfig.vdf`:
///
///     "apps"
///     {
///         "<appid>"
///         {
///             "UseSteamControllerConfig"  "2"     ← 2 = Steam Input forzato ON
///             ...
///         }
///     }
///
/// Storico: col runtime **senza SDL2** (2026-10-01) Wine non vedeva il pad, e
/// l'unica configurazione funzionante era Steam Input ON (pad virtuale di Steam).
///
/// Dal 2026-10-02 il runtime include SDL2: Wine espone il pad fisico via XInput
/// (verificato con `gxpadlive.exe`), quindi la configurazione di default è
/// **Steam Input OFF** (pad fisico). Steam Input ON resta problematico perché
/// l'overlay di Steam aggancia XInput e *nasconde* il pad fisico al gioco: se
/// Steam non rileva da solo il controller (caso Bluetooth LE, PID 0x0B13) il
/// gioco non riceve nulla.
///
/// ⚠️ Il file è **critico** per l'account: prima di scrivere viene creato un
/// backup (`localconfig.vdf.gamex-bak`) e dopo la scrittura il file viene
/// validato (bilanciamento delle graffe). Se Steam è in esecuzione la scrittura
/// viene **rifiutata** (Steam sovrascriverebbe le modifiche e potrebbe perdere
/// le impostazioni).
public enum SteamInput {

    public struct Result: Sendable {
        public var changed: [String] = []
        public var alreadyEnabled: [String] = []
        public var skippedReason: String?
        public var backup: URL?
    }

    public static let controllerKey = "UseSteamControllerConfig"
    public static let enabledValue = "2"
    public static let disabledValue = "0"

    // MARK: - Individuazione

    /// AppID installati nella box (da `steamapps/appmanifest_*.acf`).
    public static func installedAppIDs(in prefix: PrefixRecord) -> [String] {
        let fm = FileManager.default
        let dir = prefix.driveC
            .appendingPathComponent("Program Files (x86)/Steam/steamapps")
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        var ids: [String] = []
        for f in files where f.lastPathComponent.hasPrefix("appmanifest_") && f.pathExtension == "acf" {
            if let text = try? String(contentsOf: f, encoding: .utf8),
               let id = firstMatch(#""appid"\s+"(\d+)""#, in: text) {
                ids.append(id)
            }
        }
        return ids.sorted()
    }

    /// `localconfig.vdf` dell'utente Steam della box (se esiste).
    public static func localConfigURL(in prefix: PrefixRecord) -> URL? {
        let fm = FileManager.default
        let userdata = prefix.driveC.appendingPathComponent("Program Files (x86)/Steam/userdata")
        guard let dirs = try? fm.contentsOfDirectory(at: userdata, includingPropertiesForKeys: [.isDirectoryKey])
        else { return nil }
        for d in dirs {
            let cfg = d.appendingPathComponent("config/localconfig.vdf")
            if fm.fileExists(atPath: cfg.path) { return cfg }
        }
        return nil
    }

    /// Steam è in esecuzione per quel prefix?
    public static func steamIsRunning(prefix: PrefixRecord) -> Bool {
        let r = try? ProcessRunner.run("/bin/ps", ["-eo", "command"])
        guard let out = r?.stdout else { return false }
        return out.contains(prefix.url.path) && out.lowercased().contains("steam.exe")
    }

    // MARK: - Stato

    /// `UseSteamControllerConfig` per un AppID: 2 = forzato ON, 0 = off, nil = assente.
    public static func setting(appID: String, in prefix: PrefixRecord) -> String? {
        guard let url = localConfigURL(in: prefix),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let section = appsSection(of: text)
        guard let body = section else { return nil }
        return value(of: controllerKey, forApp: appID, in: body)
    }

    // MARK: - Scrittura

    @discardableResult
    public static func ensureEnabled(
        appIDs: [String], in prefix: PrefixRecord, allowWhileRunning: Bool = false
    ) throws -> Result {
        var result = Result()
        guard let url = localConfigURL(in: prefix) else {
            result.skippedReason = "localconfig.vdf not found (has Steam ever run?)"
            return result
        }
        if !allowWhileRunning, steamIsRunning(prefix: prefix) {
            result.skippedReason = "Steam is running: close Steam and try again"
            return result
        }
        guard var text = try? String(contentsOf: url, encoding: .utf8) else {
            result.skippedReason = "impossibile leggere localconfig.vdf"
            return result
        }

        var body = appsSection(of: text) ?? "\(tab)\"apps\"\n\(tab){\n\(tab)}\n"

        for appID in appIDs {
            let current = value(of: controllerKey, forApp: appID, in: body)
            if current == enabledValue {
                result.alreadyEnabled.append(appID)
                continue
            }
            body = setValue(enabledValue, of: controllerKey, forApp: appID, in: body)
            result.changed.append(appID)
        }

        if result.changed.isEmpty { return result }   // niente da scrivere

        // backup una volta sola
        let backup = url.appendingPathExtension("gamex-bak")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: url, to: backup)
            result.backup = backup
        }

        if let range = text.range(of: appsSection(of: text) ?? "\u{0}") {
            text.replaceSubrange(range, with: body)
        } else {
            text += body
        }

        guard bracesBalanced(text) else {
            throw SteamInputError.validationFailed(url.path)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return result
    }

    /// Disattiva Steam Input per gli AppID (`UseSteamControllerConfig = 0`).
    ///
    /// Serve quando il gioco deve leggere il **pad fisico** via XInput/DirectInput
    /// (Wine lo fornisce: verificato con `gxpadlive.exe`) invece del pad virtuale
    /// creato da Steam. Con Steam Input attivo, Steam *nasconde* il dispositivo
    /// fisico al gioco: se Steam non lo serve (es. gioco avviato fuori da Steam),
    /// il gioco non vede nessun controller.
    @discardableResult
    public static func ensureDisabled(
        appIDs: [String], in prefix: PrefixRecord, allowWhileRunning: Bool = false
    ) throws -> Result {
        var result = Result()
        guard let url = localConfigURL(in: prefix) else {
            result.skippedReason = "localconfig.vdf not found (has Steam ever run?)"
            return result
        }
        if !allowWhileRunning, steamIsRunning(prefix: prefix) {
            result.skippedReason = "Steam is running: close Steam and try again"
            return result
        }
        guard var text = try? String(contentsOf: url, encoding: .utf8) else {
            result.skippedReason = "impossibile leggere localconfig.vdf"
            return result
        }

        var body = appsSection(of: text) ?? "\(tab)\"apps\"\n\(tab){\n\(tab)}\n"

        for appID in appIDs {
            if value(of: controllerKey, forApp: appID, in: body) == "0" {
                result.alreadyEnabled.append(appID)     // già disattivato
                continue
            }
            body = setValue("0", of: controllerKey, forApp: appID, in: body)
            result.changed.append(appID)
        }

        if result.changed.isEmpty { return result }

        let backup = url.appendingPathExtension("gamex-bak")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: url, to: backup)
            result.backup = backup
        }
        if let range = text.range(of: appsSection(of: text) ?? "\u{0}") {
            text.replaceSubrange(range, with: body)
        } else {
            text += body
        }
        guard bracesBalanced(text) else {
            throw SteamInputError.validationFailed(url.path)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return result
    }

    // MARK: - Manipolazione VDF (testo)

    static let tab = "\t"

    /// Individua la sezione di primo livello `"apps" { … }` (indentazione minima).
    public static func appsSection(of text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        var bestIndent = Int.max
        var start = -1
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed == "\"apps\"" else { continue }
            let indent = line.prefix { $0 == "\t" || $0 == " " }.count
            if indent < bestIndent { bestIndent = indent; start = i }
        }
        guard start >= 0 else { return nil }
        // dall'indice di "apps" trova la { e la sua chiusura
        var depth = 0
        var opened = false
        var out: [String] = []
        for i in start..<lines.count {
            let line = lines[i]
            out.append(line)
            for ch in line {
                if ch == "{" { depth += 1; opened = true }
                if ch == "}" { depth -= 1 }
            }
            if opened && depth <= 0 { break }
        }
        return out.joined(separator: "\n")
    }

    /// Valore della chiave dentro il blocco dell'app (nil se assenti).
    public static func value(of key: String, forApp appID: String, in body: String) -> String? {
        guard let block = appBlock(of: appID, in: body) else { return nil }
        return firstMatch("\"\(key)\"\\s+\"([^\"]*)\"", in: block)
    }

    /// Imposta (o inserisce) la chiave nel blocco dell'app; crea il blocco se manca.
    public static func setValue(_ value: String, of key: String, forApp appID: String, in body: String) -> String {
        let keyLine = "\(tab)\(tab)\(tab)\"\(key)\"\t\t\"\(value)\""
        guard let block = appBlock(of: appID, in: body) else {
            // crea "appID" { key value } in fondo alla sezione (prima della graffa finale)
            let newBlock = "\(tab)\"\(appID)\"\n\(tab){\n\(keyLine)\n\(tab)}\n"
            if let closeRange = body.range(of: "\n\(tab)}", options: .backwards) {
                return body.replacingCharacters(in: closeRange, with: "\n" + newBlock + "\(tab)}")
            }
            return body + newBlock
        }

        // il blocco esiste: sostituisci o inserisci la chiave
        let pattern = "\"\(key)\"\\s+\"[^\"]*\""
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
           let r = Range(m.range, in: block) {
            let updated = block.replacingCharacters(in: r, with: "\"\(key)\"\t\t\"\(value)\"")
            return body.replacingOccurrences(of: block, with: updated)
        }
        // inserisci come prima riga dentro il blocco
        if let braceRange = block.range(of: "{") {
            let insertAt = block.index(after: braceRange.lowerBound)
            let updated = block.replacingCharacters(in: insertAt..<insertAt, with: "\n" + keyLine)
            return body.replacingOccurrences(of: block, with: updated)
        }
        return body
    }

    /// Blocco `"<appid>" { … }` (solo quello con contenuto, non le voci chiave-valore).
    public static func appBlock(of appID: String, in body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed == "\"\(appID)\"" else { continue }
            // deve essere seguito da una riga con {
            guard i + 1 < lines.count,
                  lines[i + 1].trimmingCharacters(in: .whitespaces).hasPrefix("{") else { continue }
            var depth = 0, opened = false
            var out: [String] = []
            for j in i..<lines.count {
                out.append(lines[j])
                for ch in lines[j] {
                    if ch == "{" { depth += 1; opened = true }
                    if ch == "}" { depth -= 1 }
                }
                if opened && depth <= 0 { break }
            }
            return out.joined(separator: "\n")
        }
        return nil
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    public static func bracesBalanced(_ text: String) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for ch in text {
            if escaped { escaped = false; continue }
            if ch == "\\" && inString { escaped = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            guard !inString else { continue }
            if ch == "{" { depth += 1 }
            else if ch == "}" { depth -= 1; if depth < 0 { return false } }
        }
        return depth == 0
    }

    public enum SteamInputError: Error, LocalizedError {
        case validationFailed(String)
        public var errorDescription: String? {
            switch self {
            case .validationFailed(let p):
                return "localconfig.vdf invalid after the edit (\(p)) — restore the .gamex-bak backup"
            }
        }
    }
}
