#!/usr/bin/env bash
# Add RHI in firewall whitelist
ping -w 1 -c 1 169.254.3.1 > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Redfish Host Interface is not enabled."
    exit 0
fi
systemctl status SuSEfirewall2 | grep -q 'Active: active' > /dev/null 2>&1
if [ $? -ne 0 ]
then
    echo "Firewall is not active."
    exit 0
fi

LASTEST_REGISTER=$(journalctl -k --output cat | grep 'rndis_host\|cdc_subset\|cdc_ether'| tail -1)
if $(echo $LASTEST_REGISTER | grep -q rndis_host); then
    echo "RNDIS host found, enabling the interface."
    driver_name=rndis_host
elif $(echo $LASTEST_REGISTER | grep -q cdc_ether); then
    echo "CDC ether found, enabling the interface." 
    driver_name=cdc_ether
elif $(echo $LASTEST_REGISTER | grep -q cdc_subset); then
    echo "CDC subset found, enabling the interface."
    driver_name=cdc_subset
else
    echo "Redfish host interface not found, please check the support for the platforms."
    exit 0
fi

MAC=$(journalctl -k --output cat | grep \'$driver_name\' | tail -n 1)
MAC_T=$(echo $MAC | rev | cut -d" " -f 1 | rev)
INTERFACE=$(echo $MAC | awk '{print $3}' | sed 's/://') 

if $(journalctl -k --output cat | grep -e "$driver_name.*renamed" -e "register '$driver_name'" | tail -1 | grep -q renamed) ; then
    INTERFACE_RENAMED=$(journalctl -k --output cat | grep -o "$driver_name.*renamed" | tail -1 | awk '{print $3}' | sed  's/://')
    RENAME=true
fi

for i in $( ls /sys/class/net )
do
  addr=$(cat /sys/class/net/$i/address)
  if [[ "$MAC_T" == "$addr" ]]
  then
    echo "'rndis_host' interface: "$i
    tmp=$(grep 'FW_DEV_INT=' /etc/sysconfig/SuSEfirewall2)
    if [ ! -z "$tmp" ]
    then
      if echo "${tmp}" | grep -qP "(?<=\"|\s)${i}(?=\"|\s)" ;
      then
        echo "Redfish_HI is already in firewall whitelist"
        exit 0
      fi
	    tmp2=$(echo ${tmp} | sed 's/.$//')
      sed -i "s/${tmp}/${tmp2} ${i}\\\"/" /etc/sysconfig/SuSEfirewall2
      echo "Add Redfish_HI in firewall whitelist."
    else
      echo "Create new firewall config: /etc/sysconfig/SuSEfirewall2"
      echo "FW_DEV_INT=\"${i}\"" >> /etc/sysconfig/SuSEfirewall2
      echo "Add Redfish_HI in firewall whitelist."
    fi
    systemctl restart SuSEfirewall2
    exit 0
  fi
done

# Handle the renaming case
if [[ $RENAME == "true" ]]; then
  echo "'rndis_host' interface: "$INTERFACE_RENAMED
  tmp=$(grep 'FW_DEV_INT=' /etc/sysconfig/SuSEfirewall2)
  if [ ! -z "$tmp" ]
  then
    if echo "${tmp}" | grep -qP "(?<=\"|\s)${i}(?=\"|\s)" ;
    then
      echo "Redfish_HI is already in firewall whitelist"
      exit 0
    fi
    tmp2=$(echo ${tmp} | sed 's/.$//')
    sed -i "s/${tmp}/${tmp2} ${i}\\\"/" /etc/sysconfig/SuSEfirewall2
    echo "Add Redfish_HI in firewall whitelist."
  else
    echo "Create new firewall config: /etc/sysconfig/SuSEfirewall2"
    echo "FW_DEV_INT=\"${i}\"" >> /etc/sysconfig/SuSEfirewall2
    echo "Add Redfish_HI in firewall whitelist."
  fi
  systemctl restart SuSEfirewall2
  exit 0
fi

# If renaming does not occur
if $(ls /sys/class/net | grep -q $INTERFACE)
then
  echo "'rndis_host' interface: "$INTERFACE
  tmp=$(grep 'FW_DEV_INT=' /etc/sysconfig/SuSEfirewall2)
  if [ ! -z "$tmp" ]
  then
    if echo "${tmp}" | grep -qP "(?<=\"|\s)${i}(?=\"|\s)" ;
    then
      echo "Redfish_HI is already in firewall whitelist"
      exit 0
    fi
    tmp2=$(echo ${tmp} | sed 's/.$//')
    sed -i "s/${tmp}/${tmp2} ${i}\\\"/" /etc/sysconfig/SuSEfirewall2
    echo "Add Redfish_HI in firewall whitelist."
  else
    echo "Create new firewall config: /etc/sysconfig/SuSEfirewall2"
    echo "FW_DEV_INT=\"${i}\"" >> /etc/sysconfig/SuSEfirewall2
    echo "Add Redfish_HI in firewall whitelist."
  fi
  systemctl restart SuSEfirewall2
  exit 0
fi
