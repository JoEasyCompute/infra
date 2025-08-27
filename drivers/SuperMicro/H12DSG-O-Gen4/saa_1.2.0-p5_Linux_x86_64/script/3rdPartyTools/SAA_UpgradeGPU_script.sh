#!/bin/bash
#clear
CONFIG=SAA_UpgradeGPU_cfg.txt

if [ ! -f $CONFIG ];then
	echo "No $CONFIG file found!"
	exit 0
fi
source $CONFIG

cd $Tool_Package_version

# Cmd1: Tranfer the package to remote.
echo "Going to transfer the HGX package to remote via SAA"; sleep 3
./$Tool_Package_name -I Remote_INB -c RemoteExec --oi $OS_IP --ou $OS_USER --op $OS_PWD --file $INB_PKG_SOURCE_PATH --remote_cmd "cd /tmp/ && tar -zxvf HGXA100.tar.gz && cd $INB_PKG_TARGET_PATH && ll"
sleep 5

# Cmd2: check GPU versions
echo "Going to check GPU versions for remote via SAA"; sleep 3
./$Tool_Package_name -I Remote_INB -c RemoteExec --oi $OS_IP --ou $OS_USER --op $OS_PWD --remote_cmd "cd $INB_PKG_TARGET_PATH && source ./functions.sh && _generate_firmware_info"
sleep 5

# Cmd3: Inb Auto-Update 
echo "Going to Inb Auto-Update for remote via SAA"; sleep 3
./$Tool_Package_name -I Remote_INB -c RemoteExec --oi $OS_IP --ou $OS_USER --op $OS_PWD --remote_cmd "cd $INB_PKG_TARGET_PATH && ./startup_INB.sh"
sleep 5

# Cmd4: Auto GPU FW OOB Update
echo "Going to upgrade CEC via SAA"; sleep 3
./$Tool_Package_name -i $BMC_IP -u $BMC_USER -p $BMC_PWD -c UpdateGpu --item CEC --file "$OOB_PKG_PATH/CEC/$CEC_VER/$CEC_FW_FILE"
sleep 5

echo "Going to upgrade FPGA via SAA"; sleep 3
./$Tool_Package_name -i $BMC_IP -u $BMC_USER -p $BMC_PWD -c UpdateGpu --item FPGA --file "$OOB_PKG_PATH/FPGA/v$FPGA_VER/$FPGA_FW_FILE"
sleep 5

# AC-Cycle and Finish
echo "Please AC-cycle the system for the update to take effect." 




