/*
	File Name : xhci.h
	
	xHCI interface define
	
	* Copyright (C) 2009 NEC Electronics Corporation
	* Copyright (c) 2009 NEC Engineering, Ltd.
*/

///////////////////////////////////////////////////////////////////////////////
//
//		History
//		2009-12-03	rev0.01		base create
//
///////////////////////////////////////////////////////////////////////////////

#ifndef _XHCI_DEF_H_
#define _XHCI_DEF_H_

#define TARGET_VENDORID				0x1033
#define TARGET_DEVICEID				0x0194

/* Register offset */
#define XHC_HCIVERSION_OFFSET		0x0

// Power On Reset wait
#define XHC_PONRESET_WAIT			30			// ms 
#define XHC_PONRESET_WAIT2			5			// ms 
#define XHC_PONRESET_WAIT_COUNT		600 		// XHC_PONRESET_WAIT2 * count
#define XHC_RELOAD_WAIT				10000

/*
 *----------------------------------------------------------------------------
 * PCI-Express Capability (PCI COnfig)
 *----------------------------------------------------------------------------
 */
#define XHC_PCIE_CONFIG_VER		0x0002	// support version


// Bit define of FW download /SerialROM UpdateControl and a status register
#define XHC_REGBIT_EXT_ROM			0x80000000UL
#define XHC_REGBIT_GET_DATA1		0x08000000UL
#define XHC_REGBIT_GET_DATA0		0x04000000UL
#define XHC_REGBIT_SET_DATA1		0x02000000UL
#define XHC_REGBIT_SET_DATA0		0x01000000UL
#define XHC_REGBIT_RESULT_CODE		0x00700000UL
#define XHC_REGBIT_RELOAD			0x00040000UL
#define XHC_REGBIT_EXTROM_ERASE		0x00020000UL
#define XHC_REGBIT_EXTROM_ACCESS_EN	0x00010000UL

#define XHC_SHIFT_SROM_RESULT_CODE	20

#define XHC_ACCESS_DATA0			0
#define XHC_ACCESS_DATA1			1

#define XHC_GET_READ_WAIT_COUNT		500UL 		// (ms)

#define XHC_SET_CHIP_ERASE_DATA		0x5A65726FUL
#define XHC_SET_ACCESS_ENABLE_DATA	0x53524F4DUL

#define XHC_HCIVERSION_DATA			0x01000020UL

#endif //  _XHCI_DEF_H_
