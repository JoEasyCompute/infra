echo -off

if %1 == "" then 
   goto No_File_1
endif

if not exist %1 then 
   goto No_File_2
endif

if %2 == "" then 
   goto No_Bmc_User_Id
endif

if %3 == "" then 
   goto No_Bmc_User_Password
endif

SUM.efi -I Redfish_HI -u %2 -p %3 -c UpdateBios --file %1 --reboot
goto END

:No_File_1
echo **************************************************************************
echo *
echo *  Please input BIOS image name.
echo *
echo **************************************************************************
goto END

:No_File_2
echo **************************************************************************
echo *
echo *  %1 doesn't exist and please double check.
echo *
echo **************************************************************************
goto END

:No_Bmc_User_Id
echo **************************************************************************
echo *
echo *  Please input BMC user name.
echo *
echo **************************************************************************
goto END

:No_Bmc_User_Password
echo **************************************************************************
echo *
echo *  Please input BMC user password.
echo *
echo **************************************************************************
goto END

:END



