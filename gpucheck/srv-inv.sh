#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# srv-inv.sh — Ubuntu Hardware & Config Inventory
#
# Default output: JSON (full system, CPU, RAM, GPU, Storage, Network)
#
# USAGE:
#   ./srv-inv.sh [options]
#
# OPTIONS:
#   --json             Output JSON (default)
#   --table | -t       Output human-readable tables
#   -o FILE            Write output to FILE instead of stdout
#   --csv "dom=file"   Export specific domains to CSV. Multiple allowed.
#                      Example: --csv "cpu=cpu.csv,ram=ram.csv,gpu=gpu.csv"
#   --all-csv DIR      Export all domains (cpu, ram, gpu, storage, network) as CSV into DIR
#   --no-gpu           Skip GPU detection (faster on systems without NVIDIA GPUs)
#   --debug            Verbose debug logging to stderr
#   --version          Print version string
#   -h, --help         Show this help header
#
# EXAMPLES:
#   # Full JSON inventory to stdout
#   sudo ./srv-inv.sh
#
#   # Human-readable tables
#   sudo ./srv-inv.sh --table
#
#   # Save JSON to file
#   sudo ./srv-inv.sh --json -o /tmp/inventory.json
#
#   # Export CPU and RAM info to CSVs
#   sudo ./srv-inv.sh --csv "cpu=/tmp/cpu.csv,ram=/tmp/ram.csv"
#
#   # Export all domains to CSV directory
#   sudo ./srv-inv.sh --all-csv /tmp/inv-csv
#
# NOTES:
#   * Run as root (sudo) for full details — especially CPU serials, RAM details, PCIe slot mapping.
#   * Without root, you still get partial info (CPU model, GPUs via lspci, etc.).
#   * GPU section requires `nvidia-smi` for full details (otherwise falls back to lspci).
# -----------------------------------------------------------------------------

set -euo pipefail
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi

VERSION="1.6.2"
FORMAT="json"
OUTFILE=""
CSV_SPEC=""
CSV_DIR=""
DEBUG="${DEBUG:-0}"
NO_GPU=0

have(){ command -v "$1" >/dev/null 2>&1; }
need(){ local m=0; for c in "$@"; do have "$c" || { echo "ERROR: missing dependency: $c" >&2; m=1; }; done; return $m; }
log(){ [ "$DEBUG" = "1" ] && echo "[DBG] $*" >&2 || true; }

CORE_DEPS=(jq lsblk ip lspci)
if ! need "${CORE_DEPS[@]}"; then
  echo "Hint: sudo apt-get update && sudo apt-get install -y jq pciutils iproute2 util-linux" >&2
  exit 1
fi

SUDO="sudo -n"; if [ "${EUID:-$(id -u)}" -eq 0 ]; then SUDO=""; fi
# TIMEOUT helper — 3s soft, 2s kill. If 'timeout' absent, return failure to avoid hangs
TIMEOUT(){ if command -v timeout >/dev/null 2>&1; then timeout -k 2 3 "$@"; else return 124; fi; }

# ---------- CLI ----------
while (($#)); do
  case "$1" in
    --table|-t) FORMAT="table"; shift;;
    --json)     FORMAT="json"; shift;;
    -o|--out)   OUTFILE="${2:-}"; shift 2;;
    --csv)      CSV_SPEC="${2:-}"; shift 2;;
    --all-csv)  CSV_DIR="${2:-}"; shift 2;;
    --no-gpu)   NO_GPU=1; shift;;
    --debug)    DEBUG="1"; shift;;
    --version)  echo "$VERSION"; exit 0;;
    -h|--help)  sed -n '1,220p' "$0"; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

# ---------- Collectors (TSV → jq) ----------
collect_system(){
  log "collect_system"
  local now host os kern virt
  now=$(date -Is)
  host=$(hostname 2>/dev/null || echo "")
  if have hostnamectl; then
    os=$(hostnamectl 2>/dev/null | awk -F': ' '/Operating System/{print $2}')
    kern=$(uname -r)
    virt=$(hostnamectl 2>/dev/null | awk -F': ' '/Virtualization/{print $2}')
  else
    os=$(grep -m1 PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
    kern=$(uname -r)
    virt=""
  fi
  jq -n --arg time "$now" --arg host "$host" --arg os "$os" --arg kern "$kern" --arg virt "$virt" \
     '{timestamp:$time, hostname:$host, os:$os, kernel:$kern, virtualization: (($virt|select(length>0)) // null)}'
}

collect_cpu(){
  log "collect_cpu"
  if have dmidecode && $SUDO TIMEOUT dmidecode -t processor >/dev/null 2>&1; then
    $SUDO TIMEOUT dmidecode -t processor 2>/dev/null | awk 'BEGIN{RS="\n\n"; FS="\n"}
      /Processor Information/ {
        sok=mfg=ver=id=serial=core=thr="";
        for(i=1;i<=NF;i++){
          if($i~/(Socket Designation:)/) sok=substr($i,index($i,": ")+2);
          if($i~/(Manufacturer:)/)       mfg=substr($i,index($i,": ")+2);
          if($i~/(Version:)/)            ver=substr($i,index($i,": ")+2);
          if($i~/(ID:)/)                 id =substr($i,index($i,": ")+2);
          if($i~/(Serial Number:)/)      serial=substr($i,index($i,": ")+2);
          if($i~/(Core Count:)/)         core=substr($i,index($i,": ")+2);
          if($i~/(Thread Count:)/)       thr =substr($i,index($i,": ")+2);
        }
        printf("%s\t%s\t%s\t%s\t%s\t%s\t%s\n", sok,mfg,ver,id,serial,core,thr);
      }' | jq -R -s '
        split("\n") | map(select(length>0))
        | map(split("\t"))
        | map({socket:.[0], manufacturer:.[1], model:.[2], id:.[3], serial:.[4],
               cores:(.[5]|tonumber?), threads:(.[6]|tonumber?)})'
  else
    lscpu | awk -F': *' '/Model name/{print $2; exit}' |
      jq -R -s 'map(select(length>0)) | map({model:., note:"Serials require dmidecode (sudo)."})'
  fi
}

collect_ram(){
  log "collect_ram"
  if have dmidecode && $SUDO TIMEOUT dmidecode -t memory >/dev/null 2>&1; then
    $SUDO TIMEOUT dmidecode -t memory 2>/dev/null | awk 'BEGIN{RS="\n\n"; FS="\n"}
      /Memory Device/ {
        size=type=speed=cfg=mfg=part=serial=locator=bank="";
        for(i=1;i<=NF;i++){
          if($i~/(Size:)/)                    size=substr($i,index($i,": ")+2);
          if($i~/(Type:)/)                    type=substr($i,index($i,": ")+2);
          if($i~/(Speed:)/)                   speed=substr($i,index($i,": ")+2);
          if($i~/(Configured Memory Speed:)/) cfg =substr($i,index($i,": ")+2);
          if($i~/(Manufacturer:)/)            mfg  =substr($i,index($i,": ")+2);
          if($i~/(Part Number:)/)             part =substr($i,index($i,": ")+2);
          if($i~/(Serial Number:)/)           serial=substr($i,index($i,": ")+2);
          if($i~/(Locator:)/)                 locator=substr($i,index($i,": ")+2);
          if($i~/(Bank Locator:)/)            bank=substr($i,index($i,": ")+2);
        }
        if(size!="No Module Installed"){
          printf("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", locator,bank,size,type,speed,cfg,mfg,part,serial);
        }
      }' | jq -R -s '
        split("\n") | map(select(length>0))
        | map(split("\t"))
        | map({locator:.[0], bank:.[1], size:.[2], type:.[3], speed:.[4],
               cfg_speed:.[5], manufacturer:.[6], part:.[7], serial:.[8]})'
  else
    jq -n '[]'
  fi
}

# ---------- PCIe helpers: slots & link info (upstream-aware) ----------
read_attr(){ [[ -r "$1" ]] && tr -d '\n' < "$1" || true; }

# lspci Physical Slot fallback
get_physical_slot_via_lspci(){ lspci -s "$1" -vv 2>/dev/null | sed -n 's/.*Physical Slot:[[:space:]]*//p' | head -n1; }

# SMBIOS slotmap (BDF -> Designation)
build_smbios_slotmap(){
  if have dmidecode && $SUDO TIMEOUT dmidecode -t slot >/dev/null 2>&1; then
    $SUDO TIMEOUT dmidecode -t slot 2>/dev/null | awk 'BEGIN{RS="\n\n"; FS="\n"}
      /System Slot Information/ {
        slot=""; bus="";
        for(i=1;i<=NF;i++){
          if($i~/(Designation:)/)   { slot=substr($i,index($i,": ")+2) }
          if($i~/(Bus Address:)/)   { bus =substr($i,index($i,": ")+2) }
        }
        if(bus!=""){
          gsub(/[ \t]/,"",bus); tolower(bus);
          if (bus !~ /^0000:/) bus="0000:" bus
          printf("%s\t%s\n", bus, slot);
        }
      }' | jq -R -s '
        split("\n") | map(select(length>0))
        | map(split("\t") | { (.[0]|ascii_downcase): .[1] }) | add'
  else
    jq -n '{}'
  fi
}

# Find nearest upstream BDF (bridge/root) from a given device BDF
nearest_slot_for_bdf(){
  local bdf="$1" p path
  path="$(readlink -f "/sys/bus/pci/devices/$bdf")" || { echo ""; return; }
  while :; do
    p="$(basename "$path")"
    if [[ "$p" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]]; then echo "$p"; return; fi
    local next; next="$(readlink -f "$path/..")" || break
    [[ "$next" == "$path" ]] && break
    path="$next"
  done
  echo ""
}

# PCIe link characterization helpers
extract_gts(){ echo "${1:-}" | sed -n 's/.*Speed[[:space:]]*\([0-9.][0-9.]*\)[[:space:]]*GT\/s.*/\1/p'; }
normalize_speed(){ local n="$1"; [[ -n "$n" ]] && echo "${n} GT/s" || echo ""; }
speed_to_gen(){ case "$1" in
  2.5\ GT/s) echo "Gen1";; 5.0\ GT/s|5\ GT/s) echo "Gen2";; 8.0\ GT/s|8\ GT/s) echo "Gen3";;
  16.0\ GT/s|16\ GT/s) echo "Gen4";; 32.0\ GT/s|32\ GT/s) echo "Gen5";; 64.0\ GT/s|64\ GT/s) echo "Gen6";; *) echo "";; esac; }
read_link_sysfs(){
  local addr="$1" dev="/sys/bus/pci/devices/$addr" cw mw cs ms cg="" mg="" sp=""
  cw="$(read_attr "$dev/current_link_width")"; mw="$(read_attr "$dev/max_link_width")"
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

# ---------- GPU Collector (with upstream-aware slot + link info) ----------
collect_gpu(){
  log "collect_gpu"
  [[ "$NO_GPU" = "1" ]] && { echo '[]'; return; }

  local smbios_map; smbios_map="$(build_smbios_slotmap)"

  if have nvidia-smi && TIMEOUT nvidia-smi -L >/dev/null 2>&1; then
    TIMEOUT nvidia-smi --query-gpu=index,name,serial,bus_id,vbios_version,temperature.gpu,power.draw,power.limit,driver_version \
      --format=csv,noheader,nounits 2>/dev/null \
    | awk -F', *' 'NF>=9{ s=$3; if(s=="N/A"||s=="") s=$4; gsub(/00000000:/,"",$4); tolower($4); printf("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",$1,$2,s,$4,$5,$6,$7,$8,$9); }' \
    | while IFS=$'\t' read -r idx name serial bus vbios temp pwr_draw pwr_lim driver; do
        up="$(nearest_slot_for_bdf "$bus")"
        slot="$(printf '%s\n' "$smbios_map" | jq -r --arg k "${up,,}" ' .[$k] // empty ')"
        [[ -z "$slot" ]] && slot="$(get_physical_slot_via_lspci "$bus")"
        [[ -z "$slot" ]] && slot="-"
        read -r cg cw mg mw sp <<<"$(get_link_info "$bus")"
        # 14 fields
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
               "$idx" "$name" "${serial:-}" "$bus" "$slot" "${cg:-}" "${cw:-}" "${mg:-}" "${mw:-}" "${sp:-}" "${vbios:-}" "${temp:-?}" "${pwr_draw:-?}" "${pwr_lim:-?}" "${driver:-?}"
      done \
    | jq -R -s '
        split("\n") | map(select(length>0)) | map(split("\t"))
        | map({
            index:    (.[0]|tonumber?),
            name:      .[1],
            serial:   (.[2]|select(.!="") // null),
            bus_id:    .[3],
            slot:      .[4],
            cur_gen:  (.[5]|select(.!="?" and .!="") // null),
            cur_width:(.[6]|select(.!="?" and .!="") // null),
            max_gen:  (.[7]|select(.!="?" and .!="") // null),
            max_width:(.[8]|select(.!="?" and .!="") // null),
            cur_speed:(.[9]|select(.!="?" and .!="") // null),
            vbios:     .[10],
            temp_c:   (.[11]|tonumber?),
            power_draw_w: (.[12]|tonumber?),
            power_limit_w: (.[13]|tonumber?),
            driver:    .[14]
          })'
  else
    lspci -Dnn | awk '/ (VGA|3D) .*NVIDIA/ {print $1"|"$0}' \
    | awk -F'[|]' '{b=$1; sub(/^.*: /,"",$2); tolower(b); printf("%s\t%s\n", b, $2);}' \
    | while IFS=$'\t' read -r bus name; do
        up="$(nearest_slot_for_bdf "$bus")"
        slot="$(printf '%s\n' "$smbios_map" | jq -r --arg k "${up,,}" ' .[$k] // empty ')"
        [[ -z "$slot" ]] && slot="$(get_physical_slot_via_lspci "$bus")"
        [[ -z "$slot" ]] && slot="-"
        read -r cg cw mg mw sp <<<"$(get_link_info "$bus")"
        # For lspci fallback, we don't have temp/power/driver easily
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
               "$bus" "$name" "$slot" "${cg:-}" "${cw:-}" "${mg:-}" "${mw:-}" "${sp:-}"
      done \
    | jq -R -s '
        split("\n") | map(select(length>0)) | map(split("\t"))
        | map({
            bus_id:    .[0],
            name:      .[1],
            slot:      .[2],
            cur_gen:  (.[3]|select(.!="?" and .!="") // null),
            cur_width:(.[4]|select(.!="?" and .!="") // null),
            max_gen:  (.[5]|select(.!="?" and .!="") // null),
            max_width:(.[6]|select(.!="?" and .!="") // null),
            cur_speed:(.[7]|select(.!="?" and .!="") // null)
          })'
  fi
}

collect_storage(){ log "collect_storage"; lsblk -J -O -e7 | jq '{blockdevices: .blockdevices}'; }

collect_network(){
  log "collect_network"
  local lhw ipj
  if have lshw && $SUDO TIMEOUT lshw -short >/dev/null 2>&1; then
    lhw=$($SUDO TIMEOUT lshw -json -class network 2>/dev/null || echo '[]')
  else
    lhw='[]'
  fi
  ipj=$(ip -j addr 2>/dev/null || echo '[]')
  printf '%s\n' "$lhw" | jq --argjson ip "$ipj" '
    def addr_for($name): ($ip[]? | select(.ifname==$name) | {mtu, operstate, addr_info}) // {};
    ( . // [] ) | map({ product, vendor, serial, businfo, logicalname, configuration, capabilities } + (addr_for(.logicalname)))'
}

# ---------- Tables ----------
border(){ printf '%*s\n' "${1:-80}" '' | tr ' ' '-'; }
print_table_cpu(){ jq -r '"SOCKET\tMODEL\tSERIAL\tCORES\tTHREADS", (.[]? | [(.socket//""),(.model//""),(.serial//""),(.cores//""),(.threads//"")] | @tsv)'; }
print_table_ram(){ jq -r '"LOCATOR\tBANK\tSIZE\tTYPE\tSPEED\tCFG_SPEED\tMFG\tPART\tSERIAL", (.[]? | [(.locator//""),(.bank//""),(.size//""),(.type//""),(.speed//""),(.cfg_speed//""),(.manufacturer//""),(.part//""),(.serial//"")] | @tsv)'; }
print_table_gpu(){ jq -r '"INDEX\tNAME\tSERIAL\tBUS_ID\tSLOT\tCUR_GEN/x\tMAX_GEN/x\tCUR_SPEED\tTEMP\tPWR(D/L)\tVBIOS\tDRIVER", (.[]? | [(.index//""),(.name//""),(.serial//""),(.bus_id//""),(.slot//""),(((.cur_gen//"?")+"/"+(.cur_width//"?"))),(((.max_gen//"?")+"/"+(.max_width//"?"))),(.cur_speed//""),((.temp_c|tostring)+"C"),((.power_draw_w|tostring)+"/"+(.power_limit_w|tostring)+"W"),(.vbios//""),(.driver//"")] | @tsv)'; }
print_table_storage(){ jq -r '"NAME\tTYPE\tSIZE\tMODEL\tSERIAL\tMOUNT\tFSTYPE\tPKNAME", (.blockdevices[]? | [(.name//""),(.type//""),(.size//""),(.model//""),(.serial//""),(.mountpoint//""),(.fstype//""),(.pkname//"")] | @tsv)'; }
print_table_network(){ jq -r '"IFACE\tPRODUCT\tVENDOR\tSERIAL/MAC\tBUS\tSTATE\tMTU\tADDRS", (.[]? | [(.logicalname//""),(.product//""),(.vendor//""),(.serial//""),(.businfo//""),(.operstate//""),(.mtu//""), ((.addr_info//[])|map(.local)|join(","))] | @tsv)'; }

# ---------- CSV ----------
csv_emit(){
  local domain="$1" json="$2" path="$3"
  mkdir -p "$(dirname -- "$path")" 2>/dev/null || true
  case "$domain" in
    cpu)     printf '%s\n' "$json" | jq -r '(["socket","model","serial","cores","threads"]|@csv), (.[]? | [.socket,.model,.serial,.cores,.threads] | @csv)' >"$path" ;;
    ram)     printf '%s\n' "$json" | jq -r '(["locator","bank","size","type","speed","cfg_speed","manufacturer","part","serial"]|@csv), (.[]? | [.locator,.bank,.size,.type,.speed,.cfg_speed,.manufacturer,.part,.serial] | @csv)' >"$path" ;;
    gpu)     printf '%s\n' "$json" | jq -r '(["index","name","serial","bus_id","slot","cur_gen","cur_width","max_gen","max_width","cur_speed","temp_c","pwr_draw_w","pwr_lim_w","vbios","driver"]|@csv), (.[]? | [.index,.name,.serial,.bus_id,.slot,.cur_gen,.cur_width,.max_gen,.max_width,.cur_speed,.temp_c,.power_draw_w,.power_limit_w,.vbios,.driver] | @csv)' >"$path" ;;
    storage) printf '%s\n' "$json" | jq -r '(["name","type","size","model","serial","mountpoint","fstype","pkname"]|@csv), (.blockdevices[]? | [.name,.type,.size,.model,.serial,.mountpoint,.fstype,.pkname] | @csv)' >"$path" ;;
    network) printf '%s\n' "$json" | jq -r '(["iface","product","vendor","serial","bus","state","mtu","addrs"]|@csv), (.[]? | [.logicalname,.product,.vendor,.serial,.businfo,.operstate,.mtu, ((.addr_info//[])|map(.local)|join(";"))] | @csv)' >"$path" ;;
    *) echo "WARN: unknown CSV domain '$domain'" >&2; return 1;;
  esac
}

process_csv_spec(){
  local spec="$1" cpu="$2" ram="$3" gpu="$4" sto="$5" net="$6"
  IFS=',' read -r -a pairs <<< "$spec"
  for kv in "${pairs[@]}"; do
    [[ -z "$kv" ]] && continue
    local k="${kv%%=*}" v="${kv#*=}"
    case "$k" in
      cpu)     csv_emit cpu     "$cpu" "$v";;
      ram)     csv_emit ram     "$ram" "$v";;
      gpu)     csv_emit gpu     "$gpu" "$v";;
      storage) csv_emit storage "$sto" "$v";;
      network) csv_emit network "$net" "$v";;
      *) echo "WARN: unknown domain in --csv: $k" >&2;;
    esac
  done
}

# ---------- Main ----------
main(){
  local sys cpu ram gpu sto net out
  sys=$(collect_system);  log "system ok"
  cpu=$(collect_cpu);     log "cpu rows=$(printf '%s' "$cpu" | jq 'length' 2>/dev/null || echo 0)"
  ram=$(collect_ram);     log "ram rows=$(printf '%s' "$ram" | jq 'length' 2>/dev/null || echo 0)"
  gpu=$(collect_gpu);     log "gpu rows=$(printf '%s' "$gpu" | jq 'length' 2>/dev/null || echo 0)"
  sto=$(collect_storage); log "storage ok"
  net=$(collect_network); log "network rows=$(printf '%s' "$net" | jq 'length' 2>/dev/null || echo 0)"

  # CSV exports
  if [[ -n "$CSV_DIR" ]]; then
    mkdir -p "$CSV_DIR"
    csv_emit cpu     "$cpu" "$CSV_DIR/cpu.csv"
    csv_emit ram     "$ram" "$CSV_DIR/ram.csv"
    csv_emit gpu     "$gpu" "$CSV_DIR/gpu.csv"
    csv_emit storage "$sto" "$CSV_DIR/storage.csv"
    csv_emit network "$net" "$CSV_DIR/network.csv"
  fi
  if [[ -n "$CSV_SPEC" ]]; then
    process_csv_spec "$CSV_SPEC" "$cpu" "$ram" "$gpu" "$sto" "$net"
  fi

  if [[ "$FORMAT" == "json" ]]; then
    out=$(jq -n --argjson system "$sys" --argjson cpu "$cpu" --argjson ram "$ram" --argjson gpu "$gpu" --argjson storage "$sto" --argjson network "$net" \
      '{system:$system, cpu:$cpu, ram:$ram, gpu:$gpu, storage:$storage, network:$network}')
    if [[ -n "$OUTFILE" ]]; then printf '%s\n' "$out" >"$OUTFILE"; else printf '%s\n' "$out"; fi
  else
    if [[ -n "$OUTFILE" ]]; then : >"$OUTFILE"; fi
    {
      echo "SYSTEM";  border 80; printf '%s\n' "$sys" | jq -r '. | to_entries | map("\(.key): \(.value)") | .[]'; echo
      echo "CPU";     border 80; printf '%s\n' "$cpu" | print_table_cpu | column -t -s $'\t'; echo
      echo "RAM";     border 80; printf '%s\n' "$ram" | print_table_ram | column -t -s $'\t'; echo
      echo "GPU";     border 80; printf '%s\n' "$gpu" | print_table_gpu | column -t -s $'\t'; echo
      echo "STORAGE"; border 80; printf '%s\n' "$sto" | print_table_storage | column -t -s $'\t'; echo
      echo "NETWORK"; border 80; printf '%s\n' "$net" | print_table_network | column -t -s $'\t'; echo
    } | { if [[ -n "$OUTFILE" ]]; then tee -a "$OUTFILE" >/dev/null; else cat; fi; }
  fi
}

main "$@"

