import Foundation
import Darwin
import GameXCore

// Igiene (F002): lock per box + orfani. Test ermetici: tutto vive in una
// tmpdir passata via `Config.cacheRoot`; mai nel vero ~/Library/Caches/game-x.

private func hygieneIsFree(_ s: BoxLock.ReadState) -> Bool {
    if case .free = s { return true }
    return false
}

private func hygieneIsHeld(_ s: BoxLock.ReadState) -> Bool {
    if case .held = s { return true }
    return false
}

private func hygieneIsStale(_ s: BoxLock.ReadState) -> Bool {
    if case .stale = s { return true }
    return false
}

private func hygieneWriteLock(_ info: BoxLockInfo, box: String, config: Config) throws {
    let url = BoxLock.lockURL(box: box, config: config)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(info).write(to: url)
}

private func hygieneISO(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
}

func runHygieneChecks(_ h: Harness) {
    print("Hygiene: box lock + orphans (F002)")

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("gx-hygiene-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let config = Config(cacheRoot: root.path)

    // Il lock vive sotto <cacheRoot>/locks e non tocca percorsi reali.
    h.equal(BoxLock.directory(config: config).path,
            root.appendingPathComponent("locks").path,
            "lock directory is <cacheRoot>/locks")
    h.equal(BoxLock.lockURL(box: "my box", config: config).lastPathComponent, "my_box.lock",
            "box name is sanitized into the file name")

    // 1) Due mutatori sullo stesso box: il secondo `wait: 0` DEVE fallire.
    let box = "lockbox"
    h.check(hygieneIsFree(BoxLock.state(box: box, config: config)), "empty box is free")

    let first: BoxLock.Handle
    do {
        first = try BoxLock.acquire(box: box, config: config,
                                    command: "gx steam install lockbox",
                                    reason: "install", wait: 0)
    } catch {
        h.check(false, "first acquire succeeds: \(error)")
        return
    }
    defer { first.release() }
    h.check(hygieneIsHeld(BoxLock.state(box: box, config: config)), "box held after acquire")

    do {
        _ = try BoxLock.acquire(box: box, config: config,
                                command: "gx steam launch lockbox",
                                reason: "launch", wait: 0)
        h.check(false, "second acquire must fail while the first holds the box")
    } catch let BoxLock.LockError.heldBy(holder) {
        h.equal(holder.pid, getpid(), "heldBy reports the holder pid")
        h.equal(holder.command, "gx steam install lockbox", "heldBy reports what the holder is doing")
        h.check(holder.pidAlive, "heldBy holder is alive")
    } catch {
        h.check(false, "second acquire returned the wrong error: \(error)")
    }

    // 2) Dopo il release il box si riprende.
    first.release()
    h.check(hygieneIsFree(BoxLock.state(box: box, config: config)), "box free after release")
    do {
        let again = try BoxLock.acquire(box: box, config: config,
                                        command: "gx steam install lockbox",
                                        reason: "install", wait: 0)
        h.check(true, "acquire succeeds after release")
        again.release()
    } catch {
        h.check(false, "acquire after release: \(error)")
    }

    // 3) Lock con pid inesistente ⇒ stale (recuperabile).
    let deadBox = "deadbox"
    do {
        try hygieneWriteLock(
            BoxLockInfo(pid: 999_999, command: "gone", reason: "crash",
                        startedAt: hygieneISO(Date()), box: deadBox),
            box: deadBox, config: config)
        h.check(hygieneIsStale(BoxLock.state(box: deadBox, config: config)),
                "lock with a nonexistent pid is stale")
        let taken = try BoxLock.acquire(box: deadBox, config: config,
                                        command: "gx steam launch deadbox",
                                        reason: "launch", wait: 0)
        h.check(true, "stale lock can be taken")
        taken.release()
    } catch {
        h.check(false, "stale-pid scenario: \(error)")
    }

    // 4) Lock vecchio di 7 h con pid VIVO ⇒ stale per età (> 6 h).
    let oldBox = "oldbox"
    do {
        try hygieneWriteLock(
            BoxLockInfo(pid: getpid(), command: "old", reason: "install",
                        startedAt: hygieneISO(Date().addingTimeInterval(-7 * 3600)), box: oldBox),
            box: oldBox, config: config)
        let state = BoxLock.state(box: oldBox, config: config)
        h.check(hygieneIsStale(state), "lock older than 6h is stale even with a live pid")
        if case .stale(let info) = state {
            h.check(info.pidAlive, "the 7h-old lock's pid is still alive (staleness comes from age)")
        }
    } catch {
        h.check(false, "old-lock scenario: \(error)")
    }

    // 5) `force` rompe un lock VIVO e lo dichiara; il vecchio release non ruba il nuovo.
    let forceBox = "forcebox"
    do {
        let holder = try BoxLock.acquire(box: forceBox, config: config,
                                         command: "gx steam install forcebox",
                                         reason: "install", wait: 0)
        let forcer = try BoxLock.acquire(box: forceBox, config: config,
                                         command: "gx steam launch forcebox",
                                         reason: "launch", wait: 0, force: true)
        h.check(true, "force breaks a live lock")
        if case .held(let info) = BoxLock.state(box: forceBox, config: config) {
            h.equal(info.command, "gx steam launch forcebox", "the forced lock names the new holder")
        } else {
            h.check(false, "forced lock is held by the new holder")
        }
        holder.release()
        h.check(hygieneIsHeld(BoxLock.state(box: forceBox, config: config)),
                "the broken holder's release does not steal the new lock")
        forcer.release()
        h.check(hygieneIsFree(BoxLock.state(box: forceBox, config: config)),
                "the new holder's release frees the box")
    } catch {
        h.check(false, "force scenario: \(error)")
    }

    // 6) `parse` è puro: esattamente i 3 `winedbg --auto`, ignora `winedbg` da solo.
    let psSample = """
      PID COMMAND
      101 /usr/bin/winedbg --auto
      202 winedbg --auto
      303 notwinedbg --auto
      404 winedbg
      505 /Applications/Wine/bin/winedbg --auto foo.dll
      606 wineserver
    """
    h.equal(Orphans.parse(psSample), [101, 202, 505],
            "parse finds exactly the winedbg --auto pids")
    h.equal(Orphans.parse(""), [], "empty ps output parses to no orphans")
    h.equal(Orphans.parse("  PID COMMAND\n    1 /sbin/launchd"), [], "no winedbg → no orphans")
}
