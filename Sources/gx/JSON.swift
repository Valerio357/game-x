import Foundation
import GameXCore

/// Strutture per l'output JSON di `gx info` (utile anche alla futura GUI, M6).

struct ConfigJSON: Encodable {
    let prefixRoot: String
    let gamesRoot: String
    let logsRoot: String
    let gptkApp: String
    let winetricks: String
    let arch: String
    let steamPrefix: String
}

struct RuntimeJSON: Encodable {
    let kind: String
    let binary: String
    let version: String
    let wineMajor: Int?
    let d3dmetal: Bool
    let rosetta: Bool
    let steamOK: Bool
}

struct InfoReport: Encodable {
    let version: String
    let configFile: String
    let config: ConfigJSON
    let runtime: RuntimeJSON?
    let gpu: GPUInfo
}

struct RuntimeListJSON: Encodable {
    let kind: String
    let binary: String
    let version: String
    let wineMajor: Int?
    let d3dmetal: Bool
}

struct GPUReport: Encodable {
    let gpu: GPUInfo
    let metal4: String
    let maxMetal: String
}

struct PrefixJSON: Encodable {
    let name: String
    let path: String
    let runtimeKind: String?
    let runtimeVersion: String?
    let hasSteam: Bool
    let shimInstalled: Bool?
    let shimProtected: Bool?
    let sizeBytes: Int64
}
