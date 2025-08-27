/*
	File Name : iorw.c
	
	Device I/O Control routine
	
    * Copyright (C) 2010 Renesas Electronics Corporation
*/

///////////////////////////////////////////////////////////////////////////////
//
//		History
//      2010-08-16  rev0.00     base create
//
///////////////////////////////////////////////////////////////////////////////

#include "stdtype.h"
#include "intrface.h"
#include "xhcdrv.h"
#include "util.h"
#include "iorw.h"
#include "debug.h"
#include "xhcutlfw.h"
#include "xhci.h"
#include "pcidef.h"

/*
 *---------------------------------------------------------------------------
 *
 *
 * Macro definition
 *
 *
 *---------------------------------------------------------------------------
 */
#ifndef max
#define max(a,b) (((a) > (b)) ? (a) : (b))
#endif /* max */

#ifndef min
#define min(a,b) (((a) < (b)) ? (a) : (b))
#endif /* min */


//
// Register Access
//

// Read Register (8bit)
#define ReadPciRegister8(info, offset)              ioread8 ((PUCHAR)(info->Resource0Base + offset))
// Write Register (8bit)
#define WritePciRegister8(info, offset, data)       iowrite8 (data, (PUCHAR)(info->Resource0Base + offset))

// Read Register (16bit)
#define ReadPciRegister16(info, offset)             ioread16 ((PUSHORT)(info->Resource0Base + offset))
// Write Register (16bit)
#define WritePciRegister16(info, offset, data)      iowrite16 (data, (PUSHORT)(info->Resource0Base + offset))

// Read Register (32bit)
#define ReadPciRegister(info, offset)               ioread32 ((PUINT)(info->Resource0Base + offset))
// Write Register (32bit)
#define WritePciRegister(info, offset, data)        iowrite32 (data, (PUINT)(info->Resource0Base + offset))

///////////////////////////////////////////////////////////////////////////////
//		Global
///////////////////////////////////////////////////////////////////////////////


static inline struct pci_dev * __deprecated 
pci_get_bus_and_slot(unsigned int bus,
						   unsigned int devfn)
{
	return pci_get_domain_bus_and_slot(0, bus, devfn);
}
XHC201W_READ_SROM_INFO	g_ReadSromInfo;
XHC201W_WRITE_SROM_INFO	g_WriteSromInfo;

// Flag of the one GetData0/1 uses
int g_ReadDataReg;
// The address location for access of GetData is remembered
//int *g_GetFWDataAddr;

// Flag of the one SetData0/1 uses
int g_WriteDataReg;
// The address location for access of SetData is remembered
//int *g_SetFWDataAddr;

// Open, the address of the device
//USHORT g_OpenDevAddr;

int g_findDevFlag = DEVICE_ID_TYPE_D201;
/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *	BOOLEAN
 *	xHc201wAddressCheck (
 *		UINT           dMemoryLength,
 *		PXHCUTIL_ADDRESS pInBuffer,
 *		UINT           dInputLength,
 *		UINT           dOutputLength,
 *		BOOLEAN         fDirection
 *	)
 *
 * Parameters :
 *
 *	dMemoryLength
 *		Size of memory space of object
 *
 *	pInBuffer
 *		Input-output buffer
 *
 *	dInputLength
 *		Size of input data
 *
 *	dOutputLength
 *		Size of output buffer
 *
 *	fDirection
 *		Direction of access
 *		TRUE	:read
 *		FALSE	:write
 *
 * Return Values :
 *
 *		TRUE    : The address is normal.
 *		FALSE   : The address is illegal.
 *
 * Description :
 *
 *
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
BOOLEAN
xHc201wAddressCheck (
	UINT dMemoryLength,
	PXHCUTIL_ADDRESS pInBuffer,
	UINT dInputLength,
	UINT dOutputLength,
	BOOLEAN  fDirection
)
{
	UINT dDataLength;

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "++");

	/*
	* The parameter size validity is judged.
	*/
//	if (sizeof (XHCUTIL_ADDRESS) > dInputLength)
	if (sizeof_XHCUTIL_ADDRESS(0) > dInputLength)
	{
		xHc201wDebugPrintFunction(DBG_IO,
						DBG_TRACE,
						"--. dInputLength = %d",
						dInputLength);
		return (FALSE);
	}

	/*
	* The size of data and the buffer is acquired.
	*/
	if (fDirection == TRUE)
	{
//		dDataLength = dOutputLength;
		dDataLength = pInBuffer->Size;

		if(dDataLength > dOutputLength){
			xHc201wDebugPrintFunction(DBG_IO,
							DBG_TRACE,
							"--. dOutputLength = %d",
							dInputLength);
			return (FALSE);
		}

	}
	else
	{
//		dDataLength = dInputLength - sizeof (XHCUTIL_ADDRESS);
		dDataLength = pInBuffer->Size;

//		if((sizeof (XHCUTIL_ADDRESS) + pInBuffer->Size) > dInputLength){
		if(sizeof_XHCUTIL_ADDRESS(pInBuffer->Size) > dInputLength){
			xHc201wDebugPrintFunction(DBG_IO,
							DBG_TRACE,
							"--. dInputLength = %d",
							dInputLength);
			return (FALSE);
		}

	}

	/*
	* The validity at each access is judged.
	*/
	if ((pInBuffer->Width != sizeof (UCHAR)) &&
		(pInBuffer->Width != sizeof (USHORT)) &&
		(pInBuffer->Width != sizeof (UINT)))
	{
		xHc201wDebugPrintFunction (DBG_IO,
						DBG_TRACE,
						"--. Width %d",
						pInBuffer->Width);
		return (FALSE);
	}

	/*
	* Make sure whether the relation between unit of the access and data Length is correct.
	*/
	switch(pInBuffer->Width)
	{
		case sizeof(UCHAR):
			break;
		case sizeof(USHORT):
			if((dDataLength % sizeof(USHORT)) != 0)
			{
				xHc201wDebugPrintFunction (DBG_IO,
								DBG_TRACE,
								"--. Address %08X, dDataLength %08X",
								pInBuffer->Address,
								dDataLength);
				return (FALSE);
			}
			break;
		case sizeof(UINT):
			if((dDataLength % sizeof(UINT)) != 0)
			{
				xHc201wDebugPrintFunction (DBG_IO,
								DBG_TRACE,
								"--. Address %08X, dDataLength %08X",
								pInBuffer->Address,
								dDataLength);
				return (FALSE);
			}
		break;
	}

	/*
	* Make sure the specified address isn't outside the range.
	*/
	if (dMemoryLength)
	{
		if ((dDataLength == 0) ||
			(dMemoryLength <= pInBuffer->Address) ||
			(dMemoryLength <= (pInBuffer->Address + dDataLength - 1)))
		{
			xHc201wDebugPrintFunction (DBG_IO,
							DBG_TRACE,
							"--. Address %08X, dDataLength %08X",
							pInBuffer->Address,
							dDataLength);
			return (FALSE);
		}
	}

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "--");

	return (TRUE);
}


/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *	STATUS
 *	xHc201wFindDevice(
 *		PXHCUTIL_FINDDEVICE pFind,
 *		UINT		dOutputLength,
 *		LPDWORD 	pBytesReturned
 *		)
 *
 * Parameters :
 *
 *	pFind
 *	  Device retrieval structure
 *
 *  dOutputLength
 *	  Size of output buffer
 *
 *  pBytesReturned
 *	  Pointer in area where output data size is stored
 *
 * Return Values :
 *
 *  Status
 *
 * Description :
 *
 *  The specified device is retrieved.
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
STATUS
xHc201wFindDevice(
	PXHCUTIL_FINDDEVICE pFind,
	UINT dOutputLength,
	LPDWORD 	pBytesReturned
	)
{
	PXHCUTIL_PCIDEVINFO pPciInfo;
	STATUS              status = STATUS_SUCCESS;
	size_t              bufsize;
	struct pci_dev      *Dev;

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "++");

	bufsize = sizeof_XHCUTIL_FINDDEVICE(pFind->nBufCount);

	if(dOutputLength < bufsize){
		xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "--. status = 0x%08X",STATUS_INVALID_PARAMETER);
		return STATUS_INVALID_PARAMETER;
	}


	xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Target VendorID = 0x%04X",pFind->VendorID);
	xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Target DeviceID = 0x%04X",pFind->DeviceID);

	*pBytesReturned = bufsize;

	Dev = NULL;
	pFind->nDevice = 0;
	pPciInfo = pFind->DevInfo;

	//while((Dev = pci_find_device(pFind->VendorID, pFind->DeviceID, Dev)) != NULL) {
	while((Dev = pci_get_device(pFind->VendorID, pFind->DeviceID, Dev)) != NULL) {
		xHc201wDebugPrint(DBG_IO, DBG_TRACE,"[%p] device found", Dev);
		if(pFind->nDevice < pFind->nBufCount)
		{
			pPciInfo->DevAddr	       = GetAddr(Dev->bus->number, Dev->devfn); //Address preservation
			pPciInfo->SuvSystemVendorID = Dev->subsystem_vendor;
			pPciInfo->SuvSystemID       = Dev->subsystem_device;
			// revisionID cannot be acquired from the pci_dev structure with kernel 2.6.20
//			pPciInfo->RevisionID        = Dev->revision;
			xHc201wRdConfig(Dev, PCI_REVISION_ID, 1, &pPciInfo->RevisionID);

			xHc201wDebugPrint(DBG_IO, DBG_TRACE,"SubSystemVendorID = 0x%04X",pPciInfo->SuvSystemVendorID);
			xHc201wDebugPrint(DBG_IO, DBG_TRACE,"SubSystemID = 0x%04X",pPciInfo->SuvSystemID);
			xHc201wDebugPrint(DBG_IO, DBG_TRACE,"RevisionID = 0x%04X",pPciInfo->RevisionID);

			if((pFind->VendorID == XHC201_VENDOR_ID) && (pFind->DeviceID == XHC201_DEVICE_ID)){
				g_findDevFlag = DEVICE_ID_TYPE_D201;
			}
			else{
				if(pFind->nDevice != 0){
					g_findDevFlag = DEVICE_ID_TYPE_D202;
				}
			}
		}


		pFind->nDevice++;
		pPciInfo = &pFind->DevInfo[pFind->nDevice];
	}

	xHc201wDebugPrint(DBG_IO, DBG_TRACE,"Total = %d device found",pFind->nDevice);

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "--. status = 0x%08X",STATUS_SUCCESS);

	return status;
}



/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *	STATUS
 *	xHc201wOpenDevice(
 *		PXHC201W_DEVICE_EXTENSION	deviceExtension,
 *		UINT						Addr
 *		)
 *
 * Parameters :
 *
 *	deviceExtension
 *		Device extension
 *
 *	Dev
 *		Device address
 *
 * Return Values :
 *
 *	Status
 *
 * Description :
 *
 *	The device is opened.
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
STATUS
xHc201wOpenDevice(
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	UINT Addr
	)
{
	
	STATUS status = STATUS_SUCCESS;
	PXHC201W_DEVICE_INFO	pDevInfo = NULL;
	struct pci_dev          *Dev;

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "++. , addr=0x%x", Addr);
	xHc201wDebugPrint(DBG_IO, DBG_TRACE, "  bus = %d, dev/func = %x", GetBusNO(Addr), GetDevFunc(Addr));

	Dev = pci_get_domain_bus_and_slot( 0, GetBusNO(Addr), GetDevFunc(Addr)); //Victor
	if(Dev == NULL) {
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wOpenDevice;
	}
	status = xHc201wEnableTarget(deviceExtension, Dev, &pDevInfo);

	if(IS_STATUSSUCCESS(status)){

		if(!pDevInfo->bResource0Mapped){

			// Disable
			xHc201wDisableTarget(deviceExtension,pDevInfo);

			status = STATUS_INVALID_HANDLE;
			goto Exit_xHc201wOpenDevice;
		}

		pDevInfo->bOpenStatus = TRUE;

		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "BackDoor open success");
	}

	/* Initialize of a global variable */
	g_ReadDataReg  = XHC_ACCESS_DATA0;
	g_WriteDataReg = XHC_ACCESS_DATA0;
	g_ReadSromInfo.ReadReturnedSize = 0;
	g_ReadSromInfo.ReadSize   = 0;
	g_ReadSromInfo.fReadState = FALSE;
	g_WriteSromInfo.WriteReturnedSize = 0;
	g_WriteSromInfo.WriteSize   = 0;
	g_WriteSromInfo.fWriteState = FALSE;
	g_WriteSromInfo.fEraseState = FALSE;

Exit_xHc201wOpenDevice:

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "--. status = 0x%08X",status);


	return status;
}


/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *	STATUS
 *	xHc201wCloseDevice(
 *		PXHC201W_DEVICE_EXTENSION	deviceExtension,
 *		UINT						Addr
 *		)
 *
 * Parameters :
 *
 *	deviceExtension
 *		Device extension
 *
 *	Dev
 *		Device address
 *
 *
 * Return Values :
 *
 *	Status
 *
 * Description :
 *
 *	The device is closed.
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
STATUS
xHc201wCloseDevice(
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	UINT Addr
	)
{
	STATUS status= STATUS_SUCCESS;
	PXHC201W_DEVICE_INFO pDevInfo = NULL;
	struct pci_dev          *Dev;

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "++.");

    Dev = pci_get_bus_and_slot(GetBusNO(Addr), GetDevFunc(Addr));
    if(Dev == NULL) {
        status = STATUS_INVALID_HANDLE;
        goto Exit_xHc201wCloseDevice;
    }
    pDevInfo = xHc201wGetDevInfo(deviceExtension,Dev);

	if(!pDevInfo){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "DeviceInfo not found (DevAddr = 0x%04X)",Addr);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wCloseDevice; 
	}

	status = xHc201wDisableTarget(deviceExtension,pDevInfo);

Exit_xHc201wCloseDevice:

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "--. status = 0x%08X",status);


	return status;

}



/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *	STATUS
 *	xHc201wGetStatusSROM_PP (
 *		PXHC201W_DEVICE_EXTENSION deviceExtension,
 *		PUCHAR 				pSystemBuffer,
 *		UINT					dInputLength,
 *		UINT					dOutputLength,
 *		LPDWORD 			pBytesReturned,
 *		BOOLEAN				fDirection
 *	)
 *
 * Parameters :
 *
 *	deviceExtension
 *		Device extension
 *
 *	pSystemBuffer
 *		Input-output buffer
 *
 *	dInputLength
 *		Input data size
 *
 *	dOutputLength
 *		Size of output buffer
 *
 *	pBytesReturned
 *		Pointer in area where output data size is store
 *
 *	fDirection
 *		Direction of access
 *		TRUE	: read
 *		FALSE	: write
 *
 * Return Values :
 *
 *	Status
 *
 * Description :
 *
 *	The state of the SROM access is acquired.
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
STATUS
xHc201wGetStatusSROM_PP (
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	PUCHAR  pSystemBuffer,
	UINT dInputLength,
	UINT dOutputLength,
	LPDWORD pBytesReturned,
	BOOLEAN fDirection
)
{
	PXHCUTIL_GETRESULT pResult = (PXHCUTIL_GETRESULT)pSystemBuffer; 

	PXHC201W_DEVICE_INFO pDevInfo;
	STATUS status = STATUS_SUCCESS;
	struct pci_dev          *Dev;
	UINT readData;
	UINT lpReturn;

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "++");
	
	// Get Device Info
    Dev = pci_get_bus_and_slot(GetBusNO(pResult->DevAddr), GetDevFunc(pResult->DevAddr));
    if(Dev == NULL) {
        status = STATUS_INVALID_HANDLE;
        goto Exit_xHc201wGetStatusSROM_PP;
    }
    pDevInfo = xHc201wGetDevInfo(deviceExtension, Dev);

	if(!pDevInfo){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "DeviceInfo not found (DevAddr = 0x%04X)",pResult->DevAddr);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wGetStatusSROM_PP;
	}
	else if((!pDevInfo->bOpenStatus) ||
			(!pDevInfo->bResource0Mapped))
	{
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Device can't access (%d , %d)",
								pDevInfo->bOpenStatus, pDevInfo->bResource0Mapped);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wGetStatusSROM_PP;
	}

	// Read //
	if( fDirection == TRUE ){
		if(g_ReadSromInfo.fReadState == TRUE){
			pResult->Status2  = g_ReadSromInfo.ReadReturnedSize;
			if(g_ReadSromInfo.ReadReturnedSize >= g_ReadSromInfo.ReadSize){
				pResult->Status = STATUS_SUCCESS;
			}
			else{
				pResult->Status = STATUS_PENDING;
			}
		}
		else{
			xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "The Read command isn't being carried out\n");
		}
	}
	else{
	// Write //
		pResult->Status2  = g_WriteSromInfo.WriteReturnedSize;
		if(g_WriteSromInfo.fWriteState == TRUE){
			if(g_WriteSromInfo.WriteReturnedSize >= g_WriteSromInfo.WriteSize){
				pResult->Status = STATUS_SUCCESS;
			}
			else{
				pResult->Status = STATUS_PENDING;
			}
		}
		else if(g_WriteSromInfo.fEraseState == TRUE){	/* Erase */
			status = pciConfigRead(pDevInfo, XHC_CONTROL_STATUS_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &readData, &lpReturn);
			if(status != STATUS_SUCCESS){
				xHc201wDebugPrint(DBG_IO, DBG_TRACE, "ChipErase PCIRegRead Error :: %x\n", status);
				goto Exit_xHc201wGetStatusSROM_PP;
			}

			readData &= XHC_REGBIT_EXTROM_ERASE;
			if(!readData){	// ChipErase completion
				pResult->Status = STATUS_SUCCESS;
			}
			else{
				pResult->Status = STATUS_PENDING;
			}
		}
		else{
			pResult->Status = STATUS_PENDING;
		}
	}
	*pBytesReturned = sizeof_XHCUTIL_GETRESULT(0);
	pResult->Size = 0;

	xHc201wDebugPrint(DBG_IO, DBG_TRACE, " Get Status(0x%08X)",pResult->Status);
	xHc201wDebugPrint(DBG_IO, DBG_TRACE, " Get Size(%d)",pResult->Status2);

Exit_xHc201wGetStatusSROM_PP:

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "--. status = 0x%08X", status);

	return status;
}

/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *	STATUS
 *	xHc201wGetDataSROM_PP(
 *		PXHC201W_DEVICE_EXTENSION deviceExtension,
 *		PUCHAR 				pSystemBuffer,
 *		UINT					dInputLength,
 *		UINT					dOutputLength,
 *		LPDWORD 			pBytesReturned
 *	)
 *
 * Parameters :
 *
 *	deviceExtension
 *		Device extension
 *
 *	pSystemBuffer
 *		Input-output buffer
 *
 *	dInputLength
 *		Input data size
 *
 *	dOutputLength
 *		Size of output buffer
 *
 *	pBytesReturned
 *		Pointer in area where output data size is store
 *
 * Return Values :
 *
 *	Status
 *
 * Description :
 *
 *	The SROM read data is acquired.
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
STATUS
xHc201wGetDataSROM_PP(
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	PUCHAR pInBuffer,
	UINT dInputLength,
	PUCHAR pOutBuffer,
	UINT dOutputLength,
	LPDWORD pBytesReturned
)
{
	PXHCUTIL_SROMACC pSROMAcc = (PXHCUTIL_SROMACC)pInBuffer; 

	PXHC201W_DEVICE_INFO pDevInfo;
	PUCHAR pData;
	struct pci_dev          *Dev;
	STATUS status = STATUS_SUCCESS;

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "++");

	*pBytesReturned = 0;

	// Get Device Info
	Dev = pci_get_bus_and_slot(GetBusNO(pSROMAcc->DevAddr), GetDevFunc(pSROMAcc->DevAddr));
	if(Dev == NULL) {
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wGetDataSROM_PP;
	}
	pDevInfo = xHc201wGetDevInfo(deviceExtension, Dev);

	if(!pDevInfo){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "DeviceInfo not found (DevAddr = 0x%04X)",pSROMAcc->DevAddr);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wGetDataSROM_PP;
	}
	else if((!pDevInfo->bOpenStatus) ||
			(!pDevInfo->bResource0Mapped))
	{
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Device can't access (%d , %d)",
								pDevInfo->bOpenStatus, pDevInfo->bResource0Mapped);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wGetDataSROM_PP;
	}

	// output buffer check
	if(dOutputLength < pSROMAcc->Size){
		status = STATUS_INVALID_PARAMETER;
		goto Exit_xHc201wGetDataSROM_PP;
	}

	if(g_ReadSromInfo.fReadState == TRUE){
		/* Check Read state */
		if(g_ReadSromInfo.ReadReturnedSize >= g_ReadSromInfo.ReadSize){
			// Read Data Buffer //
			pData = (PUCHAR)pOutBuffer;
			memcpy(pData, &g_ReadSromInfo.pReadData, g_ReadSromInfo.ReadSize);

			*pBytesReturned = g_ReadSromInfo.ReadReturnedSize;
		}
	}

Exit_xHc201wGetDataSROM_PP:

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "--");

	return status;
}


/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *	STATUS
 *	xHc201wChipEraseSROM_PP (
 *		PXHC201W_DEVICE_EXTENSION deviceExtension,
 *		PUCHAR pSystemBuffer,
 *	)
 *
 * Parameters :
 *
 *	deviceExtension
 *		Device extension
 *
 *	pSystemBuffer
 *		Input-output buffer
 *
 * Return Values :
 *
 *	Status
 *
 * Description :
 *	SROM erase beginning demand
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
STATUS
xHc201wChipEraseSROM_PP (
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	PUCHAR pSystemBuffer
)
{
	PXHCUTIL_SROMACC pSROMAcc;
	PXHC201W_DEVICE_INFO pDevInfo;
	STATUS status = STATUS_SUCCESS;
	UINT lpReturn;
	UINT readData;
	UINT writeData;
	struct pci_dev		  *Dev;

	PXHC201W_WRITE_SROM_INFO pWriteSromInfo;
	PXHC201W_READ_SROM_INFO pReadSromInfo;

	pWriteSromInfo = &g_WriteSromInfo;
	pReadSromInfo  = &g_ReadSromInfo;

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "++");


	pSROMAcc = (PXHCUTIL_SROMACC)pSystemBuffer;

	// Get Device Info
	Dev = pci_get_bus_and_slot(GetBusNO(pSROMAcc->DevAddr), GetDevFunc(pSROMAcc->DevAddr));
	if(Dev == NULL) {
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wChipEraseSROM_PP;
	}
	pDevInfo = xHc201wGetDevInfo(deviceExtension, Dev);

	if(!pDevInfo){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "DeviceInfo not found (DevAddr = 0x%04X)",pSROMAcc->DevAddr);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wChipEraseSROM_PP;
	}
	else if((!pDevInfo->bOpenStatus) ||
			(!pDevInfo->bResource0Mapped))
	{
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Device can't access (%d , %d)",
								pDevInfo->bOpenStatus, pDevInfo->bResource0Mapped);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wChipEraseSROM_PP;
	}

	status = pciConfigRead(pDevInfo, XHC_CONTROL_STATUS_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &readData, &lpReturn);
	if(status != STATUS_SUCCESS){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI Register Read Error :: %x\n", status);
		goto Exit_xHc201wChipEraseSROM_PP;
	}

	pWriteSromInfo->fEraseState = TRUE;

	pReadSromInfo->fReadState   = FALSE;
	pWriteSromInfo->fWriteState = FALSE;

	// Start ChipErase
	if((readData & XHC_REGBIT_EXT_ROM) != 0){
		writeData = XHC_SET_CHIP_ERASE_DATA;
		status = pciConfigWrite(pDevInfo, XHC_DATA0_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &writeData);
		if(status != STATUS_SUCCESS){
			xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI Register Read Error :: %x\n", status);
			goto Exit_xHc201wChipEraseSROM_PP;
		}

		status = pciConfigRead(pDevInfo, XHC_CONTROL_STATUS_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &readData, &lpReturn);
		if(status != STATUS_SUCCESS){
			xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI Register Read Error :: %x\n", status);
			goto Exit_xHc201wChipEraseSROM_PP;
		}
		// ChipErase Bit is set.
		readData |= XHC_REGBIT_EXTROM_ERASE;

		status = pciConfigWrite(pDevInfo, XHC_CONTROL_STATUS_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &readData);// Set ChipErase
		if(status != STATUS_SUCCESS){
			xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI Register Read Error :: %x\n", status);
			goto Exit_xHc201wChipEraseSROM_PP;
		}
	}
	else{
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "ERROR :: SROM is not connected\n");
	}

Exit_xHc201wChipEraseSROM_PP:

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "--. status = 0x%08X",status);

	return status ;
}


/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *	STATUS
 *	xHc201wReadSRom (
 *		PXHC201W_DEVICE_EXTENSION deviceExtension,
 *		PUCHAR pSystemBuffer,
 *		UINT dInputLength
 *	)
 *
 * Parameters :
 *
 *	deviceExtension
 *		Device extension
 *
 *	pSystemBuffer
 *		Input-output buffer
 *
 *	dInputLength
 *		Input data size
 *
 * Return Values :
 *
 *	Status
 *
 * Description :
 *
 *	SROM Read
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
STATUS
xHc201wReadSRom (
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	PUCHAR pSystemBuffer,
	UINT dInputLength
)
{
	PXHCUTIL_SROMACC pSROMAcc;
	PXHC201W_DEVICE_INFO pDevInfo;
	STATUS status = STATUS_SUCCESS;
	UINT readData;
	UINT writeData;
	UINT setRegBit;
	USHORT getReg;
	UINT lpReturn;
#ifdef _XHCI_TIMEOUT_CHECK
	int loop;
#endif
	PXHC201W_WRITE_SROM_INFO pWriteSromInfo;
	PXHC201W_READ_SROM_INFO pReadSromInfo;
	struct pci_dev          *Dev;

	pWriteSromInfo = &g_WriteSromInfo;
	pReadSromInfo  = &g_ReadSromInfo;
	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "++");

	// Buffer check
	if(dInputLength < sizeof_XHCUTIL_SROMACC(0)){
		status = STATUS_INVALID_PARAMETER;
		goto Exit_xHc201wReadSRom;
	}

	pSROMAcc = (PXHCUTIL_SROMACC)pSystemBuffer;

	// Get Device Info
	Dev = pci_get_bus_and_slot(GetBusNO(pSROMAcc->DevAddr), GetDevFunc(pSROMAcc->DevAddr));
	if(Dev == NULL) {
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wReadSRom;
	}
	pDevInfo = xHc201wGetDevInfo(deviceExtension, Dev);

	if(!pDevInfo){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "DeviceInfo not found (DevAddr = 0x%04X)",pSROMAcc->DevAddr);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wReadSRom;
	}
	else if((!pDevInfo->bOpenStatus) ||
			(!pDevInfo->bResource0Mapped))
	{
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Device can't access (%d , %d)",
								pDevInfo->bOpenStatus, pDevInfo->bResource0Mapped);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wReadSRom;
	}

	pReadSromInfo->ReadReturnedSize = 0;
	pReadSromInfo->ReadSize = pSROMAcc->Size;

	while(pReadSromInfo->ReadReturnedSize < pSROMAcc->Size)
	{
		/* The location the GetData bit accesses is checked */
		if(g_ReadDataReg == XHC_ACCESS_DATA0)
		{
			setRegBit = XHC_REGBIT_GET_DATA0;
			getReg	= XHC_DATA0_OFFSET;
			g_ReadDataReg = XHC_ACCESS_DATA1;
		}
		else
		{
			setRegBit = XHC_REGBIT_GET_DATA1;
			getReg    = XHC_DATA1_OFFSET;
			g_ReadDataReg = XHC_ACCESS_DATA0;
		}

		/* The bit of Get Data in PCI Configreg is set. */
		status = pciConfigRead(pDevInfo, XHC_CONTROL_STATUS_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &readData, &lpReturn);

		if(status != STATUS_SUCCESS){
			xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI Register Read Error :: %x\n", status);
			goto Exit_xHc201wReadSRom;
		}

		writeData = (readData | setRegBit);




		if(setRegBit == XHC_REGBIT_GET_DATA0){
			writeData &= ~XHC_REGBIT_GET_DATA1;
		}
		else{
			writeData &= ~XHC_REGBIT_GET_DATA0;
		}



		status = pciConfigWrite(pDevInfo, XHC_CONTROL_STATUS_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &writeData);

		if(status != STATUS_SUCCESS){
			xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI Register Write Error :: %x\n", status);
			goto Exit_xHc201wReadSRom;
		}

#ifdef _XHCI_TIMEOUT_CHECK
		/* until the set bit will be 0
		   The case which doesn't change even if it wait for fixation time, is a time-out error */
		for(loop = 0; loop < XHC_GET_READ_WAIT_COUNT; loop++){
#else
		while(1){
#endif
			status = pciConfigRead(pDevInfo, XHC_CONTROL_STATUS_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &readData, &lpReturn);

			if(status != STATUS_SUCCESS){
				xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI Register Read Error :: %x\n", status);
				goto Exit_xHc201wReadSRom;
			}

			readData &= setRegBit;
			if(readData == 0)
			{
				break;
			}
		}

#ifdef _XHCI_TIMEOUT_CHECK
		if(loop == XHC_GET_READ_WAIT_COUNT)	// Read completion waiting, time-out
		{
			xHc201wDebugPrint(DBG_IO, DBG_TRACE, "ERROR :: GetData reading time-out\n");
			goto Exit_xHc201wReadSRom;
		}
#endif

		/* Data is acquired and an index is advanced to the location where the next data is stocked */
		status = pciConfigRead(pDevInfo, getReg, XHC_PCIREG_ACCESS_4BYTE, &pReadSromInfo->pReadData[pReadSromInfo->ReadReturnedSize], &lpReturn);
		if(status != STATUS_SUCCESS){
			xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI Register Read Error :: %x\n", status);
			goto Exit_xHc201wReadSRom;
		}

		/* By the 4Byte unit, data, Read. */
		pReadSromInfo->ReadReturnedSize += XHC_PCIREG_ACCESS_4BYTE;
		pReadSromInfo->fReadState = TRUE;

		pWriteSromInfo->fWriteState = FALSE;
		pWriteSromInfo->fEraseState = FALSE;
	}
Exit_xHc201wReadSRom:

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "--. status = 0x%08X",status);

	return status;
}

/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *	STATUS
 *	xHc201wWriteSRom (
 *		PXHC201W_DEVICE_EXTENSION deviceExtension,
 *		PUCHAR pSystemBuffer,
 *		UINT dInputLength
 *	)
 *
 * Parameters :
 *
 *	deviceExtension
 *		Device extension
 *
 *	pSystemBuffer
 *		Input-output buffer
 *
 *	dInputLength
 *		Input data size
 *
 * Return Values :
 *
 *	Status
 *
 * Description :
 *
 *	SROM Write
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
STATUS
xHc201wWriteSRom (
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	PUCHAR pSystemBuffer,
	UINT dInputLength
)
{
	PXHCUTIL_SROMACC pSROMAcc;
	PXHC201W_DEVICE_INFO pDevInfo;
	STATUS status = STATUS_SUCCESS;
	UINT readData;
	UINT writeData;
	UINT writeReg;
	UINT setReg;
	UINT lpReturn;
	UINT *pSetData;
#ifdef _XHCI_TIMEOUT_CHECK
	int loop;
#endif
	PXHC201W_WRITE_SROM_INFO pWriteSromInfo;
	PXHC201W_READ_SROM_INFO pReadSromInfo;
	struct pci_dev          *Dev;

	pWriteSromInfo = &g_WriteSromInfo;
	pReadSromInfo = &g_ReadSromInfo;
	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "++");

	// Buffer check
	if(dInputLength < sizeof_XHCUTIL_SROMACC(0)){
		status = STATUS_INVALID_PARAMETER;
		goto Exit_xHc201wWriteSRom;
	}

	pSROMAcc = (PXHCUTIL_SROMACC)pSystemBuffer;

	// Get Device Info
	Dev = pci_get_bus_and_slot(GetBusNO(pSROMAcc->DevAddr), GetDevFunc(pSROMAcc->DevAddr));
	if(Dev == NULL) {
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wWriteSRom;
	}
	pDevInfo = xHc201wGetDevInfo(deviceExtension, Dev);

	if(!pDevInfo){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "DeviceInfo not found (DevAddr = 0x%04lX)",pSROMAcc->DevAddr);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wWriteSRom;
	}
	else if((!pDevInfo->bOpenStatus) ||
			(!pDevInfo->bResource0Mapped))
	{
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Device can't access (%d , %d)",
								pDevInfo->bOpenStatus, pDevInfo->bResource0Mapped);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wWriteSRom;
	}

	pWriteSromInfo->WriteReturnedSize = 0;
	pWriteSromInfo->WriteSize         = pSROMAcc->Size;
	pWriteSromInfo->fWriteState       = TRUE;
	pSetData = (UINT*)pSROMAcc->Data;

	pReadSromInfo->fReadState   = FALSE;
	pWriteSromInfo->fEraseState = FALSE;

	while(pWriteSromInfo->WriteReturnedSize < pSROMAcc->Size){
		/* The location the GetData bit accesses is checked */
		if(g_WriteDataReg == XHC_ACCESS_DATA0){
			writeReg = XHC_REGBIT_SET_DATA0;
			setReg   = XHC_DATA0_OFFSET;
			g_WriteDataReg = XHC_ACCESS_DATA1;
		}
		else{
			writeReg = XHC_REGBIT_SET_DATA1;
			setReg   = XHC_DATA1_OFFSET;
			g_WriteDataReg = XHC_ACCESS_DATA0;
		}

		/* The bit of Set Data in PCI Configreg is set to the location where the next data is stocked */
		writeData = *pSetData;
		status = pciConfigWrite(pDevInfo, setReg, XHC_PCIREG_ACCESS_4BYTE, &writeData);
		if(status != STATUS_SUCCESS){
			xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI Register Write Error :: %x\n", status);
			goto Exit_xHc201wWriteSRom;
		}
		pSetData++;

		/* 1 is set in Set Data. */
		status = pciConfigRead(pDevInfo, XHC_CONTROL_STATUS_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &readData, &lpReturn);
		writeData = (readData | writeReg);


		if(writeReg == XHC_REGBIT_SET_DATA0){
			writeData &= ~XHC_REGBIT_SET_DATA1;
		}
		else{
			writeData &= ~XHC_REGBIT_SET_DATA0;
		}


		status = pciConfigWrite(pDevInfo, XHC_CONTROL_STATUS_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &writeData);

#ifdef _XHCI_TIMEOUT_CHECK
		/* until the set bit will be 0
		   The case which doesn't change even if it wait for fixation time, is a time-out error */
		for(loop = 0; loop < XHC_GET_READ_WAIT_COUNT; loop++){
#else
		while(1){
#endif
			status = pciConfigRead(pDevInfo, XHC_CONTROL_STATUS_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &readData, &lpReturn);

			if(status != STATUS_SUCCESS){
				xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI Register Read Error :: %x\n", status);
				goto Exit_xHc201wWriteSRom;
			}

			readData &= writeReg;
			if(readData == 0){
				break;
			}
		}

#ifdef _XHCI_TIMEOUT_CHECK
		if(loop == XHC_GET_READ_WAIT_COUNT)	// Time-out
		{
			DbgPrint("ERROR :: SetData writing time-out\n");
			status = STATUS_SERIAL_COUNTER_TIMEOUT;
			break;
		}
#endif

		/* By the 4Byte unit, data, Read. */
		pWriteSromInfo->WriteReturnedSize += XHC_PCIREG_ACCESS_4BYTE;
	}
Exit_xHc201wWriteSRom:

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "--. status = 0x%08X",status);

	return status;
}

/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *	STATUS
 *	xHc201wGetSROMIdentify (
 *	PXHC201W_DEVICE_EXTENSION deviceExtension,
 *	PUCHAR  pSystemBuffer,
 *	UINT   dOutputLength,
 *	LPDWORD pBytesReturned
 *	)
 *
 * Parameters :
 *
 *	deviceExtension
 *		Device extension
 *
 *	pSystemBuffer
 *		Input-output buffer
 *
 * Description :
 *
 *	Serial ROM Indentify
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
STATUS
xHc201wGetSROMIdentify (
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	PUCHAR  pSystemBuffer,
	UINT   dOutputLength,
	LPDWORD pBytesReturned
)
{
	PXHCUTIL_SROMACC pSROMAcc;
	PXHC201W_DEVICE_INFO pDevInfo;
	STATUS status = STATUS_SUCCESS;
	UINT buffer;
	UINT lpReturn;
	UINT bufsize;
	struct pci_dev          *Dev;

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "++");

	pSROMAcc = (PXHCUTIL_SROMACC)pSystemBuffer;

	bufsize = sizeof_XHCUTIL_SROMACC(0);
	if(dOutputLength < bufsize){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "--. status = 0x%08X",STATUS_INVALID_PARAMETER);
		return STATUS_INVALID_PARAMETER;
	}

	*pBytesReturned = bufsize;
	// Get Device Info
	Dev = pci_get_bus_and_slot(GetBusNO(pSROMAcc->DevAddr), GetDevFunc(pSROMAcc->DevAddr));
	if(Dev == NULL) {
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wGetSROMIdentify;
	}
	pDevInfo = xHc201wGetDevInfo(deviceExtension, Dev);

	if(!pDevInfo){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "DeviceInfo not found (DevAddr = 0x%04X)", pSROMAcc->DevAddr);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wGetSROMIdentify;
	}
	else if((!pDevInfo->bOpenStatus) ||
			(!pDevInfo->bResource0Mapped)){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Device can't access (%d , %d)",
								pDevInfo->bOpenStatus, pDevInfo->bResource0Mapped);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wGetSROMIdentify;
	}

	status = pciConfigRead(pDevInfo, XHC_EXTROM_INFO0_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &buffer, &lpReturn);
	pSROMAcc->DevCode = buffer;

Exit_xHc201wGetSROMIdentify:

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "--. status = 0x%08X", status);

	return status ;
}

/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *	STATUS
 *	xHcSetSerialROMIdentify (
 *		PXHC201W_DEVICE_EXTENSION deviceExtension,
 *		PUCHAR pSystemBuffer
 *	)
 *
 * Parameters :
 *
 *	deviceExtension
 *		Device extension
 *
 *	pSystemBuffer
 *		Input-output buffer
 *
 *
 * Return Values :
 *
 *	Status
 *
 * Description :
 *
 *	Serial ROM Indentify
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
STATUS
xHc201wSetSerialROMIdentify (
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	PUCHAR  pSystemBuffer
)
{
	PXHCUTIL_SROMACC pSROMAcc;
	PXHC201W_DEVICE_INFO pDevInfo;
	STATUS status = STATUS_SUCCESS;
	UINT buffer;
	struct pci_dev          *Dev;

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "++");

	pSROMAcc = (PXHCUTIL_SROMACC)pSystemBuffer;

	// Get Device Info
	Dev = pci_get_bus_and_slot(GetBusNO(pSROMAcc->DevAddr), GetDevFunc(pSROMAcc->DevAddr));
	if(Dev == NULL) {
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wSetSerialROMIdentify;
	}
	pDevInfo = xHc201wGetDevInfo(deviceExtension, Dev);

	if(!pDevInfo){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "DeviceInfo not found (DevAddr = 0x%04X)", pSROMAcc->DevAddr);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wSetSerialROMIdentify;
	}
	else if((!pDevInfo->bOpenStatus) ||
			(!pDevInfo->bResource0Mapped))
	{
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Device can't access (%d , %d)",
								pDevInfo->bOpenStatus, pDevInfo->bResource0Mapped);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wSetSerialROMIdentify;
	}

	buffer = pSROMAcc->DevCode;
	status = pciConfigWrite(pDevInfo, XHC_EXTROM_INFO1_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &buffer);

Exit_xHc201wSetSerialROMIdentify:

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "--. status = 0x%08X", status);

	return status ;
}

/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *	STATUS
 *	xHc201wDeviceReset (
 *		PXHC201W_DEVICE_EXTENSION deviceExtension,
 *		UINT Dev
 *	)
 *
 * Parameters :
 *
 *	deviceExtension
 *		Device extension
 *
 *	Dev
 *		Device address
 *
 *
 * Return Values :
 *
 *	Status
 *
 * Description :
 *
 *	Device Reset
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
STATUS
xHc201wDeviceReset (
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	UINT devAddr
)
{
	PXHC201W_DEVICE_INFO pDevInfo;
	PXHC201W_BRIDGE_INFO pBridgeInfo;
	PCIEXP_CAPABILITY_REG expCap;
	STATUS status = STATUS_SUCCESS;
	USHORT usWork;
	int bTimeoutDisable = 0;
	UINT dLoop;
	UINT lpReturn;
	UINT regData;
	struct pci_dev  *Dev;

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "++");

	// Get Device Info
	Dev = pci_get_bus_and_slot(GetBusNO(devAddr), GetDevFunc(devAddr));
	if(Dev == NULL) {
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wDeviceReset;
	}
	pDevInfo = xHc201wGetDevInfo(deviceExtension,Dev);

	if(!pDevInfo){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "DeviceInfo not found (DevAddr = 0x%04X)",devAddr);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wDeviceReset;
	}
	else if((!pDevInfo->bOpenStatus) ||
			(!pDevInfo->bResource0Mapped))
	{
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Device can't access (%d , %d)",
								pDevInfo->bOpenStatus, pDevInfo->bResource0Mapped);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wDeviceReset;
	}

	// Parents device acquisition
	pBridgeInfo = xHc201wGetBridgeInfo(deviceExtension, Dev);

	if(pBridgeInfo){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Parent Controller found = 0x%08X", pBridgeInfo->Dev);

		if(pBridgeInfo->PciExpCapOffset){

			// Read Capability Structrue
			status = xHc201wRdConfig (
					pBridgeInfo->Dev,
					pBridgeInfo->PciExpCapOffset,
					sizeof(PCIEXP_CAPABILITY_REG),
					&expCap);

			if(!IS_STATUSSUCCESS(status)){
				xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI-Express Capability read fail");
				goto Exit_xHc201wDeviceReset;
			}

			xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI-Express Capability Version = 0x%X", 
																(expCap.Cap & PCI_EXP_FLAGS_VERS));

			// Version Check
			if((expCap.Cap & PCI_EXP_FLAGS_VERS) == XHC_PCIE_CONFIG_VER){


				xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Device Capabilities 2 = 0x%08X", expCap.DevCap2);

				if(expCap.DevCap2 & CFGBIT_DEVCAP2_TIMEOUT_DISABLE){

					xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Device Control 2 = 0x%04X", expCap.DevCtrl2);

					if(expCap.DevCtrl2 & CFGBIT_DEVCAP2_TIMEOUT_DISABLE){

						xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Completion Timeout Disable 1 -> 0");
						usWork = expCap.DevCtrl2 & ~CFGBIT_DEVCAP2_TIMEOUT_DISABLE;

						// Completion Timeout Disable 1 -> 0
						status = xHc201wWrConfig (
									Dev,
									PCI_EXP_DEVCTL2,
									2,
									&usWork);

						if(!IS_STATUSSUCCESS(status)){
							xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI-Express Device Control 2 write fail");
							goto Exit_xHc201wDeviceReset;
						}

						bTimeoutDisable = 1;
					}

				}
			}
		}else{
			xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI-Express Capability not found.");
		}
	}
	else{
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Parent Controller not found.");
	}

	status = pciConfigRead(pDevInfo, XHC_CONTROL_STATUS_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &regData, &lpReturn);
	// Immediate Reload Bit is set.
	regData |= XHC_REGBIT_RELOAD;
	status = pciConfigWrite(pDevInfo, XHC_CONTROL_STATUS_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &regData);	// Set Immediate Reload

	for(dLoop=0; dLoop<XHC_RELOAD_WAIT; dLoop++){
		status = pciConfigRead(pDevInfo, XHC_CONTROL_STATUS_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &regData, &lpReturn);

		regData &= XHC_REGBIT_RELOAD;
		if(!regData){	// Immediate Reload completion
			status = STATUS_SUCCESS;
			break;
		}
	}

	xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Reset wait = %d us",
							(XHC_PONRESET_WAIT + (dLoop * XHC_PONRESET_WAIT2)));

	if(dLoop == XHC_PONRESET_WAIT_COUNT){
		status = STATUS_UNSUCCESSFUL;
	}
	

Exit_xHc201wDeviceReset:

	// Restore Parent Bridge
	if(bTimeoutDisable){
		// Completion Timeout Disable 0 -> 1

		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Completion Timeout Disable 0 -> 1");

		status = xHc201wWrConfig (
					pBridgeInfo->Dev,
					(pBridgeInfo->PciExpCapOffset + CFGOFF_PEXCAP_DEVCTRL2),
					2,
					&expCap.DevCtrl2);
		
		if(!IS_STATUSSUCCESS(status)){
			xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI-Express Device Control 2 restore fail");
		}
	}


	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "-- (%x)",status);

	return status ;
}

/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *  STATUS
 *	xHc201wSetExtROMAccessEnable (
 *		PXHC201W_DEVICE_EXTENSION deviceExtension,
 *		PUCHAR pSystemBuffer
 *	)
 *
 * Parameters :
 *
 *	deviceExtension
 *		Device extension
 *
 *	pSystemBuffer
 *		Input-output buffer
 *
 *
 * Return Values :
 *
 *	Status
 *
 * Description :
 *
 *	Serial ROM Access Enable
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
STATUS
xHc201wSetExtROMAccessEnable (
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	PUCHAR pSystemBuffer
)
{
	PXHCUTIL_SROMACC pSROMAcc;
	PXHC201W_DEVICE_INFO pDevInfo;
	STATUS status = STATUS_SUCCESS;
	UINT buffer;
	UINT readData;
	UINT lpReturn;
	struct pci_dev          *Dev;

	pSROMAcc = (PXHCUTIL_SROMACC)pSystemBuffer;

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "++");

	// Get Device Info
	Dev = pci_get_bus_and_slot(GetBusNO(pSROMAcc->DevAddr), GetDevFunc(pSROMAcc->DevAddr));
	if(Dev == NULL) {
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wSetExtROMAccessEnable;
	}
	pDevInfo = xHc201wGetDevInfo(deviceExtension, Dev);

	if(!pDevInfo){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "DeviceInfo not found (DevAddr = 0x%04X)", pSROMAcc->DevAddr);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wSetExtROMAccessEnable;
	}
	else if((!pDevInfo->bOpenStatus) ||
			(!pDevInfo->bResource0Mapped))
	{
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Device can't access (%d , %d)",
								pDevInfo->bOpenStatus, pDevInfo->bResource0Mapped);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wSetExtROMAccessEnable;
	}

	status = pciConfigRead(pDevInfo, XHC_CONTROL_STATUS_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &readData, &lpReturn);
	if(status != STATUS_SUCCESS){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI Register Read Error :: %x\n", status);
		goto Exit_xHc201wSetExtROMAccessEnable;
	}

	g_ReadDataReg  = XHC_ACCESS_DATA0;
	g_WriteDataReg = XHC_ACCESS_DATA0;

//		g_GetFWDataAddr = 0x0;
//		g_SetFWDataAddr = 0x0;

	if((readData & XHC_REGBIT_EXT_ROM) != 0)
	{
		buffer = XHC_SET_ACCESS_ENABLE_DATA;
		status = pciConfigWrite(pDevInfo, XHC_DATA0_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &buffer);
		// AccessEnable Bit is set.
		readData |= XHC_REGBIT_EXTROM_ACCESS_EN;
		status = pciConfigWrite(pDevInfo, XHC_CONTROL_STATUS_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &readData);	// Set ExtRom_Access_Enable
	}

Exit_xHc201wSetExtROMAccessEnable:

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "--. status = 0x%08X", status);

	return status ;
}

/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *	STATUS
 *	xHc201wSetExtROMAccessDisable (
 *		PXHC201W_DEVICE_EXTENSION deviceExtension,
 *		PUCHAR pSystemBuffer
 *	)
 *
 * Parameters :
 *
 *	deviceExtension
 *		Device extension
 *
 *	pSystemBuffer
 *		Input-output buffer
 *
 *
 * Return Values :
 *
 *	Status
 *
 * Description :
 *
 *	Serial ROM Access Disable
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
STATUS
xHc201wSetExtROMAccessDisable (
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	PUCHAR pSystemBuffer
)
{
	PXHCUTIL_SROMACC pSROMAcc;
	PXHC201W_DEVICE_INFO pDevInfo;
	STATUS status = STATUS_SUCCESS;
	UINT readData;
	UINT lpReturn;
	struct pci_dev          *Dev;

	pSROMAcc = (PXHCUTIL_SROMACC)pSystemBuffer;

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "++");

	// Get Device Info
	Dev = pci_get_bus_and_slot(GetBusNO(pSROMAcc->DevAddr), GetDevFunc(pSROMAcc->DevAddr));
	if(Dev == NULL) {
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wSetExtROMAccessDisable;
	}
	pDevInfo = xHc201wGetDevInfo(deviceExtension, Dev);

	if(!pDevInfo){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "DeviceInfo not found (DevAddr = 0x%04X)", pSROMAcc->DevAddr);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wSetExtROMAccessDisable;
	}
	else if((!pDevInfo->bOpenStatus) ||
			(!pDevInfo->bResource0Mapped))
	{
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Device can't access (%d , %d)",
								pDevInfo->bOpenStatus, pDevInfo->bResource0Mapped);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wSetExtROMAccessDisable;
	}

	status = pciConfigRead(pDevInfo, XHC_CONTROL_STATUS_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &readData, &lpReturn);
	if(status != STATUS_SUCCESS){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI Register Read Error :: %x\n", status);
		goto Exit_xHc201wSetExtROMAccessDisable;
	}

	// AccessEnable Bit is clear.
	readData &= ~XHC_REGBIT_EXTROM_ACCESS_EN;
	status = pciConfigWrite(pDevInfo, XHC_CONTROL_STATUS_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &readData);	// Clear ExtRom_Access_Enable

Exit_xHc201wSetExtROMAccessDisable:

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "--. status = 0x%08X", status);

	return status ;
}


/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *	STATUS
 *	xHc201wGetROMWriteResultCode (
 *		PXHC201W_DEVICE_EXTENSION deviceExtension,
 *		PUCHAR pSystemBuffer
 *	)
 *
 * Parameters :
 *
 *	deviceExtension
 *		Device extension
 *
 *	pSystemBuffer
 *		Input-output buffer
 *
 *
 * Return Values :
 *
 *	Status
 *
 * Description :
 *
 *	Get Serial ROM ResultCode
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
STATUS
xHc201wGetROMWriteResultCode (
	PXHC201W_DEVICE_EXTENSION deviceExtension,
	PUCHAR  pSystemBuffer,
	UINT    dOutputLength,
	LPDWORD pBytesReturned
)
{
	PXHCUTIL_GETRESULT pResult;

	PXHC201W_DEVICE_INFO pDevInfo;
	STATUS status = STATUS_SUCCESS;
	UINT readData;
	UINT lpReturn;
	UINT bufsize;
	struct pci_dev          *Dev;

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "++");
	bufsize = sizeof_XHCUTIL_GETRESULT(0);
	if(dOutputLength < bufsize){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "--. status = 0x%08X",STATUS_INVALID_PARAMETER);
		return STATUS_INVALID_PARAMETER;
	}

	*pBytesReturned = bufsize;

	pResult = (PXHCUTIL_GETRESULT)pSystemBuffer;

	// Get Device Info
	Dev = pci_get_bus_and_slot(GetBusNO(pResult->DevAddr), GetDevFunc(pResult->DevAddr));
	if(Dev == NULL) {
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wGetROMWriteResultCode;
	}
	pDevInfo = xHc201wGetDevInfo(deviceExtension, Dev);

	if(!pDevInfo){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "DeviceInfo not found (DevAddr = 0x%04X)", pResult->DevAddr);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wGetROMWriteResultCode;
	}
	else if((!pDevInfo->bOpenStatus) ||
			(!pDevInfo->bResource0Mapped))
	{
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Device can't access (%d , %d)",
								pDevInfo->bOpenStatus, pDevInfo->bResource0Mapped);
		status = STATUS_INVALID_HANDLE;
		goto Exit_xHc201wGetROMWriteResultCode;
	}

	status = pciConfigRead(pDevInfo, XHC_CONTROL_STATUS_OFFSET, XHC_PCIREG_ACCESS_4BYTE, &readData, &lpReturn);
	if(status != STATUS_SUCCESS){
		xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI Register Read Error :: %x\n", status);
		goto Exit_xHc201wGetROMWriteResultCode;
	}

	readData &= XHC_REGBIT_RESULT_CODE;	// Mask Bit ResultCode
	pResult->Status2 = (readData >> XHC_SHIFT_SROM_RESULT_CODE);

//	xHc201wDebugPrint(DBG_IO, DBG_TRACE, " Get Status(0x%08X)",pResult->Status);
	xHc201wDebugPrint(DBG_IO, DBG_TRACE, " Get ResultCode(%d)",pResult->Status2);

Exit_xHc201wGetROMWriteResultCode:

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "--. status = 0x%08X", status);

	return status ;
}


STATUS
pciConfigRead(
	PXHC201W_DEVICE_INFO pDevInfo,
	UINT   offset,
	UINT   size,
	PVOID  buffer,
	PUINT  lpReturn
)
{
	STATUS status = STATUS_SUCCESS;
	status = xHc201wRdConfig(pDevInfo->Dev, offset, size, buffer);
	xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI Register Adder :: %x,  PCI Register Read :: %08X\n", offset, *(UINT*)buffer);

	return status;
}

STATUS
pciConfigWrite(
	PXHC201W_DEVICE_INFO pDevInfo,
	UINT   offset,
	UINT   size,
	PVOID  buffer
)
{
	STATUS status = STATUS_SUCCESS;

	status = xHc201wWrConfig(pDevInfo->Dev, offset , size , buffer);
	xHc201wDebugPrint(DBG_IO, DBG_TRACE, "PCI Write Adder >>>  %x,  PCI Register Write >>> %08X\n", offset, *(UINT*)buffer);
	return status;

}


