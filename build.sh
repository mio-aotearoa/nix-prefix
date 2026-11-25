#!/usr/bin/env bash
# Pure dramforever Stage-1 -> Stage-2 bootstrap for Termux (Android Bionic)
#
# Implements https://dram.page/p/bootstrapping-nix/ with ZERO patchelf path-replacing hacks:
#   - Flavor 0 (host Nix): lives in /nix/store, operates on /nix/store
#   - Flavor 1 (Stage 1):  Nix targeting /data/data/com.termux/files/nix/store
#                          (`nix-build --store 'local?root=<stage>&store=/data/data/com.termux/files/nix/store'`)
#   - Flavor 2 (Stage 2):  evaluates bootstrap.nix with builtins.storeDir == /data/data/com.termux/files/nix/store,
#                          compiling genuine Bionic binaries + Home Manager + all stdenv stages
#                          using the project's single fixed aarch64 ISA (armv8.2-a).

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARNING]${NC} $*"; }

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo "Build pure dramforever Stage-2 Bionic Nix + Home Manager installer for Termux"
    echo ""
    echo "Options:"
    echo "  -a, --arch ARCH       Target arch: aarch64 (default, fixed armv8.2-a), armv7l, x86_64 (fixed x86-64-v2), i686"
    echo "  -A, --all             Build for all supported architectures"
    echo "  --stage-root DIR      Chroot-rooted local store directory for Stage-2 builds"
    echo "  --stage1-only         Build only Stage-1 Nix driver (nix-stage1) on host /nix/store"
    echo "  -l, --list            List supported architectures"
    echo "  -h, --help            Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                    # Pure Stage-2 Bionic aarch64 (fixed armv8.2-a)"
    echo "  $0 -a x86_64          # Pure Stage-2 Bionic x86_64 (fixed x86-64-v2)"
    echo "  $0 --stage1-only      # Build Stage-1 Nix driver on host /nix/store"
}

SUPPORTED_ARCHS=("aarch64" "armv7l" "x86_64" "i686")

declare -A TARGET_PLATFORMS
TARGET_PLATFORMS["aarch64"]="aarch64-unknown-linux-android (Bionic, fixed armv8.2-a)"
TARGET_PLATFORMS["armv7l"]="armv7a-unknown-linux-androideabi (Bionic)"
TARGET_PLATFORMS["x86_64"]="x86_64-unknown-linux-android (Bionic, fixed x86-64-v2)"
TARGET_PLATFORMS["i686"]="i686-unknown-linux-android (Bionic)"

ARCHS_TO_BUILD=()
BUILD_ALL=false
STAGE1_ONLY=false
STAGE_ROOT="${STAGE_ROOT:-$PWD/result/stage2-root}"

while [[ $# -gt 0 ]]; do
    case $1 in
        -a|--arch)
            if [[ $# -lt 2 ]]; then error "Missing argument for $1"; exit 1; fi
            if [[ " ${SUPPORTED_ARCHS[*]} " =~ " $2 " ]]; then
                ARCHS_TO_BUILD+=("$2")
                shift 2
            else
                error "Unsupported architecture: $2 (supported: ${SUPPORTED_ARCHS[*]})"
                exit 1
            fi
            ;;
        -A|--all)
            BUILD_ALL=true
            shift
            ;;
        --stage-root)
            if [[ $# -lt 2 ]]; then error "Missing argument for $1"; exit 1; fi
            STAGE_ROOT="$2"
            shift 2
            ;;
        --stage1-only)
            STAGE1_ONLY=true
            shift
            ;;
        -l|--list)
            echo "Supported Android Bionic architectures (fixed ISA per arch):"
            for arch in "${SUPPORTED_ARCHS[@]}"; do
                echo "  - $arch: ${TARGET_PLATFORMS[$arch]}"
            done
            exit 0
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

if ! command -v nix >/dev/null 2>&1; then
    error "nix not found. Please install Nix first."
    exit 1
fi

OUTPUT_DIR="$PWD/result"
mkdir -p "$OUTPUT_DIR"

if [ "$STAGE1_ONLY" = true ]; then
    log "Building dramforever Stage-1 Nix driver (.#nix-stage1)..."
    nix --extra-experimental-features 'nix-command flakes' build .#nix-stage1 -L -o "$OUTPUT_DIR/nix-stage1"
    success "Stage-1 Nix driver built: $OUTPUT_DIR/nix-stage1"
    exit 0
fi

if [ ${#ARCHS_TO_BUILD[@]} -eq 0 ] && [ "$BUILD_ALL" = false ]; then
    ARCHS_TO_BUILD=("aarch64")
fi
if [ "$BUILD_ALL" = true ]; then
    ARCHS_TO_BUILD=("${SUPPORTED_ARCHS[@]}")
fi

FAILED_ARCHS=()
for arch in "${ARCHS_TO_BUILD[@]}"; do
    log "=========================================="
    log "Pure Stage-2 Bionic bootstrap: $arch"
    log "=========================================="
    if ! ./scripts/build-stage2.sh -a "$arch" --stage-root "$STAGE_ROOT"; then
        FAILED_ARCHS+=("$arch")
    fi
done

if [ ${#FAILED_ARCHS[@]} -eq 0 ]; then
    success "All pure Stage-2 Bionic builds completed!"
else
    error "Builds failed for architectures: ${FAILED_ARCHS[*]}"
    exit 1
fi
