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
#   --force               run even if GPUs have compute processes
#
# Environment overrides (used by test/gpu-bin-test.sh):
#   GPU_BIN_DIR (default /opt/gpu-bin)   FULLTEST (default <script dir>/fulltest.sh)
#   NVIDIA_SMI IPMITOOL JOURNALCTL SYSTEMCTL  POLL_SECONDS  STAGGER_SECONDS
#   GPU_POWER_LIMIT (default ../install/gpu-power-limit.sh) — per-card limits at finish
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

STATE_DIR="$GPU_BIN_DIR/state"
LOG_DIR="$GPU_BIN_DIR/logs"
CARDS="$STATE_DIR/cards.tsv"       # one line per card, see FIELDS below
RUN="$STATE_DIR/run.env"           # phase, cycles, options (parsed as data)
RESULT_CSV="$GPU_BIN_DIR/results.csv"
UNIT_NAME="gpu-bin-resume.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
PAUSED_UNITS="gpu-watchdog.timer gpu-watchdog.service"

# cards.tsv fields (tab separated):
#  1 uuid 2 serial 3 bus 4 model 5 default_pl 6 steps(comma) 7 step_idx
#  8 last_pass 9 first_fail 10 status 11 failed_tests 12 note
# status: climbing | done | dropped | failed-floor | memfail | connector | missing
export CUDA_DEVICE_ORDER=PCI_BUS_ID   # make CUDA indices match nvidia-smi

BURN_DURATION=600
CONFIRM_DURATION=1800
MAX_CYCLES=8
STEP_TIMEOUT=""
FORCE=0
MODE=run

log() { echo "$(date '+%F %T') [gpu-bin] $*" | tee -a "$LOG_DIR/gpu-bin.log" >&2; }
die() { log "ERROR: $*"; exit 1; }

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
    local tmp="$STATE_DIR/.cards.new" uuid serial bus name def min max key steps
    : > "$tmp"
    smi --query-gpu=uuid,serial,pci.bus_id,name,power.default_limit,power.min_limit,power.max_limit \
        --format=csv,noheader,nounits > "$STATE_DIR/.query" || die "nvidia-smi query failed"
    while IFS=',' read -r uuid serial bus name def min max; do
        uuid="$(echo "$uuid" | xargs)"; serial="$(echo "$serial" | xargs)"; bus="$(echo "$bus" | xargs)"
        name="$(echo "$name" | xargs)"
        def="$(printf '%.0f' "$(echo "$def" | xargs)")"; min="$(printf '%.0f' "$(echo "$min" | xargs)")"
        max="$(printf '%.0f' "$(echo "$max" | xargs)")"
        key="$(model_key "$name")"
        steps="$(build_steps "$key" "$def" "$min" "$max")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t0\t\t\tclimbing\t\t\n' \
            "$uuid" "$serial" "$bus" "$name" "$def" "$steps" >> "$tmp"
    done < "$STATE_DIR/.query"
    [ -s "$tmp" ] || die "no NVIDIA GPUs found"
    mv "$tmp" "$CARDS"
}

print_status() {
    [ -f "$CARDS" ] || { echo "No binning run in $GPU_BIN_DIR"; return 0; }
    echo "Phase: $(run_get phase)   power cycles: $(run_get cycles)/$(run_get max_cycles)"
    printf '%-14s %-18s %-14s %-24s %-8s %-8s %-12s %s\n' UUID SERIAL BUS MODEL CEILING FIRSTFAIL STATUS NOTE
    awk -F'\t' '{printf "%-14s %-18s %-14s %-24s %-8s %-8s %-12s %s\n", substr($1,1,14), $2, $3, $4, $8, $9, $10, $12}' "$CARDS"
}

# ─── Resume service ──────────────────────────────────────────────────────────
install_unit() {
    [ "${GPU_BIN_NO_UNIT:-0}" = 1 ] && return 0
    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Resume gpu-bin.sh GPU binning after power cycle
After=multi-user.target systemd-udev-settle.service nvidia-persistenced.service nvidia-runtime-policy.service
Wants=systemd-udev-settle.service
ConditionPathExists=$RUN

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
    "$SYSTEMCTL" disable "$UNIT_NAME" >/dev/null 2>&1 || true
    rm -f "$UNIT_PATH"; "$SYSTEMCTL" daemon-reload || true
}
pause_units()   { local u; for u in $PAUSED_UNITS; do "$SYSTEMCTL" stop "$u" >/dev/null 2>&1 || true; done; }
restore_units() { local u; for u in $PAUSED_UNITS; do "$SYSTEMCTL" start "$u" >/dev/null 2>&1 || true; done; }

power_cycle() {
    local cycles; cycles=$(( $(run_get cycles) + 1 ))
    if [ "$cycles" -gt "$MAX_CYCLES" ]; then
        run_set halted_from "$(run_get phase)"; run_set phase halted
        log "HALT: power-cycle limit ($MAX_CYCLES) reached. Inspect the node; resume with --resume after fixing."
        remove_unit; restore_units; exit 2
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
    local wlog="$LOG_DIR/${uuid}_${watts}W.log" rc
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
    local i rc wl watts_now ft
    for i in "${!uuids[@]}"; do
        uuid="${uuids[$i]}"
        steps="$(card_field "$uuid" 6)"; sidx="$(card_field "$uuid" 7)"
        watts_now="$(step_at "$steps" "$sidx")"
        rc="$(cat "$STATE_DIR/$uuid.rc" 2>/dev/null || echo 255)"
        wl="$LOG_DIR/${uuid}_${watts_now}W.log"
        if echo "$fell" | grep -qi "$(bus_short "$(card_field "$uuid" 3)")" || [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ] \
           || [ -z "$(index_of "$uuid")" ]; then
            drops=$((drops + 1)); need_cycle=1; dropped+=("$uuid:$watts_now")
            log "DROP: $uuid at ${watts_now}W (last pass: $(card_field "$uuid" 8 | sed 's/^$/none/'))"
        elif [ "$rc" -eq 0 ]; then
            if grep -qi 'power anomaly on GPU' "$wl"; then
                card_set "$uuid" 10 connector; card_set "$uuid" 9 "$watts_now"
                card_set "$uuid" 12 "power anomaly (12V-2x6 connector signature) at ${watts_now}W — inspect cable before any further test"
                log "CONNECTOR: $uuid flagged at ${watts_now}W — stopped climbing"
                continue
            fi
            card_set "$uuid" 8 "$watts_now"
            if [ $((sidx + 1)) -ge "$(step_count "$steps")" ]; then
                card_set "$uuid" 10 done; log "TOP: $uuid passed its default ${watts_now}W"
            else
                card_set "$uuid" 7 $((sidx + 1)); log "PASS: $uuid at ${watts_now}W"
            fi
        else
            ft="$(grep -E '\[ FAIL \]' "$wl" | sed -E 's/.*\[ FAIL \] //; s/ \(exit code.*//' | paste -sd ';' -)"
            card_set "$uuid" 9 "$watts_now"; card_set "$uuid" 11 "$ft"
            if echo "$ft" | grep -qi memtest; then
                card_set "$uuid" 10 memfail; card_set "$uuid" 12 "memtest failed — grade C"
            elif [ "$sidx" -eq 0 ]; then
                card_set "$uuid" 10 failed-floor; card_set "$uuid" 12 "failed at floor ${watts_now}W"
            else
                card_set "$uuid" 10 done
            fi
            log "FAIL: $uuid at ${watts_now}W ($ft)"
            # a failed CUDA run can leave the card wedged even without Xid 79
            smi -i "$(index_of "$uuid")" -q >/dev/null 2>&1 || need_cycle=1
        fi
    done

    if [ "$drops" -ge 2 ]; then
        # Several cards at once points at shared power, not the cards:
        # leave them climbing at the same step so the run retries after the fix.
        for d in "${dropped[@]}"; do
            card_set "${d%%:*}" 12 "dropped with $((drops - 1)) other card(s) at ${d##*:}W — PSU/riser power suspected"
        done
        run_set halted_from climb; run_set phase halted
        log "HALT: $drops cards dropped in the same round — suspect PSU / riser power, not the cards."
        log "      Fix the power path, then: sudo $SCRIPT_PATH --resume"
        remove_unit; restore_units; exit 3
    fi
    for d in "${dropped[@]}"; do
        card_set "${d%%:*}" 9 "${d##*:}"; card_set "${d%%:*}" 10 dropped
        card_set "${d%%:*}" 12 "fell off bus / hung at ${d##*:}W"
    done
    smi -L >/dev/null 2>&1 || need_cycle=1
    [ "$need_cycle" = 1 ] && power_cycle "card dropped or driver unresponsive after round"
    return 0
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
    local uuid key def c bg band grade serial bus model ff status ft note idx applied pct rung overrides=""
    run_set phase complete
    remove_unit
    "$SYSTEMCTL" restart nvidia-runtime-policy.service >/dev/null 2>&1 || true   # back to power-saving presets
    sleep 2

    # Columns match the training tracker's GPU Ladder Log (A..S) so rows paste straight in.
    echo "Date,Node,GPU UUID / idx,PCI bus ID,Model,Serial,Failing test(s),Rung reached (1-9),Default PL (W),Lowest passing PL (W),First failing PL (W),% of default,PCIe link (gen x width),Fault follows,Grade,Ticket,Evidence path,Notes,Band (auto)" > "$RESULT_CSV"
    for uuid in $(cut -f1 "$CARDS"); do
        serial="$(card_field "$uuid" 2)"; bus="$(card_field "$uuid" 3)"; model="$(card_field "$uuid" 4)"
        def="$(card_field "$uuid" 5)"; c="$(card_field "$uuid" 8)"; ff="$(card_field "$uuid" 9)"
        status="$(card_field "$uuid" 10)"; ft="$(card_field "$uuid" 11)"; note="$(card_field "$uuid" 12)"
        key="$(model_key "$model")"; idx="$(index_of "$uuid")"
        case "$status" in memfail|failed-floor|missing) c="" ;; esac
        bg="$(band_for "$key" "$c" "$def")"; band="${bg%%|*}"; grade="${bg#*|}"
        note="status ${status}; index ${idx:-n/a}${note:+; $note}"
        [ "$status" = connector ] && note="$note; grade provisional until cable replaced and re-tested"
        if [ "$grade" = C ]; then
            note="$note; NOT for client service: sell / RMA / mining only (mining needs a stress pass at its mining limit)"
        elif [ -n "$c" ] && [ -n "$idx" ]; then
            # A card whose ceiling is below what the node will run it at needs its own limit
            applied="$(smi -i "$idx" --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | head -1 | xargs)"
            applied="$(printf '%.0f' "${applied:-0}" 2>/dev/null || echo 0)"
            if [ "$applied" -gt "$c" ]; then
                overrides="$overrides --gpu-limit $idx:$c"
                note="$note; per-card limit ${c}W set (node runs ${applied}W)"
            fi
        fi
        pct=""; [ -n "$c" ] && pct="$(awk -v a="$c" -v b="$def" 'BEGIN{if(b>0)printf "%.3f", a/b}')"
        rung=4; [ "$status" = memfail ] && rung=2
        printf '%s,%s,%s,%s,%s,%s,"%s",%s,%s,%s,%s,%s,,,%s,,%s,"%s",%s\n' \
            "$(date +%F)" "$(hostname)" "$uuid" "$bus" "$model" "$serial" "$ft" "$rung" \
            "$def" "$c" "$ff" "$pct" "$grade" "$LOG_DIR/${uuid}_*W.log" "$note" "$band" >> "$RESULT_CSV"
    done

    if [ -n "$overrides" ]; then
        if [ -x "$GPU_POWER_LIMIT" ]; then
            log "Applying per-card limits: $GPU_POWER_LIMIT$overrides"
            # shellcheck disable=SC2086
            "$GPU_POWER_LIMIT" $overrides >> "$LOG_DIR/gpu-bin.log" 2>&1 \
                || log "WARNING: per-card limits FAILED — run by hand: sudo gpu-power-limit.sh$overrides"
        else
            log "WARNING: gpu-power-limit.sh not found at $GPU_POWER_LIMIT — run by hand: sudo gpu-power-limit.sh$overrides"
        fi
    fi
    restore_units
    log "Binning complete. Results: $RESULT_CSV (columns match the tracker's GPU Ladder Log)"
    column -s, -t < "$RESULT_CSV" >&2 2>/dev/null || cat "$RESULT_CSV" >&2
}

# ─── Main ────────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --resume) MODE=resume ;;
        --status) MODE=status ;;
        --dry-run) MODE=dry ;;
        --reset) MODE=reset ;;
        --force) FORCE=1 ;;
        --burn-duration) BURN_DURATION="$2"; shift ;;
        --confirm-duration) CONFIRM_DURATION="$2"; shift ;;
        --max-cycles) MAX_CYCLES="$2"; shift ;;
        --step-timeout) STEP_TIMEOUT="$2"; shift ;;
        -h|--help) sed -n '2,36p' "$SCRIPT_PATH"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done
for v in BURN_DURATION CONFIRM_DURATION MAX_CYCLES; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "$v must be a positive integer" >&2; exit 1; }
done

mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null || { [ "$MODE" = status ] || { echo "cannot create $GPU_BIN_DIR (run as root?)" >&2; exit 1; }; }

case "$MODE" in
    status) print_status; exit 0 ;;
    reset)
        remove_unit; rm -rf "$STATE_DIR"; restore_units
        echo "gpu-bin state cleared (logs kept in $LOG_DIR)"; exit 0 ;;
    dry)
        STATE_DIR="$(mktemp -d)"; CARDS="$STATE_DIR/cards.tsv"
        discover
        echo "Ladders (W) per card; top step = card default:"
        awk -F'\t' '{printf "  %-24s %-14s %-40s steps: %s\n", $4, $3, $1, $6}' "$CARDS"
        rm -rf "$STATE_DIR"; exit 0 ;;
esac

[ "$(id -u)" -eq 0 ] || [ -n "${GPU_BIN_ALLOW_NONROOT:-}" ] || die "run as root"
[ -x "$FULLTEST" ] || die "fulltest.sh not found/executable at $FULLTEST (deploy with code.sh + code.cu beside it)"
command -v "$IPMITOOL" >/dev/null 2>&1 || die "ipmitool not installed (apt install ipmitool)"

if [ -f "$RUN" ]; then
    # Continuing: keep the options the run was started with
    BURN_DURATION="$(run_get burn)"; CONFIRM_DURATION="$(run_get confirm)"; MAX_CYCLES="$(run_get max_cycles)"
    case "$(run_get phase)" in
        complete) log "Run already complete. Use --reset to start a new one."; print_status; exit 0 ;;
        halted)
            # A person running --resume by hand means the node was inspected/fixed
            if [ "$MODE" = resume ] && [ -z "${INVOCATION_ID:-}" ]; then
                run_set phase "$(run_get halted_from)"; run_set cycles 0
                log "Resuming halted run (power-cycle count reset)"
            fi ;;
    esac
    [ "$(run_get phase)" = halted ] && { log "Run is halted; fix the node, then run: sudo $SCRIPT_PATH --resume"; exit 3; }
    wait_for_driver || power_cycle "driver not ready after boot"
else
    [ "$MODE" = resume ] && die "nothing to resume"
    wait_for_driver || die "nvidia-smi not responding"
    if [ "$FORCE" -ne 1 ] && [ -n "$(smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null)" ]; then
        die "GPUs have running compute processes (miner / rental agent / container). Stop them or use --force."
    fi
    "$IPMITOOL" -I open mc info >/dev/null 2>&1 || die "in-band IPMI (/dev/ipmi0) not working — cannot recover from a GPU drop unattended"
    discover
    run_set phase warmup; run_set cycles 0; run_set burn "$BURN_DURATION"
    run_set confirm "$CONFIRM_DURATION"; run_set max_cycles "$MAX_CYCLES"
    log "New run: $(wc -l < "$CARDS") GPU(s); burn ${BURN_DURATION}s/step; confirm ${CONFIRM_DURATION}s; max ${MAX_CYCLES} cycles"
fi
STEP_TIMEOUT="${STEP_TIMEOUT:-$((BURN_DURATION + 1200))}"

install_unit
pause_units

while :; do
    case "$(run_get phase)" in
        warmup) warmup ;;
        climb)
            if [ -n "$(cards_with_status climbing)" ]; then climb_round
            else run_set phase confirm; fi ;;
        confirm) confirm_round ;;
        finish) finish; exit 0 ;;
        *) die "unknown phase $(run_get phase)" ;;
    esac
done
