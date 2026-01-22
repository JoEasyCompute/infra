#!/bin/bash

# Optional CSV output file
csv_file="$1"

# Terminal color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Check for required commands
for cmd in dmidecode nvidia-smi lspci; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is not installed." >&2
        exit 1
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

# CSV Header
if [[ -n "$csv_file" ]]; then
    echo "Slot,PCI Address,GPU Name,Serial Number,Gen(Current),Gen(Max),Width(Current),Width(Max),LnkSpeed,LnkWidth,Degraded" > "$csv_file"
fi

echo -e "=== PCIe Slot ↔ GPU Mapping ==="
echo ""
printf "%-6s %-25s %-20s %-30s %-20s %-12s %-8s %-15s %-10s %-15s %-15s %-10s\n" \
    "GPU#" "Slot" "PCI Address" "GPU Name" "Serial Number" "Gen(Cur)" "Gen(Max)" "Width(Cur)" "Width(Max)" "LnkSta Speed" "LnkSta Width" "Status"
echo "--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"

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
nvidia-smi --query-gpu=pci.bus_id,name,serial,pcie.link.gen.gpucurrent,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max \
    --format=csv,noheader,nounits | while IFS=',' read -r pci gpu_name serial gen_cur gen_max width_cur width_max; do

    pci=$(echo "$pci" | xargs)
    pci_lower=$(echo "$pci" | tr '[:upper:]' '[:lower:]')
    pci_trimmed=$(echo "$pci_lower" | cut -d':' -f2-)
    gpu_name=$(echo "$gpu_name" | xargs)
    serial=$(echo "$serial" | xargs)
    gen_cur=$(echo "$gen_cur" | xargs)
    gen_max=$(echo "$gen_max" | xargs)
    width_cur=$(echo "$width_cur" | xargs)
    width_max=$(echo "$width_max" | xargs)

    # Match slot
    slot_name="(Unknown)"
    match=$(grep "^$pci_trimmed|" "$slot_file")
    if [[ -n "$match" ]]; then
        slot_name=$(echo "$match" | cut -d'|' -f2)
    fi

    # Read LnkSta
    link_speed="N/A"
    link_width="N/A"
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
    fi

    # Additional degradation logic
    if [[ "$gen_cur" -lt "$gen_max" || "$width_cur" -lt "$width_max" ]]; then
        degraded=1
    fi

    # Status string
    if [[ "$degraded" -eq 1 ]]; then
        status_text="Degraded"
        status_color="${RED}${status_text}${NC}"
    else
        status_text="OK"
        status_color="${GREEN}${status_text}${NC}"
    fi

    # Store raw data for sorting
    # Format: SlotName|PCI|Name|Serial|GenCur|GenMax|WidthCur|WidthMax|LnkSpeed|LnkWidth|StatusText|StatusColor
    echo "$slot_name|$pci|$gpu_name|$serial|$gen_cur|$gen_max|$width_cur|$width_max|$link_speed|$link_width|$status_text|$status_color" >> "$lines_file"
done

# Sort by SLOT (1st field), then enumerate and print
gpu_idx=0
if [[ -s "$lines_file" ]]; then
    while IFS='|' read -r slot_name pci gpu_name serial gen_cur gen_max width_cur width_max link_speed link_width status_text status_color; do
        printf "%-6s %-25s %-20s %-30s %-20s %-12s %-8s %-15s %-10s %-15s %-15s %-10b\n" \
            "$gpu_idx" "$slot_name" "$pci" "$gpu_name" "$serial" "$gen_cur" "$gen_max" "$width_cur" "$width_max" "$link_speed" "$link_width" "$status_color"
        
        if [[ -n "$csv_file" ]]; then
             echo "\"$gpu_idx\",\"$slot_name\",\"$pci\",\"$gpu_name\",\"$serial\",\"$gen_cur\",\"$gen_max\",\"$width_cur\",\"$width_max\",\"$link_speed\",\"$link_width\",\"$status_text\"" >> "$csv_file"
        fi
        ((gpu_idx++))
    done < <(sort -t'|' -k1,1V "$lines_file")
else
    echo "No GPUs found or error processing."
fi
