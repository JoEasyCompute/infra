#!/bin/bash
# inv.sh - GPU to PCIe Slot inventory with extended metrics
# Usage: ./inv.sh [--csv out.csv] [--json out.json] [--help]

# Default outputs
csv_file=""
json_file=""

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --csv)
            csv_file="$2"
            shift 2
            ;;
        --json)
            json_file="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--csv output.csv] [--json output.json]"
            exit 0
            ;;
        *)
            # Backward compatibility: treat first arg as csv file if no flag
            if [[ -z "$csv_file" && "$1" != -* ]]; then
                csv_file="$1"
                shift
            else
                echo "Unknown argument: $1" >&2
                exit 1
            fi
            ;;
    esac
done

# Terminal color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Check for required commands
for cmd in dmidecode nvidia-smi lspci jq; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is not installed." >&2
        # jq is optional but highly recommended for JSON; pure bash JSON is painful
        if [[ "$cmd" == "jq" && -z "$json_file" ]]; then
            : # Skip warning if not asking for JSON
        else
             exit 1
        fi
    fi
done

# Check for root privileges (needed for dmidecode and lspci -vv)
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (or with sudo) to access hardware details." >&2
   exit 1
fi

# Cleanup trap
slot_file=$(mktemp)
lines_file=$(mktemp)
remark_file=$(mktemp)
smi_out_file=$(mktemp)
smi_err_file=$(mktemp)
gpu_raw_file=$(mktemp)
trap 'rm -f "$slot_file" "$lines_file" "$remark_file" "$smi_out_file" "$smi_err_file" "$gpu_raw_file"' EXIT

echo -e "=== PCIe Slot ↔ GPU Mapping ==="
echo ""
# Header for console
printf "%-4s %-20s %-14s %-25s %-16s %-10s %-10s %-10s %-12s %-10s %-8s %-10s %-8s\n" \
    "Idx" "Slot" "PCI Addr" "GPU Name" "Serial" "Gen(C/M)" "Wdth(C/M)" "Lnk(Sp/W)" "Temp" "Pwr(Draw/Lim)" "NUMA" "Driver" "Status"
echo "-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"

# Build slot-to-address map
current_slot=""
while IFS= read -r line; do
    if [[ $line =~ Designation:\ (.+) ]]; then
        current_slot="${BASH_REMATCH[1]}"
    elif [[ $line =~ Bus\ Address:\ (.+) ]]; then
        pci_addr="${BASH_REMATCH[1]}"
        # Format: 0000:65:00.0 -> 65:00.0
        pci_trimmed=$(echo "$pci_addr" | cut -d':' -f2- | tr '[:upper:]' '[:lower:]')
        echo "$pci_trimmed|$current_slot" >> "$slot_file"
    fi
done < <(dmidecode -t slot)

speed_to_gen() {
    case "$1" in
        *"2.5GT/s"*) echo "1" ;;
        *"5.0GT/s"*|*"5GT/s"*) echo "2" ;;
        *"8.0GT/s"*|*"8GT/s"*) echo "3" ;;
        *"16.0GT/s"*|*"16GT/s"*) echo "4" ;;
        *"32.0GT/s"*|*"32GT/s"*) echo "5" ;;
        *"64.0GT/s"*|*"64GT/s"*) echo "6" ;;
        *"128.0GT/s"*|*"128GT/s"*) echo "7" ;;
        *) echo "N/A" ;;
    esac
}

clip() {
    local s="$1" w="$2"
    if [[ ${#s} -le $w ]]; then
        echo -n "$s"
    else
        echo -n "${s:0:w-1}…"
    fi
}

get_pci_model() {
    local addr="$1" sv sd vv dd subsys
    sv=$(lspci -vmm -s "$addr" 2>/dev/null | sed -n 's/^SVendor:[[:space:]]*//p' | head -n1)
    sd=$(lspci -vmm -s "$addr" 2>/dev/null | sed -n 's/^SDevice:[[:space:]]*//p' | head -n1)
    [[ -n "$sv" && -n "$sd" ]] && { echo "$sv $sd"; return; }
    subsys=$(lspci -s "$addr" -vv 2>/dev/null | sed -n 's/^[[:space:]]*Subsystem:[[:space:]]*//p' | head -n1)
    [[ -n "$subsys" ]] && { echo "$subsys"; return; }
    vv=$(lspci -vmm -s "$addr" 2>/dev/null | sed -n 's/^Vendor:[[:space:]]*//p' | head -n1)
    dd=$(lspci -vmm -s "$addr" 2>/dev/null | sed -n 's/^Device:[[:space:]]*//p' | head -n1)
    [[ -n "$vv" && -n "$dd" ]] && { echo "$vv $dd"; return; }
    echo "-"
}

# Process GPUs
# Fast path: use the plain `nvidia-smi` table output, which still reports the
# PCI address for the broken GPU on stderr without querying the missing device.
nvidia-smi >"$smi_out_file" 2>"$smi_err_file" || true

# Pull the driver version from the banner.
driver_version=$(sed -n 's/.*Driver Version:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$smi_out_file" | head -n1)
driver_version="${driver_version:-N/A}"

awk '
function trim(s) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    return s
}
BEGIN {
    pending = 0
}
{
    if ($0 ~ /^\|[[:space:]]+[0-9]+[[:space:]]+/ && $0 ~ /\|[[:space:]]+[0-9A-Fa-f]{8}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-9][[:space:]]+/) {
        split($0, a, "|")
        left = trim(a[2])
        right = trim(a[3])
        if (match(left, /^([0-9]+)[[:space:]]+(.+)[[:space:]]+On$/, m)) {
            idx = m[1]
            name = trim(m[2])
        } else {
            next
        }
        split(right, b, /[[:space:]]+/)
        pci = tolower(b[1])
        pending_idx = idx
        pending_pci = pci
        pending_name = name
        pending = 1
        next
    }
    if (pending && $0 ~ /^\|/) {
        split($0, a, "|")
        metrics = trim(a[2])
        fan = "N/A"
        temp = "N/A"
        power_draw = "N/A"
        power_limit = "N/A"
        if (match(metrics, /^([0-9]+)%[[:space:]]+([0-9]+)C.*([0-9.]+)W[[:space:]]*\/[[:space:]]*([0-9.]+)W/, m)) {
            fan = m[1]
            temp = m[2]
            power_draw = m[3]
            power_limit = m[4]
        }
        print pending_idx "|" pending_pci "|" pending_name "|" fan "|" temp "|" power_draw "|" power_limit
        pending = 0
        next
    }
    pending = 0
}
' "$smi_out_file" > "$gpu_raw_file"

declare -A bus_lost_by_pci
while IFS= read -r err_line; do
    if [[ $err_line =~ Unable\ to\ determine\ the\ device\ handle\ for\ GPU[0-9]+:\ ([0-9A-Fa-f:.]+):\ Unknown\ Error ]]; then
        bus_lost_by_pci["${BASH_REMATCH[1],,}"]=1
    fi
done < "$smi_err_file"

while IFS='|' read -r gpu_idx pci gpu_name fan temp power_draw power_limit; do
    [[ -z "$gpu_idx" || -z "$pci" ]] && continue

    pci=$(echo "$pci" | xargs)
    gpu_name=$(echo "$gpu_name" | xargs)
    fan=$(echo "$fan" | xargs)
    temp=$(echo "$temp" | xargs)
    power_draw=$(echo "$power_draw" | xargs)
    power_limit=$(echo "$power_limit" | xargs)

    pci_lower=$(echo "$pci" | tr '[:upper:]' '[:lower:]')
    pci_trimmed=$(echo "$pci_lower" | cut -d':' -f2-)
    [[ -z "$pci_lower" ]] && continue

    # Match slot
    slot_name="(Unknown)"
    match=$(grep "^$pci_trimmed|" "$slot_file")
    if [[ -n "$match" ]]; then
        slot_name=$(echo "$match" | cut -d'|' -f2)
    fi

    # Read LnkSta/LnkCap and NUMA via lspci
    link_speed="N/A"
    link_width="N/A"
    cap_speed="N/A"
    cap_width="N/A"
    numa_node="?"
    negotiated_below_max=0
    bus_lost=0

    lspci_output=$(lspci -s "$pci_lower" -vv 2>/dev/null)
    if [[ -n "$lspci_output" ]]; then
        cap_line=$(echo "$lspci_output" | grep -i "LnkCap:" | head -n1)
        link_line=$(echo "$lspci_output" | grep -i "LnkSta:" | head -n1)
        if [[ -n "$cap_line" ]]; then
            cap_speed=$(echo "$cap_line" | sed -n 's/.*Speed \([^,]*\).*/\1/p')
            cap_width=$(echo "$cap_line" | sed -n 's/.*Width \([^,]*\).*/\1/p')
        fi
        if [[ -n "$link_line" ]]; then
            link_speed=$(echo "$link_line" | sed -n 's/.*Speed \([^,]*\).*/\1/p')
            link_width=$(echo "$link_line" | sed -n 's/.*Width \([^,]*\).*/\1/p')
        fi

        numa_line=$(echo "$lspci_output" | grep -i "NUMA node:")
        if [[ -n "$numa_line" ]]; then
            numa_node=$(echo "$numa_line" | awk '{print $NF}')
        else
            if [[ -r "/sys/bus/pci/devices/$pci_lower/numa_node" ]]; then
                numa_node=$(cat "/sys/bus/pci/devices/$pci_lower/numa_node")
                [[ "$numa_node" == "-1" ]] && numa_node="0"
            fi
        fi
    else
        bus_lost=1
    fi

    if [[ -n "${bus_lost_by_pci[$pci_lower]:-}" ]]; then
        bus_lost=1
    fi

    gen_cur=$(speed_to_gen "$link_speed")
    gen_max=$(speed_to_gen "$cap_speed")
    width_cur="${link_width#x}"
    width_max="${cap_width#x}"
    [[ "$width_cur" == "$link_width" ]] && width_cur="$link_width"
    [[ "$width_max" == "$cap_width" ]] && width_max="$cap_width"

    if [[ "$gen_cur" =~ ^[0-9]+$ && "$gen_max" =~ ^[0-9]+$ && "$gen_cur" -lt "$gen_max" ]] || \
       [[ "$width_cur" =~ ^[0-9]+$ && "$width_max" =~ ^[0-9]+$ && "$width_cur" -lt "$width_max" ]]; then
        negotiated_below_max=1
    fi

    gen_fmt="${gen_cur}/${gen_max}"
    width_fmt="${width_cur}/${width_max}"
    link_fmt="${link_speed}/${link_width}"
    power_fmt="${power_draw}/${power_limit}W"
    serial="N/A"

    if [[ "$bus_lost" -eq 1 ]]; then
        status_text="BusLost"
        status_color="${RED}BusLost${NC}"
    elif [[ "$negotiated_below_max" -eq 1 ]]; then
        status_text="BelowMax"
        status_color="${YELLOW}BelowMax${NC}"
    else
        status_text="OK"
        status_color="${GREEN}OK${NC}"
    fi

    echo "$gpu_idx|$slot_name|$pci|$gpu_name|$serial|$gen_cur|$gen_max|$width_cur|$width_max|$link_speed|$link_width|$temp|$power_draw|$power_limit|$numa_node|$driver_version|$status_text|$status_color" >> "$lines_file"
done < "$gpu_raw_file"

# Sort by SLOT (best effort)
sort -t'|' -k2,2V "$lines_file" -o "$lines_file"

# --- Output Generation ---

# 1. Console Output
while IFS='|' read -r gpu_idx slot pci name serial gc gm wc wm ls lw temp pd pl numa drv st_txt st_col; do
    gen_fmt="${gc}/${gm}"
    width_fmt="${wc}/${wm}"
    link_fmt="${ls}/${lw}"
    power_fmt="${pd}/${pl}W"
    slot_disp="$(clip "$slot" 20)"
    name_disp="$(clip "$name" 25)"

    printf "%-4s %-20s %-14s %-25s %-16s %-10s %-10s %-10s %-12s %-10s %-8s %-10s %-8b\n" \
        "$gpu_idx" "$slot_disp" "$pci" "$name_disp" "$serial" "$gen_fmt" "$width_fmt" "$link_fmt" "${temp}C" "$power_fmt" "$numa" "$drv" "$st_col"

    if [[ "$st_txt" == "BusLost" ]]; then
        printf "GPU %s in slot %s (%s): %s\n" "$gpu_idx" "$slot" "$pci" "$st_txt" >> "$remark_file"
    fi
done < "$lines_file"

for pci_lower in "${!bus_lost_by_pci[@]}"; do
    slot_name="(Unknown)"
    pci_key="${pci_lower#00000000:}"
    pci_key="${pci_key#0000:}"
    match=$(grep "^${pci_key}|" "$slot_file" 2>/dev/null || true)
    if [[ -n "$match" ]]; then
        slot_name=$(echo "$match" | cut -d'|' -f2)
    fi
    model=$(get_pci_model "$pci_lower")
    printf "PCI %s in slot %s (%s): BusLost (nvidia-smi reported device handle error)\n" "$pci_lower" "$slot_name" "$model" >> "$remark_file"
done

# 2. CSV Output
if [[ -n "$csv_file" ]]; then
    echo "Idx,Slot,PCI,Name,Serial,GenCurrent,GenMax,WidthCurrent,WidthMax,LinkSpeed,LinkWidth,TempC,PowerDrawW,PowerLimitW,NUMA,Driver,Status" > "$csv_file"
    while IFS='|' read -r gpu_idx slot pci name serial gc gm wc wm ls lw temp pd pl numa drv st_txt st_col; do
        echo "$gpu_idx,\"$slot\",\"$pci\",\"$name\",\"$serial\",$gc,$gm,$wc,$wm,\"$ls\",\"$lw\",$temp,$pd,$pl,$numa,\"$drv\",\"$st_txt\"" >> "$csv_file"
    done < "$lines_file"
    echo "CSV written to $csv_file"
fi

# 3. JSON Output
if [[ -n "$json_file" ]]; then
    jq -nR '
        [inputs
        | split("|")
        | {
            gpu_index: .[0],
            slot: .[1],
            pci_address: .[2],
            name: .[3],
            serial: .[4],
            pcie: {
                gen: {current: .[5], max: .[6]},
                width: {current: .[7], max: .[8]},
                link: {speed: .[9], width: .[10]}
            },
            thermals: {temp_c: .[11]},
            power: {draw_w: .[12], limit_w: .[13]},
            system: {numa_node: .[14], driver: .[15]},
            status: .[16]
          }
        ] | to_entries | map(.value + {index: .key})
    ' "$lines_file" > "$json_file"
    echo "JSON written to $json_file"
fi

if [[ -s "$remark_file" ]]; then
    echo ""
    echo "=== Remark: GPUs that appear to have fallen off the bus ==="
    cat "$remark_file"
fi
