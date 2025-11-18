#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 ip_list.csv"
  exit 1
fi

INPUT_FILE="$1"

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "Error: File '$INPUT_FILE' not found."
  exit 1
fi

echo "Non-responding IPs:"
echo "-------------------"

# Read CSV line by line
# Assumes IP is in the first column
while IFS=, read -r ip _; do
  # Strip leading/trailing whitespace
  ip="${ip#"${ip%%[![:space:]]*}"}"
  ip="${ip%"${ip##*[![:space:]]}"}"

  # Skip empty lines and header if any
  [[ -z "$ip" ]] && continue
  [[ "$ip" =~ ^# ]] && continue
  [[ "$ip" =~ [a-zA-Z] ]] && continue  # crude filter to skip obvious headers

  # Ping with 1 probe, 1 second timeout
  if ! ping -c 1 -W 1 "$ip" &>/dev/null; then
    echo "$ip"
  fi
done < "$INPUT_FILE"
