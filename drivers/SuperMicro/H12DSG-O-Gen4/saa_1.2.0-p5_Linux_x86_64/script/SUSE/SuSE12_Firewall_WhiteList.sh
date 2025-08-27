#!/usr/bin/env bash
# Check if the system support the Redfish Host Interface
if ! $( lsusb --verbose 2>&1 | grep -iq -e rndis -e cdc ); then
    echo "This platform does not support Redfish Host Interface"
    exit 1
fi
ping -w 1 -c 1 169.254.3.1 > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Redfish Host Interface is not enabled. No need to change firewall settings."
    exit 0
fi

# Go through all interfaces in the /proc/net/dev, if the driver name match "rndis_host" or "cdc_subset" or cdc_ether than configure the interface as Redfish Host Interface
LINE_NUM=$(cat /proc/net/dev | wc -l)
for ((i=3; i<=$LINE_NUM; i++));
do
    INTERFACE=$(cat /proc/net/dev | sed "$i!d" | cut -d ":" -f1 )
    if $(ethtool -i $INTERFACE > /dev/null 2>&1);
    then
      if $(ethtool -i $INTERFACE | grep -qe "rndis_host" -e "cdc_ether" -e "cdc_subset" > /dev/null 2>&1);
      then
          # Add RHI to firewall whitelist
          systemctl status SuSEfirewall2 | grep -q 'Active: active' > /dev/null 2>&1
          if [ $? -ne 0 ]
          then
              echo "Firewall is not active. No need to change firewall settings."
          else
            tmp=$(grep 'FW_DEV_INT=' /etc/sysconfig/SuSEfirewall2)
            if [ ! -z "$tmp" ]
            then
              if echo "${tmp}" | grep -qP "(?<=\"|\s)${INTERFACE}(?=\"|\s)" ;
              then
                echo "Redfish Host Interface is already in firewall whitelist"
                exit 0
              fi
              tmp2=$(echo ${tmp} | sed 's/.$//')
              sed -i "s/${tmp}/${tmp2} ${INTERFACE}\\\"/" /etc/sysconfig/SuSEfirewall2
              echo "Add Redfish Host Interface in firewall whitelist."
            else
              echo "Create new firewall config: /etc/sysconfig/SuSEfirewall2"
              echo "FW_DEV_INT=\"${INTERFACE}\"" >> /etc/sysconfig/SuSEfirewall2
              echo "Add Redfish Host Interface in firewall whitelist."
            fi
            systemctl restart SuSEfirewall2
          fi
          exit 0
      fi
    fi
done
echo "Can't find Redfish Host Interface."    
exit 1