#!/usr/bin/env bash
#
# Fetch the prebuilt onnxruntime.xcframework used by the MiniCPM-V iOS OCR
# layout detector (PP-DocLayoutV3). The repository does not track this binary
# (same rule as llama.xcframework).
#
# Source: Microsoft's public CocoaPods archive for onnxruntime-c 1.21.0
#   https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.21.0.zip
# Slices: ios-arm64, ios-arm64_x86_64-simulator, macos-arm64_x86_64.
#
# Usage:
#   ./scripts/download_onnxruntime.sh          # skip if 1.21.0 is already present
#   FORCE=1 ./scripts/download_onnxruntime.sh  # re-download and replace
#
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: this script uses macOS ditto(1) to preserve xcframework symlinks" >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
DEST_DIR="${REPO_ROOT}/MiniCPM-V-demo/thirdparty"
DEST="${DEST_DIR}/onnxruntime.xcframework"

ORT_VERSION="1.21.0"
ORT_URL="https://download.onnxruntime.ai/pod-archive-onnxruntime-c-${ORT_VERSION}.zip"
ORT_SHA256="936490d21475ebf03a4f5686e9a751a839d1adc5f9aaafb949485dedb066d9e5"

# Deployment target written into the framework plists. Keep in step with
# IPHONEOS_DEPLOYMENT_TARGET in the Xcode project.
IOS_MIN_OS_VERSION="16.6"

: "${FORCE:=0}"

installed_version() {
    local plist="${DEST}/ios-arm64/onnxruntime.framework/Info.plist"
    [[ -f "${plist}" ]] || return 1
    plutil -extract CFBundleShortVersionString raw "${plist}" 2>/dev/null || return 1
}

# The CocoaPods archive ships framework Info.plists without the platform
# metadata iOS needs, so App Store validation rejects the app with
# "Missing Info.plist value. A value for the key 'MinimumOSVersion' ...".
# Fill in what a normal Xcode-built framework carries. Each key is removed
# first so this is safe to re-run on an already patched plist.
patch_plist() {
    local plist="$1" platform="$2" sdk="$3"
    [[ -f "${plist}" ]] || return 0
    for pair in \
        "CFBundleDevelopmentRegion:string:en" \
        "CFBundleInfoDictionaryVersion:string:6.0" \
        "MinimumOSVersion:string:${IOS_MIN_OS_VERSION}" \
        "DTPlatformName:string:${platform}" \
        "DTSDKName:string:${sdk}"; do
        local key="${pair%%:*}" rest="${pair#*:}"
        local type="${rest%%:*}" value="${rest#*:}"
        plutil -remove "${key}" "${plist}" >/dev/null 2>&1 || true
        plutil -insert "${key}" "-${type}" "${value}" "${plist}"
    done
    plutil -remove CFBundleSupportedPlatforms "${plist}" >/dev/null 2>&1 || true
    if [[ "${platform}" == "iphoneos" ]]; then
        plutil -insert CFBundleSupportedPlatforms -json '["iPhoneOS"]' "${plist}"
    else
        plutil -insert CFBundleSupportedPlatforms -json '["iPhoneSimulator"]' "${plist}"
    fi
    plutil -remove UIDeviceFamily "${plist}" >/dev/null 2>&1 || true
    plutil -insert UIDeviceFamily -json '[1,2]' "${plist}"
}

patch_all_slices() {
    patch_plist "${DEST}/ios-arm64/onnxruntime.framework/Info.plist" \
        "iphoneos" "iphoneos"
    patch_plist "${DEST}/ios-arm64_x86_64-simulator/onnxruntime.framework/Info.plist" \
        "iphonesimulator" "iphonesimulator"
}

if [[ "${FORCE}" != "1" && -d "${DEST}" ]]; then
    local_ver="$(installed_version || true)"
    if [[ "${local_ver}" == "${ORT_VERSION}" ]]; then
        echo "onnxruntime.xcframework ${ORT_VERSION} already at ${DEST}"
        # Older checkouts predate the plist fix, so repair in place.
        patch_all_slices
        echo "re-run with FORCE=1 to replace it"
        exit 0
    fi
    echo "found existing ${DEST} (version ${local_ver:-unknown}); replacing with ${ORT_VERSION}"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ort-xcframework.XXXXXX")"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

ZIP="${WORK}/pod-archive.zip"
echo "downloading ${ORT_URL}"
curl -fL --retry 3 --retry-delay 2 -o "${ZIP}" "${ORT_URL}"

actual="$(shasum -a 256 "${ZIP}" | awk '{print $1}')"
if [[ "${actual}" != "${ORT_SHA256}" ]]; then
    echo "error: sha256 mismatch" >&2
    echo "  expected ${ORT_SHA256}" >&2
    echo "  actual   ${actual}" >&2
    exit 1
fi

echo "extracting xcframework"
ditto -x -k "${ZIP}" "${WORK}/unpacked"
SRC="${WORK}/unpacked/onnxruntime.xcframework"
if [[ ! -d "${SRC}" ]]; then
    echo "error: zip did not contain onnxruntime.xcframework" >&2
    exit 1
fi

mkdir -p "${DEST_DIR}"
rm -rf "${DEST}"
ditto "${SRC}" "${DEST}"

patch_all_slices

echo "installed onnxruntime.xcframework ${ORT_VERSION} -> ${DEST}"
ls "${DEST}"
