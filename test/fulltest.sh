#!/bin/bash
# =============================================================================
# fulltest.sh — Multi-GPU test suite
# Supports: RTX 4090/5090, A4000, A100, H100 on Ubuntu 22.04/24.04
# Usage:  ./fulltest.sh [test...] [--burn-duration <s>] [--clean] [--list] [--help]
#   Tests: preflight, ecc, pcie, clocks, nccl, cuda-samples, nvbandwidth,
#          dcgm, pytorch, memtest, stress
#   If no tests specified, all are run in the order above.
# =============================================================================

set -o pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Constants and globals
# ─────────────────────────────────────────────────────────────────────────────

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILD_DIR="$SCRIPT_DIR/build"
readonly LOG_FILE="$SCRIPT_DIR/fulltest_$(date +%Y%m%d_%H%M%S).log"

CLEAN_BUILD=false
BURN_DURATION=300   # seconds; override with --burn-duration <seconds>

mkdir -p "$BUILD_DIR"

# Write identification header to log immediately
{
    echo "============================================================"
    echo "  fulltest.sh — GPU Test Suite"
    echo "  Date     : $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "  Hostname : $(hostname -f 2>/dev/null || hostname)"
    echo "  IP(s)    : $(hostname -I 2>/dev/null | tr ' ' ',' | sed 's/,$//' || echo 'unknown')"
    echo "  User     : $(whoami)"
    echo "  Script   : $SCRIPT_DIR/fulltest.sh"
    echo "============================================================"
} | tee "$LOG_FILE"

RESULTS_PASS=()
RESULTS_FAIL=()
RESULTS_SKIP=()

# Populated during system detection
NUM_GPUS=""
GPU_NAMES=""
CUDA_VERSION=""
CUDA_MAJOR=""
CUDA_MINOR=""
CUDA_HOME_DIR=""
NVCC_PATH=""
CUDA_ARCH_LIST=""
TORCH_CUDA=""
PIP_EXTRA=""
UBUNTU_MAJOR=""
RESULTS_STRESS_LABEL="Sustained Compute Stress"

# ─────────────────────────────────────────────────────────────────────────────
# Utilities
# ─────────────────────────────────────────────────────────────────────────────

log() { echo "$@" | tee -a "$LOG_FILE"; }
log_run() { "$@" 2>&1 | tee -a "$LOG_FILE"; return "${PIPESTATUS[0]}"; }

# Run a command inside a directory in a subshell — no cd leakage on failure
in_dir() {
    local dir="$1"; shift
    (cd "$dir" && "$@")
}

# Idempotent apt package install
apt_install() {
    for pkg in "$@"; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            log "  apt: installing $pkg"
            sudo apt-get install -y "$pkg" 2>&1 | tee -a "$LOG_FILE"
        fi
    done
}

ensure_cmake() {
    command -v cmake &>/dev/null && return 0
    log "  cmake not found — installing..."
    if command -v apt-get &>/dev/null; then
        apt_install cmake
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y cmake
    else
        log "ERROR: Cannot install cmake — unknown package manager."
        return 1
    fi
}

# cmake_build <src_dir> <binary_name>
# Out-of-source build; patches sm_110 out of cuda-samples CMakeLists first.
cmake_build() {
    local src="$1" bin="$2"

    [ -f "$src/build/$bin" ] && { log "  Already built: $bin"; return 0; }

    log "  Building $bin..."

    # sm_110 was removed from CUDA 12.9 but hardcoded in cuda-samples CMakeLists
    find "$src" -name "CMakeLists.txt" -exec grep -l 'set(CMAKE_CUDA_ARCHITECTURES' {} \; \
    | while read -r f; do
        sed -i 's/\b110\b//g; s/  */ /g' "$f"
    done

    local archs_cmake
    archs_cmake=$(echo "$CUDA_ARCH_LIST" | tr ' ' ';')

    in_dir "$src" bash -c "
        rm -rf build && mkdir build && cd build
        cmake .. \
            -DCMAKE_CUDA_COMPILER='$NVCC_PATH' \
            -DCMAKE_CUDA_ARCHITECTURES='$archs_cmake'
        make -j$(nproc)
    " 2>&1 | tee -a "$LOG_FILE"
}

find_binary() {
    find "$1" -type f -name "$2" ! -name "*.cmake" ! -name "*.cpp" 2>/dev/null | head -1
}

# decode_throttle <hex_bitmask>
# Translates nvidia-smi clocks_throttle_reasons.active hex bitmask into
# human-readable labels, returning only the bits that represent real problems.
#
# Bitmask reference:
#   0x001  gpu_idle                  — normal idle clock-down, ignore
#   0x002  applications_clocks       — app clock setting, ignore
#   0x004  sw_power_cap              — driver idle power saving, ignore
#   0x008  hw_slowdown               — REAL: HW thermal or power event
#   0x010  sync_boost                — normal multi-GPU sync, ignore
#   0x020  sw_thermal_slowdown       — REAL: SW thermal limit hit
#   0x040  hw_power_brake_slowdown   — REAL: external power brake signal
#   0x080  display_clocks            — normal display setting, ignore
#
# Prints "Not Active" if no problem bits set, or a comma-separated list of
# problem names. Exits 1 if any problem bits are set.
decode_throttle() {
    local raw="$1"
    # Strip leading 0x and parse as hex
    local val
    val=$(printf '%d' "$raw" 2>/dev/null) || { echo "unknown"; return 0; }

    local problems=()
    (( val & 0x008 )) && problems+=("HW_Slowdown")
    (( val & 0x020 )) && problems+=("SW_Thermal")
    (( val & 0x040 )) && problems+=("HW_PowerBrake")

    if [ "${#problems[@]}" -eq 0 ]; then
        echo "Not Active"
        return 0
    else
        local IFS=','
        echo "${problems[*]}"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Result tracking
# ─────────────────────────────────────────────────────────────────────────────

run_test() {
    local name="$1"; shift
    log ""
    log "========================================"
    log "Running: $name"
    log "========================================"
    local rc=0
    log_run "$@" || rc=$?
    if [ "$rc" -eq 0 ]; then
        log "[ PASS ] $name"
        RESULTS_PASS+=("$name")
    else
        log "[ FAIL ] $name (exit code $rc)"
        RESULTS_FAIL+=("$name")
    fi
}

skip_test() {
    log "========================================"
    log "SKIPPED: $1"
    log "Reason : $2"
    log "========================================"
    RESULTS_SKIP+=("$1 — $2")
}

# ─────────────────────────────────────────────────────────────────────────────
# System detection
# ─────────────────────────────────────────────────────────────────────────────

detect_system() {
    log "========================================"
    log "System Detection"
    log "========================================"

    local ubuntu_ver os_id
    ubuntu_ver=$(lsb_release -rs 2>/dev/null || echo "0")
    UBUNTU_MAJOR=$(echo "$ubuntu_ver" | cut -d. -f1)
    os_id=$(lsb_release -is 2>/dev/null || echo "Unknown")
    log "  OS                  : $os_id $ubuntu_ver"

    NUM_GPUS=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU' || true)
    if [ -z "$NUM_GPUS" ] || [ "$NUM_GPUS" -eq 0 ]; then
        log "ERROR: No NVIDIA GPUs detected. Aborting."
        exit 1
    fi
    log "  GPUs detected       : $NUM_GPUS"

    GPU_NAMES=$(nvidia-smi --query-gpu=name --format=csv,noheader \
        | tr -d '\r' | sort -u | tr '\n' ',' | sed 's/,$//')
    log "  GPU model(s)        : $GPU_NAMES"

    # Find nvcc
    for candidate in "$(command -v nvcc 2>/dev/null)" \
                     /usr/local/cuda/bin/nvcc \
                     /usr/bin/nvcc; do
        [ -x "$candidate" ] && { NVCC_PATH="$candidate"; break; }
    done
    if [ -z "$NVCC_PATH" ]; then
        log "ERROR: nvcc not found. Install CUDA toolkit or add nvcc to PATH."
        exit 1
    fi

    CUDA_HOME_DIR=$(dirname "$(dirname "$NVCC_PATH")")
    CUDA_VERSION=$("$NVCC_PATH" --version | grep -oP 'release \K[0-9]+\.[0-9]+')
    CUDA_MAJOR=$(echo "$CUDA_VERSION" | cut -d. -f1)
    CUDA_MINOR=$(echo "$CUDA_VERSION" | cut -d. -f2)
    log "  nvcc                : $NVCC_PATH"
    log "  CUDA                : $CUDA_VERSION (home: $CUDA_HOME_DIR)"

    # Strip \r — nvidia-smi can emit Windows-style line endings
    CUDA_ARCH_LIST=$(
        nvidia-smi --query-gpu=compute_cap --format=csv,noheader \
        | tr -d '\r' | tr -d '.' | sort -u | tr '\n' ' ' | xargs
    )
    log "  Architecture(s)     : $CUDA_ARCH_LIST"

    # PyTorch wheel suffix
    case "$CUDA_MAJOR" in
        11) TORCH_CUDA="cu118" ;;
        12)
            if   [ "$CUDA_MINOR" -le 1 ]; then TORCH_CUDA="cu121"
            elif [ "$CUDA_MINOR" -le 4 ]; then TORCH_CUDA="cu124"
            else TORCH_CUDA="cu128"
            fi
            ;;
        *)  TORCH_CUDA="cu128" ;;
    esac
    log "  PyTorch wheel       : https://download.pytorch.org/whl/$TORCH_CUDA"

    # pip flag for Ubuntu 24.04+ (PEP 668)
    [ "$UBUNTU_MAJOR" -ge 24 ] 2>/dev/null && PIP_EXTRA="--break-system-packages" || PIP_EXTRA=""

    [ "$NUM_GPUS" -eq 1 ] && log "  NOTE: Single GPU — multi-GPU tests run in single-GPU mode."
    log ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: preflight — idle thermal baseline + persistence mode + driver state
# Run first so we have a clean-state snapshot before anything loads the GPUs.
# ─────────────────────────────────────────────────────────────────────────────

test_preflight() {
    local rc=0

    log "--- Persistence mode ---"
    # Persistence mode keeps the driver loaded between jobs, avoiding multi-second
    # cold-start latency. Should be enabled on any multi-GPU production system.
    local gpu_idx persist_mode
    while IFS=, read -r gpu_idx persist_mode; do
        persist_mode=$(echo "$persist_mode" | xargs)
        if [ "$persist_mode" = "Enabled" ]; then
            log "  GPU $gpu_idx: persistence mode Enabled — OK"
        else
            log "  GPU $gpu_idx: persistence mode Disabled — recommend: sudo nvidia-smi -pm 1"
            # Warning only, not a failure — not all environments need it
        fi
    done < <(nvidia-smi \
        --query-gpu=index,persistence_mode \
        --format=csv,noheader | tr -d '\r')

    log ""
    log "--- Idle thermal baseline ---"
    # Snapshot temp, power, clocks, fan at idle before any test loads the GPUs.
    # If a GPU is already throttling here, something is wrong (fan failure, blocked airflow).
    local gpu_name temp power clk_sm clk_mem fan throttle
    local any_hot=false
    printf "  %-4s %-25s %6s %7s %7s %7s %5s  %s\n" \
        "GPU" "Name" "Temp°C" "Power W" "SM MHz" "Mem MHz" "Fan%" "Throttle" \
        | tee -a "$LOG_FILE"
    while IFS=, read -r gpu_idx gpu_name temp power clk_sm clk_mem fan throttle; do
        gpu_name=$(echo "$gpu_name" | xargs)
        temp=$(echo "$temp"     | xargs)
        power=$(echo "$power"   | xargs)
        clk_sm=$(echo "$clk_sm" | xargs)
        clk_mem=$(echo "$clk_mem" | xargs)
        fan=$(echo "$fan"       | xargs)
        throttle=$(echo "$throttle" | xargs)
        # Decode raw hex bitmask — only flag bits that represent real problems
        # (0x4 sw_power_cap at idle is normal clock-down, not a fault)
        local throttle_decoded
        throttle_decoded=$(decode_throttle "$throttle")
        printf "  %-4s %-25s %6s %7s %7s %7s %5s  %s\n" \
            "$gpu_idx" "$gpu_name" "$temp" "$power" "$clk_sm" "$clk_mem" "$fan" "$throttle_decoded" \
            | tee -a "$LOG_FILE"
        # Warn if idle temp is already above 60°C — suggests cooling problem
        local temp_val="${temp//[^0-9]/}"
        if [ -n "$temp_val" ] && [ "$temp_val" -gt 60 ]; then
            log "  WARNING: GPU $gpu_idx idle temp ${temp}°C is high — check cooling"
            any_hot=true
        fi
        # Only flag throttle reasons that indicate real hardware problems
        if [ "$throttle_decoded" != "Not Active" ] && [ "$throttle_decoded" != "unknown" ]; then
            log "  WARNING: GPU $gpu_idx has active throttle at idle: $throttle_decoded"
            rc=1
        fi
    done < <(nvidia-smi \
        --query-gpu=index,name,temperature.gpu,power.draw,clocks.sm,clocks.mem,fan.speed,clocks_throttle_reasons.active \
        --format=csv,noheader | tr -d '\r')

    log ""
    log "--- Driver version ---"
    nvidia-smi --query-gpu=index,driver_version \
        --format=csv,noheader | tr -d '\r' \
        | while IFS=, read -r idx drv; do
            log "  GPU $idx: driver $drv"
          done

    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: ecc — ECC error check (DC GPUs only; skip/warn gracefully on GeForce)
# ─────────────────────────────────────────────────────────────────────────────

test_ecc() {
    local rc=0 any_dc=false

    log "  Checking ECC status per GPU..."
    log ""
    printf "  %-4s %-25s %-10s %-12s %s\n" \
        "GPU" "Name" "ECC Mode" "Uncorr.Errs" "Notes" | tee -a "$LOG_FILE"

    local gpu_idx gpu_name ecc_mode uncorr_errs
    while IFS=, read -r gpu_idx gpu_name ecc_mode uncorr_errs; do
        gpu_idx=$(echo "$gpu_idx"     | xargs)
        gpu_name=$(echo "$gpu_name"   | xargs)
        ecc_mode=$(echo "$ecc_mode"   | xargs)
        uncorr_errs=$(echo "$uncorr_errs" | xargs)

        local note=""
        case "$ecc_mode" in
            Enabled)
                any_dc=true
                if [ "$uncorr_errs" = "[N/A]" ] || [ -z "$uncorr_errs" ]; then
                    note="ECC on, no error count available"
                elif [ "$uncorr_errs" -gt 0 ] 2>/dev/null; then
                    note="*** UNCORRECTED ERRORS — replace GPU ***"
                    rc=1
                else
                    note="OK — 0 uncorrected errors"
                fi
                ;;
            Disabled)
                any_dc=true
                note="ECC supported but disabled — enable with: sudo nvidia-smi -e 1 && reboot"
                ;;
            "[N/A]"|"N/A"|"")
                note="ECC not supported (GeForce/consumer GPU — expected)"
                ;;
            *)
                note="Unknown ECC state: $ecc_mode"
                ;;
        esac

        printf "  %-4s %-25s %-10s %-12s %s\n" \
            "$gpu_idx" "$gpu_name" "$ecc_mode" "$uncorr_errs" "$note" \
            | tee -a "$LOG_FILE"
    done < <(nvidia-smi \
        --query-gpu=index,name,ecc.mode.current,ecc.errors.uncorrected.volatile.total \
        --format=csv,noheader | tr -d '\r')

    log ""
    if [ "$any_dc" = false ]; then
        log "  All GPUs are consumer grade — ECC not applicable. (PASS)"
    fi

    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: pcie — PCIe link width and generation check
# A GPU silently degraded to x1 or Gen2 passes every other test at low BW.
# ─────────────────────────────────────────────────────────────────────────────

test_pcie() {
    local rc=0

    # PCIe Active State Power Management (ASPM) legitimately drops the link from
    # Gen3/Gen4 down to Gen1 at idle to save power — this is correct behaviour,
    # not a fault. nvidia-smi pcie.link.gen.current is an instantaneous read, so
    # sampling at idle gives a false Gen1 result on any system with ASPM enabled.
    #
    # Strategy: always spin up a brief GPU load first to force all links to full
    # speed, then sample. Width mismatches (x8 vs x16) are hard failures because
    # lane width never power-gates. Gen mismatches are warnings only, because even
    # under load some platforms briefly drop before re-negotiating.

    local aspm_policy
    aspm_policy=$(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null || echo "unknown")
    log "  PCIe ASPM policy : $aspm_policy"
    log "  Spinning up GPU load to force links to full speed before sampling..."

    # Run load on all GPUs for 10 seconds, sample in the middle while it's active
    python3 - << 'PYEOF' &
import torch, time
gpus = list(range(torch.cuda.device_count()))
if not gpus:
    import sys; sys.exit(0)
m = [torch.randn(4096, 4096, device=f"cuda:{g}") for g in gpus]
end = time.time() + 15
while time.time() < end:
    for g, a in enumerate(m):
        with torch.cuda.device(g): torch.mm(a, a)
    for g in gpus: torch.cuda.synchronize(g)
PYEOF
    local load_pid=$!
    sleep 5   # let links negotiate up

    log ""
    log "  PCIe link width and generation per GPU (sampled under load):"
    printf "  %-4s %-25s %8s %8s %8s %8s  %s\n" \
        "GPU" "Name" "CurGen" "MaxGen" "CurWidth" "MaxWidth" "Status" \
        | tee -a "$LOG_FILE"

    local any_gen_warn=false any_width_fail=false
    local gpu_idx gpu_name cur_gen max_gen cur_width max_width
    while IFS=, read -r gpu_idx gpu_name cur_gen max_gen cur_width max_width; do
        gpu_idx=$(echo "$gpu_idx"     | xargs)
        gpu_name=$(echo "$gpu_name"   | xargs)
        cur_gen=$(echo "$cur_gen"     | xargs)
        max_gen=$(echo "$max_gen"     | xargs)
        cur_width=$(echo "$cur_width" | xargs)
        max_width=$(echo "$max_width" | xargs)

        local status="OK"

        # Gen mismatch: warning only — ASPM or platform policy can legitimately
        # keep links at Gen1/Gen2 even under load on some motherboards.
        if [ "$cur_gen" != "$max_gen" ] && \
           [ "$cur_gen" != "[N/A]" ] && [ "$max_gen" != "[N/A]" ]; then
            status="WARN: Gen${cur_gen} < Gen${max_gen} (may be BIOS/ASPM — see below)"
            any_gen_warn=true
            # Warning, not a hard failure
        fi

        # Width mismatch: hard failure — lane count never power-gates.
        # x8 when capable of x16 means a physical slot or riser limitation.
        if [ "$cur_width" != "$max_width" ] && \
           [ "$cur_width" != "[N/A]" ] && [ "$max_width" != "[N/A]" ]; then
            status="FAIL: x${cur_width} < x${max_width} (physical slot/riser limitation)"
            any_width_fail=true
            rc=1
        fi

        printf "  %-4s %-25s %8s %8s %8s %8s  %s\n" \
            "$gpu_idx" "$gpu_name" \
            "Gen$cur_gen" "Gen$max_gen" "x$cur_width" "x$max_width" \
            "$status" | tee -a "$LOG_FILE"
    done < <(nvidia-smi \
        --query-gpu=index,name,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max \
        --format=csv,noheader | tr -d '\r')

    # Stop background load
    kill "$load_pid" 2>/dev/null; wait "$load_pid" 2>/dev/null || true

    log ""
    if [ "$any_gen_warn" = true ]; then
        log "  NOTE: Generation mismatch detected (warning only — not a failure)."
        log "  Gen speed can legitimately stay low due to:"
        log "    • ASPM (power saving) — disable in BIOS or set policy to performance:"
        log "        sudo sh -c 'echo performance > /sys/module/pcie_aspm/parameters/policy'"
        log "    • BIOS PCIe speed forced to Gen1/Gen2 — set to Auto or Gen3/Gen4"
        log "    • 'Above 4G Decoding' disabled in BIOS (required for 8-GPU systems)"
        log "  If NVBandwidth host<->device numbers look normal, this is not a real issue."
    fi
    if [ "$any_width_fail" = true ]; then
        log "  FAIL: Width mismatch detected — lane count does not power-gate."
        log "  Likely causes: GPU in x8 physical slot, damaged riser, or shared PCIe lanes."
    fi
    if [ "$rc" -eq 0 ] && [ "$any_gen_warn" = false ]; then
        log "  All PCIe links running at full width and generation."
    fi

    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: clocks — clock speed verification under load
# Runs a brief 30s GEMM load and samples SM/memory clocks + throttle reasons.
# Distinguishes thermal throttle vs power throttle vs SW throttle.
# ─────────────────────────────────────────────────────────────────────────────

test_clocks() {
    local rc=0

    # Check max boost clocks at idle first
    log "  Max advertised boost clocks (idle):"
    printf "  %-4s %-25s %10s %10s\n" "GPU" "Name" "MaxSM MHz" "MaxMem MHz" \
        | tee -a "$LOG_FILE"
    local gpu_idx gpu_name max_sm max_mem
    while IFS=, read -r gpu_idx gpu_name max_sm max_mem; do
        printf "  %-4s %-25s %10s %10s\n" \
            "$(echo "$gpu_idx" | xargs)" \
            "$(echo "$gpu_name" | xargs)" \
            "$(echo "$max_sm" | xargs)" \
            "$(echo "$max_mem" | xargs)" | tee -a "$LOG_FILE"
    done < <(nvidia-smi \
        --query-gpu=index,name,clocks.max.sm,clocks.max.mem \
        --format=csv,noheader | tr -d '\r')

    log ""
    log "  Running 30s load to measure sustained clocks..."

    # Kick off a background GEMM load on all GPUs via Python
    local load_script="$BUILD_DIR/_clock_load.py"
    cat > "$load_script" << 'PYEOF'
import torch, time, sys
gpus = list(range(torch.cuda.device_count()))
SIZE = 4096
matrices = [
    (torch.randn(SIZE, SIZE, dtype=torch.float16, device=f"cuda:{g}"),
     torch.randn(SIZE, SIZE, dtype=torch.float16, device=f"cuda:{g}"))
    for g in gpus
]
end = time.time() + 30
while time.time() < end:
    for g, (a, b) in enumerate(matrices):
        with torch.cuda.device(g): torch.mm(a, b)
    for g in gpus: torch.cuda.synchronize(g)
PYEOF

    python3 "$load_script" &
    local load_pid=$!

    # Sample clocks and throttle reasons every 3 seconds for 30 seconds
    log "  Sampling clocks under load (every 3s for 30s):"
    printf "  %-6s %-4s %-10s %-10s %s\n" \
        "Time" "GPU" "SM MHz" "Mem MHz" "ThrottleReasons" | tee -a "$LOG_FILE"

    local sample=0 any_throttle=false
    while [ "$sample" -lt 10 ]; do
        sleep 3
        local elapsed=$(( (sample + 1) * 3 ))
        local gpu_idx clk_sm clk_mem throttle
        while IFS=, read -r gpu_idx clk_sm clk_mem throttle; do
            gpu_idx=$(echo "$gpu_idx" | xargs)
            clk_sm=$(echo "$clk_sm"   | xargs)
            clk_mem=$(echo "$clk_mem" | xargs)
            throttle=$(echo "$throttle" | xargs)
            local throttle_decoded
            throttle_decoded=$(decode_throttle "$throttle")
            printf "  %-6s %-4s %-10s %-10s %s\n" \
                "${elapsed}s" "$gpu_idx" "$clk_sm" "$clk_mem" "$throttle_decoded" \
                | tee -a "$LOG_FILE"
            if [ "$throttle_decoded" != "Not Active" ] && [ "$throttle_decoded" != "unknown" ]; then
                any_throttle=true
            fi
        done < <(nvidia-smi \
            --query-gpu=index,clocks.sm,clocks.mem,clocks_throttle_reasons.active \
            --format=csv,noheader | tr -d '\r')
        sample=$((sample + 1))
    done

    wait "$load_pid" 2>/dev/null || true
    rm -f "$load_script"

    log ""
    if [ "$any_throttle" = true ]; then
        log "  WARNING: Clock throttling detected under load."
        log "  Common causes:"
        log "    SW_Power_Cap  → power limit set below TDP (nvidia-smi -pl to check)"
        log "    HW_Thermal    → GPU overheating — check fans, airflow, thermal paste"
        log "    HW_Power      → PSU or power connector insufficient for load"
        rc=1
    else
        log "  No throttling detected — clocks sustained at full speed."
    fi

    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: NCCL
# ─────────────────────────────────────────────────────────────────────────────

install_nccl_lib() {
    command -v dpkg &>/dev/null || return 0   # non-Debian: skip version check

    local installed_nccl installed_cuda_major
    installed_nccl=$(dpkg -l 2>/dev/null | awk '/^ii  libnccl2 /{print $3}' | head -1)

    if [ -n "$installed_nccl" ]; then
        installed_cuda_major=$(echo "$installed_nccl" | grep -oP '\+cuda\K[0-9]+')
        if [ "$installed_cuda_major" = "$CUDA_MAJOR" ]; then
            log "  libnccl2 $installed_nccl matches CUDA ${CUDA_MAJOR}.x — OK."
            return 0
        fi
        log "  WARNING: libnccl2 $installed_nccl is +cuda${installed_cuda_major} but toolkit is CUDA $CUDA_VERSION"
        log "           Removing and reinstalling to match toolkit..."
        sudo apt-get remove -y libnccl2 libnccl-dev 2>&1 | tee -a "$LOG_FILE"
    fi

    log "  Installing libnccl2/libnccl-dev for CUDA ${CUDA_MAJOR}.x..."
    sudo apt-get update -qq

    # Prefer exact version (e.g. +cuda12.9), fall back to highest +cuda12.x
    local target_ver
    target_ver=$(
        apt-cache madison libnccl2 2>/dev/null \
        | grep "+cuda${CUDA_VERSION}" | head -1 | awk '{print $3}'
    )
    if [ -z "$target_ver" ]; then
        target_ver=$(
            apt-cache madison libnccl2 2>/dev/null \
            | grep "+cuda${CUDA_MAJOR}\." | sort -t. -k2 -rn | head -1 | awk '{print $3}'
        )
    fi

    if [ -n "$target_ver" ]; then
        log "  Pinning to libnccl2=$target_ver"
        sudo apt-get install -y "libnccl2=$target_ver" "libnccl-dev=$target_ver" \
            2>&1 | tee -a "$LOG_FILE"
    else
        log "  WARNING: No cuda${CUDA_MAJOR}.x NCCL build found — installing latest (may mismatch)."
        sudo apt-get install -y libnccl2 libnccl-dev 2>&1 | tee -a "$LOG_FILE"
    fi
}

install_nccl_tests_bin() {
    local perf="$BUILD_DIR/nccl-tests/build/all_reduce_perf"
    [ ! -d "$BUILD_DIR/nccl-tests" ] && \
        git clone https://github.com/NVIDIA/nccl-tests.git "$BUILD_DIR/nccl-tests"

    if [ -f "$perf" ]; then
        local linked_nccl system_nccl
        linked_nccl=$(ldd "$perf" 2>/dev/null | awk '/libnccl/{print $3}')
        system_nccl=$(ldconfig -p 2>/dev/null | awk '/libnccl\.so\.2 /{print $NF}' | head -1)
        if [ -n "$linked_nccl" ] && [ "$linked_nccl" != "$system_nccl" ]; then
            log "  nccl-tests links $linked_nccl but system has $system_nccl — rebuilding..."
        else
            log "  nccl-tests already built."
            return 0
        fi
    fi

    log "  Building nccl-tests..."
    in_dir "$BUILD_DIR/nccl-tests" bash -c "
        make clean 2>/dev/null || true
        make -j$(nproc) CUDA_HOME='$CUDA_HOME_DIR'
    " 2>&1 | tee -a "$LOG_FILE"
}

test_nccl() {
    install_nccl_lib
    install_nccl_tests_bin

    local perf="$BUILD_DIR/nccl-tests/build/all_reduce_perf"
    [ -f "$perf" ] || { log "ERROR: nccl-tests binary not found."; return 1; }

    if "$perf" -b 8 -e 1G -f 2 -g "$NUM_GPUS" 2>&1 | tee -a "$LOG_FILE"; then
        return 0
    fi

    # Re-run with debug output to capture the actual NCCL error
    log ""
    log "  NCCL failed — re-running with NCCL_DEBUG=INFO for diagnostics:"
    NCCL_DEBUG=INFO "$perf" -b 8 -e 32M -f 2 -g "$NUM_GPUS" 2>&1 \
        | grep -E "NCCL|WARN|error|Error|fatal" | head -60 | tee -a "$LOG_FILE"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: CUDA Samples
# ─────────────────────────────────────────────────────────────────────────────

test_cuda_samples() {
    [ ! -d "$BUILD_DIR/cuda-samples" ] && \
        git clone https://github.com/NVIDIA/cuda-samples.git "$BUILD_DIR/cuda-samples"

    cmake_build "$BUILD_DIR/cuda-samples/Samples/1_Utilities/deviceQuery" "deviceQuery"

    local p2p_src
    p2p_src=$(find "$BUILD_DIR/cuda-samples/Samples" -maxdepth 3 \
        -type d -name "p2pBandwidthLatencyTest" 2>/dev/null | head -1)
    [ -n "$p2p_src" ] && cmake_build "$p2p_src" "p2pBandwidthLatencyTest"

    local rc=0

    log "--- deviceQuery ---"
    local dq_bin
    dq_bin=$(find_binary "$BUILD_DIR/cuda-samples" "deviceQuery")
    if [ -n "$dq_bin" ]; then
        "$dq_bin" 2>&1 | tee -a "$LOG_FILE" || rc=1
    else
        log "  WARN: deviceQuery binary not found"; rc=1
    fi

    log "--- p2pBandwidthLatencyTest ---"
    local p2p_bin
    p2p_bin=$(find_binary "$BUILD_DIR/cuda-samples" "p2pBandwidthLatencyTest")
    if [ -n "$p2p_bin" ]; then
        "$p2p_bin" 2>&1 | tee -a "$LOG_FILE" || rc=1
    else
        log "  WARN: p2pBandwidthLatencyTest binary not found"; rc=1
    fi

    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: NVBandwidth
# ─────────────────────────────────────────────────────────────────────────────

test_nvbandwidth() {
    ensure_cmake || return 1

    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq
        apt_install libboost-program-options-dev
    elif command -v dnf &>/dev/null; then
        rpm -q boost-program-options &>/dev/null || sudo dnf install -y boost-program-options
    fi

    [ ! -d "$BUILD_DIR/nvbandwidth" ] && \
        git clone https://github.com/NVIDIA/nvbandwidth.git "$BUILD_DIR/nvbandwidth"

    local nvb_bin
    nvb_bin=$(find_binary "$BUILD_DIR/nvbandwidth" "nvbandwidth")

    if [ -z "$nvb_bin" ]; then
        log "  Building nvbandwidth..."
        in_dir "$BUILD_DIR/nvbandwidth" bash -c "
            cmake . -DCMAKE_CUDA_COMPILER='$NVCC_PATH'
            make -j$(nproc)
        " 2>&1 | tee -a "$LOG_FILE"
        nvb_bin=$(find_binary "$BUILD_DIR/nvbandwidth" "nvbandwidth")
    else
        log "  nvbandwidth already built: $nvb_bin"
    fi

    [ -n "$nvb_bin" ] && [ -x "$nvb_bin" ] || \
        { log "ERROR: nvbandwidth binary not found after build."; return 1; }

    # device-to-device tests are waived on single-GPU systems
    "$nvb_bin" \
        -t host_to_device_memcpy_ce \
           device_to_host_memcpy_ce \
           device_to_device_memcpy_read_ce \
           device_to_device_memcpy_write_ce \
           device_to_device_bidirectional_memcpy_read_ce \
        2>&1 | tee -a "$LOG_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: DCGM (optional)
# ─────────────────────────────────────────────────────────────────────────────

test_dcgm() {
    dcgmi discovery -l 2>&1 | tee -a "$LOG_FILE"
    dcgmi diag -r 3 2>&1 | tee -a "$LOG_FILE"
    # Fields: 203=GPU util, 252=mem util, 150=temp, 155=power draw
    # Hardware/stress subtests are skipped on GeForce GPUs — expected behaviour.
    log "--- dmon (GPU util / mem util / temp / power) ---"
    dcgmi dmon -e 203,252,150,155 -c 10 2>&1 | tee -a "$LOG_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: PyTorch multi-GPU DDP
# ─────────────────────────────────────────────────────────────────────────────

install_pytorch() {
    pip3 install --upgrade pip --quiet $PIP_EXTRA 2>&1 | tee -a "$LOG_FILE"
    pip3 install torch torchvision torchaudio \
        --index-url "https://download.pytorch.org/whl/${TORCH_CUDA}" \
        --quiet $PIP_EXTRA 2>&1 | tee -a "$LOG_FILE"
    pip3 install accelerate --quiet $PIP_EXTRA 2>&1 | tee -a "$LOG_FILE"
}

find_torchrun() {
    find "$HOME/.local/bin" /usr/local/bin /usr/bin \
        -name torchrun 2>/dev/null | head -1
}

test_pytorch() {
    install_pytorch

    local torchrun
    torchrun=$(find_torchrun)
    if [ -z "$torchrun" ] || [ ! -x "$torchrun" ]; then
        log "ERROR: torchrun not found after installing PyTorch."
        return 1
    fi
    log "  Using torchrun: $torchrun"

    local script="$BUILD_DIR/_pytorch_ddp_test.py"
    cat > "$script" << 'PYEOF'
import os
import torch
import torch.nn as nn
import torch.distributed as dist
from torch.nn.parallel import DistributedDataParallel as DDP

dist.init_process_group(backend='nccl')
local_rank = int(os.environ["LOCAL_RANK"])
torch.cuda.set_device(local_rank)

model = nn.Linear(10000, 10000).cuda(local_rank)
model = DDP(model, device_ids=[local_rank])
x = torch.randn(1000, 10000, device=f"cuda:{local_rank}")

for _ in range(100):
    _ = model(x)

torch.cuda.synchronize()
if local_rank == 0:
    world = dist.get_world_size()
    print(f"PyTorch multi-GPU DDP test completed on {world} GPU(s).")
dist.destroy_process_group()
PYEOF

    local rc=0
    "$torchrun" --nproc_per_node "$NUM_GPUS" "$script" 2>&1 | tee -a "$LOG_FILE" || rc=$?
    rm -f "$script"
    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: cuda_memtest
# ─────────────────────────────────────────────────────────────────────────────

test_memtest() {
    local bin="$BUILD_DIR/cuda_memtest/build/cuda_memtest"

    if [ ! -d "$BUILD_DIR/cuda_memtest" ]; then
        git clone https://github.com/ComputationalRadiationPhysics/cuda_memtest.git \
            "$BUILD_DIR/cuda_memtest"
    fi

    if [ ! -f "$bin" ]; then
        log "  Building cuda_memtest..."
        local archs_cmake
        archs_cmake=$(echo "$CUDA_ARCH_LIST" | tr ' ' ';')
        in_dir "$BUILD_DIR/cuda_memtest" bash -c "
            rm -rf build && mkdir build && cd build
            cmake .. \
                -DCMAKE_CUDA_COMPILER='$NVCC_PATH' \
                -DCMAKE_CUDA_ARCHITECTURES='$archs_cmake'
            make -j$(nproc)
        " 2>&1 | tee -a "$LOG_FILE"
    else
        log "  cuda_memtest already built."
    fi

    [ -f "$bin" ] || { log "ERROR: cuda_memtest binary not found after build."; return 1; }

    # Run one process per GPU in parallel; collect all exit codes
    local pids=() failed=0
    for i in $(seq 0 $((NUM_GPUS - 1))); do
        "$bin" --stress --num_passes 10 --device "$i" 2>&1 | tee -a "$LOG_FILE" &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || failed=$((failed + 1))
    done
    [ "$failed" -eq 0 ] || { log "ERROR: cuda_memtest failed on $failed GPU(s)"; return 1; }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: Sustained stress
#   Hierarchy: gpu-fryer (Rust, no CUDA compile) → gpu-burn → PyTorch fallback
# ─────────────────────────────────────────────────────────────────────────────

build_gpu_fryer() {
    local bin="$BUILD_DIR/gpu-fryer/gpu-fryer"
    [ -f "$bin" ] && { log "  gpu-fryer already built."; return 0; }

    if ! command -v cargo &>/dev/null; then
        log "  cargo not found — installing Rust toolchain..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env"
    fi
    command -v cargo &>/dev/null || { log "  WARNING: cargo unavailable."; return 1; }

    [ ! -d "$BUILD_DIR/gpu-fryer" ] && \
        git clone https://github.com/huggingface/gpu-fryer.git "$BUILD_DIR/gpu-fryer"

    LIBRARY_PATH="$CUDA_HOME_DIR/lib64:${LIBRARY_PATH:-}" \
        in_dir "$BUILD_DIR/gpu-fryer" bash -c "
            cargo build --release
            cp target/release/gpu-fryer .
        " 2>&1 | tee -a "$LOG_FILE"
}

build_gpu_burn() {
    local bin="$BUILD_DIR/gpu-burn/gpu-burn"
    [ -f "$bin" ] && { log "  gpu-burn already built."; return 0; }

    [ ! -d "$BUILD_DIR/gpu-burn" ] && \
        git clone https://github.com/wilicc/gpu-burn.git "$BUILD_DIR/gpu-burn"

    # COMPUTE must be "X.Y" — Makefile does -arch=compute_$(subst .,,${COMPUTE})
    local compute_cap
    compute_cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader \
        | tr -d '\r' | sort -u | head -1)

    in_dir "$BUILD_DIR/gpu-burn" bash -c "
        make clean 2>/dev/null || true
        make -j$(nproc) COMPUTE='$compute_cap' CUDAPATH='$CUDA_HOME_DIR'
    " 2>&1 | tee -a "$LOG_FILE"
}

run_pytorch_stress() {
    local script="$BUILD_DIR/_gpu_stress.py"
    cat > "$script" << PYEOF
import torch, time, sys

DURATION = ${BURN_DURATION}
SIZE = 8192
gpus = list(range(torch.cuda.device_count()))
if not gpus:
    print("ERROR: No CUDA GPUs found"); sys.exit(1)

print(f"Stressing {len(gpus)} GPU(s) for {DURATION}s with {SIZE}x{SIZE} BF16 GEMM...")
matrices = [
    (torch.randn(SIZE, SIZE, dtype=torch.bfloat16, device=f"cuda:{g}"),
     torch.randn(SIZE, SIZE, dtype=torch.bfloat16, device=f"cuda:{g}"))
    for g in gpus
]
start = time.time()
iters = 0
while time.time() - start < DURATION:
    for g, (a, b) in enumerate(matrices):
        with torch.cuda.device(g):
            torch.mm(a, b)
    for g in gpus:
        torch.cuda.synchronize(g)
    iters += 1
    if iters % 50 == 0:
        print(f"  {time.time()-start:.0f}s, {iters} iterations")
print(f"Stress complete: {iters} iterations — no errors.")
PYEOF
    local rc=0
    python3 "$script" 2>&1 | tee -a "$LOG_FILE" || rc=$?
    rm -f "$script"
    return $rc
}

# Thresholds for thermal flagging during burn
readonly TEMP_WARN=87      # °C — flag as potential issue
readonly FAN_WARN=100      # % — flag as maxed out

# run_burn_monitor <burn_pid>
# Polls nvidia-smi every 5s while the burn PID is alive.
# Tracks per-GPU peak temp, peak fan, throttle events.
# Writes a formatted summary and sets BURN_THERMAL_RC=1 if any threshold crossed.
BURN_THERMAL_RC=0
run_burn_monitor() {
    local burn_pid="$1"
    local sample_interval=5
    local telemetry_file="$BUILD_DIR/_burn_telemetry.csv"

    # Header for the live telemetry log
    log ""
    log "  Thermal monitor (sample every ${sample_interval}s):"
    printf "  %-8s %-4s %-6s %-8s %-7s %-8s %s\n" \
        "Elapsed" "GPU" "Temp°C" "Power W" "Fan %" "SM MHz" "Throttle" \
        | tee -a "$LOG_FILE"

    # Per-GPU tracking arrays (indexed by GPU index)
    declare -A peak_temp peak_fan peak_power throttle_seen
    local gpu_idx
    for gpu_idx in $(nvidia-smi --query-gpu=index --format=csv,noheader | tr -d '\r'); do
        peak_temp[$gpu_idx]=0
        peak_fan[$gpu_idx]=0
        peak_power[$gpu_idx]=0
        throttle_seen[$gpu_idx]="None"
    done

    local start_time
    start_time=$(date +%s)

    while kill -0 "$burn_pid" 2>/dev/null; do
        local now elapsed
        now=$(date +%s)
        elapsed=$(( now - start_time ))

        while IFS=, read -r gpu_idx temp power fan clk_sm throttle; do
            gpu_idx=$(echo "$gpu_idx" | xargs)
            temp=$(echo "$temp"       | xargs)
            power=$(echo "$power"     | xargs)
            fan=$(echo "$fan"         | xargs)
            clk_sm=$(echo "$clk_sm"   | xargs)
            throttle=$(echo "$throttle" | xargs)
            local throttle_decoded
            throttle_decoded=$(decode_throttle "$throttle")

            printf "  %-8s %-4s %-6s %-8s %-7s %-8s %s\n" \
                "${elapsed}s" "$gpu_idx" "$temp" "$power" "$fan" "$clk_sm" "$throttle_decoded" \
                | tee -a "$LOG_FILE"

            # Track peaks — strip units (°C, W, %) for numeric comparison
            local temp_val power_val fan_val
            temp_val="${temp//[^0-9]/}"
            power_val="${power//[^0-9.]/}"
            fan_val="${fan//[^0-9]/}"

            if [ -n "$temp_val" ] && [ "$temp_val" -gt "${peak_temp[$gpu_idx]:-0}" ] 2>/dev/null; then
                peak_temp[$gpu_idx]=$temp_val
            fi
            if [ -n "$fan_val" ] && [ "$fan_val" -gt "${peak_fan[$gpu_idx]:-0}" ] 2>/dev/null; then
                peak_fan[$gpu_idx]=$fan_val
            fi
            if [ "$throttle_decoded" != "Not Active" ] && [ "$throttle_decoded" != "unknown" ]; then
                throttle_seen[$gpu_idx]="$throttle_decoded"
            fi
        done < <(nvidia-smi \
            --query-gpu=index,temperature.gpu,power.draw,fan.speed,clocks.sm,clocks_throttle_reasons.active \
            --format=csv,noheader | tr -d '\r')

        sleep "$sample_interval"
    done

    # Print per-GPU peak summary
    log ""
    log "  ── Burn thermal summary ──────────────────────────────────────────"
    printf "  %-4s %-25s %8s %8s %s\n" \
        "GPU" "Name" "PeakTemp" "PeakFan" "Issues" | tee -a "$LOG_FILE"

    local gpu_name issues
    while IFS=, read -r gpu_idx gpu_name; do
        gpu_idx=$(echo "$gpu_idx"   | xargs)
        gpu_name=$(echo "$gpu_name" | xargs)
        issues=""

        local pt="${peak_temp[$gpu_idx]:-0}"
        local pf="${peak_fan[$gpu_idx]:-0}"
        local ts="${throttle_seen[$gpu_idx]:-None}"

        [ "$pt" -ge "$TEMP_WARN" ] 2>/dev/null && \
            issues+="TEMP ${pt}°C >= ${TEMP_WARN}°C (check thermal paste/airflow)  "
        [ "$pf" -ge "$FAN_WARN" ] 2>/dev/null && \
            issues+="FAN at ${pf}% (cooling at limit)  "
        [ "$ts" != "None" ] && \
            issues+="THROTTLE: $ts"

        [ -z "$issues" ] && issues="OK"

        printf "  %-4s %-25s %8s %8s %s\n" \
            "$gpu_idx" "$gpu_name" "${pt}°C" "${pf}%" "$issues" | tee -a "$LOG_FILE"

        # Set thermal RC if any GPU crossed a threshold
        if [[ "$issues" != "OK" ]]; then
            BURN_THERMAL_RC=1
        fi
    done < <(nvidia-smi --query-gpu=index,name --format=csv,noheader | tr -d '\r')

    log "  ─────────────────────────────────────────────────────────────────"
    if [ "$BURN_THERMAL_RC" -eq 1 ]; then
        log "  WARNING: One or more GPUs exceeded thermal thresholds during burn."
        log "           Temp flag: >= ${TEMP_WARN}°C   Fan flag: >= ${FAN_WARN}%"
        log "           System passed compute test but cooling should be investigated."
    else
        log "  All GPUs within thermal limits during burn."
    fi
    log ""
}

test_stress() {
    local label="Sustained Compute Stress"
    local duration_min burn_rc=0
    duration_min=$(echo "scale=1; $BURN_DURATION / 60" | bc)
    BURN_THERMAL_RC=0

    # Launch the burn tool in the background, monitor thermals alongside it,
    # then wait for it to finish and collect both the compute RC and thermal RC.

    if build_gpu_fryer && [ -f "$BUILD_DIR/gpu-fryer/gpu-fryer" ]; then
        log "  Using gpu-fryer (BF16, ${duration_min} min)"
        RESULTS_STRESS_LABEL="$label / gpu-fryer"
        "$BUILD_DIR/gpu-fryer/gpu-fryer" --use-bf16 "$BURN_DURATION" \
            2>&1 | tee -a "$LOG_FILE" &
        local burn_pid=$!

    elif build_gpu_burn && [ -f "$BUILD_DIR/gpu-burn/gpu-burn" ]; then
        log "  Using gpu-burn (FP64, ${duration_min} min)"
        RESULTS_STRESS_LABEL="$label / gpu-burn"
        "$BUILD_DIR/gpu-burn/gpu-burn" -d -tc "$BURN_DURATION" \
            2>&1 | tee -a "$LOG_FILE" &
        local burn_pid=$!

    else
        log "  gpu-fryer and gpu-burn unavailable — using PyTorch cuBLAS fallback."
        RESULTS_STRESS_LABEL="$label / PyTorch fallback"
        run_pytorch_stress 2>&1 | tee -a "$LOG_FILE" &
        local burn_pid=$!
    fi

    # Run thermal monitor alongside the burn; it exits when burn_pid dies
    run_burn_monitor "$burn_pid"

    # Collect burn tool exit code
    wait "$burn_pid" 2>/dev/null || burn_rc=$?

    # Fail if compute failed OR if thermal thresholds were crossed
    if [ "$burn_rc" -ne 0 ]; then
        log "  ERROR: Burn tool exited with code $burn_rc"
        return 1
    fi
    if [ "$BURN_THERMAL_RC" -ne 0 ]; then
        log "  Compute: PASS  |  Thermals: WARNING (see summary above)"
        return 1   # flag as failure so it shows in summary and gets attention
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

print_summary() {
    log ""
    log "========================================"
    log "TEST SUMMARY"
    log "========================================"
    log "  Host     : $(hostname -f 2>/dev/null || hostname)"
    log "  IP(s)    : $(hostname -I 2>/dev/null | tr ' ' ',' | sed 's/,$//' || echo 'unknown')"
    log "  GPUs     : $GPU_NAMES"
    log "  Arch(es) : $CUDA_ARCH_LIST"
    log "  CUDA     : $CUDA_VERSION"
    log "  Log file : $LOG_FILE"
    log ""

    local pass_count=${#RESULTS_PASS[@]}
    local fail_count=${#RESULTS_FAIL[@]}
    local skip_count=${#RESULTS_SKIP[@]}

    if [ "$pass_count" -gt 0 ]; then
        log "  PASSED ($pass_count):"
        for r in "${RESULTS_PASS[@]}"; do log "    ✓  $r"; done
        log ""
    fi
    if [ "$skip_count" -gt 0 ]; then
        log "  SKIPPED ($skip_count):"
        for r in "${RESULTS_SKIP[@]}"; do log "    -  $r"; done
        log ""
    fi
    if [ "$fail_count" -gt 0 ]; then
        log "  FAILED ($fail_count):"
        for r in "${RESULTS_FAIL[@]}"; do log "    ✗  $r"; done
        log ""
        log "========================================"
        log "  RESULT: $fail_count test(s) FAILED"
        log "========================================"
        return 1
    else
        log "========================================"
        log "  RESULT: ALL $pass_count TESTS PASSED"
        log "========================================"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: $(basename "$0") [test...] [--burn-duration <s>] [--clean] [--list] [--help]

Available tests (run in this order if none specified):
  preflight     Idle thermal baseline, persistence mode, driver state
  ecc           ECC error check (DC GPUs: fail on errors; GeForce: skip gracefully)
  pcie          PCIe link width/gen check — detects silent link degradation
  clocks        Clock speed under 30s load — detects thermal/power throttling
  nccl          NCCL all-reduce communication test
  cuda-samples  deviceQuery + p2pBandwidthLatencyTest
  nvbandwidth   Host<->device and device<->device memory bandwidth
  dcgm          DCGM diagnostics (skipped if dcgmi not installed)
  pytorch       PyTorch multi-GPU DDP benchmark
  memtest       cuda_memtest VRAM integrity (10 passes per GPU)
  stress        Sustained compute stress: gpu-fryer / gpu-burn / PyTorch

Options:
  --burn-duration <seconds>  Duration for stress test (default: 300 = 5 min)
  --clean                    Delete all build artifacts and exit
  --list                     List available test names and exit
  --help, -h                 Show this help

Examples:
  ./fulltest.sh                              # run all tests
  ./fulltest.sh preflight ecc pcie clocks    # hardware health checks only
  ./fulltest.sh nccl pytorch                 # communication + framework only
  ./fulltest.sh stress --burn-duration 3600  # 1 hour stress test
  ./fulltest.sh --clean                      # wipe build/ and exit
  ./fulltest.sh --clean nccl                 # clean then run nccl
EOF
}

ALL_TESTS=(preflight ecc pcie clocks nccl cuda-samples nvbandwidth dcgm pytorch memtest stress)
SELECTED_TESTS=()

# Two-pass parse: first pass handles --help/--list which exit immediately,
# second pass (index-based) handles --burn-duration which needs a lookahead value.
for arg in "$@"; do
    case "$arg" in
        --help|-h) usage; exit 0 ;;
        --list) echo "Available tests: ${ALL_TESTS[*]}"; exit 0 ;;
    esac
done

args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
    arg="${args[$i]}"
    case "$arg" in
        --help|-h)    usage; exit 0 ;;
        --list)       echo "Available tests: ${ALL_TESTS[*]}"; exit 0 ;;
        --clean)      CLEAN_BUILD=true ;;
        --burn-duration)
            i=$((i + 1))
            val="${args[$i]:-}"
            if [[ ! "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ]; then
                echo "ERROR: --burn-duration requires a positive integer (seconds)" >&2
                exit 1
            fi
            BURN_DURATION="$val"
            ;;
        preflight|ecc|pcie|clocks|nccl|cuda-samples|nvbandwidth|dcgm|pytorch|memtest|stress)
            SELECTED_TESTS+=("$arg") ;;
        *)
            echo "Unknown argument: $arg" >&2; usage >&2; exit 1 ;;
    esac
    i=$((i + 1))
done

# Handle --clean
if [ "$CLEAN_BUILD" = true ]; then
    echo "Cleaning build directory: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    echo "Done."
    [ "${#SELECTED_TESTS[@]}" -eq 0 ] && exit 0
    echo "Proceeding with tests: ${SELECTED_TESTS[*]}"
    echo ""
fi

[ "${#SELECTED_TESTS[@]}" -eq 0 ] && SELECTED_TESTS=("${ALL_TESTS[@]}")

# ─── Run ─────────────────────────────────────────────────────────────────────

detect_system

for test in "${SELECTED_TESTS[@]}"; do
    case "$test" in
        preflight)    run_test "Preflight (Thermal Baseline / Persistence / Driver)"  test_preflight   ;;
        ecc)          run_test "ECC Error Check"                                       test_ecc         ;;
        pcie)         run_test "PCIe Link Width / Generation"                          test_pcie        ;;
        clocks)       run_test "Clock Speed Under Load"                                test_clocks      ;;
        nccl)         run_test "NCCL All-Reduce Test"                                  test_nccl        ;;
        cuda-samples) run_test "CUDA Samples (deviceQuery / p2pBandwidthLatencyTest)"  test_cuda_samples ;;
        nvbandwidth)  run_test "NVBandwidth (GPU Memory Bandwidth)"                    test_nvbandwidth ;;
        dcgm)
            if command -v dcgmi &>/dev/null; then
                run_test "DCGM Diagnostics" test_dcgm
            else
                skip_test "DCGM Diagnostics" "dcgmi not found — install DCGM if needed (https://developer.nvidia.com/dcgm)"
            fi
            ;;
        pytorch)      run_test "PyTorch Multi-GPU Benchmark"                           test_pytorch     ;;
        memtest)      run_test "cuda_memtest (GPU Memory Stress)"                      test_memtest     ;;
        stress)
            local stress_min
            stress_min=$(echo "scale=1; $BURN_DURATION / 60" | bc)
            run_test "$RESULTS_STRESS_LABEL (${stress_min} min)"                       test_stress
            ;;
    esac
done

print_summary
