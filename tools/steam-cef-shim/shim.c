/*
 * MacHub's Steam CEF shim (GPLv3, part of MacHub).
 *
 * Steam's UI is Chromium (steamwebhelper.exe). Chromium draws in a separate GPU process and hands the frames to the
 * browser process's window; Wine's Mac driver doesn't implement that cross-process path ("Cross-process child window
 * Metal swapchains are not implemented"), and its ANGLE backend can't query the adapter Wine reports, so the window
 * stays black. Running Chromium in one process with software rendering avoids both (verified 2026-10-18 on
 * WineCX 26.2 / macOS 27: --in-process-gpu alone left the window black, --disable-gpu --single-process drew it).
 * Steam drops unknown -cef-* flags and restores a modified steamwebhelper.exe, so the flags are added from inside
 * the process instead.
 *
 * This DLL stands in for winmm.dll for steamwebhelper.exe only (HKCU\Software\Wine\AppDefaults\steamwebhelper.exe\
 * DllOverrides: winmm=native,builtin). Every winmm export is forwarded to Wine's real winmm, copied next to it as
 * winmm_orig.dll (see winmm.def). On load, in the browser process only (no --type= switch), it appends the flags
 * from MACHUB_CEF_FLAGS (default: --disable-gpu --single-process) to the command line GetCommandLineW returns.
 *
 * Wine's kernelbase returns a cached pointer (command_lineW) from GetCommandLineW, so the shim finds that pointer in
 * kernelbase's writable data and points it to the extended string. Nothing is written to disk, nothing in Steam's
 * folder changes, and every other program in the prefix loads Wine's own winmm.
 */
#include <windows.h>
#include <wchar.h>

static int is_browser_process(const WCHAR *cmdline)
{
    WCHAR path[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, path, MAX_PATH);
    if (!n || n >= MAX_PATH) return 0;
    const WCHAR *name = wcsrchr(path, L'\\');
    name = name ? name + 1 : path;
    if (_wcsicmp(name, L"steamwebhelper.exe")) return 0;
    return wcsstr(cmdline, L"--type=") == NULL;
}

/* Replaces every pointer-sized value equal to `old` in kernelbase's writable sections by `new`. */
static int repoint_kernelbase(const void *old, const void *new)
{
    HMODULE base = GetModuleHandleW(L"kernelbase.dll");
    if (!base) return 0;
    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)base;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)((BYTE *)base + dos->e_lfanew);
    IMAGE_SECTION_HEADER *section = IMAGE_FIRST_SECTION(nt);
    int count = 0;
    for (WORD i = 0; i < nt->FileHeader.NumberOfSections; i++, section++) {
        if (!(section->Characteristics & IMAGE_SCN_MEM_WRITE)) continue;
        const void **slot = (const void **)((BYTE *)base + section->VirtualAddress);
        SIZE_T slots = section->Misc.VirtualSize / sizeof(void *);
        for (SIZE_T j = 0; j < slots; j++) {
            if (slot[j] == old) { slot[j] = new; count++; }
        }
    }
    return count;
}

static void extend_command_line(void)
{
    const WCHAR *original = GetCommandLineW();
    if (!original || !is_browser_process(original)) return;

    WCHAR flags[512];
    DWORD n = GetEnvironmentVariableW(L"MACHUB_CEF_FLAGS", flags, ARRAYSIZE(flags));
    if (!n || n >= ARRAYSIZE(flags)) wcscpy(flags, L"--disable-gpu --single-process");
    if (wcsstr(original, flags)) return;

    SIZE_T length = wcslen(original) + 1 + wcslen(flags) + 1;
    WCHAR *extended = HeapAlloc(GetProcessHeap(), 0, length * sizeof(WCHAR));
    if (!extended) return;
    wcscpy(extended, original);
    wcscat(extended, L" ");
    wcscat(extended, flags);
    if (!repoint_kernelbase(original, extended)) HeapFree(GetProcessHeap(), 0, extended);
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(instance);
        extend_command_line();
    }
    return TRUE;
}
