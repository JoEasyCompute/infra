#!/usr/bin/env bash
# NVIDIA-only GPU ↔ PCIe Slot inventory (no NVIDIA tools). Upstream-aware, aligned output.
# Deps: bash, lspci (pciutils), awk, sed, grep, cut, tr, column, readlink
set -euo pipefail

have(){ command -v "$1" >/dev/null 2>&1; }
require(){ for c in "$@"; do have "$c" || { echo "ERROR: missing dependency: $c" >&2; exit 1; }; done; }
require lspci awk sed grep cut tr column readlink

DEBUG="${DEBUG:-0}"; [[ "${1:-}" == "--debug" ]] && DEBUG=1
logd(){ [[ "$DEBUG" == "1" ]] && echo "[DEBUG] $*" >&2 || true; }

trim(){ local s="${1:-}"; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }
read_attr(){ [[ -r "$1" ]] && tr -d '\n' < "$1" || true; }
clip(){ local s="$1" w="$2"; local l="${#s}"; (( l<=w )) && { echo -n "$s"; } || echo -n "${s:0:w-1}…"; }

# --- lspci helpers ---
lspci_vmm_field(){ local addr="$1" key="$2"; lspci -vmm -s "$addr" 2>/dev/null | sed -n "s/^${key}:[[:space:]]*//p" | head -n1; }

# --- Model (SVendor+SDevice → Subsystem → Vendor+Device) ---
get_model(){
  local addr="$1" sv sd vv dd subsys
  sv="$(trim "$(lspci_vmm_field "$addr" SVendor || true)")"
  sd="$(trim "$(lspci_vmm_field "$addr" SDevice || true)")"
  [[ -n "$sv" && -n "$sd" ]] && { echo "$sv $sd"; return; }
  subsys="$(lspci -s "$addr" -vv 2>/dev/null | sed -n 's/^[[:space:]]*Subsystem:[[:space:]]*//p' | head -n1)"
  subsys="$(trim "$subsys")"; [[ -n "$subsys" ]] && { echo "$subsys"; return; }
  vv="$(trim "$(lspci_vmm_field "$addr" Vendor || true)")"
  dd="$(trim "$(lspci_vmm_field "$addr" Device || true)")"
  [[ -n "$vv" && -n "$dd" ]] && { echo "$vv $dd"; return; }
  echo "-"
}

# --- Class / IDs / NUMA ---
get_class(){ case "$(cat "/sys/bus/pci/devices/$1/class" 2>/dev/null || echo "")" in
  0x030000) echo "VGA";; 0x030200) echo "3D";; *) echo "?";; esac; }
get_ids(){ echo "$(cat "/sys/bus/pci/devices/$1/vendor" 2>/dev/null || echo "")/$(cat "/sys/bus/pci/devices/$1/device" 2>/dev/null || echo "")"; }

cpu_to_node(){ local cpu="$1"; local p="/sys/devices/system/cpu/cpu${cpu}"; local n; n="$(readlink -f "$p"/node* 2>/dev/null || true)"; [[ -n "$n" ]] && basename "$n" | sed 's/^node//' || echo "-1"; }
get_numa(){
  local addr="$1" n
  n="$(cat "/sys/bus/pci/devices/$addr/numa_node" 2>/dev/null || echo "-1")"
  [[ "$n" != "-1" ]] && { echo "$n"; return; }
  local cpus; cpus="$(cat "/sys/bus/pci/devices/$addr/local_cpulist" 2>/dev/null || echo "")"
  if [[ -n "$cpus" ]]; then local first="${cpus%%,*}"; first="${first%%-*}"; local node; node="$(cpu_to_node "$first")"; [[ "$node" != "-1" ]] && { echo "$node"; return; }; fi
  echo "-"
}

# --- Link info (handles "16GT/s" and "16.0 GT/s PCIe") ---
extract_gts(){ echo "${1:-}" | sed -n 's/.*Speed[[:space:]]*\([0-9.][0-9.]*\)[[:space:]]*GT\/s.*/\1/p'; }
normalize_speed(){ local n="$1"; [[ -n "$n" ]] && echo "${n} GT/s" || echo ""; }
speed_to_gen(){ case "$1" in
  2.5\ GT/s) echo "Gen1";; 5.0\ GT/s|5\ GT/s) echo "Gen2";; 8.0\ GT/s|8\ GT/s) echo "Gen3";;
  16.0\ GT/s|16\ GT/s) echo "Gen4";; 32.0\ GT/s|32\ GT/s) echo "Gen5";; 64.0\ GT/s|64\ GT/s) echo "Gen6";; *) echo "";; esac; }

read_link_sysfs(){
  local addr="$1" dev="/sys/bus/pci/devices/$addr" cw mw cs ms cg="" mg="" sp=""
  cw="$(read_attr "$dev/current_link_width")"
  mw="$(read_attr "$dev/max_link_width")"
  cs="$(normalize_speed "$(extract_gts "Speed $(read_attr "$dev/current_link_speed")")")"
  ms="$(normalize_speed "$(extract_gts "Speed $(read_attr "$dev/max_link_speed")")")"
  [[ -n "$cs" ]] && cg="$(speed_to_gen "$cs")" && sp="$cs"
  [[ -n "$ms" ]] && mg="$(speed_to_gen "$ms")"
  echo "${cg} ${cw} ${mg} ${mw} ${sp}"
}
read_link_lspci(){
  local addr="$1" vv cap sta cw mw cg mg sp
  vv="$(lspci -s "$addr" -vv 2>/dev/null || true)"
  sta="$(grep -m1 -E "LnkSta:.*Speed[[:space:]]*[0-9.]*[[:space:]]*GT/s,.*Width x[0-9]+" <<<"$vv" || true)"
  cap="$(grep -m1 -E "LnkCap:.*Speed[[:space:]]*[0-9.]*[[:space:]]*GT/s,.*Width x[0-9]+" <<<"$vv" || true)"
  [[ -n "$sta" ]] && { sp="$(normalize_speed "$(extract_gts "$sta")")"; cw="$(sed -n 's/.*Width x\([0-9]\+\).*/\1/p' <<<"$sta")"; cg="$(speed_to_gen "$sp")"; }
  [[ -n "$cap" ]] && { mw="$(sed -n 's/.*Width x\([0-9]\+\).*/\1/p' <<<"$cap")"; local cps; cps="$(normalize_speed "$(extract_gts "$cap")")"; mg="$(speed_to_gen "$cps")"; }
  echo "${cg:-} ${cw:-} ${mg:-} ${mw:-} ${sp:-}"
}
link_ok(){ local cg="$1" cw="$2" sp="$5"; [[ -n "$cg" || -n "$cw" || -n "$sp" ]] && [[ "$sp" != "0 GT/s" ]]; }

get_link_info(){
  local addr="$1" path p cg cw mg mw sp
  path="$(readlink -f "/sys/bus/pci/devices/$addr")" || { echo "? ? ? ? ?"; return; }
  while :; do
    p="$(basename "$path")"
    if [[ "$p" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]]; then
      read -r cg cw mg mw sp <<<"$(read_link_sysfs "$p")"
      if link_ok "$cg" "$cw" "$mg" "$mw" "$sp"; then echo "${cg:-?} ${cw:-?} ${mg:-?} ${mw:-?} ${sp:-?}"; return; fi
      read -r cg cw mg mw sp <<<"$(read_link_lspci "$p")"
      if link_ok "$cg" "$cw" "$mg" "$mw" "$sp"; then echo "${cg:-?} ${cw:-?} ${mg:-?} ${mw:-?} ${sp:-?}"; return; fi
    fi
    local next; next="$(readlink -f "$path/..")" || break
    [[ "$next" == "$path" ]] && break
    path="$next"
  done
  echo "? ? ? ? ?"
}

# --- Physical Slot fallback ---
get_physical_slot_via_lspci(){ lspci -s "$1" -vv 2>/dev/null | sed -n 's/.*Physical Slot:[[:space:]]*//p' | head -n1; }

# --- SMBIOS upstream map (addr → slot) ---
declare -A SLOT_BY_UPSTREAM
if have dmidecode; then
  [[ "$(id -u)" -ne 0 ]] && echo "WARN: run as root for full SMBIOS visibility." >&2
  while IFS= read -r line; do
    addr="${line%% *}"; slot="${line#* }"; addr="$(echo "$addr" | tr 'A-Z' 'a-z')"
    [[ "$addr" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ && -n "$slot" ]] && { SLOT_BY_UPSTREAM["$addr"]="$slot"; logd "SMBIOS map: $addr -> $slot"; }
  done < <( dmidecode -t slot 2>/dev/null | awk '
      BEGIN{ slot=""; addr="" }
      function emit(){ if(slot!="" && addr!=""){ printf "%s %s\n", tolower(addr), slot } slot=""; addr="" }
      {
        if ($0 ~ /^$/){ emit(); next }
        if ($0 ~ /Designation:/){ sub(/^[[:space:]]*Designation:[[:space:]]*/,""); slot=$0 }
        else if ($0 ~ /Bus Address:/){ sub(/^[[:space:]]*Bus Address:[[:space:]]*/,""); addr=$0 }
      }
      END{ emit() }' )
fi
nearest_slot_for(){
  local addr="$1" path p
  path="$(readlink -f "/sys/bus/pci/devices/$addr")" || { echo ""; return; }
  while :; do
    p="$(basename "$path")"
    if [[ "$p" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] && [[ -n "${SLOT_BY_UPSTREAM[$p]:-}" ]]; then echo "${SLOT_BY_UPSTREAM[$p]}"; return; fi
    local next; next="$(readlink -f "$path/..")" || break
    [[ "$next" == "$path" ]] && break
    path="$next"
  done
  echo ""
}

# --- Enumerate NVIDIA GPUs only (class 0300/0302 AND vendor 0x10de) ---
gpu_addrs=()
for d in /sys/bus/pci/devices/*; do
  [[ -e "$d/class" && -e "$d/vendor" ]] || continue
  cls="$(cat "$d/class")"; ven="$(cat "$d/vendor")"
  [[ ( "$cls" == "0x030000" || "$cls" == "0x030200" ) && "$ven" == "0x10de" ]] && gpu_addrs+=("$(basename "$d")")
done
[[ ${#gpu_addrs[@]} -eq 0 ]] && { echo "No NVIDIA GPU-class PCI devices found." >&2; exit 0; }

csv_file="${1:-}"

# CSV Header
if [[ -n "$csv_file" ]]; then
  echo "GPU#,PCI-ADDR,SLOT,MODEL,PCI-IDS,CLASS,CUR_GEN/x,MAX_GEN/x,CUR_SPEED,NUMA" > "$csv_file"
fi

header_fmt="%-4s %-12s %-30s %-46s %-14s %-6s %-9s %-9s %-10s %-4s\n"
line_fmt="%-4s %-12s %-30s %-46s %-14s %-6s %-9s %-9s %-10s %-4s\n"

printf "$header_fmt" "GPU#" "PCI-ADDR" "SLOT" "MODEL" "PCI-IDS" "CLASS" "CUR_GEN/x" "MAX_GEN/x" "CUR_SPEED" "NUMA"
printf "%s\n" "--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"

lines_file=$(mktemp)
for addr in "${gpu_addrs[@]}"; do
  model="$(get_model "$addr")"; [[ -z "$model" ]] && model="-"
  class="$(get_class "$addr")"
  ids="$(get_ids "$addr")"
  read -r cur_gen cur_w max_gen max_w speed_gts <<<"$(get_link_info "$addr")"
  numa="$(get_numa "$addr")"

  slot=""; [[ "${#SLOT_BY_UPSTREAM[@]}" -gt 0 ]] && slot="$(nearest_slot_for "$addr" || true)"
  [[ -z "$slot" ]] && slot="$(get_physical_slot_via_lspci "$addr")"
  [[ -z "$slot" ]] && slot="-"

  degrade=""
  if [[ "$cur_w" =~ ^[0-9]+$ && "$max_w" =~ ^[0-9]+$ && "$cur_w" -lt "$max_w" ]]; then degrade="(WIDTH↓)"; fi
  if [[ "$cur_gen" =~ ^Gen([0-9]+)$ && "$max_gen" =~ ^Gen([0-9]+)$ && "${BASH_REMATCH[1]}" -lt "${max_gen#Gen}" ]]; then degrade="${degrade:+$degrade }(GEN↓)"; fi

  # Write all fields as a tab-separated line for sorting
  echo -e "$addr\t$slot\t$(clip "$model" 46)\t$ids\t$class\t${cur_gen:-?}/${cur_w:-?}${degrade:+*}\t${max_gen:-?}/${max_w:-?}\t${speed_gts:-?}\t${numa:-?}" >> "$lines_file"
done

gpu_idx=0
while IFS=$'\t' read -r addr slot model ids class cur max speed numa; do
  printf "$line_fmt" "$gpu_idx" "$addr" "$slot" "$model" "$ids" "$class" "$cur" "$max" "$speed" "$numa"
  if [[ -n "$csv_file" ]]; then
    echo "\"$gpu_idx\",\"$addr\",\"$slot\",\"$model\",\"$ids\",\"$class\",\"$cur\",\"$max\",\"$speed\",\"$numa\"" >> "$csv_file"
  fi
  ((gpu_idx++))
done < <(sort -t$'\t' -k2,2V "$lines_file")

rm -f "$lines_file"

if [[ "$DEBUG" == "1" ]]; then
  echo -e "\n[DEBUG] First GPU chain (endpoint → root):" >&2
  p="$(readlink -f "/sys/bus/pci/devices/${gpu_addrs[0]}")"; while :; do b="$(basename "$p")"; echo "  $b"; n="$(readlink -f "$p/..")" || break; [[ "$n" == "$p" ]] && break; p="$n"; done >&2
fi
