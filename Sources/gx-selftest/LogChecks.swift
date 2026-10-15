import Foundation
import GameXCore

// F003: il tetto di log. Test ermetico: tutto vive in una tmpdir, il processo
// scollega ~6 MB su stderr e il file resta limitato. Nessuna scrittura fuori
// dalla tmpdir, nessun Wine, nessuna box.
func runLogChecks(_ h: Harness) {
    print("Launch log cap (F003)")

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("gx-logcap-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }

    // ~6 MB su stderr, mai su stdout: stdout+stderr devono confluire nello stesso file.
    let script = #"head -c 6000000 /dev/zero 2>/dev/null | tr "\0" "x" >&2"#

    func write(_ capBytes: Int64, _ name: String) -> (LaunchLog.Outcome, URL) {
        let path = root.appendingPathComponent(name)
        let cap = LogCap(path: path, capBytes: capBytes)
        do {
            let outcome = try LaunchLog.run(
                "/bin/sh", ["-c", script],
                environment: ProcessInfo.processInfo.environment,
                cap: cap)
            return (outcome, path)
        } catch {
            h.check(false, "LaunchLog.run (\(name)): \(error)")
            return (LaunchLog.Outcome(exit: -1, written: 0, duBytes: 0,
                                      truncated: false, capBytes: capBytes), path)
        }
    }

    // 1) Cap 1 MB: si taglia, il file resta limitato, il marker c'è.
    let (capped, cappedPath) = write(1_000_000, "capped.log")
    h.check(capped.truncated, "6 MB with a 1 MB cap is reported as truncated")
    h.check(capped.written >= 6_000_000, "written counts every byte read (\(capped.written))")
    h.check(capped.duBytes <= 3_000_000, "the file stays bounded (du \(capped.duBytes))")
    h.equal(capped.duBytes, LaunchLog.du(cappedPath), "du() is the real on-disk size")
    let cappedText = (try? String(contentsOf: cappedPath, encoding: .utf8)) ?? ""
    h.check(cappedText.contains("=== gx: log truncated at "), "the capped file carries the marker")
    h.check(cappedText.contains(" MB ==="), "the marker names the cap in MB")

    // 2) Cap 50 MB: nessun taglio, il file è intero.
    let (whole, wholePath) = write(50_000_000, "whole.log")
    h.check(!whole.truncated, "6 MB under a 50 MB cap is not truncated")
    h.check(whole.written >= 6_000_000, "written counts every byte read (\(whole.written))")
    let wholeDu = LaunchLog.du(wholePath)
    h.check(wholeDu >= 5_000_000 && wholeDu <= 7_000_000, "the whole file is ~6 MB on disk (du \(wholeDu))")

    // 3) Cap 0 = nessun tetto: si scrive tutto e non si dichiara un taglio.
    let (unlimited, _) = write(0, "unlimited.log")
    h.check(!unlimited.truncated, "cap 0 writes everything, never truncated")
    h.check(unlimited.written >= 6_000_000, "cap 0 still counts every byte (\(unlimited.written))")
}
