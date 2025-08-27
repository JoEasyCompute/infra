# Note 169.254.3.1 is used as the default host ip, it will be changed automatically if the BMC's configuration is changed.
support_checking(){
    # Use lsusb to check redfish support, skip support checking if the lsusb does not install.
    lsusb > /dev/null 2>&1
    if [ $? -ne 127 ]; then 
        if ! $( lsusb --verbose 2>&1 | grep -iq -e rndis -e cdc ); then
        echo "This platform does not support Redfish host Interface"
        exit 1
        fi
    fi
}

legacy_method(){
    # If the latest method can't work, execute legacy method
    
    # Set default values
    driver_name=rndis_host
    SYSTEM=others
    RENAME=false

    # If the debian system
    if $(cat /etc/*-release | grep -q Debian);then
        SYSTEM=debian
    else
        SYSTEM=others
    fi
    
    # Determine the driver name
    if [[ $SYSTEM == "debian" ]]; then
        LASTEST_REGISTER=$(dmesg | grep 'rndis_host\|cdc_subset\|cdc_ether' | tail -1)
    else
        LASTEST_REGISTER=$(journalctl -k --output cat | grep 'rndis_host.*usb0\|cdc_subset.*usb0\|cdc_ether.*usb0'| tail -1)
	    if [ -z "$LASTEST_REGISTER" ]; then
	        LASTEST_REGISTER=$(journalctl -k --output cat | grep 'rndis_host\|cdc_subset\|cdc_ether' | tail -1)
	    fi
    fi
     
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
    
    if [[ $SYSTEM == "debian" ]]; then
        INTERFACE=$(dmesg | grep -o $driver_name.*:\ register\ \'$driver_name\' | tail -1 | cut -d ' ' -f3 | sed 's/://')
        MAC_T=$(dmesg | grep -o $driver_name.*:\ register\ \'$driver_name\' | tail -1 | grep -o '[^ ]*$')
        
	if $(dmesg | grep -e "$driver_name.*renamed" -e "register '$driver_name'" | tail -1 | grep -q renamed); then
            INTERFACE_RENAMED=$(dmesg | grep -o "$driver_name.*renamed" | tail -1 | cut -d ' ' -f3 | sed 's/://') 
            RENAME=true    
        fi
    else
        MAC=$(journalctl -k --output cat | grep \'$driver_name\' | tail -n 1)
        MAC_T=$(echo $MAC | rev | cut -d" " -f 1 | rev)
        INTERFACE=$(echo $MAC | awk '{print $3}' | sed 's/://') 
        
        if $(journalctl -k --output cat | grep -e "$driver_name.*renamed" -e "register '$driver_name'" | tail -1 | grep -q renamed) ; then
            INTERFACE_RENAMED=$(journalctl -k --output cat | grep -o "$driver_name.*renamed" | tail -1 | awk '{print $3}' | sed  's/://')
            RENAME=true
        fi
    fi
    
   for i in $(ls /sys/class/net); do
        MAC_C=$(cat /sys/class/net/$i/address)
        if [[ "$MAC_T" == "$MAC_C" ]]; then
            ip link set dev $i up
            ip addr add 169.254.3.1/24 dev $i
            exit 0
        fi
    done

    # Handle the renaming case
    if [[ $RENAME == "true" ]]; then
        ip link set dev $INTERFACE_RENAMED up
        ip addr add 169.254.3.1/24 dev $INTERFACE_RENAMED
        exit 0
    fi

    # If renaming does not occur
    if $(ls /sys/class/net | grep -q $INTERFACE); then
        ip link set dev $INTERFACE up
        ip addr add 169.254.3.1/24 dev $INTERFACE
        exit 0
    fi
   
    echo "RHI enable failed, please report the issue."
    exit 1

}
enable_checking(){

    # Check the RHI channel has already be constructed or not
    if ping -w 1 -c 1 169.254.3.1 > /dev/null 2>&1; then
        if $(ip addr | grep -q 169.254.3); then
            echo "Host side interface can be reached."
            if ping -w 1 -c 1 169.254.3.254 > /dev/null 2>&1; then
                echo "BMC side interface can be reached."
                echo "Redfish Host Interface has already been enabled."
                exit 0
            else
                echo "There are some issues occurred on at the BMC side, please reset the BMC."
                exit 1
            fi
        fi 
    fi

}

enable_interface(){
    # Go through all interfaces in the /proc/net/dev, if the driver name match "rndis_host" or "cdc_subset" or cdc_ether than configure the interface as Redfish Host Interface
    
    # Check ethtool suppport, if not support, leverage the linux file system to get driver name
    ethtool > /dev/null 2>&1
    if [ $? -ne 127 ]; then 
        # If support ethtool
        LINE_NUM=$(cat /proc/net/dev | wc -l)

        for i in $(seq 3 $LINE_NUM)
        do
            INTERFACE=$(cat /proc/net/dev | sed "$i!d" | cut -d ":" -f1 )
            if $(ethtool -i $INTERFACE > /dev/null 2>&1 );
                then
                if $(ethtool -i $INTERFACE | grep -qe "rndis_host" -e "cdc_ether" -e "cdc_subset" );
                    then
                    ip link set dev $INTERFACE up
                    ip addr add 169.254.3.1/24 dev $INTERFACE
                    echo "Done enabling Redfish Host Interface."
                    exit 0
                fi
            fi
        done
    else
        # If the ethtool is not supported by the system
        for i in $(ls /sys/class/net); do
            if $(readlink /sys/class/net/$i/device/driver/module | grep -qe "rndis_host" -e "cdc_ether" -e "cdc_subset" );
            then
                ip link set dev $i up
                ip addr add 169.254.3.1/24 dev $i
                exit 0
            fi
        done
    fi
        
    # Execute legacy method if current methods not work 
    legacy_method
}

support_checking
enable_checking
enable_interface
