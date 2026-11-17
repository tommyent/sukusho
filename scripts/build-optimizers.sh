#!/bin/zsh
# Builds the image optimizers Sukusho bundles in Contents/Helpers, from pinned source, and puts them with their
# licenses in Vendor/optimizers. The app build only copies and signs what is there, so this runs again only to
# change a version: edit the pins below, run it, and commit Vendor/optimizers.
#
#   scripts/build-optimizers.sh            needs git, cargo, cmake and Xcode's command line tools
#   CMAKE="uvx cmake" scripts/build-optimizers.sh     cmake without installing it
#   WORK=/some/folder scripts/build-optimizers.sh     keep the sources and build folders there
#
# oxipng (MIT) optimizes PNGs without changing a pixel; cwebp and webpmux (libwebp, BSD-3-Clause) write WebP and
# attach its color profile; cjpeg and jpegtran (MozJPEG; IJG, BSD-3-Clause and zlib) write JPEG and repack existing
# JPEGs without re-encoding. None of them is GPL: pngquant, libimagequant and jpegoptim must never be added here.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$ROOT/Vendor/optimizers"
WORK="${WORK:-$(mktemp -d)}"
CMAKE=(${=CMAKE:-cmake})
MIN=11.0   # the oldest macOS these run on; far below the app's own deployment target
fail() { print -ru2 -- "build-optimizers: $*"; exit 1 }

fetch() {   # name, repository, tag, and the commit that tag must be
    [[ -d "$WORK/$1" ]] || git clone --quiet --depth 1 --branch "$3" "$2" "$WORK/$1"
    [[ "$(git -C "$WORK/$1" rev-parse HEAD)" == "$4" ]] || fail "$1 $3 is not commit $4"
}
fetch oxipng  https://github.com/oxipng/oxipng.git      v10.2.1 36f3ef8aac65ecf1761739ea2f2e530281f1312b
fetch libwebp https://github.com/webmproject/libwebp.git v1.6.0  4fa21912338357f89e4fd51cf2368325b59e9bd9
fetch mozjpeg https://github.com/mozilla/mozjpeg.git     v4.1.5  6c9f0897afa1c2738d7222a0a9ab49e8b536a267

BIN="$WORK/bin"
mkdir -p "$BIN" "$OUT/OptimizerLicenses"

# Compilers write source paths into what they build (Rust's panic messages, C's assertions). These go into a
# public repository and a shipped app, so the home and build folders are renamed on the way in.
REAL_WORK="${WORK:A}"
export RUSTFLAGS="--remap-path-prefix=$HOME=~ --remap-path-prefix=$WORK=build --remap-path-prefix=$REAL_WORK=build"
PREFIX_MAP="-ffile-prefix-map=$WORK=build -ffile-prefix-map=$REAL_WORK=build -ffile-prefix-map=$HOME=~"

# oxipng: one slice per Rust target that is installed.
slices=()
for target in aarch64-apple-darwin x86_64-apple-darwin; do
    if [[ -d "$(rustc --print sysroot)/lib/rustlib/$target" ]]; then
        (cd "$WORK/oxipng" && MACOSX_DEPLOYMENT_TARGET=$MIN cargo build --quiet --release --locked --target $target)
        slices+=("$WORK/oxipng/target/$target/release/oxipng")
    else
        print -r -- "build-optimizers: Rust target $target is not installed (rustup target add $target); oxipng is built without it"
    fi
done
(( ${#slices} )) || fail "no Rust target to build oxipng for"
lipo -create $slices -output "$BIN/oxipng"

build() {   # source name, architecture, then cmake options; the targets follow "--"
    local name=$1 arch=$2; shift 2
    local split=${@[(i)--]}
    local options=("${(@)@[1,split-1]}") targets=("${(@)@[split+1,-1]}")
    local dir="$WORK/$name-$arch"
    $CMAKE -S "$WORK/$name" -B "$dir" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=$arch \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "-DCMAKE_C_FLAGS=$PREFIX_MAP" \
        "-DCMAKE_CXX_FLAGS=$PREFIX_MAP" $options > "$dir.log" 2>&1 \
        || fail "configuring $name for $arch failed, see $dir.log"
    $CMAKE --build "$dir" --target $targets -j 8 >> "$dir.log" 2>&1 || fail "building $name for $arch failed, see $dir.log"
}
for arch in arm64 x86_64; do
    # No PNG, JPEG, TIFF or GIF readers: Sukusho decodes with ImageIO and hands cwebp plain pixels.
    build libwebp $arch -DBUILD_SHARED_LIBS=OFF -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
        -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_EXTRAS=OFF \
        -DCMAKE_DISABLE_FIND_PACKAGE_PNG=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_JPEG=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_TIFF=TRUE \
        -DCMAKE_DISABLE_FIND_PACKAGE_GIF=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_OpenGL=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_GLUT=TRUE \
        -DCMAKE_DISABLE_FIND_PACKAGE_SDL2=TRUE -- cwebp webpmux
    # shortcut: the Intel slice has no SIMD, since MozJPEG's needs nasm; it is slower, not different. Build it with
    # nasm installed and WITH_SIMD=1 if Intel speed ever matters.
    simd=1; [[ $arch == x86_64 ]] && simd=0
    build mozjpeg $arch -DENABLE_SHARED=0 -DPNG_SUPPORTED=0 -DWITH_TURBOJPEG=0 -DWITH_SIMD=$simd -- cjpeg-static jpegtran-static
done
lipo -create "$WORK"/libwebp-{arm64,x86_64}/cwebp -output "$BIN/cwebp"
lipo -create "$WORK"/libwebp-{arm64,x86_64}/webpmux -output "$BIN/webpmux"
lipo -create "$WORK"/mozjpeg-{arm64,x86_64}/cjpeg-static -output "$BIN/cjpeg"
lipo -create "$WORK"/mozjpeg-{arm64,x86_64}/jpegtran-static -output "$BIN/jpegtran"

for tool in oxipng cwebp webpmux cjpeg jpegtran; do
    strip -x "$BIN/$tool" 2> /dev/null
    strings -a "$BIN/$tool" | grep -q -F -e "$HOME" -e "/Users/" -e "$WORK" -e "$REAL_WORK" \
        && fail "$tool still names this Mac's home or build folder"
    # Only system libraries may be linked: nothing from Homebrew at run time.
    for slice in ${=$(lipo -archs "$BIN/$tool")}; do
        otool -arch $slice -L "$BIN/$tool" | tail -n +2 | grep -v -E '^[[:space:]]+/usr/lib/' | grep -q . \
            && fail "$tool ($slice) links a library outside /usr/lib"
    done
    # Ad hoc, with the hardened runtime, so the app's own signature keeps that flag when it signs the copy.
    codesign --force --sign - --options runtime --identifier "com.tommyent.Sukusho.$tool" "$BIN/$tool"
    cp -f "$BIN/$tool" "$OUT/$tool"
done

# Licenses: each project's own, and for oxipng every crate compiled into it.
cp -f "$WORK/oxipng/LICENSE" "$OUT/OptimizerLicenses/oxipng.txt"
cat "$WORK/libwebp/COPYING" "$WORK/libwebp/PATENTS" > "$OUT/OptimizerLicenses/libwebp.txt"
cat "$WORK/mozjpeg/LICENSE.md" "$WORK/mozjpeg/README.ijg" > "$OUT/OptimizerLicenses/mozjpeg.txt"
crates="$OUT/OptimizerLicenses/oxipng-crates.txt"
print -r -- "Rust crates compiled into oxipng, with the license each one ships." > "$crates"
metadata="$(cd "$WORK/oxipng" && cargo metadata --quiet --locked --format-version 1)"
(cd "$WORK/oxipng" && cargo tree --quiet --locked --edges normal,build --prefix none --format '{p}' | sed 's/ (.*//' | sort -u) \
    | while read -r crate version; do
        [[ "$crate" == oxipng ]] && continue
        dir=("$HOME"/.cargo/registry/src/*/"$crate-${version#v}"(N))
        (( ${#dir} )) || fail "no source folder for the crate $crate $version"
        license="$(jq -r --arg n "$crate" --arg v "${version#v}" '.packages[] | select(.name == $n and .version == $v) | .license' <<< "$metadata")"
        print -r -- $'\n'"======== $crate ${version#v} ($license) ========" >> "$crates"
        files=("$dir[1]"/(LICENSE|LICENCE|COPYING|COPYRIGHT|UNLICENSE)*(N.))
        (( ${#files} )) || print -r -- "(the crate ships no license file; its manifest says $license)" >> "$crates"
        for file in $files; do print -r -- "---- ${file:t} ----" >> "$crates"; cat "$file" >> "$crates"; done
    done

{
    print -r -- "Built by scripts/build-optimizers.sh on $(date -u +%Y-%m-%d)."
    print -r -- "oxipng v10.2.1 36f3ef8aac65ecf1761739ea2f2e530281f1312b"
    print -r -- "libwebp v1.6.0 4fa21912338357f89e4fd51cf2368325b59e9bd9 (cwebp, webpmux)"
    print -r -- "mozjpeg v4.1.5 6c9f0897afa1c2738d7222a0a9ab49e8b536a267 (cjpeg, jpegtran)"
    print -r -- "rustc: $(rustc --version); cmake: $($CMAKE --version | head -1); clang: $(clang --version | head -1)"
    for tool in oxipng cwebp webpmux cjpeg jpegtran; do
        print -r -- "$tool: $(lipo -archs "$OUT/$tool"), $(stat -f %z "$OUT/$tool") bytes, sha256 $(shasum -a 256 "$OUT/$tool" | cut -d' ' -f1)"
    done
} > "$OUT/VERSIONS.txt"
cat "$OUT/VERSIONS.txt"
