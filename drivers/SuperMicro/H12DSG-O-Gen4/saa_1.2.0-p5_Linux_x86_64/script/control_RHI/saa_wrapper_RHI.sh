#!/bin/sh

# Check if SAA exists
if [ ! -x "./saa" ]; then
    echo "SAA executable not found. Please move this script to the SAA directory." >&2
    exit 1
fi

ENABLE_SCRIPT=""
# If current system is linux, the Linux_enable_RHI.sh should under the same folder 
if $(uname -a | grep -iq "Linux"); then
    if [ ! -x "./Linux_enable_RHI.sh" ]; then
        echo "Linux_enable_RHI.sh not found. Please move this script to the SAA directory." >&2
        exit 1
    fi
    ENABLE_SCRIPT=Linux_enable_RHI.sh
else
    # Unix system
    if [ ! -x "./FreeBSD_setup_RHI.sh" ]; then
        echo "FreeBSD_setup_RHI.sh not found. Please move this script to the SAA directory." >&2
        exit 1
    fi
    ENABLE_SCRIPT=FreeBSD_setup_RHI.sh
fi

#Check if RHI is enabled by raw command
if ./saa -c rawcommand --raw "30 B5 00" | tail -1 | cut -f1 -d " " | grep -q '01'; then
        # Check the Host side RHI is enabled, if not, enable it.
        ./$ENABLE_SCRIPT
        #run saa command
        ./saa "$@"
 
else
        ./saa -c rawcommand --raw "30 B5 01 01" >/dev/null
        #Wait for RHI bring up for 2 seconds
        sleep 2
        # Check the Host side RHI is enabled, if not, enable it.
        ./$ENABLE_SCRIPT 
        #run saa command
        ./saa "$@"
        #disable RHI if RHI is disabled at the beginning by raw command
        ./saa -c rawcommand --raw "30 B5 01 00" >/dev/null
fi
