#!/bin/bash
# Builds WineHQ's Wine for MacHub's runtime with the same configuration as the official macOS packages (Gcenx's
# MacPorts wine-stable port), plus MacHub's patches in tools/wine-patches/. x86_64 host (runs under Rosetta 2),
# new-style WoW64.
#
#   scripts/build-wine.sh <wine-x.y.tar.xz> <work-dir> <install-dir>
#
# <work-dir> must hold an extracted llvm-mingw (macOS universal). MACOS_LIBS: x86_64 dylibs Wine links against and
# ships with (wine/lib of the WineHQ macOS package). Homebrew: bison pkgconf freetype gnutls sdl2.
# Build against the oldest SDK at hand (SDKROOT=…/MacOSX26.5.sdk, read by xcrun): with a newer SDK, configure finds
# functions older macOS lack and Wine imports them weakly (engine 1.0.6 was built with the macOS 26.5 SDK).
set -euo pipefail

TARBALL="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
WORK="$(cd "$2" && pwd)"
PREFIX="$3"
MACOS_LIBS="${MACOS_LIBS:?set MACOS_LIBS to a folder of x86_64 dylibs (wine/lib of the WineHQ package)}"
NAME="$(basename "$TARBALL" .tar.xz)"
SRC="$WORK/$NAME"
BUILD="$WORK/build-$NAME"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
BREW="$(brew --prefix)"
PATCHES="$(cd "$(dirname "$0")/../tools/wine-patches" && pwd)"

if [[ ! -d "$SRC" ]]; then
  tar -xf "$TARBALL" -C "$WORK"
  for patch in "$PATCHES"/*.patch "$PATCHES"/*.diff; do
    [[ -f "$patch" ]] || continue
    echo "Applying $(basename "$patch")"
    patch -d "$SRC" -p1 --forward < "$patch"
  done
fi

MINGW="$(ls -d "$WORK"/llvm-mingw-*-macos-universal | head -1)"
# Compiler flags can't carry a path with spaces ("Application Support"): go through a link.
ln -sfn "$MACOS_LIBS" "$WORK/macos-libs"
MACOS_LIBS="$WORK/macos-libs"
export PATH="$MINGW/bin:$BREW/opt/bison/bin:$PATH"

# Xcode's clang by full path (llvm-mingw, first in PATH, has its own clang for the Windows side), x86_64 output:
# configure cross-compiles, nothing runs under Rosetta during the build.
SDK="$(xcrun --show-sdk-path)"
export CC="$(xcrun -f clang) -arch x86_64 -isysroot $SDK -mmacosx-version-min=11.0"
export CXX="$(xcrun -f clang++) -arch x86_64 -isysroot $SDK -mmacosx-version-min=11.0"
export CFLAGS="-O2 -Wno-deprecated-declarations -Wno-incompatible-function-pointer-types -Wno-int-conversion"
export CROSSCFLAGS="-O2"
export LDFLAGS="-L$MACOS_LIBS -Wl,-headerpad_max_install_names"
export FREETYPE_CFLAGS="-I$BREW/opt/freetype/include/freetype2"
export FREETYPE_LIBS="-L$MACOS_LIBS -lfreetype"
export GNUTLS_CFLAGS="-I$BREW/opt/gnutls/include -I$BREW/opt/nettle/include -I$BREW/opt/p11-kit/include/p11-kit-1"
export GNUTLS_LIBS="-L$MACOS_LIBS -lgnutls"
export SDL2_CFLAGS="-I$BREW/opt/sdl2/include/SDL2 -D_THREAD_SAFE"
export SDL2_LIBS="-L$MACOS_LIBS -lSDL2"
export PKG_CONFIG_LIBDIR=/nonexistent

mkdir -p "$BUILD"
cd "$BUILD"
# Build tools (sfnt2fon) load freetype by its bare install name; SIP strips DYLD_* in make and /bin/sh, but dyld
# also looks in the working directory.
ln -sf "$MACOS_LIBS"/libfreetype*.dylib "$BUILD/"
if [[ ! -f Makefile ]]; then
  # ac_cv_func_pipe2=no: the macOS 27 SDK declares pipe2, so configure finds it and ntdll calls it unguarded. On
  # macOS 26 and earlier the symbol is missing and every wine process crashes at start (signal 11 in
  # init_thread_pipe; engine 1.0.5 on macOS 26.5.2, 2026-10-20). Wine falls back to pipe() + fcntl() without it.
  # Options of the official macOS packages (MacPorts wine-stable), minus what isn't installed here
  # (gettext, inotify, cups, pcsclite libraries for x86_64).
  "$SRC/configure" --prefix="$PREFIX" --host=x86_64-apple-darwin \
    --enable-archs=i386,x86_64 --enable-win64 --with-mingw \
    --without-alsa --without-capi --with-coreaudio --without-cups --without-dbus --without-ffmpeg \
    --without-fontconfig --with-freetype --without-gettext --without-gettextpo --without-gphoto --with-gnutls \
    --without-gssapi --without-gstreamer --without-inotify --without-krb5 --without-netapi --with-opencl \
    --without-opengl --without-oss --with-pcap --with-pthread --without-pulse --without-sane --with-sdl \
    --without-udev --with-unwind --without-usb --without-v4l2 --with-vulkan --without-wayland --without-x \
    --disable-winemenubuilder --disable-tests \
    ac_cv_lib_soname_freetype=libfreetype.6.dylib ac_cv_lib_soname_gnutls=libgnutls.30.dylib \
    ac_cv_func_pipe2=no \
    2>&1 | tee configure.log
fi
make -j"$JOBS" 2>&1 | tee make.log | grep -E 'error:|Error [0-9]' || true
test -x "$BUILD/loader/wine" || { echo "build failed, see $BUILD/make.log" >&2; exit 1; }
make install-lib 2>&1 | tail -1
echo "Installed in $PREFIX"
