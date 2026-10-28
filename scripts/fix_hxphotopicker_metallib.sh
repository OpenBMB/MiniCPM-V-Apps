#!/usr/bin/env bash
#
# Replace the HXPhotoPicker PassThrough metallib with a fresh release build.
#
# The SwiftPM package ships Sources/HXPhotoPicker/Resources/HXPhotoPicker.bundle/
# metal/default.metallib precompiled from a Debug configuration, so it embeds the
# author's local source paths. App Store Connect flags it as
# "Metal issue detected ... contains shader source code intended only for
# development". Rebuilding from the .metal source that ships alongside it drops
# the debug payload; the shader entry points are identical.
#
# Runs as an Xcode build phase (see project.pbxproj) and can be invoked by hand
# after a Package.resolved change repopulates SourcePackages:
#
#   ./scripts/fix_hxphotopicker_metallib.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

BUNDLE_REL="HXPhotoPicker_HXPhotoPicker.bundle/HXPhotoPicker.bundle/metal/default.metallib"
SRC_REL="Sources/HXPhotoPicker/Camera/View/PassThrough.metal"

# Under Xcode, BUILD_DIR points at <DerivedData>/Build/Products and the package
# checkouts live two levels up. Outside Xcode, take the newest DerivedData dir.
find_checkout() {
    local candidates=()
    if [[ -n "${BUILD_DIR:-}" ]]; then
        candidates+=("${BUILD_DIR}/../../SourcePackages/checkouts/HXPhotoPicker")
    fi
    local dd
    for dd in ~/Library/Developer/Xcode/DerivedData/MiniCPM-V-demo-*; do
        [[ -d "${dd}" ]] && candidates+=("${dd}/SourcePackages/checkouts/HXPhotoPicker")
    done
    local c
    for c in "${candidates[@]}"; do
        if [[ -f "${c}/${SRC_REL}" ]]; then
            echo "${c}"
            return 0
        fi
    done
    return 1
}

CHECKOUT="$(find_checkout || true)"
if [[ -z "${CHECKOUT}" ]]; then
    echo "note: HXPhotoPicker checkout not found, skipping metallib rebuild"
    exit 0
fi
METAL_SRC="${CHECKOUT}/${SRC_REL}"

# Inside Xcode the bundle must be patched in the built product. Outside Xcode
# fall back to the checkouts so a manual run still prepares future builds.
if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
    METALLIB_DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/${BUNDLE_REL}"
    SDK="${PLATFORM_NAME:-iphoneos}"
else
    METALLIB_DEST="${CHECKOUT}/Sources/HXPhotoPicker/Resources/HXPhotoPicker.bundle/metal/default.metallib"
    SDK="iphoneos"
fi

if [[ ! -f "${METALLIB_DEST}" ]]; then
    echo "note: ${METALLIB_DEST} not present, skipping metallib rebuild"
    exit 0
fi

# Already clean (no debug payload) means a previous run in this build handled it.
if ! strings -a "${METALLIB_DEST}" 2>/dev/null | grep -q '\.metal'; then
    exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hxp-metal.XXXXXX")"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

xcrun -sdk "${SDK}" metal -c "${METAL_SRC}" -o "${WORK}/passthrough.air"
xcrun -sdk "${SDK}" metallib "${WORK}/passthrough.air" -o "${WORK}/default.metallib"

if [[ ! -s "${WORK}/default.metallib" ]]; then
    echo "error: rebuilt metallib is empty" >&2
    exit 1
fi

# The product file may be read-only after the resource copy phase.
chmod u+w "${METALLIB_DEST}" 2>/dev/null || true
cp "${WORK}/default.metallib" "${METALLIB_DEST}"
chmod u+w "${METALLIB_DEST}" 2>/dev/null || true

echo "rebuilt HXPhotoPicker metallib without debug info -> ${METALLIB_DEST}"
