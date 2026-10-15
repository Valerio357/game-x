// Elenca le finestre sullo schermo con pid del proprietario, id, titolo e bounds.
// Serve all'accettazione per catturare ESATTAMENTE la finestra della mia box, senza
// il permesso Accessibility (che `System Events` richiede) e senza toccare le
// finestre di altri.
//
//   swift evidence/acceptance/winlist.swift            # tutte
//   swift evidence/acceptance/winlist.swift <pid>...   # solo quelle di questi pid
import AppKit
import CoreGraphics

let wanted = Set(CommandLine.arguments.dropFirst().compactMap { Int($0) })
guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    print("no window list (Screen Recording permission?)")
    exit(1)
}
for w in list {
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
    if !wanted.isEmpty && !wanted.contains(pid) { continue }
    let num = w[kCGWindowNumber as String] as? Int ?? 0
    let name = w[kCGWindowOwnerName as String] as? String ?? "?"
    let title = w[kCGWindowName as String] as? String ?? ""
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = b["X"] as? Double ?? 0, y = b["Y"] as? Double ?? 0
    let width = b["Width"] as? Double ?? 0, height = b["Height"] as? Double ?? 0
    if width < 200 || height < 150 { continue }          // ignora toolbar/menu/ombra
    if layer != 0 { continue }                            // solo finestre normali
    let onScreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
    print("\(num)\tpid=\(pid)\t\(Int(width))x\(Int(height))+\(Int(x))+\(Int(y))\tonscreen=\(onScreen)\t\(name)\t\(title)")
}
