import Foundation
import ApplicationServices
import IOKit.hid

/// Permessi **TCC** di macOS richiesti per l'input di gioco.
///
/// Su macOS la cattura *globale* di tastiera/mouse (`CGEventTap` / Accessibilità) e
/// di gamepad (`IOHIDManager` / Monitoraggio input) è legata al **percorso del
/// binario**: un runtime nuovo (es. `wine-gptk`) **non eredita** i permessi dati a
/// un altro runtime. Causa misurata (2026-10-01/02): tastiera e pad non arrivano
/// al gioco finché i due permessi non sono concessi.
///
/// I check `accessibility()`/`inputMonitoring()` riflettono il **processo
/// responsabile corrente** (GameX.app, Terminale, IDE…): è l'antenato che lancia il
/// runtime a dover avere il permesso, oltre al binario `wine`.
public enum Permissions {

    public enum Access: String, Sendable {
        case granted
        case denied
        case unknown

        public var isGranted: Bool { self == .granted }
    }

    /// Accessibilità (`AXIsProcessTrusted`).
    public static func accessibility() -> Access {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Monitoraggio input (`IOHIDCheckAccess`, listen event).
    public static func inputMonitoring() -> Access {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }

    /// Apre il pannello Privacy → Accessibilità.
    public static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// Apre il pannello Privacy → Monitoraggio input.
    public static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func open(_ url: String) {
        _ = try? ProcessRunner.run("/usr/bin/open", [url])
    }

    /// Percorsi da aggiungere a mano nei pannelli Privacy per un dato runtime:
    /// il binario `wine` e, se presente, il preloader.
    public static func manualEntries(forRuntimeRoot root: String) -> [String] {
        var paths = ["\(root)/bin/wine"]
        for extra in ["bin/wine64-preloader", "bin/wineserver"] {
            let full = "\(root)/\(extra)"
            if FileManager.default.fileExists(atPath: full) { paths.append(full) }
        }
        return paths
    }
}
