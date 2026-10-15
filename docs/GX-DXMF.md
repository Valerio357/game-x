# gx + dxmf — design e contratto (stream `gx-dxmf`)

> Stream: `gx-dxmf` · ramo di stream: `gx-dxmf/core` · base: `ee1f267`
> Obiettivo: rendere `gx` capace di far girare un gioco **sotto dxmf** con **un comando**,
> invece della riga a mano con `WINEDLLPATH_PREPEND` + `WINEDLLOVERRIDES` che oggi si
> ricompone a memoria.

## 1. I fatti accertati (misurati su questa macchina, 2026-10-15)

| Fatto | Valore | Dove |
| --- | --- | --- |
| Host Wine del runtime dxmf | `~/wine-d3dmetal/bin/wine` = **wine-11.10** | `~/wine-d3dmetal` |
| Version pin dei moduli | `DXMF_WINE_PINNED_VERSION "11.10"` | `dxmf/src/thunk/bridge/dxmf_wine_runtime.h:25` |
| Moduli staggati | `d3d11`, `dxgi` (PE + unix) | `dxmf/build/game-stage/wine/{x86_64-windows,x86_64-unix}` |
| Contratto d'ambiente provato | `WINEDLLPATH_PREPEND=<stage>` + `WINEDLLOVERRIDES=d3d9,d3d11,dxgi=b` | `dxmf/CRITICAL.md:1400` (`DEC-137`) |
| Box con Steam + gioco | `~/WinePrefixes/dxfm-3d` (Wine **Staging 11.10**, Steam, **Thymesia** appid `1343240`) | `.gx.meta.json` + `appmanifest_1343240.acf` |
| Box storico | `~/WinePrefixes/SekiroDXMF` (Steam + Cuphead/Sekiro; meta `GPTK wine-7.7`) | `appmanifest_814380.acf` |
| Prova indipendente del pattern | `dxmf/scripts/app-probe.sh` → `measured=dxmf` con `lsof` + log; lancia l'**exe del gioco** con `SteamAppId` | `dxmf/build/app-probe/*/verdict.txt` |

**La trappola che nessuno indovina.** In un box con `dxvk` installato il registry
(`HKCU\Software\Wine\DllOverrides`) contiene gli override **native** per
`d3d9/d3d10core/d3d11/dxgi`. Un gioco che parte senza il nostro override muore
all'import con `STATUS_DLL_NOT_FOUND` (`0xC0000135`) **prima di qualunque codice dxmf**.
Quindi le due cose convivono e non si sostituiscono:

- **Steam resta su dxvk** — la sua UI (`steamwebhelper`/CEF) compone in D3D11 e senza
  dxvk la finestra è **nera**;
- **il gioco va su dxmf** — builtin (`=b`) che risolve sui moduli staggati.

**Il vincolo di versione.** La versione di Wine che esegue il processo deve combaciare
con quella dei moduli (`11.10`): l'ABI `WINE_UNIX_CALL` è legata alla versione. Un box
con runtime GPTK 7.7 non carica i nostri moduli. `gx` deve **rifiutare con un messaggio
chiaro** una coppia incompatibile, mai provarci.

## 2. API congelate per il blocco 1

Il blocco 1 introduce **solo file nuovi** più i punti di innesto dichiarati: nessun
WORKER tocca il file di un altro.

### `Sources/GameXCore/DXMF.swift` (nuovo) — runtime dxmf di prima classe

```swift
public enum DXMF {
    /// Un runtime dxmf = host Wine + stage dei moduli, con la stessa versione.
    public struct Info: Sendable, Equatable {
        public let wineBinary: String      // <runtimeRoot>/bin/wine
        public let runtimeRoot: URL        // ~/wine-d3dmetal
        public let wineVersion: String     // "wine-11.10"
        public let stageRoot: URL          // .../game-stage/wine  (WINEDLLPATH_PREPEND)
        public let modules: [String]       // ["d3d11","dxgi"]
        public let pinnedVersion: String?  // dichiarata dallo stage/manifest, se c'è
        public let wineMajor: Int?
        public var isUsable: Bool          // binario + PE + unix per ogni modulo
        /// Perché questo runtime non è utilizzabile (nil se lo è). Mai riparare in silenzio.
        public var unusableReason: String?
        /// Versione host ≠ versione dei moduli ⇒ messaggio; nil se combaciano.
        public var versionMismatch: String?
    }

    /// Diagnostica dxmf (una chiusura pesante alla volta, regola della factory).
    public struct Diagnostics: Sendable, Equatable {
        public var quiet: Bool          // DXMF_DIAG_QUIET  (default: true)
        public var frameLog: URL?       // DXMF_FRAME_TIME
        public var lockDir: String?     // DXMF_LOCK_DIR
        public var gateLockWait: Int?   // DXMF_GATE_LOCK_WAIT
        public init(quiet: Bool = true, frameLog: URL? = nil,
                    lockDir: String? = nil, gateLockWait: Int? = nil)
    }

    public static let pinnedWineVersion = "11.10"
    public static let defaultRuntimeRoot = "~/wine-d3dmetal"
    public static let overrideDefault = "d3d9,d3d11,dxgi=b"

    /// Host Wine + stage: il primo che risolve. `nil` = dxmf non installato.
    public static func discover(config: Config) -> Info?

    /// Solo lo stage (senza host), per `gx dxmf status` e per la diagnostica.
    public static func discoverStage(root: URL) -> (root: URL, modules: [String], pinned: String?)?

    /// Variabili d'ambiente del contratto d'ambiente. Sempre questi nomi.
    /// - WINEDLLPATH_PREPEND, WINEDLLOVERRIDES
    /// - DXMF_DIAG_QUIET / DXMF_FRAME_TIME / DXMF_LOCK_DIR / DXMF_GATE_LOCK_WAIT
    public static func environment(for info: Info, diagnostics: Diagnostics,
                                   extra: [String: String] = [:]) -> [String: String]

    /// Coppie (PE, unix) dei moduli presenti: la prova che i moduli sono i NOSTRI
    /// è il path, mai il nome.
    public static func moduleFiles(for info: Info) -> [(name: String, pe: URL, unix: URL)]
}
```

### `Sources/GameXCore/BoxLock.swift` (nuovo) — un lock per box

```swift
public struct BoxLockInfo: Codable, Sendable, Equatable {
    public var pid: Int32
    public var command: String     // "gx steam install dxmf-3d"
    public var reason: String      // cosa sta mutando il prefix
    public var startedAt: String   // ISO8601
    public var box: String
    public var ageSeconds: TimeInterval   // calcolato
    public var pidAlive: Bool
}

public enum BoxLock {
    public struct Handle { public func release() }

    public enum ReadState: Sendable {
        case free
        case held(BoxLockInfo)        // un mutatore è dentro adesso
        case stale(BoxLockInfo)       // holder morto o troppo vecchio
    }

    public static func directory(config: Config) -> URL   // <cache>/locks
    public static func lockURL(box: String, config: Config) -> URL
    public static func state(box: String, config: Config) -> ReadState

    /// `O_CREAT|O_EXCL`: atomico. `wait` = secondi di attesa del lock (0 = subito).
    /// `force` = rompi anche un lock VIVO, ma stampa chi ha rotto (consapevole).
    public static func acquire(box: String, config: Config, command: String,
                               reason: String, wait: TimeInterval = 0,
                               force: Bool = false,
                               onWait: (BoxLockInfo, TimeInterval) -> Void = { _, _ in }) throws -> Handle

    public enum LockError: Error, CustomStringConvertible {
        case heldBy(BoxLockInfo)
        case timedOut(BoxLockInfo?, TimeInterval)
    }
}
```

Regole: età > `staleAfterSeconds` (default **6 h**) **o** pid morto ⇒ `stale`, non
`held`. `--force` rompe anche un `held` e lo dichiara. Il lock si rilascia sempre
(`defer`), anche su errore.

### `Sources/GameXCore/Orphans.swift` (nuovo) — igiene prima di un lancio

```swift
public enum Orphans {
    public struct Report: Sendable, Equatable {
        public let winedbg: [Int32]        // `winedbg --auto` orfani
        public let totalProcesses: Int
        public let softLimit: Int?
        public var isCrowded: Bool         // totalProcesses vicino al limite
    }
    public static func scan() -> Report
    /// Uccide i `winedbg` orfani; ritorna quanti.
    public static func sweepWinedbg() -> Int
}
```

### Innesti (dichiarati, non condivisi)

- `Runtime.swift` (W1): `Kind.dxmfWine = "Game-X Wine+DXMF"`, `ResolvedRuntime.dxmf`,
  `Runtime.dxmfRuntimes(config:)`, `select("dxmf"|"wine-dxmf")`, `choices` include dxmf.
- `Config.swift` (W1): `GX_DXMF_WINE` (default `~/wine-d3dmetal`),
  `GX_DXMF_STAGE` (default: stage trovato sotto il clone dxmf), `GX_DXMF_LOCK_DIR`,
  `GX_DXMF_GATE_LOCK_WAIT`, `GX_DXMF_LOG_CAP_MB` (default 512).

## 3. Blocco 2 — il CLI impedisce gli errori già commessi tre volte

| # | Errore reale (2026-10-15) | Cosa deve fare `gx` |
| --- | --- | --- |
| 1 | updater di Steam piantato a 70/238 MB; `INSTALL` che non parte perché il prefix viene ricreato sotto | **un lock per box** onorato da ogni comando che muta il prefix; errore esplicito con pid + da quanto; `--force` consapevole |
| 2 | `ls` del box → *«No such file or directory»* su una cartella elencata dal padre (riprodotto: `stat` assoluto `ENOENT` mentre `listdir` dello stesso padre elenca il nome) | le query risolvono il box **per enumerazione**, mai come «not found» per un nome che il listino mostra; con lock attivo: *attendere* o dichiarare **«in ricostruzione»** |
| 3 | `WINEDEBUG=+d3d11,+dxgi` → **26 GB** in una run | ogni lancio con debug ha un **cap** (default 512 MB) e **misura** con `du` ciò che scrive |
| 4 | 723 `winedbg --auto` orfani → process table esaurita, 3 misure invalidate | prima di un lancio: rileva, conta e segnala gli orfani (e li spazza con `--sweep`) |
| 5 | diagnostica dxmf accesa costa frame | `--frame-log FILE` → `DXMF_FRAME_TIME`; default **spenta** (`DXMF_DIAG_QUIET=1`); esposti `DXMF_LOCK_DIR` / `DXMF_GATE_LOCK_WAIT` |

## 4. Comandi (superficie finale)

```sh
gx dxmf status  [box]                       host, stage, pin di versione, lock, orfani
gx dxmf run     <box> [--] -- <exe|cmd...>  lancia il GIOCO con il contratto dxmf
                  [--frame-log FILE] [--winedebug SPEC] [--max-log-mb N]
                  [--appid ID] [--lock-wait SEC] [--force] [--dry-run] [--sweep]
gx dxmf modules <box>                       coppie (PE, unix) e pin, per la prova lsof

gx box create <name> --runtime dxmf         risolve a ~/wine-d3dmetal + stage, rifiuta la coppia incompatibile
gx steam launch <box> <appid> --runtime dxmf
```

`gx steam launch <box> <appid> --runtime dxmf` con Steam **già avviato**: risolve l'exe
del gioco dal `appmanifest_<appid>.acf`, poi lancio **diretto** dell'exe con il contratto
dxmf e `SteamAppId=<appid>` (il pattern provato da `app-probe.sh`). Se l'exe non è
risolvibile, **rifiuta** e indica `gx dxmf run`, mai un `-applaunch` che non
trasporterebbe l'ambiente al gioco.

## 5. Evidenza di accettazione (obbligatoria)

1. `gx dxmf run dxmf-3d -- <Thymesia.exe> --appid 1343240` avvia il gioco;
2. `lsof` sul processo del gioco mostra `<stage>/x86_64-unix/d3d11.so` **e** `dxgi.so`
   (path, non nome) — come ha già fatto il CEO;
3. Steam resta vivo e con UI visibile nello stesso prefix;
4. i moduli del box (`user.reg`) restano **non toccati**: il rifiuto `0xC0000135` non
   deve comparire;
5. `gx dxmf status` dichiara host/stage/pin; una coppia incompatibile è **rifiutata**.
