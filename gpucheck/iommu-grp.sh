#!/bin/bash
shopt -s nullglob

KEYWORDS=("nvidia" "volatile" "10G")

for g in /sys/kernel/iommu_groups/*; do
    GROUP_MATCHED=false

    # Check if any device in the group matches
    for d in "$g"/devices/*; do
        LINE=$(lspci -nn -s "${d##*/}")
        for keyword in "${KEYWORDS[@]}"; do
            if echo "$LINE" | grep -iq "$keyword"; then
                GROUP_MATCHED=true
                break 2  # Exit both loops on first match
            fi
        done
    done

    # If matched, print all devices in the group
    if $GROUP_MATCHED; then
        echo "IOMMU Group ${g##*/}:"
        for d in "$g"/devices/*; do
            echo -e "\t$(lspci -nn -s "${d##*/}")"
        done
    fi
done
