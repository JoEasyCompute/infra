#!/bin/sh
set -e

INTERFACE=$(dmesg | grep -m 1 "on urndis" | awk '{print $1}' | sed 's/://')
if [ -z "$INTERFACE" ]
then
    echo "Redfish Host Interface not found."
    retuen 1
fi

if $(cat /etc/devd.conf | grep -q "dhclient $INTERFACE")
then
    echo "Already configured."
    return 1
else
    echo 'notify 101 {
    match "system"         "IFNET";
    match "subsystem"       "'$INTERFACE'";
    match "type"           "ATTACH";
    action "dhclient '$INTERFACE'";
};' >> /etc/devd.conf

fi

/etc/rc.d/devd restart
echo "Configuration is completed."
