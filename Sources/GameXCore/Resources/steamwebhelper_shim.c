/*
 * steamwebhelper_shim.c — Game-X
 *
 * Shim per `steamwebhelper.exe` che aggira il black screen di Steam su
 * macOS/Wine (Wine bug #60263: winemac.drv non implementa le cross-process
 * child window Metal swapchain).
 *
 * Il processo CEF di Steam chiede una Metal view per una child window il cui
 * root vive nel browser process; Wine ritorna NULL e il GPU process muore,
 * lasciando la finestra nera. Fondendo renderer/GPU/utility nel browser
 * process (`--single-process`) il problema cross-process sparisce.
 *
 * Flag iniettati:
 *   --no-sandbox --disable-gpu --single-process
 *
 * `--in-process-gpu` da solo NON basta: lascia renderer/utility come processi
 * separati, quindi il problema resta.
 *
 * Build (vedi scripts/build-steamwebhelper-shim.sh):
 *   x86_64-w64-mingw32-gcc -O2 -o shim64.exe steamwebhelper_shim.c
 *   i686-w64-mingw32-gcc   -O2 -o shim32.exe steamwebhelper_shim.c
 *
 * Install: rinominare l'originale in `steamwebhelper_real.exe`, copiare lo
 * shim come `steamwebhelper.exe`. Game-X NON usa più `chflags uchg` (bloccare
 * il file impediva a Steam di applicare gli aggiornamenti, causando
 * "failed to rename ... error 5" e fatal error). Lo shim viene invece
 * rilevato (tramite GX_SHIM_MARKER) e reinstallato automaticamente.
 *
 * Licenza: MIT (coerente con il progetto Game-X).
 */

#include <windows.h>
#include <stdio.h>
#include <string.h>

/* Marker riconoscibile: serve a Game-X per capire se steamwebhelper.exe è il
 * nostro shim o è stato ripristinato/sovrascritto da un aggiornamento di Steam
 * (in tal caso va reinstallato). Inserito come stringa nel binario. */
volatile const char *GX_SHIM_MARKER = "game-x-steamwebhelper-shim-v2";

int main(int argc, char *argv[]) {
    (void)GX_SHIM_MARKER; /* mantiene il marker nel binario */
    char cmdline[32768];
    char exepath[MAX_PATH];
    char *lastslash;
    int offset;

    /* Directory dello shim: l'eseguibile reale sta accanto. */
    GetModuleFileNameA(NULL, exepath, MAX_PATH);
    lastslash = strrchr(exepath, '\\');
    if (lastslash) *(lastslash + 1) = '\0';

    offset = snprintf(cmdline, sizeof(cmdline),
                      "\"%ssteamwebhelper_real.exe\"", exepath);
    if (offset < 0 || (size_t)offset >= sizeof(cmdline)) return 1;

    /* Se i figli vengono reinvocati (in teoria no con --single-process),
       non aggiungere i flag una seconda volta. */
    int already = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--single-process") == 0) { already = 1; break; }
    }

    /* Propaga tutti gli argomenti originali, con quoting dei path con spazi. */
    for (int i = 1; i < argc; i++) {
        int needed = (strchr(argv[i], ' ') != NULL)
            ? snprintf(cmdline + offset, sizeof(cmdline) - offset, " \"%s\"", argv[i])
            : snprintf(cmdline + offset, sizeof(cmdline) - offset, " %s", argv[i]);
        if (needed < 0 || (size_t)(offset + needed) >= sizeof(cmdline)) return 1;
        offset += needed;
    }

    /* Flag di compatibilita' Wine/macOS, una sola volta. */
    if (!already) {
        int needed = snprintf(cmdline + offset, sizeof(cmdline) - offset,
                              " --no-sandbox --disable-gpu --single-process");
        if (needed < 0 || (size_t)(offset + needed) >= sizeof(cmdline)) return 1;
    }

    STARTUPINFOA si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    if (!CreateProcessA(NULL, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi))
        return 1;

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return code;
}
