#!/usr/bin/env bash
# DIMM / Memory Device inventory for Ubuntu (mawk/gawk compatible)
# Supports pretty table output, CSV export, and JSON output
# Usage: ./dimm-inv.sh [--csv out.csv] [--json out.json] [--help]
set -euo pipefail

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

have(){ command -v "$1" >/dev/null 2>&1; }
require(){ for c in "$@"; do have "$c" || { echo "ERROR: missing dependency: $c" >&2; exit 1; }; done; }

require dmidecode awk column jq

if ! sudo -n true 2>/dev/null; then
  echo "INFO: dmidecode needs root. You may be prompted for sudo." >&2
fi

DMI_OUT="$(sudo dmidecode -t memory 2>/dev/null || true)"
if [[ -z "$DMI_OUT" ]]; then
  echo "ERROR: No DMI data returned. Platform hides SMBIOS or insufficient privileges." >&2
  exit 1
fi

# We use intermediate TSV for processing (easier than piping directly to jq from awk for mixed output)
tmp_file=$(mktemp)
trap 'rm -f "$tmp_file"' EXIT

# AWK processing -> Generate TSV
awk '
  BEGIN {
    RS=""; FS="\n"
  }

  function trim(s){ sub(/^[ \t\r\n]+/,"",s); sub(/[ \t\r\n]+$/,"",s); return s }
  function val(key,   i, line) {
    for (i=1;i<=NF;i++) {
      line=$i
      sub(/^[ \t]+/, "", line)
      if (index(line, key":")==1) {
        v=substr(line, length(key)+2)
        return trim(v)
      }
    }
    return ""
  }

  /Memory Device/ {
    locator   = val("Locator");           if (locator=="") locator="-"
    bank      = val("Bank Locator");      if (bank=="")    bank="-"
    size      = val("Size")
    dtype     = val("Type");              if (dtype=="")   dtype="-"
    form      = val("Form Factor");       if (form=="")    form="-"
    ranks     = val("Rank");              if (ranks=="")   ranks="-"
    dataw     = val("Data Width");        gsub(/ bits/,"",dataw); if (dataw=="") dataw="-"
    totalw    = val("Total Width");       gsub(/ bits/,"",totalw); if (totalw=="") totalw="-"
    speed     = val("Speed")
    cfgspeed  = val("Configured Memory Speed")
    mfg       = val("Manufacturer");      if (mfg=="")     mfg="-"
    part      = val("Part Number");       if (part=="")    part="-"
    serial    = val("Serial Number");     if (serial=="")  serial="-"

    if (size=="" || size ~ /^No Module Installed/) {
      size_out="Empty"
    } else {
      sz=size
      if (sz ~ /MB/) { gsub(/[^0-9]/,"",sz); size_out=sprintf("%.1fGiB", (sz+0)/1024.0) }
      else if (sz ~ /GB/) { gsub(/[^0-9]/,"",sz); size_out=sprintf("%sGiB", sz) }
      else size_out=size
    }

    if (speed=="") speed="-"
    if (cfgspeed=="") cfgspeed="-"
    if (speed ~ /[0-9]/)    { match(speed, /([0-9]+)/, m);    if (m[1]!="") speed=m[1]" MT/s" }
    if (cfgspeed ~ /[0-9]/) { match(cfgspeed, /([0-9]+)/, m2); if (m2[1]!="") cfgspeed=m2[1]" MT/s" }

    ecc="-"
    if (dataw ~ /^[0-9]+$/ && totalw ~ /^[0-9]+$/) ecc = ((totalw+0)>(dataw+0)) ? "Yes" : "No"
    width = ((dataw=="-" || totalw=="-") ? "-" : dataw "/" totalw)

    # Print row to tmp_file (tab-separated)
    print locator "\t" bank "\t" size_out "\t" dtype "\t" form "\t" ranks "\t" width "\t" ecc "\t" speed "\t" cfgspeed "\t" mfg "\t" part "\t" serial
  }
' <<< "$DMI_OUT" > "$tmp_file"

# 1. Console Table Output
HEADER="SLOT\tBANK\tSIZE\tTYPE\tFORM\tRANKS\tDATA/TOTAL\tECC\tSPEED\tCFG_SPEED\tMFG\tPART\tSERIAL"
echo -e "$HEADER" | column -t -s $'\t'
printf '%*s\n' 120 '' | tr ' ' '-'   # separator line
cat "$tmp_file" | column -t -s $'\t'

# 2. CSV output if requested
if [[ -n "$csv_file" ]]; then
    echo "SLOT,BANK,SIZE,TYPE,FORM,RANKS,DATA/TOTAL,ECC,SPEED,CFG_SPEED,MFG,PART,SERIAL" > "$csv_file"
    while IFS=$'\t' read -r loc bank size dtype form ranks width ecc speed cfg mfg part serial; do
        # Use simple quoting/escaping if needed, currently assuming no complex chars in DMI output that break CSV
        echo "$loc,$bank,$size,$dtype,$form,$ranks,$width,$ecc,$speed,$cfg,$mfg,$part,$serial" >> "$csv_file"
    done < "$tmp_file"
    echo "CSV written to $csv_file"
fi

# 3. JSON Output
if [[ -n "$json_file" ]]; then
    jq -R -s '
        split("\n") | map(select(length>0)) | map(split("\t"))
        | map({
            locator: .[0],
            bank: .[1],
            size: .[2],
            type: .[3],
            form_factor: .[4],
            ranks: .[5],
            width: .[6],
            ecc: .[7],
            speed: .[8],
            configured_speed: .[9],
            manufacturer: .[10],
            part: .[11],
            serial: .[12]
          })
    ' "$tmp_file" > "$json_file"
    echo "JSON written to $json_file"
fi
