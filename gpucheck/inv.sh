#!/bin/bash

# Optional CSV output file
csv_file="$1"

# Terminal color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# CSV Header
if [[ -n "$csv_file" ]]; then
    echo "Slot,PCI Address,GPU Name,Serial Number,Gen(Current),Gen(Max),Width(Current),Width(Max),LnkSpeed,LnkWidth,Degraded" > "$csv_file"
fi

echo -e "=== PCIe Slot ↔ GPU Mapping ==="
echo ""
printf "%-25s %-20s %-30s %-20s %-12s %-8s %-15s %-10s %-15s %-15s %-10s\n" \
    "Slot" "PCI Address" "GPU Name" "Serial Number" "Gen(Cur)" "Gen(Max)" "Width(Cur)" "Width(Max)" "LnkSta Speed" "LnkSta Width" "Status"
echo "-----------------------------------------------------------------------------------------------------------------------------------------------------"

slot_file=$(mktemp)
lines_file=$(mktemp)

# Build slot-to-address map
current_slot=""
while IFS= read -r line; do
    if [[ $line =~ Designation:\ (.+) ]]; then
        current_slot="${BASH_REMATCH[1]}"
    elif [[ $line =~ Bus\ Address:\ (.+) ]]; then
        pci_addr="${BASH_REMATCH[1]}"
        pci_trimmed=$(echo "$pci_addr" | cut -d':' -f2- | tr '[:upper:]' '[:lower:]')
        echo "$pci_trimmed|$current_slot" >> "$slot_file"
    fi
done < <(sudo dmidecode -t slot)

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
    lspci_output=$(sudo lspci -s "$pci_lower" -vv 2>/dev/null)
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

    # Color code status
    if [[ "$degraded" -eq 1 ]]; then
        status="${RED}Degraded${NC}"
    else
        status="${GREEN}OK${NC}"
    fi

    # Store all fields as a tab-separated line for sorting
    echo -e "$slot_name\t$pci\t$gpu_name\t$serial\t$gen_cur\t$gen_max\t$width_cur\t$width_max\t$link_speed\t$link_width\t$status" >> "$lines_file"
done

# Print header
printf "%-6s %-25s %-20s %-30s %-20s %-12s %-8s %-15s %-10s %-15s %-15s %-10s\n" \
    "GPU#" "Slot" "PCI Address" "GPU Name" "Serial Number" "Gen(Cur)" "Gen(Max)" "Width(Cur)" "Width(Max)" "LnkSta Speed" "LnkSta Width" "Status"
echo "-----------------------------------------------------------------------------------------------------------------------------------------------------"

# Sort by SLOT (1st field), then enumerate and print
gpu_idx=0
while IFS=$'\t' read -r slot_name pci gpu_name serial gen_cur gen_max width_cur width_max link_speed link_width status; do
    printf "%-6s %-25s %-20s %-30s %-20s %-12s %-8s %-15s %-10s %-15s %-15s %-10b\n" \
        "$gpu_idx" "$slot_name" "$pci" "$gpu_name" "$serial" "$gen_cur" "$gen_max" "$width_cur" "$width_max" "$link_speed" "$link_width" "$status"
    sorted_lines[$gpu_idx]="$slot_name|$pci|$gpu_name|$serial|$gen_cur|$gen_max|$width_cur|$width_max|$link_speed|$link_width|$status"
    ((gpu_idx++))
done < <(sort -t$'\t' -k1,1V "$lines_file")

# Write CSV
if [[ -n "$csv_file" ]]; then
    for idx in "${!sorted_lines[@]}"; do
        IFS='|' read -r slot_name pci gpu_name serial gen_cur gen_max width_cur width_max link_speed link_width status <<<"${sorted_lines[$idx]}"
        csv_status=$([[ "$status" == *"Degraded"* ]] && echo "Degraded" || echo "OK")
        echo "\"$idx\",\"$slot_name\",\"$pci\",\"$gpu_name\",\"$serial\",\"$gen_cur\",\"$gen_max\",\"$width_cur\",\"$width_max\",\"$link_speed\",\"$link_width\",\"$csv_status\"" >> "$csv_file"
    done
fi

rm -f "$slot_file" "$lines_file"
