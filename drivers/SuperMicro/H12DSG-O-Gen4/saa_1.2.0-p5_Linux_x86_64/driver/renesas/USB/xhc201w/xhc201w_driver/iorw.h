/*
    File Name : iorw.h

    xHC Utility Driver defines


    * Copyright (C) 2010 Renesas Electronics Corporation

*/

///////////////////////////////////////////////////////////////////////////////
//
//      History
//      2010-08-16  rev0.00     base create
//
///////////////////////////////////////////////////////////////////////////////

#ifndef __IORW_H__
#define __IORW_H__

#include "stdtype.h"

STATUS
xHc201wFindDevice(
    PXHCUTIL_FINDDEVICE pFind,
    UINT dOutputLength,
    LPDWORD pBytesReturned
    );
STATUS
xHc201wOpenDevice(
    PXHC201W_DEVICE_EXTENSION deviceExtension,
    UINT   Addr
    );
STATUS
xHc201wCloseDevice(
    PXHC201W_DEVICE_EXTENSION deviceExtension,
    UINT   Addr
    );
STATUS
xHc201wGetStatusSROM_PP (
    PXHC201W_DEVICE_EXTENSION deviceExtension,
    PUCHAR  pSystemBuffer,
    UINT dInputLength,
    UINT dOutputLength,
    LPDWORD pBytesReturned,
    BOOLEAN fDirection
);
STATUS
xHc201wGetDataSROM_PP(
    PXHC201W_DEVICE_EXTENSION deviceExtension,
    PUCHAR pInBuffer,
    UINT dInputLength,
    PUCHAR pOutBuffer,
    UINT dOutputLength,
    LPDWORD pBytesReturned
);
STATUS
xHc201wDeviceReset (
    PXHC201W_DEVICE_EXTENSION deviceExtension,
    UINT   Addr
);
STATUS
xHc201wChipEraseSROM_PP (
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	PUCHAR pSystemBuffer
);
STATUS
xHc201wReadSRom (
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	PUCHAR pSystemBuffer,
	UINT   dInputLength
);
STATUS
xHc201wWriteSRom (
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	PUCHAR pSystemBuffer,
	UINT dInputLength
);
STATUS
xHc201wGetSROMIdentify (
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	PUCHAR  pSystemBuffer,
	UINT    dOutputLength,
	LPDWORD pBytesReturned
);
STATUS
xHc201wSetSerialROMIdentify (
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	PUCHAR  pSystemBuffer
);
STATUS
xHc201wSetExtROMAccessEnable (
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	PUCHAR pSystemBuffer
);
STATUS
xHc201wSetExtROMAccessDisable (
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	PUCHAR pSystemBuffer
);
STATUS
xHc201wGetROMWriteResultCode (
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	PUCHAR  pSystemBuffer,
	UINT    dOutputLength,
	LPDWORD pBytesReturned
);
STATUS
pciConfigRead(
	PXHC201W_DEVICE_INFO pDevInfo,
	UINT  offset,
	UINT  size,
	PVOID buffer,
	PUINT lpReturn
);
STATUS
pciConfigWrite(
	PXHC201W_DEVICE_INFO pDevInfo,
	UINT   offset,
	UINT   size,
	PVOID  buffer
);
#endif//__IORW_H__
