#!/bin/bash
# Packs MacHub's Windows engine: the Wine that scripts/build-wine.sh compiled, the macOS libraries, Wine Mono and
# Gecko from the WineHQ package, DXMT, DXVK and the Steam CEF shim. Every download is checked against a pinned SHA-256.
#
#   WINE_BUILD=<install dir of scripts/build-wine.sh> WINE_SOURCES=<wine-x.y.tar.xz> VERSION=<engine version> \
#   LLVM_MINGW=<llvm-mingw dir> scripts/build-runtime.sh [download-cache-dir] [output-dir]
#
# Output: MacHubRuntime-<version>.tar.xz and runtime-manifest.json (version, archive, SHA-256, size, download URL).
# Publish the archive as the GitHub release `runtime-<version>`, then copy the manifest to
# MacHub/Engine/runtime-manifest.json. (Earlier CrossOver-based variants were dropped: Steam never connected with
# them, see docs/ENGINE.md.)
set -euo pipefail

: "${WINE_BUILD:?set WINE_BUILD to the install dir of scripts/build-wine.sh}"
: "${WINE_SOURCES:?set WINE_SOURCES to the wine-x.y.tar.xz it was built from}"
VERSION="${VERSION:-${VERSION_OVERRIDE:?set VERSION to the engine version, e.g. 1.0.6}}"
RELEASES="https://github.com/machub-app/machub/releases/download"

# name|version|license|source repo|release tag|asset|sha256 (GitHub's published digest)
COMPONENTS=(
  "macos-libraries|11.0_1 (wine-stable)|LGPL-2.1-or-later|Gcenx/macOS_Wine_builds|11.0_1|wine-stable-11.0_1-osx64.tar.xz|b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388"
)
COMPONENTS+=(
  "dxmt|0.80|MIT|3Shain/dxmt|v0.80|dxmt-v0.80-builtin.tar.gz|8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d"
  "dxvk|1.10.3-20230507 (macOS async repack)|Zlib|Gcenx/DXVK-macOS|v1.10.3-20230507-repack|dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz|810b1e5caf8ce975b784fae866a130ad23fa0ea233b0e5609cbc4a45f3ef6f00"
)

CACHE="${1:-build/runtime-cache}"
OUT="${2:-build/runtime}"
mkdir -p "$CACHE" "$OUT"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/MacHubRuntime-$VERSION"
mkdir -p "$ROOT"

mkdir -p "$ROOT/wine"
cp -a "$WINE_BUILD/." "$ROOT/wine/"
src_sha="$(shasum -a 256 "$WINE_SOURCES" | cut -d' ' -f1)"
components_json=$(printf '\n    {"name": "wine", "version": "%s (WineHQ sources + Gcenx and MacHub patches, built by MacHub)", "license": "LGPL-2.1-or-later", "source": "https://dl.winehq.org/wine/source/", "sha256": "%s"}' "$(basename "$WINE_SOURCES" .tar.xz)" "$src_sha")
for entry in "${COMPONENTS[@]}"; do
  IFS='|' read -r name version license repo tag asset sha <<<"$entry"
  file="$CACHE/$asset"
  if [[ ! -f "$file" ]]; then
    echo "Downloading $asset from $repo…"
    curl -fL --retry 3 -o "$file.part" "https://github.com/$repo/releases/download/$tag/$asset"
    mv "$file.part" "$file"
  fi
  actual="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  if [[ "$actual" != "$sha" ]]; then
    echo "SHA-256 mismatch for $asset: expected $sha, got $actual" >&2
    exit 1
  fi

  unpack="$STAGE/unpack-$name"
  mkdir -p "$unpack"
  tar -xf "$file" -C "$unpack"
  case "$name" in
    macos-libraries)
      mkdir -p "$ROOT/wine/lib" "$ROOT/wine/share/wine"
      cp -a "$unpack/"*.app/Contents/Resources/wine/lib/*.dylib "$ROOT/wine/lib/"
      # Wine Mono and Gecko, shared by every prefix (a compiled Wine doesn't include them).
      for extra in mono gecko; do
        [[ -d "$ROOT/wine/share/wine/$extra" ]] || cp -a "$unpack/"*.app/Contents/Resources/wine/share/wine/$extra "$ROOT/wine/share/wine/"
      done ;;
    *) mkdir -p "$ROOT/$name" && cp -R "$unpack"/*/* "$ROOT/$name/" ;;
  esac

  components_json+=","
  components_json+=$(printf '\n    {"name": "%s", "version": "%s", "license": "%s", "source": "https://github.com/%s/releases/tag/%s", "sha256": "%s"}' \
    "$name" "$version" "$license" "$repo" "$tag" "$sha")
done

# DXMT's winemetal bridge only works builtin-loaded (its __wine_unix_call reaches winemetal.so): it lives in
# Wine's own folders. Its d3d11/dxgi/d3d10core stay in dxmt/ and are deployed per program by MacHub.
if [[ -d "$ROOT/dxmt" ]]; then
  cp "$ROOT/dxmt/x86_64-windows/winemetal.dll" "$ROOT/wine/lib/wine/x86_64-windows/winemetal.dll"
  cp "$ROOT/dxmt/i386-windows/winemetal.dll" "$ROOT/wine/lib/wine/i386-windows/winemetal.dll"
  cp "$ROOT/dxmt/x86_64-unix/winemetal.so" "$ROOT/wine/lib/wine/x86_64-unix/winemetal.so"
fi

# Steam's UI shim (tools/steam-cef-shim), built against this runtime's own winmm.dll.
if [[ -n "${LLVM_MINGW:-}" ]]; then
  mkdir -p "$ROOT/shims/x86_64-windows"
  "$(dirname "$0")/../tools/steam-cef-shim/build.sh" "$LLVM_MINGW" "$ROOT/wine/lib/wine/x86_64-windows/winmm.dll" "$STAGE/shim"
  cp "$STAGE/shim/winmm.dll" "$ROOT/shims/x86_64-windows/winmm.dll"
fi

cat >"$ROOT/runtime.json" <<EOF
{
  "version": "$VERSION",
  "components": [$components_json
  ]
}
EOF

# Downloaded files carry no quarantine for the app, but strip any left by the build machine.
xattr -cr "$ROOT"

ARCHIVE="MacHubRuntime-$VERSION.tar.xz"
echo "Compressing $ARCHIVE…"
tar -C "$STAGE" -cJf "$OUT/$ARCHIVE" "MacHubRuntime-$VERSION"
sha="$(shasum -a 256 "$OUT/$ARCHIVE" | cut -d' ' -f1)"
size="$(stat -f %z "$OUT/$ARCHIVE")"

cat >"$OUT/runtime-manifest.json" <<EOF
{
  "version": "$VERSION",
  "archive": "$ARCHIVE",
  "sha256": "$sha",
  "size": $size,
  "url": "$RELEASES/runtime-$VERSION/$ARCHIVE"
}
EOF
echo "Done: $OUT/$ARCHIVE ($size bytes, sha256 $sha)"
