#!/usr/bin/env bash
# Mocked end-to-end test for test/gpu-bin.sh — no GPUs, BMC or systemd needed.
#
# Server SRV123: GPU0 RTX 5090 (healthy, in SLOT1 behind a riser bridge),
#   GPU1 RTX 5090 (falls off the bus at 550 W), GPU2 RTX 4090 (fails stress
#   at 450 W), GPU3 RTX A4000 (fails at 140 W).
# Plus a node like the real BR80S5402800219 run: 6 fitted / 4 visible, three
#   cards failing the floor together, re-tested alone before grading.
# Expect: one cold power cycle, then GPU0 Default/A (575 W),
#   GPU1 Acceptable/A (540 W), GPU2 Grade B/B (300 W),
#   GPU3 Grade B/B (100 W) with a per-card 100 W limit (preset is 140 W).
# Also: results in tracker column order (A..S), run ID + server serial,
#   physical slot next to the PCI address, USB mode records limits instead of
#   applying them, a stick moved to another server does not resume the old run,
#   and a two-card drop halts without power-cycling.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS="$(mktemp -d /tmp/gpu-bin-test.XXXX)"
trap 'rm -rf "$WS"' EXIT
M="$WS/mock"; mkdir -p "$M" "$WS/node"
export NODE="$WS/node"

# Fake sysfs: GPU0 sits behind bridge 0000:00:01.0, which SMBIOS calls SLOT1
mkdir -p "$WS/sys/pci0000:00/0000:00:01.0/0000:25:00.0" "$WS/devices"
ln -s "$WS/sys/pci0000:00/0000:00:01.0/0000:25:00.0" "$WS/devices/0000:25:00.0"

cat > "$M/dmidecode" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-s system-serial-number") cat "$NODE/serial" 2>/dev/null || echo SRV123 ;;
  "-t slot") printf 'Handle 0x0901, DMI type 9, 17 bytes\nSystem Slot Information\n\tDesignation: SLOT1\n\tBus Address: 0000:00:01.0\n\n' ;;
esac
EOF

cat > "$M/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
uuids=(GPU-aaaa GPU-bbbb GPU-cccc GPU-dddd)
preset=(450 450 300 140)
case "$*" in
  *--query-gpu=uuid,serial*)
    echo "GPU-aaaa, 1001, 00000000:25:00.0, NVIDIA GeForce RTX 5090, 575.00, 400.00, 600.00"
    echo "GPU-bbbb, 1002, 00000000:41:00.0, NVIDIA GeForce RTX 5090, 575.00, 400.00, 600.00"
    echo "GPU-cccc, 1003, 00000000:61:00.0, NVIDIA GeForce RTX 4090, 450.00, 150.00, 600.00"
    echo "GPU-dddd, 1004, 00000000:81:00.0, NVIDIA RTX A4000, 140.00, 70.00, 140.00" ;;
  *--query-gpu=index,uuid*)
    for i in 0 1 2 3; do [ -f "$NODE/dropped_$i" ] || echo "$i, ${uuids[$i]}"; done ;;
  *--query-compute-apps*) : ;;
  *--query-gpu=power.limit*) set -- $*; echo "${preset[$2]}.00" ;;
  -L) echo "GPU 0: mock" ;;
  *-pl*) set -- $*; [ -f "$NODE/dropped_$2" ] && exit 15; echo "$4" > "$NODE/pl_$2"; echo "$2:$4" >> "$NODE/pl.history" ;;
  *-q*) set -- $*; [ -f "$NODE/dropped_$2" ] && exit 15; exit 0 ;;
esac
EOF

cat > "$M/fulltest.sh" <<'EOF'
#!/usr/bin/env bash
gpu="$2"
echo "args: $*" >> "$NODE/fulltest.calls"
case "$gpu" in *,*) echo "[ PASS ] confirm"; exit 0 ;; esac
pl="$(cat "$NODE/pl_$gpu")"
# how many cards are under test right now (shared round vs solo re-test)
touch "$NODE/running_$gpu"; trap 'rm -f "$NODE/running_$gpu"' EXIT
sleep 0.5; n="$(ls "$NODE"/running_* 2>/dev/null | wc -l)"
if [ -n "${MOCK_SHARED:-}" ] && [ "$gpu" != 3 ] && [ "$pl" -le 450 ]; then
  if [ "$gpu" = 0 ]; then   # bad card: drops at the floor, alone or not
    touch "$NODE/dropped_0"
    echo "NVRM: Xid (PCI:0000:25:00): 79, pid=1, GPU has fallen off the bus." >> "$NODE/journal"; exit 1
  fi
  if [ "$gpu" = 1 ] && [ "$n" -gt 1 ]; then echo "[ FAIL ] cuda_memtest (GPU Memory Stress) (exit code 1)"; exit 1; fi
  if [ "$gpu" = 2 ]; then echo "[ FAIL ] Sustained Compute Stress (exit code 1)"; exit 1; fi
fi
if [ -n "${MOCK_DOUBLE:-}" ] && { [ "$gpu" = 0 ] || [ "$gpu" = 1 ]; } && [ "$pl" -ge 500 ]; then
  touch "$NODE/dropped_$gpu"
  echo "NVRM: Xid (PCI:0000:$([ "$gpu" = 0 ] && echo 25 || echo 41):00): 79, pid=1, GPU has fallen off the bus." >> "$NODE/journal"
  exit 1
fi
if [ "$gpu" = 1 ] && [ "$pl" -ge 550 ]; then
  touch "$NODE/dropped_1"
  echo "NVRM: Xid (PCI:0000:41:00): 79, pid=1234, GPU has fallen off the bus." >> "$NODE/journal"
  echo "[ FAIL ] CUDA Int32 Compute Stress (code.cu) (exit code 1)"; exit 1
fi
if { [ "$gpu" = 2 ] && [ "$pl" -ge 450 ]; } || { [ "$gpu" = 3 ] && [ "$pl" -ge 140 ]; }; then
  echo "[ FAIL ] Sustained Compute Stress (exit code 1)"; exit 1
fi
echo "[ PASS ] all"; exit 0
EOF

cat > "$M/journalctl" <<'EOF'
#!/usr/bin/env bash
cat "$NODE/journal" 2>/dev/null
EOF

cat > "$M/ipmitool" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"mc info"*) exit 0 ;;
  *"chassis power cycle"*)
    echo x >> "$NODE/cycles"; rm -f "$NODE"/dropped_* "$NODE/journal"
    kill -9 "$PPID"; exit 0 ;;
esac
EOF

printf '#!/usr/bin/env bash\nexit 0\n' > "$M/systemctl"
cat > "$M/gpu-power-limit.sh" <<'EOF'
#!/usr/bin/env bash
GPU_PRESET_MODELS=("5090" "4090" "A100" "H100" "A4000")
GPU_PRESET_WATTS=(450 300 300 500 140)
echo "$*" >> "$NODE/gpl.calls"
EOF
chmod +x "$M"/*

export GPU_BIN_DIR="$WS/bin" FULLTEST="$M/fulltest.sh" NVIDIA_SMI="$M/nvidia-smi" \
       IPMITOOL="$M/ipmitool" GPU_POWER_LIMIT="$M/gpu-power-limit.sh" JOURNALCTL="$M/journalctl" \
       SYSTEMCTL="$M/systemctl" DMIDECODE="$M/dmidecode" SYSFS_PCI="$WS/devices" \
       POLL_SECONDS=0 STAGGER_SECONDS=0 GPU_BIN_NO_UNIT=1 GPU_BIN_ALLOW_NONROOT=1 GPU_BIN_ALLOW_VOLATILE=1
GB="$ROOT_DIR/test/gpu-bin.sh"

fail=0
check() { if eval "$1"; then echo "ok   - $2"; else echo "FAIL - $2"; fail=1; fi; }
newest_csv() { ls -t "$GPU_BIN_DIR"/SRV123/*/results_*.csv 2>/dev/null | head -1; }

# ── fulltest must number GPUs like nvidia-smi (PCI order), or --gpu N hits another card on mixed nodes ──
for f in fulltest.sh gpu-fulltest-v2.sh; do
  check 'awk "/export CUDA_DEVICE_ORDER=PCI_BUS_ID/{o=NR} /export CUDA_VISIBLE_DEVICES=/{v=NR} END{exit !(o && v && o<v)}" "$ROOT_DIR/test/$f"' "$f sets CUDA_DEVICE_ORDER=PCI_BUS_ID before CUDA_VISIBLE_DEVICES"
done

# ── Ladders and slot lookup ─────────────────────────────────────────────────
dry="$(GPU_BIN_MEDIA=host bash "$GB" --dry-run 2>&1)"
check 'echo "$dry" | grep -q "steps: 450,500,540,550,575$"' "5090 ladder stops at card default 575"
check 'echo "$dry" | grep -q "steps: 300,450$"'             "4090 ladder is 300,450"
check 'echo "$dry" | grep -q "steps: 100,140$"'             "A4000 ladder is 100,140"
check 'echo "$dry" | grep -q "00000000:25:00.0 *SLOT1"'     "physical slot found through the riser bridge"
check 'echo "$dry" | grep -q "Server SRV123"'               "server identified by DMI system serial"

# ── Run 1 on the host disk: drop, power cycle, resume, finish ───────────────
GPU_BIN_MEDIA=host bash "$GB" --burn-duration 1 --confirm-duration 1 >/dev/null 2>&1
check '[ "$(wc -l < "$NODE/cycles")" -eq 1 ]'  "exactly one power cycle after the drop"
check '[ -z "$(newest_csv)" ]'                  "no results before resume"
check '[ -s "$GPU_BIN_DIR/SRV123/active-run" ]' "active run recorded for this server"
GPU_BIN_MEDIA=host bash "$GB" --resume >/dev/null 2>&1
R="$(newest_csv)"
check '[ -n "$R" ] && echo "$R" | grep -Eq "/SRV123/20[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}/results_SRV123_20[0-9-]+\.csv$"' "results file named by server and run ID"
check '[ "$(head -1 "$R")" = "Date,Node,GPU UUID / idx,PCI bus ID,Model,Serial,Failing test(s),Rung reached (1-9),Default PL (W),Lowest passing PL (W),First failing PL (W),% of default,PCIe link (gen x width),Fault follows,Grade,Ticket,Evidence path,Notes,Band (auto)" ]' "CSV header matches tracker columns A..S"
check 'grep -Eq "^20[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2},SRV123,GPU-aaaa,\"00000000:25:00.0 \(SLOT1\)\"," "$R"' "row carries run ID, server serial, PCI address and slot"
check 'grep -q "GPU-aaaa.*,4,575,575,,1.000,,,A,,.*\"status done; index 0\",Default$" "$R"'       "GPU0 healthy 5090 -> Default / A at 575 W"
check 'grep -q "GPU-bbbb.*,4,575,540,550,0.939,,,A,,.*fell off bus.*,Acceptable$" "$R"'         "GPU1 dropped at 550 -> Acceptable / A at 540 W"
check 'grep -q "GPU-cccc.*,\"Sustained Compute Stress\",4,450,300,450,0.667,,,B,.*,Grade B$" "$R"' "GPU2 4090 fails 450 -> Grade B / B at 300 W"
check 'grep -q "GPU-dddd.*,4,140,100,140,0.714,,,B,.*per-card limit 100W set.*,Grade B$" "$R"'  "GPU3 A4000 fails 140 -> Grade B / B at 100 W"
check '[ "$(cat "$NODE/gpl.calls")" = "--gpu-limit 3:100" ]'  "host disk: per-card limit applied to the grade B A4000 only"
check '[ "$(python3 -c "import csv,sys; print(sorted({len(r) for r in csv.reader(open(sys.argv[1]))}))" "$R")" = "[19]" ]' "every row has 19 columns"
check '[ "$(wc -l < "$NODE/cycles")" -eq 1 ]'                  "no further power cycles"
check 'grep -q -- "--gpu 0,1,2,3 stress" "$NODE/fulltest.calls"' "all-GPU confirm burn ran"
check 'grep -q -- "--gpu 2 code memtest stress" "$NODE/fulltest.calls"' "memtest runs on the floor step"
check '[ ! -e "$GPU_BIN_DIR/SRV123/active-run" ]'              "active run cleared when finished"
check '[ "$(cat "$NODE"/pl_0 "$NODE"/pl_1 "$NODE"/pl_2 "$NODE"/pl_3 | tr "\n" " ")" = "575 575 450 140 " ]' "finish: every card back at its own default limit"
check '! grep -q "GPU-bbbb.*per-card limit" "$R"'              "5090 at 540 W gets no override (above the 450 W fleet preset)"
T1="${R%.csv}.txt"
check '[ -s "$T1" ]'                                                  "readable report written beside the CSV"
check '[ "$(grep -c "^GPU [0-9]" "$T1")" -eq 4 ] && [ "$(grep -c "^  Grade:" "$T1")" -eq 4 ]' "report has one block per card"
check '[ "$(awk "/^GPU [0-9]/{n++} END{print n}" "$T1")" -eq "$(( $(grep -c "^$" "$T1") - 1 ))" ]' "a blank line after every card block"
check 'grep -q "^  Grade:    B   Band: Grade B" "$T1" && grep -q "^  Ceiling:  100 W of 140 W (71%)   first fail 140 W" "$T1"' "report shows grade, band, ceiling and % of default"
check 'grep -q "^  Notes:    per-card limit 100W set (fleet preset 140W)$" "$T1"' "report shows the per-card limit note"
check 'grep -q "^Cards: 4   grade A: 2   grade B: 2   grade C: 0" "$T1"' "report summary counts grades"
st1="$(bash "$GB" --status 2>&1)"
check 'echo "$st1" | grep -q "Latest results:" && echo "$st1" | grep -q "^  Grade:"' "--status shows the latest report when no run is active"
R1="$R"

# ── Run 2 from a USB stick: limits recorded, not applied ────────────────────
rm -f "$NODE"/cycles "$NODE"/gpl.calls
GPU_BIN_MEDIA=usb bash "$GB" --burn-duration 1 --confirm-duration 1 >/dev/null 2>&1
GPU_BIN_MEDIA=usb bash "$GB" --resume >/dev/null 2>&1
R2="$(newest_csv)"
check '[ -n "$R2" ] && [ "$R2" != "$R1" ]'          "second run gets its own run ID and folder"
check '[ ! -f "$NODE/gpl.calls" ]'                   "USB: gpu-power-limit.sh NOT run on the stick"
H="$(ls "$(dirname "$R2")"/apply-on-host_SRV123_*.sh 2>/dev/null)"
check '[ -x "$H" ] && grep -q "gpu-power-limit.sh --gpu-limit 3:100$" "$H"' "USB: apply-on-host script written for the server OS"
check 'grep -q "index 3 = 00000000:81:00.0 NVIDIA RTX A4000 1004 GPU-dddd -> 100W" "$H"' "apply-on-host script names bus, model, serial, UUID"
check 'grep -q "GPU-dddd.*NOT applied (USB run)" "$R2"' "USB: CSV note says limit not applied"
check '[ "$(tail -n +2 "$GPU_BIN_DIR/all-results.csv" | wc -l)" -eq 8 ]' "all-results.csv collects both runs (8 rows)"

# ── Stick moved to another server mid-run ───────────────────────────────────
rm -f "$NODE"/cycles
GPU_BIN_MEDIA=usb bash "$GB" --burn-duration 1 --confirm-duration 1 >/dev/null 2>&1   # SRV123 cycles mid-run
check '[ -s "$GPU_BIN_DIR/SRV123/active-run" ]' "SRV123 has an unfinished run"
echo SRV999 > "$NODE/serial"
out="$(GPU_BIN_MEDIA=usb bash "$GB" --resume 2>&1)"; rc=$?
check '[ "$rc" -eq 0 ] && echo "$out" | grep -q "No active run for SRV999"' "other server boots the stick: SRV123 run is not resumed there"
check '[ -s "$GPU_BIN_DIR/SRV123/active-run" ]' "SRV123 run is kept for when the stick goes back"
rm -f "$NODE/serial"
GPU_BIN_MEDIA=usb bash "$GB" --reset >/dev/null 2>&1

# ── Node like BR80S5402800219: 6 fitted, 4 visible, shared-round floor failures ──
rm -rf "$GPU_BIN_DIR" "$NODE"/*
export MOCK_SHARED=1
GPU_BIN_MEDIA=host bash "$GB" --expect-gpus 6 --burn-duration 1 --confirm-duration 1 >/dev/null 2>&1
for k in 1 2 3 4 5; do
  [ -n "$(newest_csv)" ] && break
  GPU_BIN_MEDIA=host bash "$GB" --resume >/dev/null 2>&1
done
unset MOCK_SHARED
R3="$(newest_csv)"; LOG3="$(ls "$GPU_BIN_DIR"/SRV123/*/logs/gpu-bin.log | head -1)"
check '[ -n "$R3" ]'                                             "shared-failure node: run completes"
check 'grep -q "ISOLATE: GPU-aaaa" "$LOG3" && grep -q "ISOLATE: GPU-bbbb" "$LOG3" && grep -q "ISOLATE: GPU-cccc" "$LOG3"' "3 cards failing the floor together are re-tested alone"
check '! grep -q "ISOLATE: GPU-dddd" "$LOG3"'                    "the card that passed the shared round is not re-tested"
check 'grep -q "GPU-aaaa.*,C,.*also when tested alone.*,Fail$" "$R3"'     "card that drops alone too -> grade C"
check 'grep -q "GPU-bbbb.*,A,.*passed alone.*,Acceptable$" "$R3"'          "card whose memtest only failed alongside others climbs on -> Acceptable / A"
check 'grep -q "ISOLATE: GPU-bbbb.*(memtest)" "$LOG3"'                     "shared-round memtest failure is re-tested alone, not graded C"
check 'grep -q "GPU-cccc.*,C,.*also when tested alone.*,Fail$" "$R3"'     "card that fails alone too -> grade C"
check 'grep -q "GPU-dddd.*,B,.*,Grade B$" "$R3"'                          "unaffected A4000 still graded normally"
check '[ "$(grep -c "not detected .* of 2" "$R3")" -eq 2 ]'              "--expect-gpus 6 with 4 visible -> 2 not-detected rows"
check 'grep -q "not detected 1 of 2.*,C,.*6 GPUs expected / 4 visible" "$R3"' "not-detected rows are grade C with a check-hardware note"
check '[ "$(python3 -c "import csv,sys; print(sorted({len(r) for r in csv.reader(open(sys.argv[1]))}))" "$R3")" = "[19]" ] && [ "$(tail -n +2 "$R3" | wc -l)" -eq 6 ]' "all 6 rows have 19 columns"
check 'grep -q "NODE NOTE" "$LOG3"'                                       "node note about full-load power written"
check '! grep -q "HALT" "$LOG3"'                                          "floor drops do not trigger the PSU halt"
T3="${R3%.csv}.txt"
check '[ "$(grep -c "^NOT DETECTED" "$T3")" -eq 2 ] && grep -q "^NODE NOTE:" "$T3" && grep -q "grade C: 4 (incl. 2 not detected)" "$T3"' "report lists not-detected cards and the node note"
check 'grep -A1 "^  Notes:    .*alone" "$T3" | grep -q "^            NOT for client service"' "report splits several notes one per line"

# ── Two cards dropping in the same round -> halt, no power cycle ────────────
rm -f "$NODE"/cycles "$NODE"/pl_* "$NODE"/journal
MOCK_DOUBLE=1 GPU_BIN_MEDIA=host bash "$GB" --burn-duration 1 >/dev/null 2>&1; rc=$?
check '[ "$rc" -eq 3 ]'                    "double drop halts with exit 3"
check '[ ! -f "$NODE/cycles" ]'             "double drop does not power-cycle"
st="$(bash "$GB" --status 2>&1)"
check 'echo "$st" | grep -q "phase: halted"' "status shows halted"
check 'echo "$st" | grep -q "PSU/riser power suspected"' "halt note blames the shared power path"
check '[ "$(echo "$st" | grep -c " climbing ")" -eq 2 ]' "both dropped cards left climbing for a retry after the fix"
check '[ "$(echo "$st" | grep -c " done ")" -eq 2 ]'     "other cards' results from the halted round are kept"
check '[ "$(cat "$NODE"/pl_2 "$NODE"/pl_3 | tr "\n" " ")" = "450 140 " ]' "halt: surviving cards back at their own default limit"

exit "$fail"
