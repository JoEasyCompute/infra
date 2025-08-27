#!/bin/sh

# Check if SAA exists
if [ ! -x "./saa" ]; then
    echo "SAA executable not found. Please move this script to the SAA directory." >&2
    exit 1
fi
 
# Disable RHI by raw command
output=$(./saa -c rawcommand --raw "30 B5 01 00")
exit_code=$?

# Check the exit code
if [ $exit_code -ne 0 ]; then
    printf "%b\n" "$output"
elif echo "$output" | tail -1 | grep -q '00'; then
    sleep 2
    echo "RHI disabled successfully."
else
    echo "Fail to disable RHI."
fi
