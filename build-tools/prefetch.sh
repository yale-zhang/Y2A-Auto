#!/usr/bin/env bash
# Y2A-Auto build dependency prefetch script
# ---------------------------------------------------------------
# Pre-downloads FFmpeg tarball and pip wheels on the host so the
# Dockerfile can use --mount=type=bind and skip the Docker VM
# network path. Avoids the macOS HTTP/2 / large-file issue we hit
# when downloading 100MB+ files from inside the OrbStack VM.
#
# Usage:
#   ./build-tools/prefetch.sh                 # ffmpeg (arm64) + torch + requirements
#   ./build-tools/prefetch.sh --all-arch      # also fetch ffmpeg amd64
#   ./build-tools/prefetch.sh --ffmpeg-only
#   ./build-tools/prefetch.sh --pip-only
# Override mirrors:
#   PIP_MIRROR=https://pypi.org/simple ./build-tools/prefetch.sh --pip-only
# ---------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

FFMPEG_DIR=build-tools/ffmpeg-cache
PIP_DIR=build-tools/pip-cache

# Tsinghua by default; export PIP_MIRROR to change.
PIP_MIRROR=${PIP_MIRROR:-https://pypi.tuna.tsinghua.edu.cn/simple}
TORCH_MIRROR=${TORCH_MIRROR:-https://download.pytorch.org/whl/cpu}

download_ffmpeg() {
  local arch=$1
  local out="$FFMPEG_DIR/ffmpeg-${arch}.tar.xz"
  if [[ -f "$out" && -s "$out" ]]; then
    echo "[skip] $out already exists ($(du -h "$out" | cut -f1))"
    return 0
  fi
  mkdir -p "$FFMPEG_DIR"
  local url
  case "$arch" in
    amd64|x86_64) url='https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n8.1-latest-linux64-gpl-8.1.tar.xz' ;;
    arm64|aarch64) url='https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n8.1-latest-linuxarm64-gpl-8.1.tar.xz' ;;
    *) echo "[err] unknown arch: $arch" >&2; return 1 ;;
  esac
  echo "[dl ] ffmpeg $arch -> $out"
  # Two mirror modes:
  #   GITHUB_MIRROR=https://gh-proxy.com            -> https://gh-proxy.com/<full github URL>
  #   GITHUB_MIRROR=https://gh-proxy.com/           -> same (trailing slash, normalized)
  #   (unset)                                       -> direct
  GITHUB_MIRROR="${GITHUB_MIRROR:-}"
  GITHUB_MIRROR="${GITHUB_MIRROR%/}"
  if [[ -n "$GITHUB_MIRROR" ]]; then
    # Strip the original https://github.com so we don't double-prefix.
    url="${GITHUB_MIRROR}/${url#https://github.com}"
  fi
  echo "      url: $url"
  curl --http1.1 \
       --retry 5 --retry-delay 3 --retry-connrefused --retry-all-errors \
       --connect-timeout 30 --max-time 1800 \
       -fL --progress-bar \
       -o "$out.part" "$url"
  mv "$out.part" "$out"
  echo "[ok ] $out ($(du -h "$out" | cut -f1))"
}

download_pip() {
  mkdir -p "$PIP_DIR"
  echo "[dl ] torch + torchaudio -> $PIP_DIR (mirror: $TORCH_MIRROR, fallback: $PIP_MIRROR)"
  # PyTorch's CPU-only CDN sometimes prunes old versions (e.g. torchaudio 2.6.0
  # disappeared from there); use a regular PyPI mirror as a fallback. We pin to
  # manylinux + cp311 so the wheels match the python:3.11-slim container regardless
  # of what Python version is on the host.
  pip download --dest "$PIP_DIR" \
       --index-url "$TORCH_MIRROR" \
       --extra-index-url "$PIP_MIRROR" \
       --platform manylinux_2_28_aarch64 \
       --python-version 311 \
       --abi cp311 \
       --only-binary=:all: \
       --no-deps \
       "torch==2.6.0" "torchaudio==2.6.0"

  echo "[dl ] requirements.txt -> $PIP_DIR (mirror: $PIP_MIRROR)"
  pip download --dest "$PIP_DIR" \
       --index-url "$PIP_MIRROR" \
       --extra-index-url "$TORCH_MIRROR" \
       --platform manylinux_2_28_aarch64 \
       --python-version 311 \
       --abi cp311 \
       --prefer-binary \
       -r requirements.txt

  local n
  n=$(ls "$PIP_DIR" | wc -l | tr -d ' ')
  echo "[ok ] $n wheels in $PIP_DIR"
}

ALL_ARCH=0
FFMPEG_ONLY=0
PIP_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --all-arch) ALL_ARCH=1 ;;
    --ffmpeg-only) FFMPEG_ONLY=1 ;;
    --pip-only) PIP_ONLY=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "[err] unknown arg: $arg" >&2; exit 1 ;;
  esac
done

if [[ $PIP_ONLY -eq 0 ]]; then
  download_ffmpeg arm64
  if [[ $ALL_ARCH -eq 1 ]]; then download_ffmpeg amd64; fi
fi
if [[ $FFMPEG_ONLY -eq 0 ]]; then
  download_pip
fi
echo "[done] prefetch complete"
