#!/bin/bash
# Builds Packages/FreeFlowEngine/FreeFlowSpeech.xcframework: ONE ggml shared by llama.cpp (+ mtmd, for Liquid LFM audio
# models) and whisper.cpp's Parakeet code, plus our C shim (Packages/FreeFlowEngine/Engine/ff_engine.cpp), as one static
# library per slice: iOS arm64, iOS Simulator arm64, macOS arm64, Mac Catalyst arm64 (the Mac app is the iPhone app
# built for Mac Catalyst, build 20; the catalyst slice is added to the xcframework when it has been built).
# Metal is compiled in (foreground); CPU mode lists no
# GPU device, so the background path never touches Metal. Only ff_engine.h is public.
#
# CPU code is built for the iOS 18 floor (A12: ARMv8.2-A + FP16, no dot product / int8 matmul) on every slice, so every
# iPhone we support runs it and the simulator, the Mac CLI and devices run the same instructions (same text).
# Accelerate is ON (GGML_BLAS=ON): ggml sends prefill matmuls to Apple's sgemm, which makes the CPU path (the background
# path, where iOS gives the least time) 2-3x faster: Parakeet Q4_0 30.4x vs 10.5x real time, LFM2.5 6.4x vs 3.75x on an M5 Mac
# (measured 2026-10-29). Accelerate comes from the OS and rounds differently per OS, so text can differ by a word
# between devices (1 of 100 clips Mac vs simulator, WER unchanged). The sim-vs-Mac check compares WER, not bytes.
# ggml's runtime CPU-variant selection exists only as GGML_BACKEND_DL (dlopen'ed shared modules, no A12 variant), which
# iOS app bundles cannot carry as plain dylibs; its cost was measured on an M5 Mac.
#
# Also builds two Mac CLIs over the same shim: build/ffasr (baseline flags, = the xcframework's macOS slice) and
# build/ffasr-native (GGML_NATIVE, the build machine's CPU), used to measure what the baseline costs.
#
# Pinned sources live outside the repo (FF_ENGINE_SRC, default ~/Developer/freeflow-cpp/src):
#   llama.cpp  b11982 = 8a199ad31a7eb27d5a46a6b08026176d82bc9894 (MIT)  includes LFM3-Audio (19ff817fb, #31257)
#   whisper.cpp 284029c07012d2000941a08d38a31ffb71f4734e        (MIT)  src/parakeet.cpp, built against the ggml above
# The xcframework is not in git. Its sha256 list is: Packages/FreeFlowEngine/FreeFlowSpeech.xcframework.sha256 (with the Xcode
# version that built it). Builds are reproducible on the same Xcode: archive dates are zeroed (ZERO_AR_DATE) and source paths
# are mapped to fixed names (-ffile-prefix-map), so no local path ends up in the binary.
# usage: scripts/build-engine.sh [slices...]   (default: ios sim mac native; env J = parallel jobs, default 8)
#        scripts/build-engine.sh --record      write the sha256 list of the current xcframework
#        scripts/build-engine.sh --check       exit 1 unless the xcframework matches the sha256 list
set -euo pipefail
export ZERO_AR_DATE=1
export PATH=/opt/homebrew/bin:$PATH DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
REPO=$(cd "$(dirname "$0")/.." && pwd); PKG=$REPO/Packages/FreeFlowEngine; ENG=$PKG/Engine
S=${FF_ENGINE_SRC:-$HOME/Developer/freeflow-cpp/src}; B=${FF_ENGINE_BUILD:-$HOME/Developer/freeflow-cpp/build-apple2}; J=${J:-8}
LLAMA_REV=8a199ad31a7eb27d5a46a6b08026176d82bc9894; WHISPER_REV=284029c07012d2000941a08d38a31ffb71f4734e
SUMS=$PKG/FreeFlowSpeech.xcframework.sha256
# Info.plist is left out: xcodebuild -create-xcframework writes its library list in no fixed order.
xcf_sums() { (cd "$PKG" && find FreeFlowSpeech.xcframework -type f ! -name Info.plist | LC_ALL=C sort | xargs shasum -a 256); }
xcode_line() { echo "# $(xcodebuild -version | tr '\n' ' ')llama.cpp $LLAMA_REV whisper.cpp $WHISPER_REV"; }
if [ "${1:-}" = --record ]; then { xcode_line; xcf_sums; } > "$SUMS"; echo "recorded $SUMS"; exit 0; fi
if [ "${1:-}" = --check ]; then
  [ -d "$PKG/FreeFlowSpeech.xcframework" ] || { echo "ENGINE_CHECK FAIL: no xcframework (run scripts/build-engine.sh)"; exit 1; }
  [ "$(head -1 "$SUMS")" = "$(xcode_line)" ] || echo "ENGINE_CHECK note: recorded with: $(head -1 "$SUMS")"
  if diff <(tail -n +2 "$SUMS") <(xcf_sums) > /dev/null; then echo "ENGINE_CHECK OK $(tail -n +2 "$SUMS" | wc -l | tr -d ' ') files"; exit 0; fi
  echo "ENGINE_CHECK FAIL: xcframework differs from $SUMS"; diff <(tail -n +2 "$SUMS") <(xcf_sums) | head -20; exit 1
fi
BASE_ARCH=armv8.2-a+fp16
mkdir -p "$S" "$B"
[ -d "$S/llama.cpp" ] || git clone -q --filter=blob:none https://github.com/ggml-org/llama.cpp.git "$S/llama.cpp"
[ -d "$S/wcpp" ] || git clone -q --filter=blob:none https://github.com/ggml-org/whisper.cpp.git "$S/wcpp"
[ "$(git -C "$S/llama.cpp" rev-parse HEAD)" = $LLAMA_REV ] || git -C "$S/llama.cpp" checkout -q $LLAMA_REV
[ "$(git -C "$S/wcpp" rev-parse HEAD)" = $WHISPER_REV ] || git -C "$S/wcpp" checkout -q $WHISPER_REV
[ "$(git -C "$S/llama.cpp" rev-parse HEAD)" = $LLAMA_REV ] && [ "$(git -C "$S/wcpp" rev-parse HEAD)" = $WHISPER_REV ] || { echo "sources not at the pins"; exit 1; }

slice() {  # name: ios | sim | mac | native | catalyst
  local n=$1 X G root min target
  case $n in
    ios)    root=iphoneos;        min=18.0; target=arm64-apple-ios18.0 ;;
    sim)    root=iphonesimulator; min=18.0; target=arm64-apple-ios18.0-simulator ;;
    mac|native) root=macosx;      min=14.0; target=arm64-apple-macos14.0 ;;
    catalyst)   root=macosx;      min=;     target=arm64-apple-ios18.0-macabi ;;
  esac
  X=(-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=$root -DCMAKE_OSX_DEPLOYMENT_TARGET=$min)
  case $n in ios|sim) X+=(-DCMAKE_SYSTEM_NAME=iOS -DGGML_METAL_TARGET_OS=ios) ;; esac
  local MAP="-ffile-prefix-map=$S=src -ffile-prefix-map=$B=build -ffile-prefix-map=$REPO=freeflow"
  # Mac Catalyst: the macOS SDK with the iOS-on-Mac target triple and the iOSSupport headers (no deployment-target flag,
  # which would add -mmacosx-version-min and clash with the triple).
  if [ $n = catalyst ]; then
    local SDK; SDK=$(xcrun --sdk macosx --show-sdk-path)
    MAP="$MAP -target $target -isystem $SDK/System/iOSSupport/usr/include -iframework $SDK/System/iOSSupport/System/Library/Frameworks"
    X+=("-DCMAKE_ASM_FLAGS=-target $target")   # the embedded Metal shader sources are assembled too
  fi
  X+=("-DCMAKE_C_FLAGS=$MAP" "-DCMAKE_CXX_FLAGS=$MAP" "-DCMAKE_OBJC_FLAGS=$MAP")
  # GGML_ACCELERATE is set explicitly (its default is ON) so a build dir configured with it OFF goes back to ON.
  G=(-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON -DGGML_ACCELERATE=ON -DGGML_OPENMP=OFF)
  if [ $n = native ]; then G+=(-DGGML_NATIVE=ON); else G+=(-DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=$BASE_ARCH); fi
  local P=$B/ggml-$n L=$B/llama-$n W=$B/parakeet-$n O=$B/lib-$n
  echo "=== $(date -u +%FT%TZ) slice $n load $(sysctl -n vm.loadavg)"
  cmake -S "$S/llama.cpp" -B "$L" "${X[@]}" "${G[@]}" -DCMAKE_INSTALL_PREFIX="$P" -DLLAMA_USE_SYSTEM_GGML=OFF \
    -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_MTMD=ON -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF > "$L.cfg.log" 2>&1
  cmake --build "$L" --target llama mtmd -j $J > "$L.build.log" 2>&1
  cmake --install "$L/ggml" > "$L.install.log" 2>&1
  cmake -S "$S/wcpp" -B "$W" "${X[@]}" "${G[@]}" -DWHISPER_USE_SYSTEM_GGML=ON -Dggml_DIR="$P/lib/cmake/ggml" -DCMAKE_PREFIX_PATH="$P" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_SDL2=OFF -DWHISPER_COREML=OFF > "$W.cfg.log" 2>&1
  cmake --build "$W" --target parakeet -j $J > "$W.build.log" 2>&1
  mkdir -p "$O"
  xcrun clang++ -std=c++17 -O2 -DNDEBUG $MAP -target $target -isysroot "$(xcrun --sdk $root --show-sdk-path)" \
    -I "$S/llama.cpp/include" -I "$S/llama.cpp/ggml/include" -I "$S/llama.cpp/tools/mtmd" -I "$S/wcpp/include" -I "$ENG" \
    -c "$ENG/ff_engine.cpp" -o "$O/ff_engine.o"
  { echo "$O/ff_engine.o"; find "$L/tools/mtmd" "$L/vendor/hash" "$L/src" -name "*.a"; find "$W/src" -name "libparakeet.a"; ls "$P"/lib/libggml*.a; } > "$O/inputs.txt"
  libtool -static -o "$O/libFreeFlowSpeech.a" $(cat "$O/inputs.txt") 2> "$O/libtool.err"
  echo "slice $n: $(wc -l < "$O/inputs.txt" | tr -d ' ') inputs, $(stat -f %z "$O/libFreeFlowSpeech.a") B, ggml $(grep -o 'ggml version: [0-9.]*' "$L.cfg.log" | head -1)"
  if [ $n = mac ] || [ $n = native ]; then
    local cli=$B/ffasr; [ $n = native ] && cli=$B/ffasr-native
    xcrun clang++ -std=c++17 -O2 -target $target -I "$ENG" "$ENG/ffasr.cpp" "$O/libFreeFlowSpeech.a" \
      -framework Accelerate -framework Metal -framework Foundation -o "$cli"
    echo "cli $cli"
  fi
}
SLICES=${*:-ios sim mac native}
for n in $SLICES; do slice $n; done
H=$B/headers; mkdir -p "$H"; cp "$ENG/ff_engine.h" "$H/"
printf 'module FreeFlowSpeech {\n    header "ff_engine.h"\n    link "c++"\n    link framework "Accelerate"\n    link framework "Metal"\n    link framework "Foundation"\n    export *\n}\n' > "$H/module.modulemap"
if [ -f "$B/lib-ios/libFreeFlowSpeech.a" ] && [ -f "$B/lib-sim/libFreeFlowSpeech.a" ] && [ -f "$B/lib-mac/libFreeFlowSpeech.a" ]; then
  XCF=$PKG/FreeFlowSpeech.xcframework
  [ -e "$XCF" ] && mv "$XCF" "$B/FreeFlowSpeech.xcframework.prev.$(date +%s)"
  xcodebuild -create-xcframework -library "$B/lib-ios/libFreeFlowSpeech.a" -headers "$H" \
    -library "$B/lib-sim/libFreeFlowSpeech.a" -headers "$H" -library "$B/lib-mac/libFreeFlowSpeech.a" -headers "$H" \
    $([ -f "$B/lib-catalyst/libFreeFlowSpeech.a" ] && echo -library "$B/lib-catalyst/libFreeFlowSpeech.a" -headers "$H") -output "$XCF" > "$B/xcf.log"
  echo "ENGINE_OK $XCF $(du -sh "$XCF" | cut -f1)"
fi
