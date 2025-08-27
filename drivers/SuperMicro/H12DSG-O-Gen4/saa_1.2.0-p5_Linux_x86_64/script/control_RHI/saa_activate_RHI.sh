#!/bin/sh

# Check if SAA exists
if [ ! -x "./saa" ]; then
    echo "SAA executable not found. Please move this script to the SAA directory." >&2
    exit 1
fi

# Enable RHI by raw command
output=$(./saa -c rawcommand --raw "30 B5 01 01")
exit_code=$?

# Check the exit code
if [ $exit_code -ne 0 ]; then
    printf "%b\n" "$output"
elif echo "$output" | tail -1 | grep -q '00'; then
    sleep 2
    echo "RHI enabled successfully."
else
    echo "Fail to enable RHI."
fi