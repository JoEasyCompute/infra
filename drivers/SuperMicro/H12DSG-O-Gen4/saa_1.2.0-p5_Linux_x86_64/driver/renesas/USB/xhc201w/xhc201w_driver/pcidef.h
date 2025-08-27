/*
	File Name : pcidef.h
	
	PCI interface defines
	
    * Copyright (C) 2010 Renesas Electronics Corporation

*/

///////////////////////////////////////////////////////////////////////////////
//
//		History
//      2010-09-29  rev0.01     base create
//
///////////////////////////////////////////////////////////////////////////////

#ifndef _XHC_PCIDEF_H_
#define _XHC_PCIDEF_H_

typedef union __PCI_CONFIG_REG
{
	unsigned char data[256];
	struct{
		USHORT	venderID;
		USHORT	deviceID;
		USHORT	command;
		USHORT	status;
		UCHAR	revision;
		UCHAR	progIF;
		UCHAR	subclass;
		UCHAR	baseclass;
		UCHAR	cashe;
		UCHAR	latency;
		UCHAR	header;
		UCHAR	selftest;
		UINT	baseAddr[6];
		UINT	cardbus;
		USHORT	subvenderID;
		USHORT	subsysID;
		UINT	exrom;
		UCHAR	cap;
		UCHAR	rsv0[7];
		UCHAR	intline;
		UCHAR	intpin;
		UCHAR	mingnt;
		UCHAR	maxlat;
		UCHAR	devreg[192];
	};
}PCI_CONFIG_REG, *PPCI_CONFIG_REG;


// pci 
#define MAX_BUS_NUM		256
#define MAX_DEV_NUM		32
#define MAX_FUNC_NUM	8

// FindDeivce Returned Max (T.Okamoto)
#ifndef MAX_DEVLIST_NUM
#define MAX_DEVLIST_NUM 32
#endif

// Configuration Register Offset
#define CFG_REG_VENDER_ID		0x00
#define CFG_REG_DEVICE_ID		0x02
#define CFG_REG_COMMAND			0x04
#define CFG_REG_STATUS			0x06
#define CFG_REG_REVISION		0x08
#define CFG_REG_CLASS			0x09
#define CFG_REG_PROGRAM_IF		0x09
#define CFG_REG_SUB_CLASS		0x0A
#define CFG_REG_BASE_CLASS		0x0B
#define CFG_REG_CASHE_SIZE		0x0C
#define CFG_REG_LATENCY			0x0D
#define CFG_REG_HEADER_TYPE		0x0E
#define CFG_REG_SELF_TEST		0x0F
#define CFG_REG_BASE_ADDR0		0x10
#define CFG_REG_BASE_ADDR1		0x14
#define CFG_REG_BASE_ADDR2		0x18
#define CFG_REG_BASE_ADDR3		0x1C
#define CFG_REG_BASE_ADDR4		0x20
#define CFG_REG_BASE_ADDR5		0x24
#define CFG_REG_CARDBUS_POINTER	0x28
#define CFG_REG_SUB_VENDER_ID	0x2C
#define CFG_REG_SUB_SYSTEM_ID	0x2E
#define CFG_REG_EXROM_BASE_ADDR	0x30
#define CFG_REG_CAP_POINTER		0x34
#define CFG_REG_INT_LINE		0x3C
#define CFG_REG_INT_PIN			0x3D
#define CFG_REG_MIN_GNT			0x3E
#define CFG_REG_MAX_LATENCY		0x3F
#if 0
#define CFG_REG_DEV_EXTENSION	0x4C
#else
#define CFG_REG_DEV_EXTENSION	0x40
#endif


// command register bits
#define CFGBIT_CMD_IO_SPACE						0x0001
#define CFGBIT_CMD_MEMORY_SPACE					0x0002
#define CFGBIT_CMD_BUS_MASTER					0x0004
#define CFGBIT_CMD_SPECIAL_CYCLES				0x0008
#define CFGBIT_CMD_WRITE_AND_VALIDATE			0x0010
#define CFGBIT_CMD_VGA_COMPATIBLE_PALETTE		0x0020
#define CFGBIT_CMD_PARITY						0x0040
#define CFGBIT_CMD_WAIT_CYCLE					0x0080
#define CFGBIT_CMD_SERR							0x0100
#define CFGBIT_CMD_FAST_BACK_TO_BACK			0x0200
#define CFGBIT_CMD_INT_DISABLE 					0x0400

// status register bits
#define CFGBIT_STATUS_INT_STATUS				0x0008
#define CFGBIT_STATUS_NEWFUNC					0x0010
#define CFGBIT_STATUS_66MHZ						0x0020
#define CFGBIT_STATUS_FAST_BACK_TO_BACK			0x0080 // read-only
#define CFGBIT_STATUS_DATA_PARITY_DETECTED		0x0100
#define CFGBIT_STATUS_DEVSEL9					0x0200 // 2 bits wide
#define CFGBIT_STATUS_DEVSEL10 					0x0400 // 2 bits wide
#define CFGBIT_STATUS_SIGNALED_TARGET_ABORT		0x0800
#define CFGBIT_STATUS_RECEIVED_TARGET_ABORT		0x1000
#define CFGBIT_STATUS_RECEIVED_MASTER_ABORT		0x2000
#define CFGBIT_STATUS_SIGNALED_SYSTEM_ERROR		0x4000
#define CFGBIT_STATUS_DETECTED_PARITY_ERROR		0x8000


//
// PCI Config Capability Structrue
//

// Generic define
#define CFGOFF_CAP_ID				0x00
#define CFGOFF_CAP_NEXT_ITEM_PTR	0x01

// Capability ID define
#define CFGDEF_CAPID_PM			0x01
#define CFGDEF_CAPID_PCIE			0x10


//
// PM
//

// Power Management Block Offset
#define CFGOFF_PMCAP_PMC 			0x02
#define CFGOFF_PMCAP_PMCSR			0x04
#define CFGOFF_PMCAP_PMCSR_BSE		0x06
#define CFGOFF_PMCAP_DATA			0x07

// PMCSR register bits
#define CFGBIT_PMCSR_POWERSTATE		0x0003

#define CFGDEF_PMCSR_POWERSTATE_D0	0x0000
#define CFGDEF_PMCSR_POWERSTATE_D1	0x0001
#define CFGDEF_PMCSR_POWERSTATE_D2	0x0002
#define CFGDEF_PMCSR_POWERSTATE_D3	0x0003

//
// PCI-Express Capability
//
typedef union __PCIEXP_CAPABILITY_REG{
	UCHAR data[0x3C];

	struct{
		UCHAR  CapID;
		UCHAR  NextCapPtr;
		USHORT Cap;
		UINT   DevCap;
		USHORT DevCtrl;
		USHORT DevStatus;
		UINT   LinkCap;
		USHORT LinkCtrl;
		USHORT LinkStatus;
		UINT   SlotCap;
		USHORT SlotCtrl;
		USHORT SlotStatus;
		USHORT RootCtrl;
		USHORT RootCap;
		UINT   RootStatus;
		UINT   DevCap2;
		USHORT DevCtrl2;
		USHORT DevStatus2;
		UINT   LinkCap2;
		USHORT LinkCtrl2;
		USHORT LinkStatus2;
		UINT   SlotCap2;
		USHORT SlotCtrl2;
		USHORT SlotStatus2;
	};
}PCIEXP_CAPABILITY_REG, PPCIEXP_CAPABILITY_REG;


// Offset
#define CFGOFF_PEXCAP_LINKCTL				0x10
#define CFGOFF_PEXCAP_DEVCTRL2				0x28

// PCI-Express Capabilities bit
#define CFGBIT_PEXCAP_VER					0x000F

// Link Control Register
#define CFGBIT_LINKCTL_CLKPM				0x0100

// Device Cpabilities 2 Register
#define CFGBIT_DEVCAP2_TIMEOUT_DISABLE		(1 << 4)

// .... .... .... ....	BBBB BBBB dddd dfff
#define GetAddr(bus,devfunc)        (((bus & 0xFF) <<8) | (devfunc & 0xFF))
#define GetOffset(data)				((data>>16)&0xFFFF)
#define GetBusNO(data)				((data>>8)&0xFF)
#define GetDevFunc(data)            (data&0xFF)

#define CFG_ADDR(addr, offset)		(((UINT)addr) | ((UINT)offset << 16))

#ifndef PCI_EXP_DEVCAP2
#define PCI_EXP_DEVCAP2     36  /* Device Capabilities 2 */
#endif
#ifndef PCI_EXP_DEVCTL2
#define PCI_EXP_DEVCTL2     40  /* Device Control 2 */
#endif


#endif // #ifndef _XHC_PCIDEF_H_


