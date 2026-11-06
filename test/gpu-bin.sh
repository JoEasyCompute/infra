#!/usr/bin/env bash
# =============================================================================
# gpu-bin.sh — unattended GPU power-limit ladder + binning across power cycles
#
# For every NVIDIA GPU in the node, climbs the power limit from the model's
# grade B floor up through its band edges, running fulltest.sh on each GPU
# in parallel (one single-GPU process per card). A card that fails or falls
# off the bus is recorded with its ceiling (last passing step) and leaves the
# round; the others keep climbing. When a round leaves the driver or any card
# unusable, the node cold power-cycles itself through its own BMC
# (ipmitool -I open chassis power cycle) and a systemd resume service carries
# on after boot. When every card has a ceiling, all cards are burned together
# at their ceilings to confirm, then each card is banded and graded.
#
# Cards are tracked by UUID (indices can change after a drop or reboot).
# Each run gets an ID (yyyy-mm-dd-hh-mm) and its own folder per server:
#   $GPU_BIN_DIR/<server-serial>/<run-id>/{state,logs,results_<server>_<run>.csv}
# plus results_<server>_<run>.txt, the same results as one readable block per card,
# and every finished row is appended to $GPU_BIN_DIR/all-results.csv.
# The server is identified by its DMI system serial (then board serial,
# then BMC MAC), so one USB stick can test many servers.
#
# Booted from USB / live media, per-card power limits are NOT applied (they
# would land on the stick, not the server's OS); they are written to
# apply-on-host_<server>_<run>.sh to run on the server's own OS.
#
# Usage:
#   sudo ./gpu-bin.sh                   start (or continue) a binning run
#   sudo ./gpu-bin.sh --resume          used by the boot service
#   ./gpu-bin.sh --status               show per-card progress
#   ./gpu-bin.sh --dry-run              show discovered cards and ladders only
#   sudo ./gpu-bin.sh --reset           discard state and remove resume service
#
# Options:
#   --burn-duration S     stress seconds per ladder step        (default 600)
#   --confirm-duration S  all-GPU confirm burn seconds          (default 1800)
#   --max-cycles N        max power cycles before giving up     (default 8)
#   --step-timeout S      kill a worker after S seconds         (default burn+1200)
#   --force               run even if GPU compute processes exist
#   --expect-gpus N       GPUs fitted in the server; each one the driver
#                         cannot see is reported as a "not detected" row
#   --apply-limits        always apply per-card limits at finish
#   --record-limits       never apply them; write apply-on-host script only
#                         (a card needs its own limit when its ceiling is below
#                          the fleet preset in gpu-power-limit.sh)
# On finish or halt every card is set back to its own default power limit,
# then nvidia-runtime-policy.service (if installed) re-applies the presets.
#                         (default: record only when booted from USB/live media)
#
# Environment overrides (used by test/gpu-bin-test.sh):
#   GPU_BIN_DIR (default /opt/gpu-bin)   FULLTEST (default <script dir>/fulltest.sh)
#   NVIDIA_SMI IPMITOOL JOURNALCTL SYSTEMCTL  POLL_SECONDS  STAGGER_SECONDS
#   GPU_POWER_LIMIT (default ../install/gpu-power-limit.sh) — per-card limits at finish
#   DMIDECODE  SYSFS_PCI  GPU_BIN_SERVER_ID  GPU_BIN_MEDIA=usb|host  GPU_BIN_ALLOW_VOLATILE=1
#   GPU_BIN_NO_UNIT=1  (do not install the systemd resume unit)
# =============================================================================
set -uo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

GPU_BIN_DIR="${GPU_BIN_DIR:-/opt/gpu-bin}"
FULLTEST="${FULLTEST:-$SCRIPT_DIR/fulltest.sh}"
NVIDIA_SMI="${NVIDIA_SMI:-nvidia-smi}"
IPMITOOL="${IPMITOOL:-ipmitool}"
JOURNALCTL="${JOURNALCTL:-journalctl}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
POLL_SECONDS="${POLL_SECONDS:-15}"
STAGGER_SECONDS="${STAGGER_SECONDS:-2}"
GPU_POWER_LIMIT="${GPU_POWER_LIMIT:-$(readlink -f "$SCRIPT_DIR/../install/gpu-power-limit.sh" 2>/dev/null || echo /opt/provision/gpu-power-limit.sh)}"

DMIDECODE="${DMIDECODE:-dmidecode}"
SYSFS_PCI="${SYSFS_PCI:-/sys/bus/pci/devices}"

# Per-run paths are set by set_run_paths once the server and run are known
SERVER_ID=""; SERVER_DIR=""; ACTIVE=""; RUN_ID=""; RUN_DIR=""
STATE_DIR=""; CARDS=""; RUN=""; RESULT_CSV=""
LOG_DIR="$GPU_BIN_DIR"
ALL_RESULTS="$GPU_BIN_DIR/all-results.csv"
APPLY_LIMITS=auto
EXPECT_GPUS=""
UNIT_NAME="gpu-bin-resume.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
PAUSED_UNITS="gpu-watchdog.timer gpu-watchdog.service"

# cards.tsv fields (tab separated):
#  1 uuid 2 serial 3 bus 4 model 5 default_pl 6 steps(comma) 7 step_idx
#  8 last_pass 9 first_fail 10 status 11 failed_tests 12 note 13 physical_slot
# 14 solo_retested (1 once a card has had its solo re-test)
# status: climbing | isolate | done | dropped | failed-floor | memfail | connector | missing
export CUDA_DEVICE_ORDER=PCI_BUS_ID   # make CUDA indices match nvidia-smi

BURN_DURATION=600
CONFIRM_DURATION=1800
MAX_CYCLES=8
STEP_TIMEOUT=""
FORCE=0
MODE=run

log() { echo "$(date '+%F %T') [gpu-bin] $*" | tee -a "$LOG_DIR/gpu-bin.log" >&2; }
die() { log "ERROR: $*"; exit 1; }

set_run_paths() {
    RUN_ID="$1"; RUN_DIR="$SERVER_DIR/$RUN_ID"
    STATE_DIR="$RUN_DIR/state"; LOG_DIR="$RUN_DIR/logs"
    CARDS="$STATE_DIR/cards.tsv"; RUN="$STATE_DIR/run.env"
    RESULT_CSV="$RUN_DIR/results_${SERVER_ID}_${RUN_ID}.csv"
    RESULT_TXT="$RUN_DIR/results_${SERVER_ID}_${RUN_ID}.txt"
    mkdir -p "$STATE_DIR" "$LOG_DIR"
}

# ─── Server identity, media, slots ───────────────────────────────────────────
server_id() {
    if [ -n "${GPU_BIN_SERVER_ID:-}" ]; then echo "$GPU_BIN_SERVER_ID" | tr -c 'A-Za-z0-9._\n-' '_'; return; fi
    local v="" k c mac
    for k in system-serial-number baseboard-serial-number; do
        c="$("$DMIDECODE" -s "$k" 2>/dev/null | head -1 | xargs 2>/dev/null)"
        case "$c" in
            ""|*"To Be Filled"*|*"Default string"*|*"Not Specified"*|*"Not Applicable"*|*"Serial Number"*|0123456789|N/A|None) continue ;;
        esac
        v="$c"; break
    done
    if [ -z "$v" ]; then
        mac="$("$IPMITOOL" -I open lan print 2>/dev/null | awk -F': *' '/^MAC Address/{print $2; exit}' | tr -d ':')"
        if [ -n "$mac" ]; then v="bmc-$mac"; else v="host-$(hostname)"; fi
    fi
    echo "$v" | tr -c 'A-Za-z0-9._\n-' '_'
}

# True when this OS runs from USB/removable or live (casper) media
running_from_removable() {
    case "${GPU_BIN_MEDIA:-auto}" in usb) return 0 ;; host) return 1 ;; esac
    grep -qwE 'boot=(casper|live)' /proc/cmdline 2>/dev/null && return 0
    local src; src="$(findmnt -no SOURCE / 2>/dev/null)"
    [ -n "$src" ] || return 1
    lsblk -sno TRAN,RM "$src" 2>/dev/null | awk '$1=="usb" || $NF=="1"{f=1} END{exit !f}'
}

SLOT_MAP=""
build_slot_map() {   # SMBIOS "bus address <TAB> slot designation"
    SLOT_MAP="$("$DMIDECODE" -t slot 2>/dev/null | awk '
        BEGIN { RS="\n\n"; FS="\n" }
        /System Slot Information/ {
            slot=""; bus=""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /Designation:/) { sub(/^[[:space:]]*Designation:[[:space:]]*/, "", $i); slot=$i }
                else if ($i ~ /Bus Address:/) { sub(/^[[:space:]]*Bus Address:[[:space:]]*/, "", $i); bus=$i }
            }
            gsub(/[[:space:]]/, "", bus)
            if (bus != "" && slot != "") printf "%s\t%s\n", tolower(bus), slot
        }')"
}
# physical_slot <nvidia-smi bus id> -> slot label from SMBIOS or lspci, walking up through risers/switches
physical_slot() {
    local bdf path p s
    bdf="$(echo "$1" | tr 'A-F' 'a-f' | sed -E 's/^0*([0-9a-f]{4}:)/\1/')"
    path="$(readlink -f "$SYSFS_PCI/$bdf" 2>/dev/null)"
    [ -n "$path" ] && [ -e "$path" ] || return 0
    while [ -n "$path" ] && [ "$path" != / ]; do
        p="$(basename "$path")"
        if [[ "$p" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]]; then
            s="$(printf '%s\n' "$SLOT_MAP" | awk -F'\t' -v b="$p" '$1==b{print $2; exit}')"
            [ -n "$s" ] || s="$(lspci -s "$p" -vv 2>/dev/null | sed -n 's/.*Physical Slot:[[:space:]]*//p' | head -1)"
            [ -n "$s" ] && { echo "$s"; return 0; }
        fi
        path="$(dirname "$path")"
    done
}

# ─── Model band tables ───────────────────────────────────────────────────────
# Edges are ladder steps (W). The top step is always the card's own default.
model_key() {
    case "$1" in
        *5090*) echo 5090 ;;
        *4090*) echo 4090 ;;
        *A4000*) echo A4000 ;;
        *) echo unknown ;;
    esac
}
model_edges() {
    case "$1" in
        5090) echo "450 500 540 550 575 600" ;;
        4090) echo "300 450" ;;
        A4000) echo "100 140" ;;
        *) echo "" ;;
    esac
}
# band <model_key> <ceiling_w|empty> <default_w>  -> "Band|Grade"
band_for() {
    local key="$1" c="$2" def="$3"
    if [ -z "$c" ]; then echo "Fail|C"; return; fi
    case "$key" in
        5090)
            if   [ "$c" -ge "$def" ]; then echo "Default|A"
            elif [ "$c" -ge 550 ]; then echo "Slightly degraded|A"
            elif [ "$c" -ge 540 ]; then echo "Acceptable|A"
            elif [ "$c" -ge 500 ]; then echo "Below threshold|B"
            elif [ "$c" -ge 450 ]; then echo "Grade B|B"
            else echo "Fail|C"; fi ;;
        4090)
            if   [ "$c" -ge "$def" ]; then echo "Default|A"
            elif [ "$c" -ge 300 ]; then echo "Grade B|B"
            else echo "Fail|C"; fi ;;
        A4000)
            if   [ "$c" -ge "$def" ]; then echo "Default|A"
            elif [ "$c" -ge 100 ]; then echo "Grade B|B"
            else echo "Fail|C"; fi ;;
        *)  echo "No bands set|" ;;
    esac
}
# steps <model_key> <default> <min> <max> -> comma list ending at default
build_steps() {
    local key="$1" def="$2" min="$3" max="$4" out="" e
    for e in $(model_edges "$key"); do
        [ "$e" -lt "$def" ] || continue
        [ "$e" -ge "$min" ] && [ "$e" -le "$max" ] || continue
        out="${out:+$out,}$e"
    done
    echo "${out:+$out,}$def"
}

# ─── State helpers ───────────────────────────────────────────────────────────
run_get() { [ -f "$RUN" ] && awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$RUN"; }
run_set() {
    local k="$1" v="$2" tmp
    tmp="$(mktemp "$STATE_DIR/.run.XXXX")"
    [ -f "$RUN" ] && grep -v "^$k=" "$RUN" > "$tmp"
    echo "$k=$v" >> "$tmp"; mv "$tmp" "$RUN"
}
card_field() { awk -F'\t' -v u="$1" -v f="$2" '$1==u{print $f}' "$CARDS"; }
card_set() {   # card_set uuid field value
    local tmp; tmp="$(mktemp "$STATE_DIR/.cards.XXXX")"
    awk -F'\t' -v OFS='\t' -v u="$1" -v f="$2" -v v="$3" '$1==u{$f=v}1' "$CARDS" > "$tmp" && mv "$tmp" "$CARDS"
}
# note_add <uuid> <text>: keep a "passed alone" note, otherwise replace
note_add() {
    local prev; prev="$(card_field "$1" 12)"
    case "$prev" in *"passed alone"*) card_set "$1" 12 "$prev; $2" ;; *) card_set "$1" 12 "$2" ;; esac
}
cards_with_status() { awk -F'\t' -v s="$1" '$10==s{print $1}' "$CARDS"; }
step_at() { echo "$1" | cut -d, -f$(( $2 + 1 )); }
step_count() { echo "$1" | awk -F, '{print NF}'; }

smi() { timeout 20 "$NVIDIA_SMI" "$@"; }
# current index of a UUID, empty if the GPU is not visible
index_of() { smi --query-gpu=index,uuid --format=csv,noheader 2>/dev/null | awk -F', *' -v u="$1" '$2==u{print $1}'; }

wait_for_driver() {
    local i
    for i in $(seq 1 60); do
        smi -L >/dev/null 2>&1 && return 0
        sleep 5
    done
    return 1
}

# ─── Discovery ───────────────────────────────────────────────────────────────
discover() {
    local tmp="$STATE_DIR/.cards.new" uuid serial bus name def min max key steps slot
    : > "$tmp"
    build_slot_map
    smi --query-gpu=uuid,serial,pci.bus_id,name,power.default_limit,power.min_limit,power.max_limit \
        --format=csv,noheader,nounits > "$STATE_DIR/.query" || die "nvidia-smi query failed"
    while IFS=',' read -r uuid serial bus name def min max; do
        uuid="$(echo "$uuid" | xargs)"; serial="$(echo "$serial" | xargs)"; bus="$(echo "$bus" | xargs)"
        name="$(echo "$name" | xargs)"
        def="$(printf '%.0f' "$(echo "$def" | xargs)")"; min="$(printf '%.0f' "$(echo "$min" | xargs)")"
        max="$(printf '%.0f' "$(echo "$max" | xargs)")"
        key="$(model_key "$name")"
        steps="$(build_steps "$key" "$def" "$min" "$max")"
        slot="$(physical_slot "$bus")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t0\t\t\tclimbing\t\t\t%s\t\n' \
            "$uuid" "$serial" "$bus" "$name" "$def" "$steps" "$slot" >> "$tmp"
    done < "$STATE_DIR/.query"
    [ -s "$tmp" ] || die "no NVIDIA GPUs found"
    mv "$tmp" "$CARDS"
}

print_status() {
    echo "Server: $SERVER_ID   (runs under $SERVER_DIR)"
    if [ -n "$RUN_ID" ] && [ -f "$CARDS" ]; then
        echo "Active run: $RUN_ID   phase: $(run_get phase)   power cycles: $(run_get cycles)/$(run_get max_cycles)"
        printf '%-14s %-16s %-16s %-14s %-22s %-8s %-9s %-12s %s\n' UUID SERIAL BUS SLOT MODEL CEILING FIRSTFAIL STATUS NOTE
        awk -F'\t' '{printf "%-14s %-16s %-16s %-14s %-22s %-8s %-9s %-12s %s\n", substr($1,1,14), $2, $3, $13, $4, $8, $9, $10, $12}' "$CARDS"
    else
        echo "Active run: none"
    fi
    local d
    for d in "$SERVER_DIR"/*/; do
        [ -f "$d/state/run.env" ] || continue
        echo "  run $(basename "$d"): $(awk -F= '$1=="phase"{print $2}' "$d/state/run.env")$(ls "$d"/results_*.txt >/dev/null 2>&1 && echo "  -> $(ls "$d"/results_*.txt)")"
    done
    if [ -z "$RUN_ID" ]; then
        local latest
        latest="$(ls -t "$SERVER_DIR"/*/results_*.txt 2>/dev/null | head -1)"
        [ -n "$latest" ] && { echo; echo "Latest results:"; echo; cat "$latest"; }
    fi
    return 0
}

# ─── Resume service ──────────────────────────────────────────────────────────
install_unit() {
    [ "${GPU_BIN_NO_UNIT:-0}" = 1 ] && return 0
    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Resume gpu-bin.sh GPU binning after power cycle
After=multi-user.target systemd-udev-settle.service nvidia-persistenced.service nvidia-runtime-policy.service
Wants=systemd-udev-settle.service

[Service]
Type=simple
ExecStart=$SCRIPT_PATH --resume
Environment=GPU_BIN_DIR=$GPU_BIN_DIR FULLTEST=$FULLTEST GPU_POWER_LIMIT=$GPU_POWER_LIMIT
TimeoutStartSec=infinity
StandardOutput=append:$LOG_DIR/gpu-bin.console.log
StandardError=append:$LOG_DIR/gpu-bin.console.log

[Install]
WantedBy=multi-user.target
EOF
    "$SYSTEMCTL" daemon-reload
    "$SYSTEMCTL" enable "$UNIT_NAME" >/dev/null 2>&1
}
remove_unit() {
    [ "${GPU_BIN_NO_UNIT:-0}" = 1 ] && return 0
    if ls "$GPU_BIN_DIR"/*/active-run >/dev/null 2>&1; then
        log "Resume service kept: another server on this media still has an active run"; return 0
    fi
    "$SYSTEMCTL" disable "$UNIT_NAME" >/dev/null 2>&1 || true
    rm -f "$UNIT_PATH"; "$SYSTEMCTL" daemon-reload || true
}
pause_units()   { local u; for u in $PAUSED_UNITS; do "$SYSTEMCTL" stop "$u" >/dev/null 2>&1 || true; done; }
restore_units() { local u; for u in $PAUSED_UNITS; do "$SYSTEMCTL" start "$u" >/dev/null 2>&1 || true; done; }

# Fleet preset (power-saving floor) for a model, read from gpu-power-limit.sh;
# falls back to the card's own default when the model has no preset.
fleet_preset() {   # fleet_preset <model name> <default W>
    local model="$1" def="$2" names watts i
    if [ -r "$GPU_POWER_LIMIT" ]; then
        read -r -a names <<< "$(sed -n 's/^GPU_PRESET_MODELS=(\(.*\))/\1/p' "$GPU_POWER_LIMIT" | tr -d '"')"
        read -r -a watts <<< "$(sed -n 's/^GPU_PRESET_WATTS=(\(.*\))/\1/p' "$GPU_POWER_LIMIT")"
        for i in "${!names[@]}"; do
            if [[ "$model" == *"${names[$i]}"* ]] && [ -n "${watts[$i]:-}" ]; then echo "${watts[$i]}"; return; fi
        done
    fi
    echo "$def"
}

# Put every visible card back to its own default limit, then let the node's
# power policy (if installed) re-apply its presets.
reset_limits() {
    local uuid idx def
    [ -f "$CARDS" ] || return 0
    for uuid in $(cut -f1 "$CARDS"); do
        idx="$(index_of "$uuid")"; def="$(card_field "$uuid" 5)"
        [ -n "$idx" ] && [ -n "$def" ] || continue
        smi -i "$idx" -pl "$def" >/dev/null 2>&1 && echo "$idx:$def" >> "$STATE_DIR/.reset" \
            || log "WARNING: could not reset GPU $idx ($uuid) to ${def}W"
    done
    if "$SYSTEMCTL" cat nvidia-runtime-policy.service >/dev/null 2>&1; then
        "$SYSTEMCTL" restart nvidia-runtime-policy.service >/dev/null 2>&1 || true
        log "Power limits reset to card defaults, then nvidia-runtime-policy presets re-applied"
    else
        log "Power limits reset to card defaults"
    fi
}

power_cycle() {
    local cycles; cycles=$(( $(run_get cycles) + 1 ))
    if [ "$cycles" -gt "$MAX_CYCLES" ]; then
        run_set halted_from "$(run_get phase)"; run_set phase halted
        log "HALT: power-cycle limit ($MAX_CYCLES) reached. Inspect the node; resume with --resume after fixing."
        reset_limits; remove_unit; restore_units; exit 2
    fi
    run_set cycles "$cycles"
    log "Cold power cycle $cycles/$MAX_CYCLES via BMC (in-band): $1"
    sync
    "$IPMITOOL" -I open chassis power cycle || die "ipmitool power cycle failed — power-cycle the node manually; the run resumes on boot"
    sleep 300   # the cycle normally kills us; if not, give it time
    die "power cycle was accepted but the node is still up"
}

# ─── Worker ──────────────────────────────────────────────────────────────────
# run_worker <uuid> <index> <watts> <tests...>  (background) -> writes .rc
run_worker() {
    local uuid="$1" idx="$2" watts="$3"; shift 3
    local wlog="$LOG_DIR/${uuid}_${watts}W${WORKER_TAG:+_$WORKER_TAG}.log" rc
    {
        echo "== $(date '+%F %T') uuid=$uuid index=$idx limit=${watts}W tests=$*"
        timeout --kill-after=60 "$STEP_TIMEOUT" "$FULLTEST" --gpu "$idx" "$@" --burn-duration "$BURN_DURATION"
    } >> "$wlog" 2>&1
    rc=$?
    echo "$rc" > "$STATE_DIR/$uuid.rc"
}

xid79_bus_ids() {   # bus ids reported as fallen off since the given epoch
    "$JOURNALCTL" -k --since "@$1" --no-pager 2>/dev/null \
        | grep -Ei 'Xid \(PCI:[^)]*\): 79\b|fallen off the bus' \
        | grep -Eio '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}|[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' | sort -u
}
bus_short() { echo "$1" | sed -E 's/^0*([0-9a-fA-F]{4}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-9]).*/\2:\3/' | tr 'A-F' 'a-f'; }

# ─── One climbing round ──────────────────────────────────────────────────────
climb_round() {
    local start uuid idx steps sidx watts tests pids=() uuids=() need_cycle=0 drops=0 dropped=() d
    start=$(date +%s)
    for uuid in $(cards_with_status climbing); do
        idx="$(index_of "$uuid")"
        if [ -z "$idx" ]; then
            card_set "$uuid" 10 missing; card_set "$uuid" 12 "not visible after boot; inspect slot/riser/power"
            log "Card $uuid is not visible — marked missing"; continue
        fi
        steps="$(card_field "$uuid" 6)"; sidx="$(card_field "$uuid" 7)"
        watts="$(step_at "$steps" "$sidx")"
        if [ "$sidx" -eq 0 ]; then tests="code memtest stress"; else tests="code stress"; fi
        if ! smi -i "$idx" -pl "$watts" >/dev/null 2>&1; then
            card_set "$uuid" 10 dropped; card_set "$uuid" 9 "$watts"; card_set "$uuid" 12 "could not set ${watts}W"
            need_cycle=1; continue
        fi
        rm -f "$STATE_DIR/$uuid.rc"
        log "Step: $(card_field "$uuid" 4) $uuid (index $idx) at ${watts}W: $tests"
        # shellcheck disable=SC2086
        run_worker "$uuid" "$idx" "$watts" $tests &
        pids+=($!); uuids+=("$uuid")
        sleep "$STAGGER_SECONDS"   # distinct fulltest log names, staggered build use
    done
    [ "${#pids[@]}" -gt 0 ] || { [ "$need_cycle" = 1 ] && power_cycle "card could not take its power limit"; return 0; }

    # Wait, watching for fall-off events while workers run
    local alive=1
    while [ "$alive" -gt 0 ]; do
        sleep "$POLL_SECONDS"
        alive=0
        for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done
    done

    local fell; fell="$(xid79_bus_ids "$start")"
    local i rc wl watts_now ft outcomes=() o ou oc ow os oft floor_bad=0 drops_up=0
    for i in "${!uuids[@]}"; do
        uuid="${uuids[$i]}"
        steps="$(card_field "$uuid" 6)"; sidx="$(card_field "$uuid" 7)"
        watts_now="$(step_at "$steps" "$sidx")"
        rc="$(cat "$STATE_DIR/$uuid.rc" 2>/dev/null || echo 255)"
        wl="$LOG_DIR/${uuid}_${watts_now}W.log"
        ft=""
        if echo "$fell" | grep -qi "$(bus_short "$(card_field "$uuid" 3)")" || [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ] \
           || [ -z "$(index_of "$uuid")" ]; then
            oc=drop; need_cycle=1
            if [ "$sidx" -eq 0 ]; then floor_bad=$((floor_bad + 1)); else drops_up=$((drops_up + 1)); fi
            log "DROP: $uuid at ${watts_now}W (last pass: $(card_field "$uuid" 8 | sed 's/^$/none/'))"
        elif [ "$rc" -eq 0 ]; then
            oc=pass
        else
            ft="$(grep -E '\[ FAIL \]' "$wl" | sed -E 's/.*\[ FAIL \] //; s/ \(exit code.*//' | paste -sd ';' -)"
            if echo "$ft" | grep -qi memtest; then
                oc=memfail; [ "$sidx" -eq 0 ] && floor_bad=$((floor_bad + 1))
            elif [ "$sidx" -eq 0 ]; then oc=floorfail; floor_bad=$((floor_bad + 1))
            else oc=fail; fi
            log "FAIL: $uuid at ${watts_now}W ($ft)"
            # a failed CUDA run can leave the card wedged even without Xid 79
            smi -i "$(index_of "$uuid")" -q >/dev/null 2>&1 || need_cycle=1
        fi
        outcomes+=("$uuid|$oc|$watts_now|$sidx|$ft")
    done

    for o in "${outcomes[@]}"; do
        IFS='|' read -r ou oc ow os oft <<< "$o"
        steps="$(card_field "$ou" 6)"
        [ -n "$oft" ] && card_set "$ou" 11 "$oft"
        case "$oc" in
            pass)
                card_set "$ou" 8 "$ow"
                if [ $((os + 1)) -ge "$(step_count "$steps")" ]; then
                    card_set "$ou" 10 done; log "TOP: $ou passed its default ${ow}W"
                else
                    card_set "$ou" 7 $((os + 1)); log "PASS: $ou at ${ow}W"
                fi ;;
            memfail)
                card_set "$ou" 9 "$ow"
                if [ "$os" -eq 0 ] && [ "$floor_bad" -ge 2 ] && [ "$(card_field "$ou" 14)" != 1 ]; then
                    # memtest failing alongside other cards' failures can be collateral
                    # (e.g. a neighbour falling off the bus): re-test alone first
                    card_set "$ou" 10 isolate
                    card_set "$ou" 12 "memtest failed at floor ${ow}W with $((floor_bad - 1)) other card(s) failing — re-testing alone"
                    log "ISOLATE: $ou will be re-tested alone at ${ow}W (memtest)"
                else
                    card_set "$ou" 10 memfail; card_set "$ou" 12 "memtest failed — grade C"
                fi ;;
            fail)
                card_set "$ou" 9 "$ow"; card_set "$ou" 10 done ;;
            drop|floorfail)
                if [ "$oc" = drop ] && [ "$os" -gt 0 ] && [ "$drops_up" -ge 2 ]; then
                    continue   # left climbing at this step: shared-power halt below
                fi
                card_set "$ou" 9 "$ow"
                if [ "$os" -eq 0 ] && [ "$floor_bad" -ge 2 ] && [ "$(card_field "$ou" 14)" != 1 ]; then
                    # Several cards failing the floor together may be one shared event:
                    # re-test each alone before grading (ladder rung 2).
                    card_set "$ou" 10 isolate
                    card_set "$ou" 12 "$([ "$oc" = drop ] && echo dropped || echo failed) at floor ${ow}W with $((floor_bad - 1)) other card(s) — re-testing alone"
                    log "ISOLATE: $ou will be re-tested alone at ${ow}W"
                elif [ "$oc" = drop ]; then
                    card_set "$ou" 10 dropped
                    note_add "$ou" "fell off bus / hung at ${ow}W"
                else
                    card_set "$ou" 10 failed-floor; card_set "$ou" 12 "failed at floor ${ow}W"
                fi ;;
        esac
    done
    # Cards that already passed a lower step dropping together point at shared power.
    if [ "$drops_up" -ge 2 ]; then
        for o in "${outcomes[@]}"; do
            IFS='|' read -r ou oc ow os oft <<< "$o"
            [ "$oc" = drop ] && [ "$os" -gt 0 ] && card_set "$ou" 12 "dropped with $((drops_up - 1)) other card(s) at ${ow}W — PSU/riser power suspected"
        done
        run_set halted_from climb; run_set phase halted
        log "HALT: $drops_up cards dropped above their floor in the same round — suspect PSU / riser power, not the cards."
        log "      Fix the power path, then: sudo $SCRIPT_PATH --resume"
        reset_limits; remove_unit; restore_units; exit 3
    fi

    smi -L >/dev/null 2>&1 || need_cycle=1
    [ "$need_cycle" = 1 ] && power_cycle "card dropped or driver unresponsive after round"
    return 0
}

# ─── Isolation: re-test one floor-failing card alone ─────────────────────────
isolate_round() {
    local uuid idx steps floor start rc wl ft
    uuid="$(cards_with_status isolate | head -1)"
    idx="$(index_of "$uuid")"
    card_set "$uuid" 14 1
    if [ -z "$idx" ]; then
        card_set "$uuid" 10 dropped; card_set "$uuid" 12 "not visible for the solo re-test; inspect slot/riser/power"
        return 0
    fi
    steps="$(card_field "$uuid" 6)"; floor="$(step_at "$steps" 0)"
    smi -i "$idx" -pl "$floor" >/dev/null 2>&1 || true
    rm -f "$STATE_DIR/$uuid.rc"
    log "Solo re-test: $(card_field "$uuid" 4) $uuid (index $idx) alone at ${floor}W: code memtest stress"
    start=$(date +%s)
    WORKER_TAG=solo run_worker "$uuid" "$idx" "$floor" code memtest stress
    rc="$(cat "$STATE_DIR/$uuid.rc" 2>/dev/null || echo 255)"
    wl="$LOG_DIR/${uuid}_${floor}W_solo.log"
    if xid79_bus_ids "$start" | grep -qi "$(bus_short "$(card_field "$uuid" 3)")" || [ "$rc" -eq 124 ] \
       || [ "$rc" -eq 137 ] || [ -z "$(index_of "$uuid")" ]; then
        card_set "$uuid" 10 dropped; card_set "$uuid" 9 "$floor"
        card_set "$uuid" 12 "fell off bus at floor ${floor}W, also when tested alone"
        log "SOLO DROP: $uuid at ${floor}W — grade C"
        power_cycle "card dropped in solo re-test"
    elif [ "$rc" -eq 0 ]; then
        card_set "$uuid" 8 "$floor"; card_set "$uuid" 9 ""; card_set "$uuid" 11 ""
        card_set "$uuid" 12 "failed the floor only alongside other cards; passed alone — check node PSU/riser power under full load"
        run_set node_note "cards failed the floor together but passed alone — check PSU/riser power under full-node load"
        if [ "$(step_count "$steps")" -le 1 ]; then card_set "$uuid" 10 done
        else card_set "$uuid" 7 1; card_set "$uuid" 10 climbing; fi
        log "SOLO PASS: $uuid at ${floor}W — back on the ladder"
    else
        ft="$(grep -E '\[ FAIL \]' "$wl" | sed -E 's/.*\[ FAIL \] //; s/ \(exit code.*//' | paste -sd ';' -)"
        card_set "$uuid" 9 "$floor"; card_set "$uuid" 11 "$ft"
        if echo "$ft" | grep -qi memtest; then card_set "$uuid" 10 memfail; card_set "$uuid" 12 "memtest failed alone — grade C"
        else card_set "$uuid" 10 failed-floor; card_set "$uuid" 12 "failed at floor ${floor}W, also when tested alone"; fi
        log "SOLO FAIL: $uuid at ${floor}W ($ft) — grade C"
        smi -L >/dev/null 2>&1 || power_cycle "driver unresponsive after solo re-test"
    fi
}

# ─── Warm-up: build fulltest's tools once, serially, before parallel workers ──
warmup() {
    local uuid idx floor
    run_set phase climb          # never repeat warm-up, even if it wedges a card
    uuid="$(cards_with_status climbing | head -1)"; idx="$(index_of "$uuid")"
    floor="$(step_at "$(card_field "$uuid" 6)" 0)"
    smi -i "$idx" -pl "$floor" >/dev/null 2>&1 || true
    log "Warm-up: building/caching fulltest tools on GPU $idx at ${floor}W (result not graded)"
    timeout --kill-after=60 "$STEP_TIMEOUT" "$FULLTEST" --gpu "$idx" code memtest stress \
        --burn-duration 60 >> "$LOG_DIR/warmup.log" 2>&1 || log "Warm-up returned non-zero (see warmup.log); continuing"
    smi -L >/dev/null 2>&1 || power_cycle "driver unresponsive after warm-up"
    local u
    for u in $(cut -f1 "$CARDS"); do
        [ -n "$(index_of "$u")" ] || power_cycle "a card dropped during warm-up — cycling so it gets its real test"
    done
}

# ─── Confirm: all cards together at their ceilings ───────────────────────────
confirm_round() {
    local uuid idx c list="" start rc
    for uuid in $(awk -F'\t' '$8!="" && ($10=="done"||$10=="dropped"){print $1}' "$CARDS"); do
        idx="$(index_of "$uuid")"; c="$(card_field "$uuid" 8)"
        [ -n "$idx" ] || { card_set "$uuid" 10 missing; continue; }
        smi -i "$idx" -pl "$c" >/dev/null 2>&1 || true
        list="${list:+$list,}$idx"
    done
    [ -n "$list" ] || { run_set phase finish; return 0; }
    log "Confirm: GPUs $list together at their ceilings, stress ${CONFIRM_DURATION}s"
    start=$(date +%s)
    timeout --kill-after=60 $((CONFIRM_DURATION + 1200)) "$FULLTEST" --gpu "$list" stress \
        --burn-duration "$CONFIRM_DURATION" >> "$LOG_DIR/confirm.log" 2>&1
    rc=$?
    local fell; fell="$(xid79_bus_ids "$start")"
    if [ "$rc" -eq 0 ] && [ -z "$fell" ]; then
        # The power-anomaly check compares a card with its peers, so it is only
        # meaningful here, where all cards run in one fulltest.
        local flagged gi gu
        flagged="$(grep -oE 'power anomaly on GPU\(s\) [0-9, ]+' "$LOG_DIR/confirm.log" | tail -1 | grep -oE '[0-9]+')"
        for gi in $flagged; do
            gu="$(smi --query-gpu=index,uuid --format=csv,noheader 2>/dev/null | awk -F', *' -v i="$gi" '$1==i{print $2}')"
            [ -n "$gu" ] || continue
            card_set "$gu" 10 connector
            card_set "$gu" 12 "power anomaly (12V-2x6 connector signature) in the all-GPU confirm — inspect cable"
            log "CONNECTOR: GPU $gi ($gu) flagged in confirm"
        done
        log "Confirm passed"; run_set phase finish; return 0
    fi
    # Step down every card that fell off; if none identifiable, step all down one.
    local stepped=0 steps sidx
    for uuid in $(awk -F'\t' '$8!=""{print $1}' "$CARDS"); do
        if [ -n "$fell" ] && ! echo "$fell" | grep -qi "$(bus_short "$(card_field "$uuid" 3)")"; then continue; fi
        steps="$(card_field "$uuid" 6)"; c="$(card_field "$uuid" 8)"
        sidx="$(echo "$steps" | tr ',' '\n' | grep -nx "$c" | cut -d: -f1)"
        if [ -n "$sidx" ] && [ "$sidx" -ge 2 ]; then
            card_set "$uuid" 9 "$c"; card_set "$uuid" 8 "$(step_at "$steps" $((sidx - 2)))"
        else
            card_set "$uuid" 9 "$c"; card_set "$uuid" 8 ""; card_set "$uuid" 10 failed-floor
        fi
        card_set "$uuid" 12 "stepped down after failing all-GPU confirm"
        stepped=$((stepped + 1))
    done
    log "Confirm failed (rc=$rc) — stepped down $stepped card(s)"
    power_cycle "confirm burn failed"
}

finish() {
    local uuid key def c bg band grade serial bus slot model ff status ft note idx applied pct rung
    local overrides="" host_lines="" report="" extra pctr cl nA=0 nB=0 nC=0 nND=0
    run_set phase complete
    rm -f "$ACTIVE"
    remove_unit
    reset_limits

    local header="Date,Node,GPU UUID / idx,PCI bus ID,Model,Serial,Failing test(s),Rung reached (1-9),Default PL (W),Lowest passing PL (W),First failing PL (W),% of default,PCIe link (gen x width),Fault follows,Grade,Ticket,Evidence path,Notes,Band (auto)"
    # Columns match the training tracker's GPU Ladder Log (A..S) so rows paste straight in.
    # Date = run ID (yyyy-mm-dd-hh-mm); Node = server serial; PCI bus ID includes the physical slot.
    echo "$header" > "$RESULT_CSV"
    for uuid in $(cut -f1 "$CARDS"); do
        serial="$(card_field "$uuid" 2)"; bus="$(card_field "$uuid" 3)"; model="$(card_field "$uuid" 4)"
        def="$(card_field "$uuid" 5)"; c="$(card_field "$uuid" 8)"; ff="$(card_field "$uuid" 9)"
        status="$(card_field "$uuid" 10)"; ft="$(card_field "$uuid" 11)"; note="$(card_field "$uuid" 12)"
        slot="$(card_field "$uuid" 13)"
        key="$(model_key "$model")"; idx="$(index_of "$uuid")"
        case "$status" in memfail|failed-floor|missing) c="" ;; esac
        bg="$(band_for "$key" "$c" "$def")"; band="${bg%%|*}"; grade="${bg#*|}"
        extra="$note"
        note="status ${status}; index ${idx:-n/a}${note:+; $note}"
        [ "$status" = connector ] && note="$note; grade provisional until cable replaced and re-tested"
        if [ "$grade" = C ]; then
            note="$note; NOT for client service: sell / RMA / mining only (mining needs a stress pass at its mining limit)"
        elif [ -n "$c" ] && [ -n "$idx" ]; then
            # A card whose ceiling is below the fleet preset it will run at needs its own limit
            applied="$(fleet_preset "$model" "$def")"
            if [ "$applied" -gt "$c" ]; then
                overrides="$overrides --gpu-limit $idx:$c"
                host_lines="${host_lines}#   index $idx = $bus${slot:+ ($slot)} $model $serial $uuid -> ${c}W
"
                if [ "$(run_get apply)" = yes ]; then
                    note="$note; per-card limit ${c}W set (fleet preset ${applied}W)"
                else
                    note="$note; per-card limit ${c}W NOT applied (USB run) - apply on the server OS: apply-on-host_${SERVER_ID}_${RUN_ID}.sh"
                fi
            fi
        fi
        pct=""; [ -n "$c" ] && pct="$(awk -v a="$c" -v b="$def" 'BEGIN{if(b>0)printf "%.3f", a/b}')"
        rung=4; [ "$status" = memfail ] && rung=2
        printf '%s,%s,%s,"%s",%s,%s,"%s",%s,%s,%s,%s,%s,,,%s,,%s,"%s",%s\n' \
            "$RUN_ID" "$SERVER_ID" "$uuid" "$bus${slot:+ ($slot)}" "$model" "$serial" "$ft" "$rung" \
            "$def" "$c" "$ff" "$pct" "$grade" "$LOG_DIR/${uuid}_*.log" "$note" "$band" >> "$RESULT_CSV"
        case "$grade" in A) nA=$((nA+1)) ;; B) nB=$((nB+1)) ;; *) nC=$((nC+1)) ;; esac
        # Readable copy: the notes after "status; index" are split one per line
        extra="${note#"status ${status}; index ${idx:-n/a}"}"; extra="${extra#; }"
        pctr=""; [ -n "$pct" ] && pctr=" ($(awk -v p="$pct" 'BEGIN{printf "%.0f", p*100}')%)"
        cl="none passed"; [ -n "$c" ] && cl="${c} W of ${def} W${pctr}"
        report="${report}GPU ${idx:-?}  ${bus}${slot:+ ($slot)}  ${model}  serial ${serial:-n/a}
  Grade:    ${grade}   Band: ${band}
  Ceiling:  ${cl}${ff:+   first fail ${ff} W}
  Failing:  ${ft:--}
  Status:   ${status} (rung ${rung})
  Notes:    $(printf '%s' "${extra:--}" | sed 's/; /\n            /g')
  UUID:     ${uuid}
  Evidence: ${LOG_DIR}/${uuid}_*.log

"
    done

    local expect found k nn
    expect="$(run_get expect)"; found="$(wc -l < "$CARDS")"; nn="$(run_get node_note)"
    if [ -n "$expect" ] && [ "$found" -lt "$expect" ]; then
        for k in $(seq 1 $((expect - found))); do
            printf '%s,%s,%s,"%s",%s,%s,"%s",%s,%s,%s,%s,%s,,,%s,,%s,"%s",%s\n' \
                "$RUN_ID" "$SERVER_ID" "not detected $k of $((expect - found))" "" "(not detected)" "" "" 1 \
                "" "" "" "" C "" "$expect GPUs expected / $found visible: not on PCIe or not seen by the driver - check slot / riser / power / BIOS bifurcation" "Not detected" >> "$RESULT_CSV"
            nC=$((nC+1)); nND=$((nND+1))
            report="${report}NOT DETECTED ($k of $((expect - found)))
  Grade:    C   Band: Not detected
  Notes:    $expect GPUs expected, $found visible: not on PCIe or not seen by the driver
            check slot / riser / power / BIOS bifurcation

"
        done
        log "$((expect - found)) expected GPU(s) not detected — rows added"
    fi
    [ -n "$nn" ] && log "NODE NOTE: $nn"

    if [ -n "$overrides" ]; then
        local host_script="$RUN_DIR/apply-on-host_${SERVER_ID}_${RUN_ID}.sh"
        {
            echo "#!/usr/bin/env bash"
            echo "# Per-card power limits from gpu-bin run $RUN_ID on server $SERVER_ID."
            echo "# Run from the infra repo root on the server's own OS (not the test USB). Check the indices still match:"
            echo "#   nvidia-smi --query-gpu=index,pci.bus_id,serial --format=csv"
            printf '%s' "$host_lines"
            echo "set -e"
            echo "sudo ./install/gpu-power-limit.sh$overrides"
        } > "$host_script"; chmod +x "$host_script"
        if [ "$(run_get apply)" = yes ]; then
            if [ -x "$GPU_POWER_LIMIT" ]; then
                log "Applying per-card limits: $GPU_POWER_LIMIT$overrides"
                # shellcheck disable=SC2086
                "$GPU_POWER_LIMIT" $overrides >> "$LOG_DIR/gpu-bin.log" 2>&1 \
                    || log "WARNING: per-card limits FAILED - run by hand: $host_script"
            else
                log "WARNING: gpu-power-limit.sh not found at $GPU_POWER_LIMIT - run by hand: $host_script"
            fi
        else
            log "USB/live boot: per-card limits NOT applied. Run on the server's own OS: $host_script"
        fi
    fi

    [ -f "$ALL_RESULTS" ] || echo "$header" > "$ALL_RESULTS"
    tail -n +2 "$RESULT_CSV" >> "$ALL_RESULTS"
    restore_units
    {
        echo "gpu-bin results: server $SERVER_ID, run $RUN_ID (finished $(date '+%F %T'))"
        echo "Cards: $((nA + nB + nC))   grade A: $nA   grade B: $nB   grade C: $nC$([ "$nND" -gt 0 ] && echo " (incl. $nND not detected)")"
        [ -n "$nn" ] && echo "NODE NOTE: $nn"
        [ -n "$overrides" ] && echo "Per-card limits:$overrides$([ "$(run_get apply)" = yes ] || echo "  (NOT applied: run apply-on-host_${SERVER_ID}_${RUN_ID}.sh on the server's own OS)")"
        echo "Tracker rows: $RESULT_CSV"
        echo
        printf '%s' "$report"
    } > "$RESULT_TXT"
    log "Binning complete: run $RUN_ID on $SERVER_ID. Results: $RESULT_TXT (tracker rows: $RESULT_CSV, also appended to $ALL_RESULTS)"
    cat "$RESULT_TXT" >&2
}

# ─── Main ────────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --resume) MODE=resume ;;
        --status) MODE=status ;;
        --dry-run) MODE=dry ;;
        --reset) MODE=reset ;;
        --force) FORCE=1 ;;
        --apply-limits) APPLY_LIMITS=yes ;;
        --record-limits) APPLY_LIMITS=no ;;
        --expect-gpus) EXPECT_GPUS="$2"; shift ;;
        --burn-duration) BURN_DURATION="$2"; shift ;;
        --confirm-duration) CONFIRM_DURATION="$2"; shift ;;
        --max-cycles) MAX_CYCLES="$2"; shift ;;
        --step-timeout) STEP_TIMEOUT="$2"; shift ;;
        -h|--help) sed -n '2,50p' "$SCRIPT_PATH"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done
[ -z "$EXPECT_GPUS" ] || [[ "$EXPECT_GPUS" =~ ^[0-9]+$ ]] || { echo "--expect-gpus must be a number" >&2; exit 1; }
for v in BURN_DURATION CONFIRM_DURATION MAX_CYCLES; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "$v must be a positive integer" >&2; exit 1; }
done

mkdir -p "$GPU_BIN_DIR" 2>/dev/null || { [ "$MODE" = status ] || { echo "cannot create $GPU_BIN_DIR (run as root?)" >&2; exit 1; }; }
SERVER_ID="$(server_id)"; SERVER_DIR="$GPU_BIN_DIR/$SERVER_ID"; ACTIVE="$SERVER_DIR/active-run"
mkdir -p "$SERVER_DIR" 2>/dev/null || true
[ -s "$ACTIVE" ] && set_run_paths "$(cat "$ACTIVE")"

case "$MODE" in
    status) print_status; exit 0 ;;
    reset)
        if [ -n "$RUN_ID" ]; then run_set phase reset; rm -f "$ACTIVE"; fi
        remove_unit; restore_units
        echo "Active run for $SERVER_ID cleared (${RUN_ID:-none}); its logs are kept in ${RUN_DIR:-$SERVER_DIR}"; exit 0 ;;
    dry)
        STATE_DIR="$(mktemp -d)"; CARDS="$STATE_DIR/cards.tsv"
        discover
        echo "Server $SERVER_ID - $(wc -l < "$CARDS") GPU(s) visible${EXPECT_GPUS:+, $EXPECT_GPUS expected} - ladders (W) per card; top step = card default:"
        awk -F'\t' '{printf "  %-24s %-16s %-14s %-40s steps: %s\n", $4, $3, $13, $1, $6}' "$CARDS"
        if running_from_removable; then echo "Media: USB/live - per-card limits will be recorded, not applied"
        else echo "Media: host disk - per-card limits will be applied"; fi
        rm -rf "$STATE_DIR"; exit 0 ;;
esac

[ "$(id -u)" -eq 0 ] || [ -n "${GPU_BIN_ALLOW_NONROOT:-}" ] || die "run as root"
[ -x "$FULLTEST" ] || die "fulltest.sh not found/executable at $FULLTEST (deploy with code.sh + code.cu beside it)"
command -v "$IPMITOOL" >/dev/null 2>&1 || die "ipmitool not installed (apt install ipmitool)"
case "$(stat -f -c %T "$GPU_BIN_DIR" 2>/dev/null)" in
    overlayfs|tmpfs|ramfs)
        [ -n "${GPU_BIN_ALLOW_VOLATILE:-}" ] || die "$GPU_BIN_DIR is on RAM-backed storage (live boot?) - state, logs and the resume service would be lost at the first power cycle. Point GPU_BIN_DIR at a persistent partition and bake the resume service into the image, or boot a full install." ;;
esac

if [ -n "$RUN_ID" ]; then
    # Continuing: keep the options the run was started with
    BURN_DURATION="$(run_get burn)"; CONFIRM_DURATION="$(run_get confirm)"; MAX_CYCLES="$(run_get max_cycles)"
    if [ "$(run_get phase)" = halted ]; then
        # A person running --resume by hand means the node was inspected/fixed
        if [ "$MODE" = resume ] && [ -z "${INVOCATION_ID:-}" ]; then
            run_set phase "$(run_get halted_from)"; run_set cycles 0
            log "Resuming halted run $RUN_ID (power-cycle count reset)"
        else
            log "Run $RUN_ID is halted; fix the node, then run: sudo $SCRIPT_PATH --resume"; exit 3
        fi
    fi
    wait_for_driver || power_cycle "driver not ready after boot"
    seen=0
    for u in $(cut -f1 "$CARDS"); do [ -n "$(index_of "$u")" ] && { seen=1; break; }; done
    if [ "$seen" -eq 0 ]; then
        run_set halted_from "$(run_get phase)"; run_set phase halted
        reset_limits
        die "none of run $RUN_ID's GPUs are visible on $SERVER_ID (GPUs swapped, or all lost?). Inspect, then --resume or --reset."
    fi
    log "Resuming run $RUN_ID on $SERVER_ID (phase $(run_get phase))"
else
    if [ "$MODE" = resume ]; then
        log "No active run for $SERVER_ID - nothing to resume"; exit 0
    fi
    wait_for_driver || die "nvidia-smi not responding"
    if [ "$FORCE" -ne 1 ] && [ -n "$(smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null)" ]; then
        die "GPUs have running compute processes (miner / rental agent / container). Stop them or use --force."
    fi
    "$IPMITOOL" -I open mc info >/dev/null 2>&1 || die "in-band IPMI (/dev/ipmi0) not working - cannot recover from a GPU drop unattended"
    rid="$(date +%Y-%m-%d-%H-%M)"; n=2
    while [ -e "$SERVER_DIR/$rid" ]; do rid="$(date +%Y-%m-%d-%H-%M)-$n"; n=$((n + 1)); done
    set_run_paths "$rid"
    discover
    if [ "$APPLY_LIMITS" = auto ]; then
        if running_from_removable; then APPLY_LIMITS=no; else APPLY_LIMITS=yes; fi
    fi
    run_set phase warmup; run_set cycles 0; run_set burn "$BURN_DURATION"
    run_set confirm "$CONFIRM_DURATION"; run_set max_cycles "$MAX_CYCLES"; run_set apply "$APPLY_LIMITS"
    run_set expect "$EXPECT_GPUS"
    if [ -n "$EXPECT_GPUS" ] && [ "$(wc -l < "$CARDS")" -lt "$EXPECT_GPUS" ]; then
        log "WARNING: $EXPECT_GPUS GPUs expected, only $(wc -l < "$CARDS") visible — the missing ones will be reported as not detected"
    fi
    echo "$RUN_ID" > "$ACTIVE"
    log "New run $RUN_ID on $SERVER_ID: $(wc -l < "$CARDS") GPU(s); burn ${BURN_DURATION}s/step; confirm ${CONFIRM_DURATION}s; max ${MAX_CYCLES} cycles; apply per-card limits: $APPLY_LIMITS"
fi
STEP_TIMEOUT="${STEP_TIMEOUT:-$((BURN_DURATION + 1200))}"

install_unit
pause_units

while :; do
    case "$(run_get phase)" in
        warmup) warmup ;;
        climb)
            if [ -n "$(cards_with_status isolate)" ]; then isolate_round
            elif [ -n "$(cards_with_status climbing)" ]; then climb_round
            else run_set phase confirm; fi ;;
        confirm) confirm_round ;;
        finish) finish; exit 0 ;;
        *) die "unknown phase $(run_get phase)" ;;
    esac
done
