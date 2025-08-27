echo -off

set Debug_Mode 0

if %1 == "" then
   goto Err_Print
endif

if not exist %1 then 
   goto No_File
endif

if %2 == "-d" then 
   set Debug_Mode 1
endif

if exist fdt.smc then 
   mv fdt.smc fdtx64.efi
endif

if exist afuefi.smc then 
   mv afuefi.smc afuefix64.efi
endif

# ##Read CMOS50 value
if %Debug_Mode% == 0 then 
   fdtx64.efi -r 50
endif

if %Debug_Mode% == 1 then 
   fdtx64.efi -r 50 -d
endif

if %lasterror% == "0x5A" then 
   if not %lasterror% == "0x5B" then 
      goto FDT_Different
   endif
endif

goto Compare_FDT_Table

:Compare_FDT_Table
echo **************************************************************************
echo *
echo *  Compare Flash Descriptor Table(FDT). Please wait...
echo *
echo **************************************************************************
# echo afuefix64.efi %1 /ME
fdtx64.efi -w 50 A5
afuefix64.efi %1 /ME

#fdtx64.efi -b 0

if %Debug_Mode% == 0 then 
   fdtx64.efi -r 50
endif

if %Debug_Mode% == 1 then 
   fdtx64.efi -r 50 -d
endif

if %lasterror% == "0xA5" then 
   if not %lasterror% == "0xA6" then 
      echo flash BIOS
      goto Flash_BIOS
   endif
endif

if %lasterror% == "0x5A" then 
   if not %lasterror% == "0x5B" then 
      echo FDT different
      goto FDT_Different
   endif
endif

:Flash_BIOS
echo **************************************************************************
echo *
echo *  FDT is same. Program BIOS and ME (excluding FDT) regions...
echo *
echo **************************************************************************

# echo afuefix64.efi %1 /P /B /N /K /R
fdtx64.efi -w 50 A5
afuefix64.efi %1 /P /B /N /K /R /ME
fdtx64.efi -w 50 00
fdtx64.efi -c
goto END

:FDT_Different
if %Debug_Mode% == 1 then 
   fdtx64.efi -r 51 -d
endif

if %Debug_Mode% == 0 then 
   fdtx64.efi -r 51
endif

if %lasterror% == "0x18" then 
   if not %lasterror% == "0x19" then 
      goto Update_BIOS_ME
   endif
endif

if %lasterror% == "0x0" then 
   if not %lasterror% == "0x1" then 
      goto Modify_Autoexec
   endif
endif

goto CMOS51_Not_Equal_00h_OR_18h

:Update_BIOS_ME
echo **************************************************************************
echo *
echo *  Program BIOS and ME (including FDT) regions...
echo *
echo **************************************************************************

# echo afuefix64.efi %1 /P /B /N /K /R /ME
fdtx64.efi -w 50 A5
afuefix64.efi %1 /P /B /N /K /R /ME
fdtx64.efi -c
mv fdtx64.efi fdt.smc
mv afuefix64.efi afuefi.smc

cd \
if exist Startup.nsh then 
    echo **************************************************************************
    echo *
    echo *  Please ignore this "'Shell: Cannot read from file - Device Error'" 
    echo *  warning message due to it does not impact flashing process.
    echo *
    echo **************************************************************************
    del Startup.nsh
endif

if exist a.nsh then 
   mv a.nsh Startup.nsh
endif

goto END1

:Modify_Autoexec
echo **************************************************************************
echo *
echo *  FDT is different. Creating new Startup.nsh file...
echo *
echo **************************************************************************


if %Debug_Mode% == 1 then 
   echo Modify c:\Startup.nsh
endif

fdtx64.efi -mauto %1

:Reboot_System
echo **************************************************************************
echo *
echo *   System will reboot to change the operating mode in 10 seconds....
echo *   
echo *   Please also ensure to boot system from "'UEFI: Built-in EFI Shell'"  
echo *   boot device by pressing F11 hot key later for continuing process 
echo *   of programming BIOS.
echo *
echo **************************************************************************

#choice /C:Y /T:Y,10
echo 
Stall 10000000

if %Debug_Mode% == 1 then 
   pause
endif

fdtx64.efi -reset

:No_File
echo **************************************************************************
echo *
echo *  %1 doesn't exist and please double check.
echo *
echo **************************************************************************
goto END

:CMOS51_Not_Equal_00h_OR_18h
# echo CMOS51 doesn't equal 00h or 18h !
# echo ManufacturingMode is Disabled.
echo **************************************************************************
echo *
echo *  Current BIOS or hardware does not support software controllable
echo *  ME Manufactuing mode.
echo *
echo **************************************************************************
mv afuefix64.efi afuefi.smc

cd \
if exist a.nsh then 
    echo **************************************************************************
    echo *
    echo *  Please ignore this "'Shell: Cannot read from file - Device Error'" 
    echo *  warning message due to it does not impact flashing process.
    echo *
    echo **************************************************************************
    del Startup.nsh
endif

if exist a.nsh then 
    mv a.nsh Startup.nsh
endif
goto END1

:Err_Print
echo **************************************************************************
echo *
echo "*  Usage:"
echo "*         flash.nsh romfile"
echo *
echo **************************************************************************

:END
if exist fdtx64.efi then 
   mv fdtx64.efi fdt.smc
endif

if exist afuefix64.efi then 
   mv afuefix64.efi afuefi.smc
endif

:END1

