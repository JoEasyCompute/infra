/*
	File Name : intrface.h
	
	xHC Utility Driver interface defines
	
    * Copyright (C) 2010 Renesas Electronics Corporation

*/

///////////////////////////////////////////////////////////////////////////////
//
//		History
//      2010-08-16  rev0.00     base create
//
///////////////////////////////////////////////////////////////////////////////

#ifndef __INTRFACE_H__
#define __INTRFACE_H__

typedef struct {
    LPVOID          lpInBuffer;         // Pointer to buffer where input data is supplied
    DWORD           nInBufferSize;      // Size of each byte of input buffer
    LPVOID          lpOutBuffer;        // Pointer to buffer where output data is received
    DWORD           nOutBufferSize;     // Size of each byte of output buffer
    DWORD           lpBytesReturned;    // Variable that receives number of bytes
} IOCTL_ARGP, *PIOCTL_ARGP;

/*
 *---------------------------------------------------------------------------
 *
 * Definition of XHCUtil Device Type
 *
 *---------------------------------------------------------------------------
 */
#define FILE_DEVICE_XHCUTIL  0xd0

/*
 *---------------------------------------------------------------------------
 *
 *---------------------------------------------------------------------------
 */
#define XHCUTIL_IOCTL(index) \
	_IOC(_IOC_READ, FILE_DEVICE_XHCUTIL, index, 0)

/*
 *---------------------------------------------------------------------------
 * IOCTL_READ_PCI_CONFIG
 *	 lpInBuffer  - PXHCUTIL_ADDRESS
 *	 lpOutBuffer - PUCHAR
 *---------------------------------------------------------------------------
 */
#define IOCTL_READ_PCI_CONFIG \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x05, sizeof(IOCTL_ARGP))

/*
 *---------------------------------------------------------------------------
 * IOCTL_WRITE_PCI_CONFIG
 *	 lpInBuffer  - PXHCUTIL_ADDRESS
 *	 lpOutBuffer - NULL
 *---------------------------------------------------------------------------
 */
#define IOCTL_WRITE_PCI_CONFIG \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x06, sizeof(IOCTL_ARGP))

/*
 *---------------------------------------------------------------------------
 * IOCTL_READ_PCI_MEMORY
 *	 lpInBuffer  - PXHCUTIL_ADDRESS
 *	 lpOutBuffer - PUCHAR
 *---------------------------------------------------------------------------
 */
#define IOCTL_READ_PCI_MEMORY \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x07, sizeof(IOCTL_ARGP))

/*
 *---------------------------------------------------------------------------
 * IOCTL_WRITE_PCI_MEMORY
 *	 lpInBuffer  - PXHCUTIL_ADDRESS
 *	 lpOutBuffer - NULL
 *---------------------------------------------------------------------------
 */
#define IOCTL_WRITE_PCI_MEMORY \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x08, sizeof(IOCTL_ARGP))

/*
 *---------------------------------------------------------------------------
 * IOCTL_FIND_DEVICE
 *	 lpInBuffer  - NULL
 *	 lpOutBuffer - PLONG
 *---------------------------------------------------------------------------
 */
#define IOCTL_FIND_DEVICE \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x10, sizeof(IOCTL_ARGP))

/*
 *---------------------------------------------------------------------------
 * IOCTL_DEVICE_OPEN
 *	 lpInBuffer  - UINT devAddr
 *	 lpOutBuffer - NULL
 *---------------------------------------------------------------------------
 */
#define IOCTL_DEVICE_OPEN \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x11, sizeof(IOCTL_ARGP))

/*
 *---------------------------------------------------------------------------
 * IOCTL_DEVICE_CLOSE
 *	 lpInBuffer  - UINT devAddr
 *	 lpOutBuffer - NULL
 *---------------------------------------------------------------------------
 */
#define IOCTL_DEVICE_CLOSE \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x12, sizeof(IOCTL_ARGP))


/*
 *---------------------------------------------------------------------------
 * IOCTL_DEVICE_RESET
 *	 lpInBuffer  - UINT devAddr
 *	 lpOutBuffer - NULL
 *---------------------------------------------------------------------------
 */
#define IOCTL_DEVICE_RESET \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x13, sizeof(IOCTL_ARGP))


/*
 *---------------------------------------------------------------------------
 * IOCTL_READ_SROM
 *	 lpInBuffer  - PXHCUTIL_SROMACC
 *	 lpOutBuffer - PUCHAR
 *---------------------------------------------------------------------------
 */
#define IOCTL_READ_SROM \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x20, sizeof(IOCTL_ARGP))


/*
 *---------------------------------------------------------------------------
 * IOCTL_GET_READSTATUS
 *	 lpInBuffer  - PXHCUTIL_GETRESULT
 *	 lpOutBuffer - PXHCUTIL_GETRESULT
 *---------------------------------------------------------------------------
 */
#define IOCTL_GET_READSTATUS \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x21, sizeof(IOCTL_ARGP))



/*
 *---------------------------------------------------------------------------
 * IOCTL_GET_READDATA
 *	 lpInBuffer  - PXHCUTIL_SROMACC
 *	 lpOutBuffer - PUCHAR
 *---------------------------------------------------------------------------
 */
#define IOCTL_GET_READDATA \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x22, sizeof(IOCTL_ARGP))


/*
 *---------------------------------------------------------------------------
 * IOCTL_WRITE_SROM
 *	 lpInBuffer  - PXHCUTIL_SROMACC
 *	 lpOutBuffer - NULL
 *---------------------------------------------------------------------------
 */
#define IOCTL_WRITE_SROM \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x23, sizeof(IOCTL_ARGP))

/*
 *---------------------------------------------------------------------------
 * IOCTL_ERASE_SROM
 *	 lpInBuffer  - PXHCUTIL_SROMACC
 *	 lpOutBuffer - NULL
 *---------------------------------------------------------------------------
 */
#define IOCTL_ERASE_SROM \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x24, sizeof(IOCTL_ARGP))


/*
 *---------------------------------------------------------------------------
 * IOCTL_GET_WRITESTATUS
 *	 lpInBuffer  - PXHCUTIL_GETRESULT
 *	 lpOutBuffer - PXHCUTIL_GETRESULT
 *---------------------------------------------------------------------------
 */
#define IOCTL_GET_WRITESTATUS \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x25, sizeof(IOCTL_ARGP))


/*
 *---------------------------------------------------------------------------
 * IOCTL_SERIALROM_IDENTIFY
 *	 lpInBuffer  - UINT devAddr
 *	 lpOutBuffer - NULL
 *---------------------------------------------------------------------------
 */
#define IOCTL_SERIALROM_IDENTIFY \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x30, sizeof(IOCTL_ARGP))


/*
 *---------------------------------------------------------------------------
 * IOCTL_FLASHMEMORY_IDENTIFY
 *	 lpInBuffer  - UINT devAddr
 *	 lpOutBuffer - NULL
 *---------------------------------------------------------------------------
 */
#define IOCTL_FLASHMEMORY_IDENTIFY \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x31, sizeof(IOCTL_ARGP))

/*
 *---------------------------------------------------------------------------
 * IOCTL_GET_SROM_IDENTIFY
 *	 lpInBuffer  - UINT devAddr
 *	 lpOutBuffer - NULL
 *---------------------------------------------------------------------------
 */
#define IOCTL_GET_SROM_IDENTIFY \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x32, sizeof(IOCTL_ARGP))

/*
 *---------------------------------------------------------------------------
 * IOCTL_SET_SROM_IDENTIFY
 *	 lpInBuffer  - UINT devAddr
 *	 lpOutBuffer - NULL
 *---------------------------------------------------------------------------
 */
#define IOCTL_SET_SROM_IDENTIFY \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x33, sizeof(IOCTL_ARGP))

/*
 *---------------------------------------------------------------------------
 * IOCTL_SET_EXTROM_ACCESS_ENABLE
 *	 lpInBuffer  - UINT devAddr
 *	 lpOutBuffer - NULL
 *---------------------------------------------------------------------------
 */
#define IOCTL_SET_EXTROM_ACCESS_ENABLE \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x34, sizeof(IOCTL_ARGP))

/*
 *---------------------------------------------------------------------------
 * IOCTL_SET_EXTROM_ACCESS_DISABLE
 *	 lpInBuffer  - UINT devAddr
 *	 lpOutBuffer - NULL
 *---------------------------------------------------------------------------
 */
#define IOCTL_SET_EXTROM_ACCESS_DISABLE \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x35, sizeof(IOCTL_ARGP))

/*
 *---------------------------------------------------------------------------
 * IOCTL_GET_SROM_RESULT_CODE
 *	 lpInBuffer  - UINT devAddr
 *	 lpOutBuffer - NULL
 *---------------------------------------------------------------------------
 */
#define IOCTL_GET_SROM_RESULT_CODE \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x36, sizeof(IOCTL_ARGP))

/*
 *---------------------------------------------------------------------------
 * IOCTL_XHCI_RESET
 *	 lpInBuffer  - UINT devAddr
 *	 lpOutBuffer - NULL
 *---------------------------------------------------------------------------
 */
#define IOCTL_XHCI_RESET \
	_IOC(_IOC_READ|_IOC_WRITE, FILE_DEVICE_XHCUTIL, 0x51, sizeof(IOCTL_ARGP))


/*
 *---------------------------------------------------------------------------
 * Structure definition used in the following processing
 *	 IOCTL_FIND_DEVICE
 *---------------------------------------------------------------------------
 */

typedef struct _XHCUTIL_PCIDEVINFO{
	UINT	DevAddr;
	USHORT	SuvSystemVendorID;
	USHORT	SuvSystemID;
	UCHAR	RevisionID;
}XHCUTIL_PCIDEVINFO,*PXHCUTIL_PCIDEVINFO;


typedef struct _XHCUTIL_FINDDEVICE {
	USHORT	VendorID;
	USHORT	DeviceID;
	UINT	nBufCount;
	UINT	nDevice;
	XHCUTIL_PCIDEVINFO	DevInfo[1];
} XHCUTIL_FINDDEVICE, *PXHCUTIL_FINDDEVICE;


#define sizeof_XHCUTIL_FINDDEVICE(n)									\
	((size_t)((signed int)sizeof(XHCUTIL_FINDDEVICE) +					\
	((signed int)sizeof(XHCUTIL_PCIDEVINFO) * ((signed int)n - 1))))

/*
 *---------------------------------------------------------------------------
 * Structure definition used in the following processing
 *	 IOCTL_READ_PCI_CONFIG
 *	 IOCTL_WRITE_PCI_CONFIG
 *	 IOCTL_READ_PCI_MEMORY
 *	 IOCTL_WRITE_PCI_MEMORY
 *---------------------------------------------------------------------------
 */
typedef struct _XHCUTIL_ADDRESS {
	UINT DevAddr;
	UINT Address;
	UINT Width;
	UINT Size;
	UCHAR Data[1];
} XHCUTIL_ADDRESS, *PXHCUTIL_ADDRESS;


#define sizeof_XHCUTIL_ADDRESS(n)						\
	((size_t)((signed int)sizeof(XHCUTIL_ADDRESS) +		\
	((signed int)sizeof(UCHAR) * ((signed int)n - 1))))


/*
 *---------------------------------------------------------------------------
 * Structure definition used in the following processing
 *	 IOCTL_READ_SROM_PP
 *	 IOCTL_WRITE_SROM_PP
 *	 IOCTL_ERASE_SERIALROM_PP
 *	 IOCTL_GET_READDATA
 * Structure definition used in the following processing
 *	 IOCTL_GET_READSTATUS
 *	 IOCTL_GET_WRITESTATUS
 *	 IOCTL_GET_READDATA
 *---------------------------------------------------------------------------
 */
typedef struct _XHCUTIL_SROMACC {
	UINT DevAddr;
	UINT Offset;
	UINT Size;
	union{
		struct{ // Use at Request
			UINT PageSize;
			UINT DevCode;
		};
		struct{	// Use when Result is acquired
			UINT Status;
			UINT Status2;
		};
	};
	UCHAR Data[1];
} XHCUTIL_SROMACC, *PXHCUTIL_SROMACC,
  XHCUTIL_GETRESULT, *PXHCUTIL_GETRESULT;


#define sizeof_XHCUTIL_SROMACC(n)						\
	((size_t)((signed int)sizeof(XHCUTIL_SROMACC) +		\
	((signed int)sizeof(UCHAR) * ((signed int)n - 1))))


#define sizeof_XHCUTIL_GETRESULT(n)	sizeof_XHCUTIL_SROMACC(n)

/*
 *---------------------------------------------------------------------------
 * Structure definition used in the following processing
 *	 IOCTL_SERIALROM_IDENTIFY
 *	 IOCTL_FLASHMEMORY_IDENTIFY
 *---------------------------------------------------------------------------
 */
typedef struct _XHCUTIL_SERIALROM_IDENTIFY {
	UINT  MemorySize;
	UINT  PageSize;
	UINT  DevCode;
} XHCUTIL_SERIALROM_IDENTIFY, *PXHCUTIL_SERIALROM_IDENTIFY;


#pragma pack()

/*
 *----------------------------------------------------------------------------
 *
 *	Various name definitions
 *
 *----------------------------------------------------------------------------
 */
#define DEVICE_NAME         "xhc201"

#endif /* __INTRFACE_H__ */
