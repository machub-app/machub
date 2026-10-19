#!/bin/bash
# Builds Wine from CodeWeavers' CrossOver sources (LGPL) for MacHub's runtime: x86_64 host (runs under Rosetta 2),
# new-style WoW64 (32- and 64-bit Windows programs from one build).
#
#   scripts/build-winecx.sh <work-dir> <install-dir>
#
# <work-dir> must hold crossover-sources-<version>.tar.gz and an extracted llvm-mingw (macOS universal).
# Headers come from Homebrew (bison, pkgconf, freetype, gnutls, sdl2); the x86_64 libraries Wine links against
# are the ones the runtime ships (MACOS_LIBS, from the official WineHQ macOS package), so what Wine is built
# against is exactly what it finds at run time.
set -euo pipefail

CX_VERSION="${CX_VERSION:-26.2.0}"
WORK="$(cd "$1" && pwd)"
PREFIX="$2"
MACOS_LIBS="${MACOS_LIBS:?set MACOS_LIBS to a folder of x86_64 dylibs (wine/lib of runtime 1.0.0)}"
SRC="$WORK/sources/wine"
BUILD="$WORK/build-$CX_VERSION"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
BREW="$(brew --prefix)"

if [[ ! -d "$SRC" ]]; then
  tar -xzf "$WORK/crossover-sources-$CX_VERSION.tar.gz" -C "$WORK"
fi
MINGW="$(ls -d "$WORK"/llvm-mingw-*-macos-universal | head -1)"
# Compiler flags can't carry a path with spaces ("Application Support"): go through a link.
ln -sfn "$MACOS_LIBS" "$WORK/macos-libs"
MACOS_LIBS="$WORK/macos-libs"
export PATH="$MINGW/bin:$BREW/opt/bison/bin:$PATH"

# Native clang, emitting x86_64: configure cross-compiles, nothing runs under Rosetta during the build.
# Xcode's clang by full path: llvm-mingw, first in PATH, has its own clang for the Windows side.
SDK="$(xcrun --show-sdk-path)"
export CC="$(xcrun -f clang) -arch x86_64 -isysroot $SDK -mmacosx-version-min=11.0"
export CXX="$(xcrun -f clang++) -arch x86_64 -isysroot $SDK -mmacosx-version-min=11.0"
export CFLAGS="-O2 -Wno-deprecated-declarations -Wno-incompatible-function-pointer-types -Wno-int-conversion"
export CROSSCFLAGS="-O2"
export LDFLAGS="-L$MACOS_LIBS -Wl,-headerpad_max_install_names"
# Wine dlopens these by name at run time; configure only needs headers and a link test.
# The WineHQ package's dylibs carry bare install names, which configure's otool parsing mangles: the sonames
# are given explicitly below.
# OpenGL is left to its default: the EGL check is for the X11/Wayland drivers, winemac.drv uses OpenGL.framework.
export FREETYPE_CFLAGS="-I$BREW/opt/freetype/include/freetype2"
export FREETYPE_LIBS="-L$MACOS_LIBS -lfreetype"
export GNUTLS_CFLAGS="-I$BREW/opt/gnutls/include -I$BREW/opt/nettle/include -I$BREW/opt/p11-kit/include/p11-kit-1"
export GNUTLS_LIBS="-L$MACOS_LIBS -lgnutls"
export SDL2_CFLAGS="-I$BREW/opt/sdl2/include/SDL2 -D_THREAD_SAFE"
export SDL2_LIBS="-L$MACOS_LIBS -lSDL2"
# Keep Homebrew's arm64 pkg-config results out of the x86_64 build.
export PKG_CONFIG_LIBDIR=/nonexistent

mkdir -p "$BUILD"
cd "$BUILD"
# Build tools (sfnt2fon) load freetype by its bare install name. DYLD_* variables don't survive make and /bin/sh
# (SIP strips them), but dyld also looks in the working directory, which is the build root.
ln -sf "$MACOS_LIBS"/libfreetype*.dylib "$BUILD/"
if [[ ! -f Makefile ]]; then
  "$SRC/configure" --prefix="$PREFIX" --host=x86_64-apple-darwin \
    --enable-archs=i386,x86_64 --with-mingw \
    --with-coreaudio --with-vulkan --with-freetype --with-gnutls --with-sdl --with-pcap --with-unwind \
    --without-x --without-wayland --without-fontconfig --without-dbus --without-alsa --without-oss --without-pulse \
    --without-gstreamer --without-gettext --without-gettextpo --without-krb5 --without-gssapi --without-netapi \
    --without-sane --without-gphoto --without-v4l2 --without-udev --without-usb --without-capi --without-inotify \
    --without-cups --disable-winemenubuilder --disable-tests \
    ac_cv_lib_soname_freetype=libfreetype.6.dylib ac_cv_lib_soname_gnutls=libgnutls.30.dylib \
    2>&1 | tee configure.log
fi
make -j"$JOBS" 2>&1 | tee make.log | grep -E 'error:|Error [0-9]' || true
test -x "$BUILD/loader/wine" || { echo "build failed, see $BUILD/make.log" >&2; exit 1; }
make install-lib 2>&1 | tail -2
echo "Installed in $PREFIX"
