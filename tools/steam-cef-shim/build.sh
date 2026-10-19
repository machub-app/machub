#!/bin/bash
# Builds the Steam CEF shim (winmm.dll, x86_64) with llvm-mingw.
#
#   tools/steam-cef-shim/build.sh <llvm-mingw dir> <Wine's x86_64-windows/winmm.dll> <output dir>
#
# The forwarding table is generated from the winmm.dll of the runtime it will run with, so every export
# (named or ordinal-only) reaches Wine's real winmm, renamed winmm_orig.dll.
set -euo pipefail
MINGW="$1"; WINMM="$2"; OUT="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT"
DEF="$OUT/winmm.def"
{
  echo "LIBRARY winmm.dll"
  echo "EXPORTS"
  "$MINGW/bin/llvm-objdump" -p "$WINMM" | awk '
    /Ordinal +RVA +Name/ { table = 1; next }
    table && NF == 0 { exit }
    table && NF >= 3 { printf "  %s=winmm_orig.%s @%s\n", $3, $3, $1 }
    table && NF == 2 { printf "  machub_ord%s=winmm_orig.#%s @%s NONAME\n", $1, $1, $1 }'
} > "$DEF"
"$MINGW/bin/x86_64-w64-mingw32-clang" -O2 -shared -municode -o "$OUT/winmm.dll" "$HERE/shim.c" "$DEF" -Wl,--kill-at
echo "Built $OUT/winmm.dll ($(grep -c winmm_orig "$DEF") forwarded exports)"
