import Foundation
import GameXCore

/// Il lock è per le **mutazioni**, non per la vita di un'applicazione.
/// Difetto reale (2026-10-15, trovato dal CEO usando `gx`): `gx dxmf run` teneva il
/// lock per tutta la vita del processo, quindi la sequenza vera — Steam vivo +
/// gioco lanciato nella stessa box (handshake SteamAPI) — era **impossibile**.
func runLockScopeChecks(_ h: Harness) {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("gx-lockscope-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let config = Config(cacheRoot: root.path)
    let box = "lockbox"

    // 1) Con una MUTAZIONE in corso, un lancio è rifiutato e il rifiuto nomina chi muta.
    let mutation = try? BoxLock.acquire(box: box, config: config,
                                        command: "gx steam install lockbox",
                                        reason: "install", wait: 0)
    h.check(mutation != nil, "the mutation takes the lock")
    do {
        try BoxLock.allowsLaunch(box: box, config: config)
        h.check(false, "a launch must be refused while a mutation is in progress")
    } catch let BoxLock.LockError.heldBy(info) {
        h.equal(info.command, "gx steam install lockbox",
                "the launch refusal names the mutation in progress")
    } catch {
        h.check(false, "the launch refusal has the wrong error: \(error)")
    }

    // 2) Ma un lancio NON prende il lock: due lanci insieme sono la norma.
    try? mutation?.release()
    h.check(BoxLock.state(box: box, config: config) == .free, "no lock after the mutation ends")
    do {
        try BoxLock.allowsLaunch(box: box, config: config)
        try BoxLock.allowsLaunch(box: box, config: config)   // il secondo lancio
        h.check(true, "two launches in a row are allowed (the lock is not held by a run)")
    } catch {
        h.check(false, "a launch must be allowed with no mutation in progress: \(error)")
    }
    h.check(BoxLock.state(box: box, config: config) == .free,
            "a launch leaves the box UNLOCKED (this is the defect that was fixed)")

    // 3) La valvola di sfogo: --no-lock/--force passa e lo DICHIARA.
    let held = try? BoxLock.acquire(box: box, config: config, command: "gx deps install lockbox",
                                    reason: "deps", wait: 0)
    var warned = false
    do {
        try BoxLock.allowsLaunch(box: box, config: config, force: true, warn: { _ in warned = true })
        h.check(warned, "forcing a launch while a mutation runs is declared, not silent")
    } catch {
        h.check(false, "force must allow the launch: \(error)")
    }
    try? held?.release()

    // 4) `--lock-wait`: aspetta la fine della mutazione invece di fallire.
    let waiter = try? BoxLock.acquire(box: box, config: config, command: "gx box remove lockbox",
                                      reason: "remove", wait: 0)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) { waiter?.release() }
    do {
        try BoxLock.allowsLaunch(box: box, config: config, wait: 10)
        h.check(true, "lock-wait waits for the mutation to finish")
    } catch {
        h.check(false, "lock-wait must not fail while the mutation is still running: \(error)")
    }

    // 5) La guardia distruttiva: una box IN USO si riconosce dal socket del suo
    //    wineserver — non dai processi (`ps eww` su macOS non stampa l'ambiente).
    let usedBox = root.appendingPathComponent("boxes/inuse")
    try? fm.createDirectory(at: usedBox.appendingPathComponent("drive_c"),
                            withIntermediateDirectories: true)
    let freeBox = root.appendingPathComponent("boxes/free")
    try? fm.createDirectory(at: freeBox.appendingPathComponent("drive_c"),
                            withIntermediateDirectories: true)

    h.check(BoxLock.prefixInUse(prefix: freeBox).verified, "the in-use probe could look")
    h.check(!BoxLock.prefixInUse(prefix: freeBox).inUse,
            "a box nobody started is NOT reported as in use")

    // Si SIMULA il wineserver vivo creando esattamente il file che Wine crea:
    // /tmp/.wine-<uid>/server-<devhex>-<inohex>/socket
    var st = stat()
    _ = stat(usedBox.resolvingSymlinksInPath().path, &st)
    let name = "server-" + String(UInt64(bitPattern: Int64(st.st_dev)), radix: 16)
        + "-" + String(UInt64(st.st_ino), radix: 16)
    let dir = URL(fileURLWithPath: "/tmp/.wine-\(getuid())/\(name)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let socket = dir.appendingPathComponent("socket")
    fm.createFile(atPath: socket.path, contents: nil)
    defer { try? fm.removeItem(at: dir) }

    let inUse = BoxLock.prefixInUse(prefix: usedBox)
    h.check(inUse.inUse, "a live wineserver socket makes the box 'in use' (protects 11 GB)")
    h.check((inUse.socketPath ?? "").contains(name), "the report names the socket that proves it")
    h.check(!BoxLock.prefixInUse(prefix: freeBox).inUse,
            "another box without a wineserver is not blamed")
}
