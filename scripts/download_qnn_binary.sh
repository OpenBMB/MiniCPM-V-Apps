#!/usr/bin/env bash
#
# Fetch the QNN context binaries for the MiniCPM-OCR vision tower. The
# repository does not track them: each is ~868 MB and compiled for one DSP
# architecture (same rule as llama.xcframework).
#
# They are only needed to run OCR on the Hexagon NPU. Without them the app falls
# back to the CPU vision tower and works normally, so skipping this is fine
# unless you want the speedup. See scripts/qnn/README.md for the measured
# difference and for how to build the binaries yourself.
#
# Usage:
#   ./scripts/download_qnn_binary.sh              # every arch still missing
#   ./scripts/download_qnn_binary.sh v85          # just one
#   FORCE=1 ./scripts/download_qnn_binary.sh v85  # replace an existing file
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
DEST_DIR="${REPO_ROOT}/scripts/qnn"

# Same two mirrors the app races at runtime, so this works from either side of
# the mainland China border.
HF_BASE="https://huggingface.co/tc-mb/MiniCPM-V-Apps-gguf/resolve/main/MiniCPM-OCR-1.0"
MS_BASE="https://www.modelscope.cn/models/zerg13/MiniCPM-V-Apps-gguf/resolve/master/MiniCPM-OCR-1.0"

: "${FORCE:=0}"

# arch -> md5, from the conversion run that produced these files
declare -A MD5=(
    [v69]="481fe8fa0233f894e27261bfc91c4a71"
    [v73]="c5a9d57decaf306378f0c8d193eee223"
    [v75]="f4e0a538d7b96d34d539e632251a952f"
    [v85]="8d4b0ec720cefa30dd67810f834a30ca"
)

md5_of() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" | awk '{print $1}'
    else
        md5 -q "$1"
    fi
}

download() {
    local url="$1" out="$2"
    echo "downloading ${url}"
    curl -fL --retry 3 --retry-delay 2 --continue-at - -o "${out}" "${url}"
}

want=("$@")
if [[ ${#want[@]} -eq 0 ]]; then
    want=(v69 v73 v75 v85)
fi

mkdir -p "${DEST_DIR}"

for arch in "${want[@]}"; do
    name="minicpm-ocr-qnn-${arch}.bin"
    dest="${DEST_DIR}/${name}"
    if [[ "${FORCE}" != "1" && -f "${dest}" ]]; then
        echo "${name} already present (md5 $(md5_of "${dest}"))"
        continue
    fi

    tmp="${dest}.part"
    rm -f "${tmp}"
    if ! download "${HF_BASE}/${name}" "${tmp}"; then
        echo "HuggingFace failed, trying ModelScope" >&2
        rm -f "${tmp}"
        download "${MS_BASE}/${name}" "${tmp}"
    fi

    expect="${MD5[$arch]:-}"
    if [[ -n "${expect}" ]]; then
        actual="$(md5_of "${tmp}")"
        if [[ "${actual}" != "${expect}" ]]; then
            echo "error: ${name} md5 mismatch" >&2
            echo "  expected ${expect}" >&2
            echo "  actual   ${actual}" >&2
            rm -f "${tmp}"
            exit 1
        fi
    else
        echo "note: no pinned md5 for ${arch}; recording $(md5_of "${tmp}")"
    fi

    mv "${tmp}" "${dest}"
    echo "installed ${name}"
done

echo
echo "push the ones this device needs with:"
echo "  adb push ${DEST_DIR}/minicpm-ocr-qnn-<arch>.bin /data/local/tmp/"
echo "  adb shell run-as com.tianchi.minicpmv mkdir -p files/models/minicpm-ocr-1.0"
echo "  adb shell \"run-as com.tianchi.minicpmv cp /data/local/tmp/minicpm-ocr-qnn-<arch>.bin \\"
echo "             files/models/minicpm-ocr-1.0/\""
