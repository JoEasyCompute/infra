#!/usr/bin/env bash
set -euo pipefail
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi
SUDO="sudo -n"; [ "${EUID:-$(id -u)}" -eq 0 ] && SUDO=""

have(){ command -v "$1" >/dev/null 2>&1; }
fail(){ echo "ERROR: $*" >&2; exit 1; }

for c in jq lsblk ip; do have "$c" || fail "missing dependency: $c"; done

collect_system(){
  local now host os kern virt
  now=$(date -Is); host=$(hostname || true)
  if have hostnamectl; then
    os=$(hostnamectl 2>/dev/null | awk -F': ' '/Operating System/{print $2}')
    kern=$(uname -r); virt=$(hostnamectl 2>/dev/null | awk -F': ' '/Virtualization/{print $2}')
  else
    os=$(grep -m1 PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"'); kern=$(uname -r); virt=""
  fi
  jq -n --arg time "$now" --arg host "$host" --arg os "$os" --arg kern "$kern" --arg virt "$virt" \
     '{timestamp:$time, hostname:$host, os:$os, kernel:$kern, virtualization:(($virt|select(length>0)) // null)}'
}

collect_cpu(){
  if have dmidecode && $SUDO dmidecode -t processor >/dev/null 2>&1; then
    $SUDO dmidecode -t processor | awk 'BEGIN{RS="\n\n";FS="\n"} /Processor Information/{
      sok=mfg=ver=id=serial=core=thr="";
      for(i=1;i<=NF;i++){
        if($i~/(Socket Designation:)/)sok=substr($i,index($i,": ")+2);
        if($i~/(Manufacturer:)/)mfg=substr($i,index($i,": ")+2);
        if($i~/(Version:)/)ver=substr($i,index($i,": ")+2);
        if($i~/(ID:)/)id=substr($i,index($i,": ")+2);
        if($i~/(Serial Number:)/)serial=substr($i,index($i,": ")+2);
        if($i~/(Core Count:)/)core=substr($i,index($i,": ")+2);
        if($i~/(Thread Count:)/)thr=substr($i,index($i,": ")+2);
      }
      printf("%s\t%s\t%s\t%s\t%s\t%s\t%s\n",sok,mfg,ver,id,serial,core,thr);
    }' | jq -R -s 'split("\n")|map(select(length>0))|map(split("\t"))|
        map({socket:.[0],manufacturer:.[1],model:.[2],id:.[3],serial:.[4],
            cores:(.[5]|tonumber?),threads:(.[6]|tonumber?)})'
  else
    lscpu | awk -F': *' '/Model name/{print $2;exit}' | jq -R -s 'map(select(length>0))|map({model:.,note:"Serials require dmidecode (sudo)."})'
  fi
}

collect_ram(){
  if have dmidecode && $SUDO dmidecode -t memory >/dev/null 2>&1; then
    $SUDO dmidecode -t memory | awk 'BEGIN{RS="\n\n";FS="\n"} /Memory Device/{
      size=type=speed=cfg=mfg=part=serial=locator=bank="";
      for(i=1;i<=NF;i++){
        if($i~/(Size:)/)size=substr($i,index($i,": ")+2);
        if($i~/(Type:)/)type=substr($i,index($i,": ")+2);
        if($i~/(Speed:)/)speed=substr($i,index($i,": ")+2);
        if($i~/(Configured Memory Speed:)/)cfg=substr($i,index($i,": ")+2);
        if($i~/(Manufacturer:)/)mfg=substr($i,index($i,": ")+2);
        if($i~/(Part Number:)/)part=substr($i,index($i,": ")+2);
        if($i~/(Serial Number:)/)serial=substr($i,index($i,": ")+2);
        if($i~/(Locator:)/)locator=substr($i,index($i,": ")+2);
        if($i~/(Bank Locator:)/)bank=substr($i,index($i,": ")+2);
      }
      if(size!="No Module Installed") printf("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",locator,bank,size,type,speed,cfg,mfg,part,serial);
    }' | jq -R -s 'split("\n")|map(select(length>0))|map(split("\t"))|
        map({locator:.[0],bank:.[1],size:.[2],type:.[3],speed:.[4],cfg_speed:.[5],manufacturer:.[6],part:.[7],serial:.[8]})'
  else
    jq -n '[]'
  fi
}

collect_storage(){ lsblk -J -O -e7 | jq '{blockdevices:.blockdevices}'; }
collect_network(){
  local lhw ipj; if have lshw && $SUDO lshw -short >/dev/null 2>&1; then lhw=$($SUDO lshw -json -class network||echo '[]'); else lhw='[]'; fi
  ipj=$(ip -j addr || echo '[]')
  printf '%s\n' "$lhw" | jq --argjson ip "$ipj" '
    def addr_for($n): ($ip[]? | select(.ifname==$n) | {mtu,operstate,addr_info}) // {};
    ( . // [] ) | map({product,vendor,serial,businfo,logicalname,configuration,capabilities}+addr_for(.logicalname))'
}

main(){
  local sys cpu ram sto net
  sys=$(collect_system)
  cpu=$(collect_cpu)
  ram=$(collect_ram)
  sto=$(collect_storage)
  net=$(collect_network)
  jq -n --argjson system "$sys" --argjson cpu "$cpu" --argjson ram "$ram" \
        --argjson storage "$sto" --argjson network "$net" \
     '{system:$system,cpu:$cpu,ram:$ram,storage:$storage,network:$network}'
}
main "$@"
