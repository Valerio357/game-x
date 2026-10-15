import Foundation
import Darwin

// MARK: - Helpers

/// Durata in forma umana (`6h 0m`, `7d 2h`, …). Usata nei messaggi d'errore,
/// perché un lock senza "da quanto" non dice niente a chi lo incontra.
fileprivate func humanDuration(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds).rounded())
    if s < 60 { return "\(s)s" }
    let m = s / 60
    if m < 60 { return "\(m)m \(s % 60)s" }
    let h = m / 60
    if h < 24 { return "\(h)h \(m % 60)m" }
    let d = h / 24
    return "\(d)d \(h % 24)h"
}

/// Formato scritto da `BoxLock` (con frazioni di secondo: due acquisizioni nello
/// stesso secondo devono restare distinguibili).
fileprivate func iso8601String(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

/// Accetta sia il formato con frazioni sia quello senza, così un lock scritto a
/// mano (o da una versione precedente) resta leggibile.
fileprivate func parseISO8601(_ string: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: string) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: string)
}

/// Nome box → nome file sicuro: `..`, `/` e spazi non escono dalla directory.
fileprivate func sanitizeLockName(_ s: String) -> String {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    let mapped = String(s.map { allowed.contains($0) ? $0 : "_" })
    return mapped.isEmpty ? "_" : mapped
}

// MARK: - BoxLockInfo

/// Chi tiene il lock di un box, e da quanto. `ageSeconds` e `pidAlive` sono
/// calcolati al momento della lettura: non vengono serializzati e non entrano
/// nell'uguaglianza (un lock letto due volte è lo stesso lock).
public struct BoxLockInfo: Codable, Sendable, Equatable, CustomStringConvertible {
    public var pid: Int32
    public var command: String     // "gx steam install dxmf-3d"
    public var reason: String      // cosa sta mutando il prefix
    public var startedAt: String   // ISO8601
    public var box: String

    /// Età del lock in secondi (0 se `startedAt` non è leggibile).
    public var ageSeconds: TimeInterval {
        guard let date = parseISO8601(startedAt) else { return 0 }
        return max(0, Date().timeIntervalSince(date))
    }

    /// `true` solo se il pid è vivo e verificabile. Un `EPERM` (processo di un
    /// altro utente) conta come vivo: nel dubbio, `held`.
    public var pidAlive: Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public init(pid: Int32, command: String, reason: String, startedAt: String, box: String) {
        self.pid = pid
        self.command = command
        self.reason = reason
        self.startedAt = startedAt
        self.box = box
    }

    public var description: String {
        "pid \(pid) (\(pidAlive ? "alive" : "dead")), age \(humanDuration(ageSeconds)), "
            + "box '\(box)', command '\(command)', reason '\(reason)'"
    }
}

// MARK: - BoxLock

/// Un lock per box: un file JSON, creazione atomica (`O_CREAT|O_EXCL`).
///
/// Regole:
/// - il file di stato è la fonte: nessun `flock` è obbligatorio;
/// - `stale` se il pid dell'holder è morto (`ESRCH`) **o** se l'età supera
///   `staleAfterSeconds` (6 h di default). Un lock stantio si può prendere;
/// - `pid` vivo ma non verificabile (permessi) **non** è stantio: in dubbio `held`;
/// - `wait > 0` attende con `onWait(holder, atteso)` ogni ~2 s e scade in
///   `.timedOut`; `wait == 0` fallisce subito con `.heldBy`;
/// - `force == true` rompe anche un lock **vivo**: chi rompe riceve `BoxLockInfo`
///   dell'holder nel log (`BoxLock: FORCE breaking …`), quindi può dire chi ha
///   scalzato. Il vecchio holder che chiama `release()` non cancella il nuovo lock.
///
/// Chi acquisisce deve rilasciare sempre, anche su errore:
///
/// ```swift
/// let lock = try BoxLock.acquire(...)
/// defer { lock.release() }
/// ```
public enum BoxLock {

    /// Un lock è stantio oltre questo tempo anche se il pid risponde ancora
    /// (difesa dal riuso dei pid).
    public static let staleAfterSeconds: TimeInterval = 6 * 60 * 60

    public struct Handle {
        let url: URL
        let info: BoxLockInfo

        /// Rilascia solo il **proprio** lock: se nel frattempo è stato rotto con
        /// `force` e sostituito, questo `release()` non tocca il nuovo holder.
        public func release() {
            guard let data = try? Data(contentsOf: url),
                  let current = try? JSONDecoder().decode(BoxLockInfo.self, from: data),
                  current.pid == info.pid,
                  current.startedAt == info.startedAt
            else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    public enum ReadState: Sendable, Equatable {
        case free
        case held(BoxLockInfo)        // un mutatore è dentro adesso
        case stale(BoxLockInfo)       // holder morto o troppo vecchio
    }

    /// Un **lancio** (la UI di Steam, un gioco, un programma in `box exec`) è un
    /// processo di **lunga vita**: NON prende il lock di mutazione. Prenderlo
    /// renderebbe impossibile il caso d'uso principale — la sequenza reale
    /// `gx steam run` (Steam vivo) + `gx dxmf run <box> -- <gioco>`, dove il gioco
    /// ha bisogno dell'handshake SteamAPI con Steam **già in esecuzione**.
    /// (Difetto trovato dal CEO il 2026-10-15 usando `gx` sul binario mergiato.)
    ///
    /// Un lancio prende solo una **decisione**: una MUTAZIONE è in corso? Se sì
    /// rifiuta (o attende `wait`, o prosegue con `force`/`--no-lock` e lo dichiara).
    public static func allowsLaunch(
        box: String,
        config: Config,
        wait: TimeInterval = 0,
        force: Bool = false,
        onWait: (BoxLockInfo, TimeInterval) -> Void = { _, _ in },
        warn: (String) -> Void = { _ in }
    ) throws {
        let deadline = Date().addingTimeInterval(wait)
        var announced = false
        while true {
            switch state(box: box, config: config) {
            case .free, .stale:
                return
            case .held(let holder):
                if force {
                    warn("launching while a mutation is in progress on '\(box)': \(holder)")
                    return
                }
                if Date() >= deadline {
                    throw LockError.heldBy(holder)
                }
                if !announced { onWait(holder, wait); announced = true }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    /// La box è **in uso**?
    ///
    /// Segnale: il **socket del wineserver di quel prefix**, in
    /// `/tmp/.wine-<uid>/server-<devhex>-<inohex>/socket` (Wine lo deriva da
    /// `st_dev`/`st_ino` del `WINEPREFIX`). Verificato su questa macchina:
    /// presente mentre un wineserver vive, **sparito** dopo `wineserver -k`, e
    /// assente per un prefix mai avviato.
    ///
    /// Perché non `ps eww`: su macOS **non stampa l'ambiente** (provato: l'unico
    /// match era il `grep` stesso), quindi attribuire un processo a una box
    /// leggendo `WINEPREFIX` **non è possibile**, e un filtro per nome
    /// (`pgrep -f wine`) mancherebbe proprio i processi del gioco
    /// (`C:\...\Steam.exe`, `...PlagueProject-Win64-Shipping.exe`).
    ///
    /// Limite dichiarato: un **crash** può lasciare il socket orfano; il
    /// messaggio lo dice e `--force` è la valvola. `verified == false` significa
    /// «non ho potuto guardare», mai «libera».
    public struct PrefixUse: Sendable, Equatable {
        public let inUse: Bool
        public let verified: Bool
        public let socketPath: String?
        public var description: String {
            guard verified else { return "could not determine whether the box is in use" }
            guard let socketPath else { return "no running wineserver for this box" }
            return "a wineserver is running for this box (\(socketPath))"
        }
        public init(inUse: Bool, verified: Bool, socketPath: String?) {
            self.inUse = inUse
            self.verified = verified
            self.socketPath = socketPath
        }
    }

    /// Esito della guardia distruttiva su una box/URL.
    ///
    /// Generalizzazione su un **URL** (non solo su un nome nel `prefixRoot`):
    /// così la stessa guardia copre anche una voce nel `.trash`. `Prefix.remove`
    /// sposta la cartella sullo stesso filesystem, quindi l'inode — e il socket
    /// del wineserver (`/tmp/.wine-<uid>/server-<devhex>-<inohex>/socket`) —
    /// restano validi per il path nel cestino.
    public enum DestructiveGuard: Sendable, Equatable {
        case proceed
        case unverified          // non ho potuto guardare: mai assumere "libera"
        case inUse(String)       // descrizione che nomina il socket
    }

    public static func destructiveGuard(_ url: URL) -> DestructiveGuard {
        let use = prefixInUse(prefix: url)
        guard use.verified else { return .unverified }
        return use.inUse ? .inUse(use.description) : .proceed
    }

    public static func prefixInUse(prefix: URL) -> PrefixUse {
        let uid = getuid()
        var dev: UInt64 = 0, ino: UInt64 = 0
        var st = stat()
        guard stat(prefix.resolvingSymlinksInPath().path, &st) == 0 else {
            return PrefixUse(inUse: false, verified: false, socketPath: nil)
        }
        dev = UInt64(bitPattern: Int64(st.st_dev))
        ino = UInt64(st.st_ino)
        let name = "server-" + String(dev, radix: 16) + "-" + String(ino, radix: 16)
        let socket = "/tmp/.wine-\(uid)/\(name)/socket"
        let exists = FileManager.default.fileExists(atPath: socket)
            || FileManager.default.fileExists(atPath: socket + "/")
        return PrefixUse(inUse: exists, verified: true, socketPath: exists ? socket : nil)
    }


    public enum LockError: Error, CustomStringConvertible {
        case heldBy(BoxLockInfo)
        case timedOut(BoxLockInfo?, TimeInterval)

        public var description: String {
            switch self {
            case .heldBy(let h):
                return "box '\(h.box)' is locked by pid \(h.pid) — \(humanDuration(h.ageSeconds)) "
                    + "— command: \(h.command) — reason: \(h.reason)"
            case .timedOut(let h, let waited):
                if let h {
                    return "box '\(h.box)' still locked after waiting \(humanDuration(waited)); "
                        + "held by pid \(h.pid) — \(humanDuration(h.ageSeconds)) "
                        + "— command: \(h.command) — reason: \(h.reason)"
                }
                return "box still locked after waiting \(humanDuration(waited))"
            }
        }
    }

    /// `<cacheRoot>/locks`.
    public static func directory(config: Config) -> URL {
        Paths.url(config.cacheRoot).appendingPathComponent("locks")
    }

    public static func lockURL(box: String, config: Config) -> URL {
        directory(config: config)
            .appendingPathComponent(sanitizeLockName(box) + ".lock")
    }

    /// Stato corrente senza acquisire. Non uccide né modifica nulla.
    public static func state(box: String, config: Config) -> ReadState {
        let url = lockURL(box: box, config: config)
        guard let data = try? Data(contentsOf: url) else { return .free }
        guard let info = try? JSONDecoder().decode(BoxLockInfo.self, from: data) else {
            // File presente ma illeggibile: non c'è un holder identificabile,
            // quindi è recuperabile (pid negativo ⇒ `pidAlive == false`).
            return .stale(BoxLockInfo(
                pid: -1, command: "<unreadable>", reason: "<unreadable lock>",
                startedAt: iso8601String(Date(timeIntervalSince1970: 0)), box: box))
        }
        if !info.pidAlive || info.ageSeconds > staleAfterSeconds {
            return .stale(info)
        }
        return .held(info)
    }

    /// Crea il lock in modo atomico ed esclusivo. Ritorna `true` se questo
    /// processo ha vinto, `false` se il lock esiste già. Il file di stato non è
    /// **mai** visibile vuoto: il JSON completo viene scritto su un temporaneo e
    /// pubblicato con `link()`, che fallisce con `EEXIST` se qualcuno è già
    /// dentro. Il temporaneo usa a sua volta `O_CREAT|O_EXCL`.
    private static func createLockAtomically(url: URL, content: Data) throws -> Bool {
        let dir = url.deletingLastPathComponent()
        let tmpURL = dir.appendingPathComponent(
            ".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0..<UInt32.max)).tmp")
        let fd = open(tmpURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: content)
        } catch {
            try? handle.close()
            _ = unlink(tmpURL.path)
            throw error
        }
        try? handle.close()
        let published = link(tmpURL.path, url.path) == 0
        _ = unlink(tmpURL.path)
        return published
    }

    /// `O_CREAT|O_EXCL`: atomico, niente TOCTOU. `wait` = secondi di attesa
    /// (0 = subito). `force` = rompi anche un lock VIVO, dichiarandolo nel log.
    public static func acquire(
        box: String,
        config: Config,
        command: String,
        reason: String,
        wait: TimeInterval = 0,
        force: Bool = false,
        onWait: (BoxLockInfo, TimeInterval) -> Void = { _, _ in }
    ) throws -> Handle {
        let dir = directory(config: config)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = lockURL(box: box, config: config)
        let started = Date()
        let deadline = started.addingTimeInterval(max(0, wait))

        while true {
            let info = BoxLockInfo(
                pid: getpid(), command: command, reason: reason,
                startedAt: iso8601String(Date()), box: box)

            // Pubblica il lock con contenuto completo: un lettore non vede mai
            // un file vuoto fra creazione e scrittura.
            if try createLockAtomically(url: url, content: try JSONEncoder().encode(info)) {
                return Handle(url: url, info: info)
            }

            switch state(box: box, config: config) {
            case .free:
                // Il file è sparito fra `open` e `state`: riprova a creare.
                continue

            case .held(let holder):
                if force {
                    Log.shared.warn("BoxLock: FORCE breaking live lock on box '\(box)': \(holder)")
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                if wait <= 0 {
                    throw LockError.heldBy(holder)
                }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    throw LockError.timedOut(holder, wait)
                }
                onWait(holder, Date().timeIntervalSince(started))
                Thread.sleep(forTimeInterval: min(2.0, max(0.05, remaining)))

            case .stale(let holder):
                Log.shared.warn("BoxLock: reclaiming stale lock on box '\(box)': \(holder)")
                try? FileManager.default.removeItem(at: url)
                continue
            }
        }
    }
}
