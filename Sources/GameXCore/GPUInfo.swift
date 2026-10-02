import Foundation

/// Informazioni su sistema e capacità grafiche / Metal (DESIGN §8, §14).
public struct GPUInfo: Codable, Sendable {
    public let macOSVersion: String
    public let architecture: String            // "arm64" | "x86_64"
    public let chip: String?
    public let gpuCores: Int?

    public init(macOSVersion: String, architecture: String, chip: String?, gpuCores: Int? = nil) {
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.chip = chip
        self.gpuCores = gpuCores
    }

    public var isAppleSilicon: Bool { architecture == "arm64" }
    public var macOSMajor: Int? { Int(macOSVersion.split(separator: ".").first ?? "") }

    /// Maximum Metal version reasonably available on this machine.
    public var maxMetal: String {
        if isAppleSilicon, let major = macOSMajor, major >= 27 { return "Metal 4 (with GPTK 4)" }
        return "Metal 3"
    }

    /// Metal 4 requires Apple Silicon + macOS 27 + GPTK 4 (DESIGN §2.2).
    public func metal4Verdict(gptkVersion: String?) -> String {
        var reasons: [String] = []
        if !isAppleSilicon { reasons.append("requires Apple Silicon") }
        if let major = macOSMajor, major < 27 { reasons.append("requires macOS 27 (current \(macOSVersion))") }
        if let gptk = gptkVersion, !gptk.contains("4") { reasons.append("requires GPTK 4 (current \(gptk))") }
        return reasons.isEmpty
            ? "Metal 4 available"
            : "Metal 4 unavailable: " + reasons.joined(separator: ", ")
    }

    public static func detect() -> GPUInfo {
        GPUInfo(
            macOSVersion: osVersion(),
            architecture: architecture(),
            chip: chipName(),
            gpuCores: gpuCores()
        )
    }

    static func osVersion() -> String {
        if let v = ProcessRunner.firstLine("/usr/bin/sw_vers", ["-productVersion"]) { return v }
        return ProcessInfo.processInfo.operatingSystemVersionString
    }

    static func architecture() -> String {
        var info = utsname(); uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        if machine == "x86_64" {
            let translated = sysctl("sysctl.proc_translated") ?? 0
            if translated == 1 { return "arm64" }
        }
        return machine
    }

    static func chipName() -> String? {
        sysctlString("machdep.cpu.brand_string")
    }

    /// Numero di core GPU (Apple Silicon) da `hw.perflevel0.graphics`/`hw.gpu.corecount`.
    static func gpuCores() -> Int? {
        sysctl("hw.gpu.corecount")                       // macOS 15+
            ?? sysctl("hw.perflevel0.graphics")
            ?? sysctl("hw.perflevel1.graphics")
    }

    // MARK: - sysctl helpers

    static func sysctl(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname(name, &value, &size, nil, 0) == 0 { return Int(value) }
        return nil
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
