/*
    File Name : util.h

    xHC Utility Driver defines


    * Copyright (C) 2010 NEC Electronics Corporation
*/

///////////////////////////////////////////////////////////////////////////////
//
//      History
//      2010-07-26  rev0.00     base create
//
///////////////////////////////////////////////////////////////////////////////

#ifndef __UTIL_H__
#define __UTIL_H__

#include "stdtype.h"

/*************************************************************************/
// Define
/*************************************************************************/

typedef struct _XHC201W_DEVICE_EXTENSION
{
    //
    XHC201W_IO_LOCK         IoLock;                 // I/O lock
    LONG                    OpenHandleCount;

    // Bridge list
    KSPIN_LOCK              ListLock;
    LIST_ENTRY              OpenDeviceList;
    UINT                    OpenDeviceNum;
    LIST_ENTRY              BridgeList;
    UINT                    BridgeNum;

#ifdef __CLOCK_PM_DISABLE
    LIST_ENTRY              ClkPMDeviceList;
#endif

} XHC201W_DEVICE_EXTENSION, *PXHC201W_DEVICE_EXTENSION;


#define PCI_TYPE0_ADDRESSES 6
#define PCI_TYPE1_ADDRESSES 2
#define PCI_TYPE2_ADDRESSES 5

typedef struct _PCI_COMMON_CONFIG {
  USHORT VendorID;
  USHORT DeviceID;
  USHORT Command;
  USHORT Status;
  UCHAR RevisionID;
  UCHAR ProgIf;
  UCHAR SubClass;
  UCHAR BaseClass;
  UCHAR CacheLineSize;
  UCHAR LatencyTimer;
  UCHAR HeaderType;
  UCHAR BIST;

  union {
    struct _PCI_HEADER_TYPE_0 {
      UINT   BaseAddresses[PCI_TYPE0_ADDRESSES];
      UINT   CIS;
      USHORT SubVendorID;
      USHORT SubSystemID;
      UINT   ROMBaseAddress;
      UINT   Reserved2[2];

      UCHAR InterruptLine;
      UCHAR InterruptPin;
      UCHAR MinimumGrant;
      UCHAR MaximumLatency;
    } type0;

    struct _PCI_HEADER_TYPE_1 {
      UINT   BaseAddresses[PCI_TYPE1_ADDRESSES];
      UCHAR  PrimaryBusNumber;
      UCHAR  SecondaryBusNumber;
      UCHAR  SubordinateBusNumber;
      UCHAR  SecondaryLatencyTimer;
      UCHAR  IOBase;
      UCHAR  IOLimit;
      USHORT SecondaryStatus;
      USHORT MemoryBase;
      USHORT MemoryLimit;
      USHORT PrefetchableMemoryBase;
      USHORT PrefetchableMemoryLimit;
      UINT   PrefetchableMemoryBaseUpper32;
      UINT   PrefetchableMemoryLimitUpper32;
      USHORT IOBaseUpper;
      USHORT IOLimitUpper;
      UINT   Reserved2;
      UINT   ExpansionROMBase;
      UCHAR  InterruptLine;
      UCHAR  InterruptPin;
      USHORT BridgeControl;
    } type1;

    struct _PCI_HEADER_TYPE_2 {
      UINT   BaseAddress;
      UCHAR  CapabilitiesPtr;
      UCHAR  Reserved2;
      USHORT SecondaryStatus;
      UCHAR  PrimaryBusNumber;
      UCHAR  CardbusBusNumber;
      UCHAR  SubordinateBusNumber;
      UCHAR  CardbusLatencyTimer;
      UINT   MemoryBase0;
      UINT   MemoryLimit0;
      UINT   MemoryBase1;
      UINT   MemoryLimit1;
      USHORT IOBase0_LO;
      USHORT IOBase0_HI;
      USHORT IOLimit0_LO;
      USHORT IOLimit0_HI;
      USHORT IOBase1_LO;
      USHORT IOBase1_HI;
      USHORT IOLimit1_LO;
      USHORT IOLimit1_HI;
      UCHAR  InterruptLine;
      UCHAR  InterruptPin;
      USHORT BridgeControl;
      USHORT SubVendorID;
      USHORT SubSystemID;
      UINT  LegacyBaseAddress;
      UCHAR Reserved3[56];
      UINT  SystemControl;
      UCHAR MultiMediaControl;
      UCHAR GeneralStatus;
      UCHAR Reserved4[2];
      UCHAR GPIO0Control;
      UCHAR GPIO1Control;
      UCHAR GPIO2Control;
      UCHAR GPIO3Control;
      UINT  IRQMuxRouting;
      UCHAR RetryStatus;
      UCHAR CardControl;
      UCHAR DeviceControl;
      UCHAR Diagnostic;
    } type2;

  } u;

  UCHAR DeviceSpecific[108];

} PCI_COMMON_CONFIG , *PPCI_COMMON_CONFIG;

/*************************************************************************/
// function prototype
/*************************************************************************/

PXHC201W_BRIDGE_INFO
xHc201wGetBridgeInfo(
    PXHC201W_DEVICE_EXTENSION   deviceExtension,
    struct pci_dev              *Dev
    );
PXHC201W_DEVICE_INFO
xHc201wGetDevInfo(
    PXHC201W_DEVICE_EXTENSION   deviceExtension,
    struct pci_dev              *Dev
    );
STATUS
xHc201wRdConfig(
    struct pci_dev  *Dev,
    UINT            offset,
    UINT            size,
    PVOID           buffer
    );
STATUS
xHc201wWrConfig(
    struct pci_dev  *Dev,
    UINT            offset,
    UINT            size,
    PVOID           buffer
    );
STATUS
xHc201wEnumBridge(
    PXHC201W_DEVICE_EXTENSION deviceExtension
    );
void
xHc201wRemoveAllBridgeInfo(
    PXHC201W_DEVICE_EXTENSION   deviceExtension
    );
STATUS
xHc201wEnableTarget (
    PXHC201W_DEVICE_EXTENSION   deviceExtension,
    struct pci_dev              *Dev,
    PXHC201W_DEVICE_INFO        *ppDevInfo
);
STATUS
xHc201wDisableTarget (
    PXHC201W_DEVICE_EXTENSION   deviceExtension,
    PXHC201W_DEVICE_INFO        pDevInfo
);
STATUS
xHc201wDisableClkPM(
    PXHC201W_DEVICE_EXTENSION   deviceExtension,
    USHORT venID,
    USHORT devID
    );
STATUS
xHc201wRestoreClkPM(
    PXHC201W_DEVICE_EXTENSION   deviceExtension
    );



#endif//__UTIL_H__
