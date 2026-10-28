#!/usr/bin/env bash
#
# Build llama.xcframework for the MiniCPM-V iOS demo and install it under
# MiniCPM-V-demo/thirdparty/. The repository intentionally does *not* track
# the compiled framework — this script is the one-shot way to put it back
# wherever a fresh checkout / fresh submodule bump needs it.
#
# This script drives cmake directly against the llama.cpp-omni submodule.
# It builds only the targets the iOS app needs (voxcpm2_runtime + mtmd
# and their transitive deps) without touching omni / server / tests / CLI
# targets, and without modifying *any* file inside the llama.cpp-omni submodule.
#
# Default MINIMAL_MODE=ios builds both device + simulator slices.
#
# Usage:
#   ./scripts/build_xcframework.sh                   # default MINIMAL_MODE=ios
#   MINIMAL_MODE=ios-sim ./scripts/build_xcframework.sh
#   MINIMAL_MODE=ios-device ./scripts/build_xcframework.sh
#   MINIMAL_MODE=macos ./scripts/build_xcframework.sh
#
# Re-run when:
#   - The llama.cpp-omni submodule pointer has been bumped in the parent repo
#     (`git submodule status` shows a different commit than your last build).
#   - You edited any source under llama.cpp-omni/ that affects the framework.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SUBMODULE_DIR="${REPO_ROOT}/llama.cpp-omni"
DEST_DIR="${REPO_ROOT}/MiniCPM-V-demo/thirdparty"

: "${MINIMAL_MODE:=ios}"

# ── build-time tunables ────────────────────────────────────────────────
IOS_MIN_OS_VERSION=16.4

BUILD_SHARED_LIBS=OFF
LLAMA_BUILD_APP=OFF
LLAMA_BUILD_COMMON=ON
LLAMA_BUILD_EXAMPLES=OFF
LLAMA_BUILD_TOOLS=ON
LLAMA_BUILD_TESTS=OFF
LLAMA_BUILD_SERVER=OFF
GGML_METAL=ON
GGML_METAL_EMBED_LIBRARY=ON
GGML_BLAS_DEFAULT=ON
GGML_METAL_USE_BF16=ON
GGML_OPENMP=OFF

# voxcpm2 needs <log.h> from common/ and GGML_KQ_MASK_PAD (defined in
# feat/voxcpm_app's ggml.h but not on master). Inject both via cflags to avoid
# touching any file inside the llama.cpp-omni submodule.
COMMON_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g -I${SUBMODULE_DIR}/common -DGGML_KQ_MASK_PAD=64"
COMMON_CXX_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g -I${SUBMODULE_DIR}/common -DGGML_KQ_MASK_PAD=64"

COMMON_CMAKE_ARGS=(
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT="dwarf-with-dsym"
    -DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=YES
    -DCMAKE_XCODE_ATTRIBUTE_COPY_PHASE_STRIP=NO
    -DCMAKE_XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT=NO
    -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS}
    -DLLAMA_BUILD_APP=${LLAMA_BUILD_APP}
    -DLLAMA_BUILD_COMMON=${LLAMA_BUILD_COMMON}
    -DLLAMA_BUILD_EXAMPLES=${LLAMA_BUILD_EXAMPLES}
    -DLLAMA_BUILD_TOOLS=${LLAMA_BUILD_TOOLS}
    -DLLAMA_BUILD_TESTS=${LLAMA_BUILD_TESTS}
    -DLLAMA_BUILD_SERVER=${LLAMA_BUILD_SERVER}
    -DGGML_METAL_EMBED_LIBRARY=${GGML_METAL_EMBED_LIBRARY}
    -DGGML_BLAS_DEFAULT=${GGML_BLAS_DEFAULT}
    -DGGML_METAL=${GGML_METAL}
    -DGGML_METAL_USE_BF16=${GGML_METAL_USE_BF16}
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=${GGML_OPENMP}
)

# ── preflight checks ──────────────────────────────────────────────────

if [[ ! -f "${SUBMODULE_DIR}/CMakeLists.txt" ]]; then
    cat >&2 <<EOF
Error: llama.cpp-omni submodule is not initialised at:
       ${SUBMODULE_DIR}
       Run this first (shallow + single-branch, see README):
           git submodule update --init --recursive --depth 1 --single-branch
EOF
    exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "Error: cmake is not installed.  brew install cmake" >&2
    exit 1
fi
CMAKE_VER="$(cmake --version | head -n1 | awk '{print $3}')"
CMAKE_MAJOR="${CMAKE_VER%%.*}"
CMAKE_REST="${CMAKE_VER#*.}"
CMAKE_MINOR="${CMAKE_REST%%.*}"
: "${CMAKE_MAJOR:=0}"
: "${CMAKE_MINOR:=0}"
if (( CMAKE_MAJOR < 3 || (CMAKE_MAJOR == 3 && CMAKE_MINOR < 28) )); then
    echo "Error: cmake ${CMAKE_VER} is too old; need >= 3.28 (brew upgrade cmake)" >&2
    exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
    echo "Error: xcrun not found.  Install Xcode + Command Line Tools." >&2
    exit 1
fi

echo "==> Building llama.xcframework"
echo "    MINIMAL_MODE=${MINIMAL_MODE}"
echo "    submodule:   ${SUBMODULE_DIR}  ($(cd "${SUBMODULE_DIR}" && git rev-parse --short HEAD))"
echo "    install to:  ${DEST_DIR}/llama.xcframework"
echo "    cmake:       ${CMAKE_VER}"
echo

# ── helpers ────────────────────────────────────────────────────────────

# Clean previous build dirs
clean_build_dirs() {
    rm -rf "${SUBMODULE_DIR}/build-ios-sim"
    rm -rf "${SUBMODULE_DIR}/build-ios-device"
    rm -rf "${SUBMODULE_DIR}/build-macos"
    rm -rf "${SUBMODULE_DIR}/build-apple"
}

# Set up the .framework directory structure (iOS flat layout).
setup_ios_framework() {
    local build_dir="$1"          # e.g. build-ios-sim
    local framework_name="llama"

    echo "  → setting up framework structure in ${build_dir}"

    mkdir -p "${build_dir}/framework/${framework_name}.framework/Headers"
    mkdir -p "${build_dir}/framework/${framework_name}.framework/Modules"
    rm -rf "${build_dir}/framework/${framework_name}.framework/Versions"

    local header_path="${build_dir}/framework/${framework_name}.framework/Headers/"
    local module_path="${build_dir}/framework/${framework_name}.framework/Modules/"

    # ---------- core llama.cpp headers ----------
    cp "${SUBMODULE_DIR}/include/llama.h"             "${header_path}"
    cp "${SUBMODULE_DIR}/ggml/include/ggml.h"         "${header_path}"
    cp "${SUBMODULE_DIR}/ggml/include/ggml-opt.h"     "${header_path}"
    cp "${SUBMODULE_DIR}/ggml/include/ggml-alloc.h"   "${header_path}"
    cp "${SUBMODULE_DIR}/ggml/include/ggml-backend.h" "${header_path}"
    cp "${SUBMODULE_DIR}/ggml/include/ggml-metal.h"   "${header_path}"
    cp "${SUBMODULE_DIR}/ggml/include/ggml-cpu.h"     "${header_path}"
    cp "${SUBMODULE_DIR}/ggml/include/ggml-blas.h"    "${header_path}"
    cp "${SUBMODULE_DIR}/ggml/include/gguf.h"         "${header_path}"

    # ---------- mtmd headers ----------
    cp "${SUBMODULE_DIR}/tools/mtmd/mtmd.h"        "${header_path}"
    cp "${SUBMODULE_DIR}/tools/mtmd/mtmd-helper.h" "${header_path}"

    # ---------- voxcpm2 headers ----------
    cp "${SUBMODULE_DIR}/tools/omni/voxcpm2/"*.h "${header_path}"

    # ---------- module map ----------
    cat > "${module_path}module.modulemap" << 'MODMAP'
framework module llama {
    umbrella "Headers"
    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"
    link framework "CoreML"
    export *
}
MODMAP

    # ---------- Info.plist ----------
    local plist_path="${build_dir}/framework/${framework_name}.framework/Info.plist"
    cat > "${plist_path}" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>llama</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.llama</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>llama</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>${IOS_MIN_OS_VERSION}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>iPhoneOS</string>
    </array>
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>
    <key>DTPlatformName</key>
    <string>iphoneos</string>
    <key>DTSDKName</key>
    <string>iphoneos${IOS_MIN_OS_VERSION}</string>
</dict>
</plist>
EOF
}

# Create a dynamic library from all the static libraries.
combine_ios_libs() {
    local build_dir="$1"       # e.g. build-ios-sim
    local release_dir="$2"     # e.g. Release-iphonesimulator
    local is_simulator="$3"    # "true" or "false"
    local framework_name="llama"

    local output_lib="${build_dir}/framework/${framework_name}.framework/${framework_name}"

    # Collect ALL static libs (core ggml/llama + voxcpm2 + mtmd + common)
    local libs=(
        "${build_dir}/src/${release_dir}/libllama.a"
        "${build_dir}/ggml/src/${release_dir}/libggml.a"
        "${build_dir}/ggml/src/${release_dir}/libggml-base.a"
        "${build_dir}/ggml/src/${release_dir}/libggml-cpu.a"
        "${build_dir}/ggml/src/ggml-metal/${release_dir}/libggml-metal.a"
        "${build_dir}/ggml/src/ggml-blas/${release_dir}/libggml-blas.a"
        "${build_dir}/common/${release_dir}/libllama-common-base.a"
        "${build_dir}/common/${release_dir}/libllama-common.a"
        "${build_dir}/tools/mtmd/${release_dir}/libmtmd.a"
        "${build_dir}/tools/omni/${release_dir}/libvoxcpm2_runtime.a"
        "${build_dir}/tools/omni/${release_dir}/libvoxcpm2_llm.a"
        "${build_dir}/tools/omni/${release_dir}/libvoxcpm2_fsq.a"
        "${build_dir}/tools/omni/${release_dir}/libvoxcpm2_acoustic.a"
    )

    local temp_dir="${build_dir}/temp"
    mkdir -p "${temp_dir}"

    echo "  → combining static libs with libtool…"
    xcrun libtool -static -o "${temp_dir}/combined.a" "${libs[@]}" 2>/dev/null

    local sdk=""
    local archs=""
    local min_version_flag=""

    if [[ "$is_simulator" == "true" ]]; then
        sdk="iphonesimulator"
        archs="arm64 x86_64"
        min_version_flag="-mios-simulator-version-min=${IOS_MIN_OS_VERSION}"
    else
        sdk="iphoneos"
        archs="arm64"
        min_version_flag="-mios-version-min=${IOS_MIN_OS_VERSION}"
    fi

    local install_name="@rpath/llama.framework/llama"

    local arch_flags=""
    for arch in $archs; do
        arch_flags+=" -arch $arch"
    done

    echo "  → creating dynamic library…"
    xcrun -sdk "$sdk" clang++ -dynamiclib \
        -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
        $arch_flags \
        $min_version_flag \
        -Wl,-force_load,"${temp_dir}/combined.a" \
        -framework Foundation -framework Metal -framework Accelerate -framework CoreML \
        -install_name "$install_name" \
        -o "${output_lib}"

    # ---------- dSYM + strip ----------
    echo "  → generating dSYM…"
    mkdir -p "${build_dir}/dSYMs"
    xcrun dsymutil "${output_lib}" -o "${build_dir}/dSYMs/llama.dSYM"

    cp "${output_lib}" "${temp_dir}/binary_to_strip"
    xcrun strip -S "${temp_dir}/binary_to_strip" -o "${temp_dir}/stripped_lib"
    mv "${temp_dir}/stripped_lib" "${output_lib}"

    if [ -d "${output_lib}.dSYM" ]; then
        rm -rf "${output_lib}.dSYM"
    fi

    # ---------- mark device binary ----------
    if [[ "$is_simulator" == "false" ]]; then
        if xcrun -f vtool &>/dev/null; then
            echo "  → marking as framework binary (vtool)…"
            xcrun vtool -set-build-version ios "${IOS_MIN_OS_VERSION}" "${IOS_MIN_OS_VERSION}" -replace \
                -output "${output_lib}" "${output_lib}"
        fi
    fi

    rm -rf "${temp_dir}"
    echo "  ✓ framework ready: ${output_lib}"
}

# ── build one iOS slice ───────────────────────────────────────────────

build_ios_slice() {
    local build_dir="$1"          # build-ios-sim | build-ios-device
    local sdk="$2"                # iphonesimulator | iphoneos
    local sysroot="$3"            # iphonesimulator | iphoneos
    local archs="$4"              # "arm64;x86_64" | "arm64"
    local release_dir="$5"        # Release-iphonesimulator | Release-iphoneos
    local is_simulator="$6"       # true | false
    local supported_platforms="$7" # iphonesimulator | iphoneos

    echo
    echo "─── Building iOS ${is_simulator:+simulator }slice (${archs}) ───"

    local build_path="${SUBMODULE_DIR}/${build_dir}"

    # cmake configure
    cmake -B "${build_path}" -G Xcode \
        "${COMMON_CMAKE_ARGS[@]}" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_MIN_OS_VERSION}" \
        -DIOS=ON \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="${sysroot}" \
        -DCMAKE_OSX_ARCHITECTURES="${archs}" \
        -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS="${supported_platforms}" \
        -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
        -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
        -DLLAMA_OPENSSL=OFF \
        -DLLAMA_CURL=OFF \
        -S "${SUBMODULE_DIR}"

    # Build only the targets we need (+ transitive deps: ggml, llama, common,
    # voxcpm2_llm, voxcpm2_fsq, voxcpm2_acoustic).  Deliberately NOT building
    # the 'omni' library or any CLI executables.
    cmake --build "${build_path}" \
        --config Release \
        --target voxcpm2_runtime mtmd llama-common \
        -j "$(sysctl -n hw.logicalcpu)" \
        -- -quiet

    setup_ios_framework "${build_path}"
    combine_ios_libs "${build_path}" "${release_dir}" "${is_simulator}"
}

# ── build macOS slice (core ggml+llama only, no voxcpm2/mtmd) ─────────

build_macos_slice() {
    local build_dir="build-macos"
    local build_path="${SUBMODULE_DIR}/${build_dir}"

    echo
    echo "─── Building macOS slice (arm64 x86_64) ───"

    cmake -B "${build_path}" -G Xcode \
        "${COMMON_CMAKE_ARGS[@]}" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 \
        -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
        -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
        -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
        -DLLAMA_OPENSSL=OFF \
        -DLLAMA_CURL=OFF \
        -S "${SUBMODULE_DIR}"

    cmake --build "${build_path}" --config Release -j "$(sysctl -n hw.logicalcpu)" -- -quiet

    # Minimal macOS framework — no voxcpm2/mtmd
    local fw="${build_path}/framework/llama.framework"
    mkdir -p "${fw}/Versions/A/Headers" "${fw}/Versions/A/Modules" "${fw}/Versions/A/Resources"
    ln -sf A               "${fw}/Versions/Current"
    ln -sf Versions/Current/Headers   "${fw}/Headers"
    ln -sf Versions/Current/Modules   "${fw}/Modules"
    ln -sf Versions/Current/Resources "${fw}/Resources"
    ln -sf Versions/Current/llama     "${fw}/llama"

    local header_path="${fw}/Versions/A/Headers/"
    cp "${SUBMODULE_DIR}/include/llama.h"             "${header_path}"
    cp "${SUBMODULE_DIR}/ggml/include/ggml.h"         "${header_path}"
    cp "${SUBMODULE_DIR}/ggml/include/ggml-opt.h"     "${header_path}"
    cp "${SUBMODULE_DIR}/ggml/include/ggml-alloc.h"   "${header_path}"
    cp "${SUBMODULE_DIR}/ggml/include/ggml-backend.h" "${header_path}"
    cp "${SUBMODULE_DIR}/ggml/include/ggml-metal.h"   "${header_path}"
    cp "${SUBMODULE_DIR}/ggml/include/ggml-cpu.h"     "${header_path}"
    cp "${SUBMODULE_DIR}/ggml/include/ggml-blas.h"    "${header_path}"
    cp "${SUBMODULE_DIR}/ggml/include/gguf.h"         "${header_path}"

    local module_path="${fw}/Versions/A/Modules/"
    cat > "${module_path}module.modulemap" << 'MODMAP'
framework module llama {
    umbrella "Headers"
    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"
    export *
}
MODMAP

    local output_lib="${fw}/Versions/A/llama"
    local libs=(
        "${build_path}/src/Release/libllama.a"
        "${build_path}/ggml/src/Release/libggml.a"
        "${build_path}/ggml/src/Release/libggml-base.a"
        "${build_path}/ggml/src/Release/libggml-cpu.a"
        "${build_path}/ggml/src/ggml-metal/Release/libggml-metal.a"
        "${build_path}/ggml/src/ggml-blas/Release/libggml-blas.a"
    )

    local temp_dir="${build_path}/temp"
    mkdir -p "${temp_dir}"
    xcrun libtool -static -o "${temp_dir}/combined.a" "${libs[@]}" 2>/dev/null

    xcrun -sdk macosx clang++ -dynamiclib \
        -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
        -arch arm64 -arch x86_64 \
        -mmacosx-version-min=13.3 \
        -Wl,-force_load,"${temp_dir}/combined.a" \
        -framework Foundation -framework Metal -framework Accelerate \
        -install_name "@rpath/llama.framework/Versions/Current/llama" \
        -o "${output_lib}"

    mkdir -p "${build_path}/dSYMs"
    xcrun dsymutil "${output_lib}" -o "${build_path}/dSYMs/llama.dSYM"
    cp "${output_lib}" "${temp_dir}/binary_to_strip"
    xcrun strip -S "${temp_dir}/binary_to_strip" -o "${temp_dir}/stripped_lib"
    mv "${temp_dir}/stripped_lib" "${output_lib}"
    rm -rf "${temp_dir}"
    echo "  ✓ macOS framework ready"
}

# ── main ───────────────────────────────────────────────────────────────

clean_build_dirs

HAS_IOS_SIM=false
HAS_IOS_DEVICE=false
HAS_MACOS=false

case "${MINIMAL_MODE}" in
    ios|all)
        build_ios_slice "build-ios-sim"    "iphonesimulator" "iphonesimulator" "arm64;x86_64" "Release-iphonesimulator" "true"  "iphonesimulator"
        build_ios_slice "build-ios-device" "iphoneos"        "iphoneos"        "arm64"         "Release-iphoneos"        "false" "iphoneos"
        HAS_IOS_SIM=true
        HAS_IOS_DEVICE=true
        ;;
    ios-sim)
        build_ios_slice "build-ios-sim" "iphonesimulator" "iphonesimulator" "arm64;x86_64" "Release-iphonesimulator" "true" "iphonesimulator"
        HAS_IOS_SIM=true
        ;;
    ios-device)
        build_ios_slice "build-ios-device" "iphoneos" "iphoneos" "arm64" "Release-iphoneos" "false" "iphoneos"
        HAS_IOS_DEVICE=true
        ;;
    macos)
        build_macos_slice
        HAS_MACOS=true
        ;;
    *)
        echo "Error: unknown MINIMAL_MODE=${MINIMAL_MODE}" >&2
        echo "Valid: ios | ios-sim | ios-device | macos | all" >&2
        exit 1
        ;;
esac

# ── create xcframework ─────────────────────────────────────────────────

echo
echo "─── Creating XCFramework ───"

XC_ARGS=()
if $HAS_IOS_SIM; then
    XC_ARGS+=(
        -framework "${SUBMODULE_DIR}/build-ios-sim/framework/llama.framework"
        -debug-symbols "${SUBMODULE_DIR}/build-ios-sim/dSYMs/llama.dSYM"
    )
fi
if $HAS_IOS_DEVICE; then
    XC_ARGS+=(
        -framework "${SUBMODULE_DIR}/build-ios-device/framework/llama.framework"
        -debug-symbols "${SUBMODULE_DIR}/build-ios-device/dSYMs/llama.dSYM"
    )
fi
if $HAS_MACOS; then
    XC_ARGS+=(
        -framework "${SUBMODULE_DIR}/build-macos/framework/llama.framework"
        -debug-symbols "${SUBMODULE_DIR}/build-macos/dSYMs/llama.dSYM"
    )
fi

OUTPUT="${SUBMODULE_DIR}/build-apple/llama.xcframework"
xcrun xcodebuild -create-xcframework "${XC_ARGS[@]}" -output "${OUTPUT}"

if [[ ! -d "${OUTPUT}" ]]; then
    echo "Error: expected build output not found at ${OUTPUT}" >&2
    exit 1
fi

# ── install ────────────────────────────────────────────────────────────

rm -rf "${DEST_DIR}/llama.xcframework"
# thirdparty/ is not tracked and holds nothing else, so a fresh clone does not have it.
mkdir -p "${DEST_DIR}"
cp -R "${OUTPUT}" "${DEST_DIR}/llama.xcframework"

SIZE="$(du -sh "${DEST_DIR}/llama.xcframework" | awk '{print $1}')"
echo
echo "✓ llama.xcframework installed:"
echo "    ${DEST_DIR}/llama.xcframework   (${SIZE})"
echo
echo "Next: open MiniCPM-V-demo/MiniCPM-V-demo.xcodeproj in Xcode and Build (⌘B)."
