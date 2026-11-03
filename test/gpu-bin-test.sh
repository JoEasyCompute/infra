#!/usr/bin/env bash
# Mocked end-to-end test for test/gpu-bin.sh — no GPUs, BMC or systemd needed.
#
# Node: GPU0 RTX 5090 (healthy), GPU1 RTX 5090 (falls off the bus at 550 W),
#       GPU2 RTX 4090 (fails stress at 450 W).
# Expect: one cold power cycle, then
#   GPU0 Default/A (575 W), GPU1 Acceptable/A (540 W), GPU2 Grade B/B (300 W).
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS="$(mktemp -d /tmp/gpu-bin-test.XXXX)"
trap 'rm -rf "$WS"' EXIT
M="$WS/mock"; mkdir -p "$M" "$WS/node"
export NODE="$WS/node"

cat > "$M/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
uuids=(GPU-aaaa GPU-bbbb GPU-cccc)
case "$*" in
  *--query-gpu=uuid,serial*)
    echo "GPU-aaaa, 1001, 00000000:25:00.0, NVIDIA GeForce RTX 5090, 575.00, 400.00, 600.00"
    echo "GPU-bbbb, 1002, 00000000:41:00.0, NVIDIA GeForce RTX 5090, 575.00, 400.00, 600.00"
    echo "GPU-cccc, 1003, 00000000:61:00.0, NVIDIA GeForce RTX 4090, 450.00, 150.00, 600.00" ;;
  *--query-gpu=index,uuid*)
    for i in 0 1 2; do [ -f "$NODE/dropped_$i" ] || echo "$i, ${uuids[$i]}"; done ;;
  *--query-compute-apps*) : ;;
  -L) echo "GPU 0: mock" ;;
  *-pl*) set -- $*; [ -f "$NODE/dropped_$2" ] && exit 15; echo "$4" > "$NODE/pl_$2" ;;
  *-q*) set -- $*; [ -f "$NODE/dropped_$2" ] && exit 15; exit 0 ;;
esac
EOF

cat > "$M/fulltest.sh" <<'EOF'
#!/usr/bin/env bash
gpu="$2"
echo "args: $*" >> "$NODE/fulltest.calls"
case "$gpu" in *,*) echo "[ PASS ] confirm"; exit 0 ;; esac
pl="$(cat "$NODE/pl_$gpu")"
if [ -n "${MOCK_DOUBLE:-}" ] && [ "$gpu" != 2 ] && [ "$pl" -ge 500 ]; then
  touch "$NODE/dropped_$gpu"
  echo "NVRM: Xid (PCI:0000:$([ "$gpu" = 0 ] && echo 25 || echo 41):00): 79, pid=1, GPU has fallen off the bus." >> "$NODE/journal"
  exit 1
fi
if [ "$gpu" = 1 ] && [ "$pl" -ge 550 ]; then
  touch "$NODE/dropped_1"
  echo "NVRM: Xid (PCI:0000:41:00): 79, pid=1234, GPU has fallen off the bus." >> "$NODE/journal"
  echo "[ FAIL ] CUDA Int32 Compute Stress (code.cu) (exit code 1)"; exit 1
fi
if [ "$gpu" = 2 ] && [ "$pl" -ge 450 ]; then
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
chmod +x "$M"/*

export GPU_BIN_DIR="$WS/bin" FULLTEST="$M/fulltest.sh" NVIDIA_SMI="$M/nvidia-smi" \
       IPMITOOL="$M/ipmitool" JOURNALCTL="$M/journalctl" SYSTEMCTL="$M/systemctl" \
       POLL_SECONDS=0 STAGGER_SECONDS=0 GPU_BIN_NO_UNIT=1 GPU_BIN_ALLOW_NONROOT=1

fail=0
check() { if eval "$1"; then echo "ok   - $2"; else echo "FAIL - $2"; fail=1; fi; }

# Ladders from --dry-run
dry="$(bash "$ROOT_DIR/test/gpu-bin.sh" --dry-run 2>&1)"
check 'echo "$dry" | grep -q "steps: 450,500,540,550,575$"' "5090 ladder stops at card default 575"
check 'echo "$dry" | grep -q "steps: 300,450$"'             "4090 ladder is 300,450"

# First boot: runs until GPU1 drops at 550 W and the node power-cycles
bash "$ROOT_DIR/test/gpu-bin.sh" --burn-duration 1 --confirm-duration 1 >/dev/null 2>&1
check '[ "$(wc -l < "$NODE/cycles")" -eq 1 ]' "exactly one power cycle after the drop"
check '[ ! -f "$GPU_BIN_DIR/results.csv" ]'    "no results before resume"

# After "boot": resume service continues the run
bash "$ROOT_DIR/test/gpu-bin.sh" --resume >/dev/null 2>&1
R="$GPU_BIN_DIR/results.csv"
check '[ -f "$R" ]' "results.csv written after resume"
check 'grep -q "GPU-aaaa.*,575,575,,Default,A,done" "$R"'           "GPU0 healthy 5090 -> Default / A at 575 W"
check 'grep -q "GPU-bbbb.*,\"\",575,540,550,Acceptable,A,dropped,\"fell off bus" "$R"' "GPU1 dropped at 550 -> Acceptable / A at 540 W"
check 'grep -q "GPU-cccc.*,\"Sustained Compute Stress\",450,300,450,Grade B,B,done" "$R"'    "GPU2 4090 fails 450 -> Grade B / B at 300 W"
check '[ "$(wc -l < "$NODE/cycles")" -eq 1 ]'               "no further power cycles"
check 'grep -q -- "--gpu 0,1,2 stress" "$NODE/fulltest.calls"' "all-GPU confirm burn ran"
check 'grep -q -- "--gpu 2 code memtest stress" "$NODE/fulltest.calls"' "memtest runs on the floor step"
out="$(bash "$ROOT_DIR/test/gpu-bin.sh" 2>&1)"
check 'echo "$out" | grep -q "already complete"'            "completed run is not restarted"

# Two cards dropping in the same round -> halt for a PSU check, no power cycle
rm -rf "$GPU_BIN_DIR" "$NODE"/*
MOCK_DOUBLE=1 bash "$ROOT_DIR/test/gpu-bin.sh" --burn-duration 1 >/dev/null 2>&1; rc=$?
check '[ "$rc" -eq 3 ]'                    "double drop halts with exit 3"
check '[ ! -f "$NODE/cycles" ]'             "double drop does not power-cycle"
st="$(bash "$ROOT_DIR/test/gpu-bin.sh" --status 2>&1)"
check 'echo "$st" | grep -q "Phase: halted"' "status shows halted"
check 'echo "$st" | grep -q "PSU/riser power suspected"' "halt note blames the shared power path"
check 'echo "$st" | grep -c "climbing" | grep -q 2' "both cards left climbing for a retry after the fix"

exit "$fail"
