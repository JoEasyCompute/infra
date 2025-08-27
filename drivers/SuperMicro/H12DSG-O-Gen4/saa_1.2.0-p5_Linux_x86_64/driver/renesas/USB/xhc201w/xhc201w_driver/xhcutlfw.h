/*
	File Name : xhcutlfw.h
	
	xHC Utility FW defines
	
	* Copyright (C) 2010 Renesas Electronics Corporation
	* Copyright (C) 2009 NEC Electronics Corporation
	* Copyright (c) 2009 NEC Engineering, Ltd.
	* Copyright (c) 2009 COSMO CO.,LTD. All Rights Reserved.
*/

///////////////////////////////////////////////////////////////////////////////
//
//		History
//		2009-09-29	rev0.01		base create 
//
///////////////////////////////////////////////////////////////////////////////


#ifndef _XHCUTLFW_H_
#define _XHCUTLFW_H_


/*
 *----------------------------------------------------------------------------
 *
 * HW block base address
 *
 *----------------------------------------------------------------------------
 */
#define XHC_IRAM_BASE			(0x00008000)
#define XHC_IRAM_SIZE			(0x00008000)

#define XHC_EXTMEM_BASE 		(0x03FF0000)

#define XHC_INTRAM_BASE 		(0x03FF8000)
#define XHC_INTRAM_SIZE 		(0x00004000)

#define XHC_WARAM_BASE			(0x03FFA800)
#define XHC_WARAM_SIZE			(0x00001800)

#define XHC_DBC_REGISTER		(XHC_EXTMEM_BASE + 0x5F00)
#define XHC_PCI_CONFIG			(XHC_EXTMEM_BASE + 0x6000)
#define XHC_PCI_MEMORY			(XHC_EXTMEM_BASE + 0x6400)
#define XHC_PCE_REGISTER		(XHC_EXTMEM_BASE + 0x6900)
#define XHC_HSP_REGISTER		(XHC_EXTMEM_BASE + 0x6A00)
#define XHC_HEP_REGISTER		(XHC_EXTMEM_BASE + 0x7400)
#define XHC_JCG_REGISTER		(XHC_EXTMEM_BASE + 0x7800)
#define XHC_IRC_REGISTER		(XHC_EXTMEM_BASE + 0x7900)
#define XHC_U2IF_REGISTER		(XHC_EXTMEM_BASE + 0x7A00)
#define XHC_SSIF_REGISTER		(XHC_EXTMEM_BASE + 0x7B00)
#define XHC_WAC_REGISTER		(XHC_EXTMEM_BASE + 0x7C00)
#define XHC_HTM_REGISTER		(XHC_EXTMEM_BASE + 0x7D00)
#define XHC_CCU_REGISTER		(XHC_EXTMEM_BASE + 0x7E00)
#define XHC_CCUP_REGISTER		(XHC_EXTMEM_BASE + 0x5900)
#define XHC_WAR_REGISTER		(XHC_EXTMEM_BASE + 0xDC00)

#define XHC_AHB_LENGTH			(0x04000000)

#define XHC_PCIEX_SIZE			(0x00002000)

/*
 *----------------------------------------------------------------------------
 * DBC register index
 *----------------------------------------------------------------------------
 */
#define DBCCMD					(XHC_DBC_REGISTER + 0x00)
#define DBCSTS					(XHC_DBC_REGISTER + 0x04)
#define DBCIMSK 				(XHC_DBC_REGISTER + 0x08)

/* DBCSTS bit define */
/* DBCIMSK bit define */
#define DBCSTS_ALL				0xFFFFFFFF


/*
 *----------------------------------------------------------------------------
 * PCI Config index
 *----------------------------------------------------------------------------
 */

#define PCICNF000			   (XHC_PCI_CONFIG + 0x00)
#define PCICNF004			   (XHC_PCI_CONFIG + 0x04)
#define PCICNF008			   (XHC_PCI_CONFIG + 0x08)
#define PCICNF00C			   (XHC_PCI_CONFIG + 0x0C)
#define PCICNF010			   (XHC_PCI_CONFIG + 0x10)
#define PCICNF014			   (XHC_PCI_CONFIG + 0x14)

#define PCICNF_REVISIONID		0x000000FF

// PCI Cnf(D720201)
#define XHC_EXTROM_INFO0_OFFSET		0x00EC
#define XHC_EXTROM_INFO1_OFFSET		0x00F0
#define XHC_CONTROL_STATUS_OFFSET	0x00F4
#define XHC_DATA0_OFFSET			0x00F8
#define XHC_DATA1_OFFSET			0x00FC

/*
 *----------------------------------------------------------------------------
 * PCI memory index
 *----------------------------------------------------------------------------
 */
#define HCSPARAMS0				(XHC_PCI_MEMORY + 0x00)
#define HCSPARAMS1				(XHC_PCI_MEMORY + 0x04)
#define HCSPARAMS2				(XHC_PCI_MEMORY + 0x08)
#define HCSPARAMS3				(XHC_PCI_MEMORY + 0x0C)
#define HCCPARAMS				(XHC_PCI_MEMORY + 0x10)
#define DBOFF					(XHC_PCI_MEMORY + 0x14)
#define RTSOFF					(XHC_PCI_MEMORY + 0x18)
//
#define USBCMD					(XHC_PCI_MEMORY + 0x20)
#define USBSTS					(XHC_PCI_MEMORY + 0x24)
//
#define CRCRLO					(XHC_PCI_MEMORY + 0x38)
#define CRCRHI					(XHC_PCI_MEMORY + 0x3C)
//
#define DCBAAPLO				(XHC_PCI_MEMORY + 0x50)
#define DCBAAPHI				(XHC_PCI_MEMORY + 0x54)
//
#define USBLEGSUP				(XHC_PCI_MEMORY + 0xA0)

/* USBCMD bit define */
#define USBCMD_RS				0x00000001
#define USBCMD_HCRST			0x00000002
#define USBCMD_INTE 			0x00000004
#define USBCMD_HSEE 			0x00000008
#define USBCMD_LHCRST			0x00000080
#define USBCMD_CSS				0x00000100
#define USBCMD_CRS				0x00000200
#define USBCMD_EWE				0x00000400


/*
 *----------------------------------------------------------------------------
 * PCI register index
 *----------------------------------------------------------------------------
 */
#define PCICMD					(XHC_PCE_REGISTER + 0x00)
#define PCISTS					(XHC_PCE_REGISTER + 0x04)
#define PCIIMSK 				(XHC_PCE_REGISTER + 0x08)
#define PCIDMASTSF				(XHC_PCE_REGISTER + 0x0C)
//
#define PCIASPML1				(XHC_PCE_REGISTER + 0x24)
#define PCITXL0S				(XHC_PCE_REGISTER + 0x4C)
//
#define PCICNF000M				(XHC_PCE_REGISTER + 0x60)
#define PCICNF008M				(XHC_PCE_REGISTER + 0x64)
#define PCICNF020M				(XHC_PCE_REGISTER + 0x68)
#define PCICNF050M				(XHC_PCE_REGISTER + 0x6C)

/* PCICMD bit define */
#define PCICMD_HSEE_DISABLE 	0x00000001
#define PCICMD_PCIEN			0x00010000
#define PCICMD_CHGATTR			0x80000000

/* PCISTS bit define */
/* PCIIMSK bit define */
#define PCISTS_ALL				0xFFFFFFFF

/* PCIDMASTSF bit define */
#define PCIDMASTSF_ALL			0xFFFFFFFF

/* PCIASPML1 bit define */
#define PCIASPML1_ASPML1EN		0x00000001
#define PCIASPML1_ASPML1STS 	0x00000100

/* PCITXL0S bit define */
#define PCITXL0S_TXL0S			0x00000001

/* PCI Config. HW default */
#define XHC_DEFAULT_VID 		(0x1033)
#define XHC_DEFAULT_DID 		(0x0194)

/* Register Access byte */
#define XHC_PCIREG_ACCESS_4BYTE		4

/*
 *----------------------------------------------------------------------------
 * register index
 *----------------------------------------------------------------------------
 */
#define CCUCMD					(XHC_CCU_REGISTER + 0x00)
#define CCUMODE1				(XHC_CCU_REGISTER + 0x0C)
#define CCUMODE2				(XHC_CCU_REGISTER + 0x10)
#define CCUMODE3				(XHC_CCU_REGISTER + 0x14)
#define CCUCLKSEL				(XHC_CCU_REGISTER + 0x18)
#define CCUCLKMSK				(XHC_CCU_REGISTER + 0x1C)

#define CCUCMD_CPURSTON 		0x00010000

#define CCUMODE1_WAKEUPSTS		0x00000001

#define CCUCLKSEL_SCLKSEL_60MHz 0x00000001

/*
 *----------------------------------------------------------------------------
 * register index
 *----------------------------------------------------------------------------
 */
#define PATCHROMADDR0           (XHC_WAR_REGISTER + 0x74)
#define PATCHRAMADDR0           (XHC_WAR_REGISTER + 0x78)
#define PATCHROMADDR1           (XHC_WAR_REGISTER + 0x7C)
#define PATCHRAMADDR1           (XHC_WAR_REGISTER + 0x80)



/*
 *----------------------------------------------------------------------------
 *
 * Serial ROM Format
 *
 *----------------------------------------------------------------------------
 */
#define XHCUTLFW_SROM_SIGNATURE_ADDR	0
#define XHCUTLFW_SROM_SIGNATURE_SIZE	sizeof(USHORT)
#define XHCUTLFW_SROM_BCD_ADDR_ADDR 	(XHCUTLFW_SROM_SIGNATURE_ADDR + XHCUTLFW_SROM_SIGNATURE_SIZE)
#define XHCUTLFW_SROM_BCD_ADDR_SIZE 	sizeof(USHORT)
#define XHCUTLFW_SROM_BCD_SIZE_ADDR 	(XHCUTLFW_SROM_BCD_ADDR_ADDR  + XHCUTLFW_SROM_BCD_ADDR_SIZE)
#define XHCUTLFW_SROM_BCD_SIZE_SIZE 	sizeof(USHORT)
#define XHCUTLFW_SROM_FWID_ADDR_ADDR	(XHCUTLFW_SROM_BCD_SIZE_ADDR  + XHCUTLFW_SROM_BCD_SIZE_SIZE)
#define XHCUTLFW_SROM_FWID_ADDR_SIZE	sizeof(USHORT)
#define XHCUTLFW_SROM_FWID_SIZE_ADDR	(XHCUTLFW_SROM_FWID_ADDR_ADDR + XHCUTLFW_SROM_FWID_ADDR_SIZE)
#define XHCUTLFW_SROM_FWID_SIZE_SIZE	sizeof(USHORT)
#define XHCUTLFW_SROM_ACD_ADDR_ADDR 	(XHCUTLFW_SROM_FWID_SIZE_ADDR + XHCUTLFW_SROM_FWID_SIZE_SIZE)
#define XHCUTLFW_SROM_ACD_ADDR_SIZE 	sizeof(USHORT)
//#define XHCUTLFW_SROM_ACD_SIZE_ADDR 	(XHCUTLFW_SROM_ACD_ADDR_ADDR  + XHCUTLFW_SROM_ACD_ADDR_SIZE)
//#define XHCUTLFW_SROM_ACD_SIZE_SIZE 	sizeof(USHORT)

//#define XHCUTLFW_SROM_SIGNATURE 		(0x55AA)

#define XHCUTLFW_SROM_ACD_ID_ADDR						0
#define XHCUTLFW_SROM_ACD_ID_SIZE						sizeof(USHORT)
#define XHCUTLFW_SROM_ACD_LENGTH_ADDR					(XHCUTLFW_SROM_ACD_ID_ADDR + XHCUTLFW_SROM_ACD_ID_SIZE)
#define XHCUTLFW_SROM_ACD_LENGTH_SIZE					sizeof(USHORT)
//#define XHCUTLFW_SROM_ACD_HEADER_SIZE					(XHCUTLFW_SROM_ACD_ID_SIZE + XHCUTLFW_SROM_ACD_LENGTH_SIZE)
#define XHCUTLFW_SROM_ACD_MEMORY_SIZE_ADDR				(XHCUTLFW_SROM_ACD_LENGTH_ADDR + XHCUTLFW_SROM_ACD_LENGTH_SIZE)
#define XHCUTLFW_SROM_ACD_MEMORY_SIZE_SIZE				sizeof(ULONG)
#define XHCUTLFW_SROM_ACD_PAGE_SIZE_ADDR				(XHCUTLFW_SROM_ACD_MEMORY_SIZE_ADDR + XHCUTLFW_SROM_ACD_MEMORY_SIZE_SIZE)
#define XHCUTLFW_SROM_ACD_PAGE_SIZE_SIZE				sizeof(USHORT)
//#define XHCUTLFW_SROM_ACD_DEVICE_CODE_ADDR				(XHCUTLFW_SROM_ACD_PAGE_SIZE_ADDR + XHCUTLFW_SROM_ACD_PAGE_SIZE_SIZE)
#define XHCUTLFW_SROM_ACD_DEVICE_CODE_SIZE				sizeof(USHORT)
//#define XHCUTLFW_SROM_ACD_SERIALROM_INFORMATION_SIZE	(XHCUTLFW_SROM_ACD_MEMORY_SIZE_SIZE + XHCUTLFW_SROM_ACD_PAGE_SIZE_SIZE + XHCUTLFW_SROM_ACD_DEVICE_CODE_SIZE)
//#define XHCUTLFW_SROM_ACD_MULTIPURPOSE_DATA_WRITE		0x0001
#define XHCUTLFW_SROM_ACD_SERIALROM_INFORMATION 		0x0002


/*
 *----------------------------------------------------------------------------
 *
 * FW Interface
 *
 *----------------------------------------------------------------------------
 */
#define XHCUTLFW_CONTROL				(USBLEGSUP)
#define XHCUTLFW_STATUS 				(DCBAAPHI)
#define XHCUTLFW_COMMAND_BASE			(XHC_INTRAM_BASE + 0x00000000)
#define XHCUTLFW_COMMAND_SIZE			0x00000020
#define XHCUTLFW_EXTEND_STATUS_BASE 	(XHC_INTRAM_BASE + XHCUTLFW_COMMAND_SIZE)
#define XHCUTLFW_EXTEND_STATUS_SIZE 	0x00000010
#define XHCUTLFW_MAX_FW_SIZE			0x00003000
#define XHCUTLFW_DATA_WORK_AREA_1_BASE	(XHC_IRAM_BASE + XHCUTLFW_MAX_FW_SIZE)
#define XHCUTLFW_DATA_WORK_AREA_1_SIZE	(XHC_IRAM_SIZE - XHCUTLFW_MAX_FW_SIZE)
#define XHCUTLFW_DATA_WORK_AREA_2_BASE	(XHC_INTRAM_BASE + 0x00001000)	//Stack(2KByte) + Work(2KByte)
#define XHCUTLFW_DATA_WORK_AREA_2_SIZE	(XHCUTLFW_MAX_FW_SIZE)
//
#define XHCUTLFW_CONTROL_OFFSET 		(0x500)  //USBLEGSUP
#define XHCUTLFW_STATUS_OFFSET			(DCBAAPHI  - XHC_PCI_MEMORY)

/* CONTROL bit define */
#define XHCUTLFW_CONTROL_ACTIVE 		0x00010000

/*
 *----------------------------------------------------------------------------
 * Status
 *----------------------------------------------------------------------------
 */
/* Result value define */
typedef enum _XHCUTLFW_STATUS_RESULT {
	XHCUTLFW_SR_SUCCESS 				 =	 0 ,
	XHCUTLFW_SR_DMA_ERROR				 = (-1),
	XHCUTLFW_SR_READ_SERIAL_ROM_ERROR	 = (-2),
	XHCUTLFW_SR_WRITE_SERIAL_ROM_ERROR	 = (-3),
	XHCUTLFW_SR_ERASE_SERIAL_ROM_ERROR	 = (-4),
	XHCUTLFW_SR_READ_PROM_ERROR 		 = (-5),
	XHCUTLFW_SR_WRITE_PROM_ERROR		 = (-6),
	XHCUTLFW_SR_ERASE_PROM_ERROR		 = (-7),
	XHCUTLFW_SR_INVALID_COMMAND 		 = (-9),
	XHCUTLFW_SR_UNKNOWN_SERIALROM		 = (-10)
}  XHCUTLFW_STATUS_RESULT, *PXHCUTLFW_STATUS_RESULT;

/* State value define */
typedef enum _XHCUTLFW_STATUS_STATE {
	XHCUTLFW_SS_IDLE	=	0,
	XHCUTLFW_SS_RUN 	=	1
}  XHCUTLFW_STATUS_STATE, *PXHCUTLFW_STATUS_STATE;

#endif /* _XHCUTLFW_H_ */
