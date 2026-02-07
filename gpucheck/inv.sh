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
trap 'rm -f "$slot_file" "$lines_file"' EXIT

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

# Process GPUs
# Query includes extended metrics
nvidia-smi --query-gpu=pci.bus_id,name,serial,pcie.link.gen.gpucurrent,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,temperature.gpu,power.draw,power.limit,driver_version \
    --format=csv,noheader,nounits | while IFS=',' read -r pci gpu_name serial gen_cur gen_max width_cur width_max temp power_draw power_limit driver; do

    # Trim whitespace
    pci=$(echo "$pci" | xargs)
    gpu_name=$(echo "$gpu_name" | xargs)
    serial=$(echo "$serial" | xargs)
    gen_cur=$(echo "$gen_cur" | xargs)
    gen_max=$(echo "$gen_max" | xargs)
    width_cur=$(echo "$width_cur" | xargs)
    width_max=$(echo "$width_max" | xargs)
    temp=$(echo "$temp" | xargs)
    power_draw=$(echo "$power_draw" | xargs)
    power_limit=$(echo "$power_limit" | xargs)
    driver=$(echo "$driver" | xargs)

    pci_lower=$(echo "$pci" | tr '[:upper:]' '[:lower:]')
    pci_trimmed=$(echo "$pci_lower" | cut -d':' -f2-)

    # Match slot
    slot_name="(Unknown)"
    match=$(grep "^$pci_trimmed|" "$slot_file")
    if [[ -n "$match" ]]; then
        slot_name=$(echo "$match" | cut -d'|' -f2)
    fi

    # Read LnkSta and NUMA via lspci
    link_speed="N/A"
    link_width="N/A"
    numa_node="?"
    degraded=0
    
    # lspci might fail if device is in a bad state, suppress stderr
    lspci_output=$(lspci -s "$pci_lower" -vv 2>/dev/null)
    if [[ -n "$lspci_output" ]]; then
        link_line=$(echo "$lspci_output" | grep -i "LnkSta:" | head -n1)
        if [[ -n "$link_line" ]]; then
            link_speed=$(echo "$link_line" | sed -n 's/.*Speed \([^,]*\).*/\1/p')
            link_width=$(echo "$link_line" | sed -n 's/.*Width \([^,]*\).*/\1/p')
            [[ "$link_line" == *"(downgraded)"* ]] && degraded=1
        fi
        
        # Try finding NUMA node
        numa_line=$(echo "$lspci_output" | grep -i "NUMA node:")
        if [[ -n "$numa_line" ]]; then
             numa_node=$(echo "$numa_line" | awk '{print $NF}')
        else
            # Fallback to sysfs
            if [[ -r "/sys/bus/pci/devices/$pci_lower/numa_node" ]]; then
                 numa_node=$(cat "/sys/bus/pci/devices/$pci_lower/numa_node")
                 [[ "$numa_node" == "-1" ]] && numa_node="0" # Assume 0 if -1 (often means UMA/Single socket)
            fi
        fi
    fi

    # Additional degradation logic
    if [[ "$gen_cur" -lt "$gen_max" || "$width_cur" -lt "$width_max" ]]; then
        degraded=1
    fi

    # Formatting for display
    gen_fmt="${gen_cur}/${gen_max}"
    width_fmt="${width_cur}/${width_max}"
    link_fmt="${link_speed}/${link_width}"
    power_fmt="${power_draw}/${power_limit}W"
    
    # Status coloring
    if [[ "$degraded" -eq 1 ]]; then
        status_text="Degraded"
        status_color="${RED}Degraded${NC}"
    else
        status_text="OK"
        status_color="${GREEN}OK${NC}"
    fi

    # Store all fields for sorting and later output
    # Delimiter: |
    # 1:Slot 2:PCI 3:Name 4:Serial 5:GenCur 6:GenMax 7:WdthCur 8:WdthMax 9:LnkSpd 10:LnkWdth 11:Temp 12:PwrDraw 13:PwrLim 14:NUMA 15:Driver 16:StatusText 17:StatusColor
    echo "$slot_name|$pci|$gpu_name|$serial|$gen_cur|$gen_max|$width_cur|$width_max|$link_speed|$link_width|$temp|$power_draw|$power_limit|$numa_node|$driver|$status_text|$status_color" >> "$lines_file"
done

# Sort by SLOT (using sort -V for version sort on the slot string if possible, or usually just text)
# We will do a best effort sort. `sort -k1,1`
sort -t'|' -k1,1V "$lines_file" -o "$lines_file"

# --- Output Generation ---

# 1. Console Output
gpu_idx=0
while IFS='|' read -r slot pci name serial gc gm wc wm ls lw temp pd pl numa drv st_txt st_col; do
    gen_fmt="${gc}/${gm}"
    width_fmt="${wc}/${wm}"
    link_fmt="${ls}/${lw}"
    power_fmt="${pd}/${pl}W"
    
    printf "%-4s %-20s %-14s %-25s %-16s %-10s %-10s %-10s %-12s %-10s %-8s %-10s %-8b\n" \
        "$gpu_idx" "$slot" "$pci" "${name:0:22}.." "$serial" "$gen_fmt" "$width_fmt" "$link_fmt" "${temp}C" "$power_fmt" "$numa" "$drv" "$st_col"
    ((gpu_idx++))
done < "$lines_file"

# 2. CSV Output
if [[ -n "$csv_file" ]]; then
    echo "Idx,Slot,PCI,Name,Serial,GenCurrent,GenMax,WidthCurrent,WidthMax,LinkSpeed,LinkWidth,TempC,PowerDrawW,PowerLimitW,NUMA,Driver,Status" > "$csv_file"
    gpu_idx=0
    while IFS='|' read -r slot pci name serial gc gm wc wm ls lw temp pd pl numa drv st_txt st_col; do
        echo "$gpu_idx,\"$slot\",\"$pci\",\"$name\",\"$serial\",$gc,$gm,$wc,$wm,\"$ls\",\"$lw\",$temp,$pd,$pl,$numa,\"$drv\",\"$st_txt\"" >> "$csv_file"
        ((gpu_idx++))
    done < "$lines_file"
    echo "CSV written to $csv_file"
fi

# 3. JSON Output
if [[ -n "$json_file" ]]; then
    # We'll construct JSON using jq for safety, or a loop if we assume simple data.
    # To be robust, let's use jq if available (checked at start), or fallback?
    # We enforced jq check if json_file is set.
    
    # Create valid JSON array
    jq -nR '
        [inputs 
        | split("|") 
        | {
            slot: .[0],
            pci_address: .[1],
            name: .[2],
            serial: .[3],
            pcie: {
                gen: {current: .[4], max: .[5]},
                width: {current: .[6], max: .[7]},
                link: {speed: .[8], width: .[9]}
            },
            thermals: {temp_c: .[10]},
            power: {draw_w: .[11], limit_w: .[12]},
            system: {numa_node: .[13], driver: .[14]},
            status: .[15]
          }
        ] |  to_entries | map(.value + {index: .key})
    ' "$lines_file" > "$json_file"
    echo "JSON written to $json_file"
fi
