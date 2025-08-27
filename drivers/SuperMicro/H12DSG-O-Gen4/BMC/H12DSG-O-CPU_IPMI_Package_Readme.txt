================================================================================
Supermicro System IPMI Firmware Update Package Operation Instructions
================================================================================

Please read this document in it before performing the system IPMI firmware update.  
Please verify that your system meets the requirments.

********************************************************************************
This update package includes the following system software updates & utilities:

--- IPMI Firmware image ---

  IPMI Firmware  - BMC_H12AST2500-ROT-2201MS_20250217_01.05.08_STDsp.bin   (REV 01.05.08)

--- IPMI Firmware Update Tools ---

  SuperServer Automation Assistant (SAA) UEFI V1.2.0-p3 (2025/02/26)
 
  SAA.efi                              (SAA for UEFI)
  ReleaseNote.txt                      (SAA release note) 
  UEFI_SAA_UserGuide.pdf               (SAA User Guide) 
  flash.nsh                            (Update Script)
  command_example.txt                  (Example file for using the update script)


--- Supported Products ---

  Supermicro Motherboards:
  MBD-H12DSG-O-CPU
  

*************************************************************************************
                       SYSTEM HARDWARE and FIRMWARE REQUIREMENTS
*************************************************************************************

<NONE>


*************************************************************************************
                                         Warning
*************************************************************************************

1. Do not interrupt, reboot or remove power from your system during the update.
   Doing so may cause the system failure.

2. If the software update fails, you may contact our RMA Department to have the BIOS/
   IPMI firmware chip reprogrammed.  This will require shipping the board to Supermicro
   for repair.  Please submit your RMA request at:
   http://www.supermicro.com/support/rma/.
