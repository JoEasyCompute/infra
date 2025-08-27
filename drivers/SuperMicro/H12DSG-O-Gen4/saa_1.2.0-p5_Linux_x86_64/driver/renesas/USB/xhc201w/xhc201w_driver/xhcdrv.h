/*
	File Name : xhcdrv.h
	
	xHC Utility Driver defines
	

    * Copyright (C) 2010 Renesas Electronics Corporation
*/

///////////////////////////////////////////////////////////////////////////////
//
//		History
//      2010-07-26  rev0.00     base create
//
///////////////////////////////////////////////////////////////////////////////

#ifndef __XHC201W_H__
#define __XHC201W_H__


/*************************************************************************/
// Build Option
/*************************************************************************/

#define __CLOCK_PM_DISABLE		// Clock Power Mangement disable

#include "stdtype.h"

/*************************************************************************/
// Define
/*************************************************************************/
#define DEVICEID_AUTO               (0)

#define TARGET_VENDORID             0x1033
#define TARGET_DEVICEID             0x0194

// default device
#define XHC201_VENDOR_ID	0x1912	// vendor ID
#define XHC201_DEVICE_ID	0x0014	// vendor ID

#define XHC202_VENDOR_ID	0x1912	// vendor ID
#define XHC202_DEVICE_ID	0x0015	// vendor ID

typedef enum {
	DEVICE_ID_TYPE_D201 = 0,
	DEVICE_ID_TYPE_D202,
	DEVICE_ID_TYPE_ALL
} DEVICE_ID_TYPE;


// PCI Config. restore area
typedef struct _XHC201W_PCI_CONFIG_DATA
{
    USHORT CommandData;  // Command reg.
    UCHAR  PMCSROffset;  // PMCSR reg. offset
    UCHAR  PMCSRData;     // PMCSR reg. data
    UINT   BaseAddr;    // Base Address;
    UCHAR  LinkCTLOffset;   // PCI-Express Cap:LinkControl offset
} XHC201W_PCI_CONFIG_DATA, *PXHC201W_PCI_CONFIG_DATA;

#define MAX_SROM_SIZE				0x8000		// MAX Serial ROM size = 32k byte

#define MAX_SROM_DUMP_SIZE			0x40000		// MAX Serial ROM dump size = 256k byte

// Bus Bridge Controller (PCI-Bridge or CardBus Controller) 
typedef struct _XHC201W_BRIDGE_INFO {
	LIST_ENTRY          link;
	struct pci_dev      *Dev;               // BUS:DEV:FUNC
	UCHAR               SubBusNumber;       // sub bus number
	UINT                MemoryBase0;        // memory base address0
	UINT                MemoryLimit0;       // memory limit address0
	BOOLEAN             MemoryEnable0;      //
	UINT                MemoryBase1;        // memory base address1
	UINT                MemoryLimit1;       // memory limit address1
	BOOLEAN             MemoryEnable1;      //
	UCHAR               PciExpCapOffset;    // PCI-Express Capability Offset
} XHC201W_BRIDGE_INFO, *PXHC201W_BRIDGE_INFO;


// Device Information
typedef struct _XHC201W_DEVICE_INFO{
	LIST_ENTRY				link;
	struct pci_dev			*Dev;				// BUS:DEV:FUNC
	PHYSICAL_ADDRESS		PhyAddr;			// Physical address
	PUCHAR					Resource0Base; 		// pointer to memory resource
	UINT					Resource0Length;	// memory resource length
	BOOLEAN					bResource0Mapped;	// Mapped flag of memory resource
	BOOLEAN					bResource0IsIo;
	BOOLEAN					bOpenStatus;
	XHC201W_PCI_CONFIG_DATA	ConfigData;
}XHC201W_DEVICE_INFO,*PXHC201W_DEVICE_INFO;


// Clock Power Management Device Infromation
typedef struct _XHC201W_CLKPM_INFO{
	LIST_ENTRY				link;
	struct pci_dev			*Dev;			// BUS:DEV:FUNC
	UINT					Offset;			// PCI-Express Capability: Link Control offset
}XHC201W_CLKPM_INFO,*PXHC201W_CLKPM_INFO;

// SROM Read Infromation
typedef struct _XHC201W_READ_SROM_INFO {
	volatile UINT ReadReturnedSize;		// SROMのリードが完了したサイズ(Byte)
	volatile UINT ReadSize;				// SROMリードのサイズ(Byte)
	BOOLEAN fReadState;						// Read実行中かどうかのフラグ
	UCHAR   pReadData[MAX_SROM_DUMP_SIZE];		// Readしたデータを格納しておくバッファ
} XHC201W_READ_SROM_INFO, *PXHC201W_READ_SROM_INFO;

// SROM Write Infromation
typedef struct _XHC201W_WRITE_SROM_INFO {
	volatile UINT WriteReturnedSize;	// SROMのライトが完了したサイズ(Byte)
	volatile UINT WriteSize;			// SROMライトのサイズ(Byte)
	BOOLEAN fWriteState;				// 直前に実行されたコマンドを記憶  True:Write False:Erase
	BOOLEAN fEraseState;				// 直前に実行されたコマンドを記憶  True:Write False:Erase
	UCHAR   pWriteData[MAX_SROM_SIZE];	// Writeしたデータを格納しておくバッファ
} XHC201W_WRITE_SROM_INFO, *PXHC201W_WRITE_SROM_INFO;

#endif	// __XHC201W_H__
