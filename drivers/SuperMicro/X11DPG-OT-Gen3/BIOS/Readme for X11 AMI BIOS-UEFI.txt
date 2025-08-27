***** Important Notice *****


On X11 Purley platforms, Supermicro had introduced a jumper-free solution
that places ME into the manufacturing mode.  The user doesn't have to open
the chassis to change the ME-related jumper on the motherboard any more.
The ME manufacturing mode is required upon updating all software-strap
settings in the Flash Descriptor Table (FDT) inside the ME region.

If the user does not use Supermicro's Purley BIOS flash package, the BIOS
will instruct the AMI AFU tool to terminate the process with the below
message:

 "- Error: Please use BIOS flash package from www.supermicro.com for
 BIOS update."

The following instructions describe the BIOS upgrade process of the X11
Purley BIOS flash package.  Please follow the instructions carefully to
prevent the need of any RMA repair or replacement.


================================================
Standard BIOS Update Procedure under UEFI Shell
================================================

1. Save the BIOS update package to your computer.

2. Extract the files from the UEFI folder of the BIOS package to a USB stick. 
   (Note: The USB stick doesn't have to be bootable, but has to be formatted
   with the FAT/FAT32 file system.)

3. Plug the USB stick into a USB port, boot to the Build-In UEFI Shell, and
   type FLASH.nsh BIOSname#.### to start the BIOS update:

     Shell> fs0:
     fs0:\> cd UEFI
     fs0:\UEFI> flash.nsh X11DPU7.218

4. The FLASH.NSH script will compare the Flash Descriptor Table (FDT) code in
   the new BIOS with the existing one in the motherboard:

   a. If a different FDT is found, a new file, STARTUP.NSH, will be created,
      and the system will go into reboot in 10 seconds if no key is pressed.
      Press "Y" to go into system reboot right away.  At the reboot, hit
      "F11" key to invoke the boot menu & boot into the build-in UEFI Shell
      again.  The BIOS update will resume, automatically. 

   b. If the FDT is the same, the BIOS update will be started right away.  No
      reboot will be needed.

5. Do not interrupt the process until the BIOS update is complete.

6. Perform an A/C power cycle after the message indicating the BIOS update
   has completed.

7. Go to the BIOS configuration, and restore the BIOS settings.



Notes:

* Supermicro no longer supports the BIOS update method in DOS.

* If the BIOS flash fails, you may contact our RMA Dept. to have the BIOS
  chip reprogrammed.  This will require shipping the board to our RMA Dept.
  for repair.  Please submit your RMA request at 
  http://www.supermicro.com/support/rma/.



********* BIOS Naming Convention **********

-(For BIOS 3.4 or earlier)-

BIOS name  : PPPPPSSY.MDD
PPPPP      : 5-Bytes for project name
SS         : 2-Bytes supplement for PPPPP (if applicable)
Y          : Year, 4 -> 2014, 5-> 2015, 6->2016
MDD        : Month + Date, for months, A -> Oct., B -> Nov., C -> Dec.

E.g., For BIOS with the build date, 2/18/2017:
        X11DPU+  -> X11DPU7.218
        X11DPi-T -> X11DPi7.218


-(For BIOS 3.4a or later)-

BIOS name  : BIOS_X11DXXXXX-BBBB_YYYYMMDD_VVV_T.TTt_STDsp.bin

"BIOS"     : BIOS image identifier
X12DXXXXX  : Project name
BBBB       : 4-digit project ID
YYYY       : Year of the build date
MM         : Month of the build date
DD         : Day of the build date
T.Tt       : BIOS revision number
"STD"      : Standard BIOS ("OEM" = Custom BIOS)
"sp"       : Production signed image (No "sp" means Unsigned.)

Examples:
           X11DPi-N(T) -> BIOS_X11DPi-N-0917_20210312_3.4a_STDsp.bin
           X11DPT-B(H) -> BIOS_X11DPTB-0962_20210113_3.4a_STDsp.bin





---Last Update on: 03/17/2021---