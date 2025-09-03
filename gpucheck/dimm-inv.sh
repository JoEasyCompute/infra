#!/usr/bin/env bash
# DIMM / Memory Device inventory for Ubuntu (mawk/gawk compatible)
# Supports pretty table output + optional CSV export
set -euo pipefail

have(){ command -v "$1" >/dev/null 2>&1; }
require(){ for c in "$@"; do have "$c" || { echo "ERROR: missing dependency: $c" >&2; exit 1; }; done; }

require dmidecode awk column

if ! sudo -n true 2>/dev/null; then
  echo "INFO: dmidecode needs root. You may be prompted for sudo."
fi

OUTFILE="${1:-}"   # optional CSV filename

DMI_OUT="$(sudo dmidecode -t memory 2>/dev/null || true)"
if [[ -z "$DMI_OUT" ]]; then
  echo "ERROR: No DMI data returned. Platform hides SMBIOS or insufficient privileges." >&2
  exit 1
fi

HEADER="SLOT\tBANK\tSIZE\tTYPE\tFORM\tRANKS\tDATA/TOTAL\tECC\tSPEED\tCFG_SPEED\tMFG\tPART\tSERIAL"

# Print table header
echo -e "$HEADER" | column -t -s $'\t'
printf '%*s\n' 120 '' | tr ' ' '-'   # separator line

# AWK processing
awk -v csvfile="$OUTFILE" '
  BEGIN {
    RS=""; FS="\n"
    if (csvfile!="") {
      print "SLOT,BANK,SIZE,TYPE,FORM,RANKS,DATA/TOTAL,ECC,SPEED,CFG_SPEED,MFG,PART,SERIAL" > csvfile
    }
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

    # Print row to stdout (tab-separated for column)
    print locator "\t" bank "\t" size_out "\t" dtype "\t" form "\t" ranks "\t" width "\t" ecc "\t" speed "\t" cfgspeed "\t" mfg "\t" part "\t" serial

    # CSV output if requested
    if (csvfile!="") {
      gsub(/,/, ";", locator); gsub(/,/, ";", bank); gsub(/,/, ";", size_out)
      gsub(/,/, ";", dtype); gsub(/,/, ";", form); gsub(/,/, ";", ranks)
      gsub(/,/, ";", width); gsub(/,/, ";", ecc); gsub(/,/, ";", speed)
      gsub(/,/, ";", cfgspeed); gsub(/,/, ";", mfg); gsub(/,/, ";", part); gsub(/,/, ";", serial)
      print locator "," bank "," size_out "," dtype "," form "," ranks "," width "," ecc "," speed "," cfgspeed "," mfg "," part "," serial >> csvfile
    }
  }
' <<< "$DMI_OUT" | column -t -s $'\t'
