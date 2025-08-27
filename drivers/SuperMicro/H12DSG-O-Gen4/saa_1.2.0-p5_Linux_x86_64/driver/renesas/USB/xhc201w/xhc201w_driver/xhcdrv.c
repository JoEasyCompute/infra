/*
	File Name : xhcdrv.c
	
    Driver

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

//-----------------------------------------------------------------------------
// GLOBAL VARIABLES
//-----------------------------------------------------------------------------

static XHC201W_DEVICE_EXTENSION g_dDeviceExtension;
static int device_major = 0;

//-----------------------------------------------------------------------------
// PROTOTYPE FNCTION
//-----------------------------------------------------------------------------
static STATUS
DriverEntry(
	void
	);
static void
xHc201wUnload(
	void
	);
static STATUS
xHc201wCreateDispatch(
	struct inode * inode,
	struct file * file
	);
static LSTATUS
xHc201wDeviceIoControlDispatch(
	struct file * file,
	unsigned int function,
	unsigned long arg
	);
static STATUS
xHc201wFreeResources(
	PXHC201W_DEVICE_EXTENSION DeviceExtension
	);
static STATUS
xHc201wCloseDispatch(
	struct inode * inode,
	struct file * file
	);



//-----------------------------------------------------------------------------
//
//-----------------------------------------------------------------------------
static struct file_operations xHCDRV_FOPS = {
	.open            = xHc201wCreateDispatch,
	.unlocked_ioctl  = xHc201wDeviceIoControlDispatch,
	.release         = xHc201wCloseDispatch,
};

//#############################################################################
//-----------------------------------------------------------------------------
// DriverEntry
//
// Return value   (STATUS code / WIN32 error code)
//
//	Success
//	  STATUS_SUCCESS				(NO_ERROR)
//
//	Resource error
//	  STATUS_INSUFFICIENT_RESOURCES (ERROR_NO_SYSTEM_RESOURCES)
//
//	No device found
//	  STATUS_NO_SUCH_DEVICE 		(ERROR_FILE_NOT_FOUND)
//
//	Other errors
//	  STATUS_UNSUCCESSFUL			(ERROR_GEN_FAILURE)
//

static STATUS
DriverEntry(
	void
	)
{
	int status;

	xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "++. ");
	xHc201wDebugPrint(DBG_UTIL, DBG_INFO, "Compiled at %s on %s", __DATE__, __TIME__);

	/* register dipatch */
	status = register_chrdev(DEVICEID_AUTO, DEVICE_NAME, &xHCDRV_FOPS);
	if(0 > status){
		xHc201wDebugPrint(DBG_UTIL, DBG_ERR, "Add one Device--. IoCreateDevice STATUS %x", status);
		xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "--");

		unregister_chrdev(DEVICEID_AUTO, DEVICE_NAME);
		return -EBUSY;
	}
	else {
		xHc201wDebugPrint(DBG_UTIL, DBG_INFO, "Add Device");
		device_major = status;
	}

	/*
	 * Search a cardbus controller and create a list
	 *   Assumed that the list is static and the cardbus controller is not removed
	 */
	xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "search bus bridge controller ++.");

	// Initialize device extension
	memset(&g_dDeviceExtension, 0, sizeof(XHC201W_DEVICE_EXTENSION));

	// Initialize I/O lock
	mutex_init(&g_dDeviceExtension.IoLock);

	// Initialize spin lock
	spin_lock_init(&g_dDeviceExtension.ListLock);

	// Initialize list
	INIT_LIST_HEAD(&g_dDeviceExtension.BridgeList);
	INIT_LIST_HEAD(&g_dDeviceExtension.OpenDeviceList);
#ifdef __CLOCK_PM_DISABLE
	INIT_LIST_HEAD(&g_dDeviceExtension.ClkPMDeviceList);
#endif

	status = xHc201wEnumBridge(&g_dDeviceExtension);
	if(!IS_STATUSSUCCESS(status))
	{
		xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "search bus bridge controller --. error");
		xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "--");

		return (status);
	}
	else
	{
		xHc201wDebugPrint(DBG_UTIL, DBG_INFO, "Bus bridge controller found %d", g_dDeviceExtension.BridgeNum);
	}

	xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "search bus bridge controller --.");

#ifdef __CLOCK_PM_DISABLE
	
	xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "search target device & disable Clock Power Mangement ++.");

	// Diable power management capability of D720201/202
   status = xHc201wDisableClkPM(&g_dDeviceExtension, TARGET_VENDORID, TARGET_DEVICEID);
	if(!IS_STATUSSUCCESS(status))
	{
		xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "search target device & disable Clock Power Mangement --. error");
		xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "--");

		return (status);
	}

	xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "search target device & disable Clock Power Mangement --.");
#endif

	xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "--");

	status = STATUS_SUCCESS;

	return status;
}

//-----------------------------------------------------------------------------
//
static void
xHc201wUnload(
	void
	)
{
	xHc201wDebugPrintFunction(DBG_UNLOAD, DBG_TRACE, "++.");

	unregister_chrdev(device_major, DEVICE_NAME);
	xHc201wFreeResources(&g_dDeviceExtension);
	xHc201wRemoveAllBridgeInfo(&g_dDeviceExtension);

	xHc201wDebugPrintFunction(DBG_UNLOAD, DBG_TRACE, "--");

	return;
}


///////////////////////////////////////////////////////////////////////////////////////////////////
//	xHc201wCreateDispatch
//		IRP_MJ_CREATE request dispatch routine
//
//	Parameters:
//		struct inode * inode
//		struct file * file
//
//	Return value:
//		STATUS_SUCCESS
//
static STATUS
xHc201wCreateDispatch(
	struct inode * inode,
	struct file * file
	)
{
	xHc201wDebugPrintFunction(DBG_CREATECLOSE, DBG_TRACE, "++.");
	xHc201wDebugPrintFunction(DBG_CREATECLOSE, DBG_TRACE, "--");

	return STATUS_SUCCESS;
}

/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *	STATUS
 *	xHc201wDeviceIoControlDispatch (
 *		struct file * file,
 *		unsigned int function,
 *		unsigned long arg
 *	);
 *
 * Parameters :
 *
 *
 * Return Values :
 *
 *	Status
 *
 * Description :
 *
 *	I/O control request is processed.
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
static LSTATUS
 xHc201wDeviceIoControlDispatch(
	struct file * file,
	unsigned int function,
	unsigned long arg
	)
{
	STATUS    status = STATUS_SUCCESS;
	IOCTL_ARGP  structArgment;
	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "++. ");

	mutex_lock(&g_dDeviceExtension.IoLock);

	if(copy_from_user((void*)&structArgment, (void*)arg, sizeof(IOCTL_ARGP))) {
	    status = STATUS_UNSUCCESSFUL;
	}

	switch (function)
	{
	case IOCTL_DEVICE_OPEN: /*************************************************************/

		xHc201wDebugPrintFunction(DBG_IO, DBG_INFO, ": IOCTL_DEVICE_OPEN");

		if(structArgment.nInBufferSize < sizeof(UINT)){
			status = STATUS_INVALID_PARAMETER;
		}
		else{
			UINT addr;
			if(copy_from_user(&addr, structArgment.lpInBuffer, sizeof(UINT))) {
				status = STATUS_UNSUCCESSFUL;
			}
			if(IS_STATUSSUCCESS(status)) {
				status = xHc201wOpenDevice(
					&g_dDeviceExtension,
						addr
						);
			}
		}

		break;

	case IOCTL_DEVICE_CLOSE: /*************************************************************/

		xHc201wDebugPrintFunction(DBG_IO, DBG_INFO, ": IOCTL_DEVICE_CLOSE");

		if(structArgment.nInBufferSize < sizeof(UINT)){
		    status = STATUS_INVALID_PARAMETER;
		}
		else{
			UINT addr;
			if(copy_from_user(&addr, structArgment.lpInBuffer, sizeof(UINT))) {
				status = STATUS_UNSUCCESSFUL;
			}
			if(IS_STATUSSUCCESS(status)) {
				status = xHc201wCloseDevice(
						&g_dDeviceExtension,
						addr
						);
			}
		}
		break;

	case	IOCTL_FIND_DEVICE : /***************************************************************/

		xHc201wDebugPrintFunction(DBG_IO, DBG_INFO, ": IOCTL_FIND_DEVICE");

		if(structArgment.nInBufferSize < sizeof_XHCUTIL_FINDDEVICE(0)){
			status = STATUS_INVALID_PARAMETER;
		}
		else{
			PXHCUTIL_FINDDEVICE pFind = kcalloc(structArgment.nOutBufferSize, 1, GFP_KERNEL);
			if((pFind == NULL)||copy_from_user(pFind, structArgment.lpInBuffer, structArgment.nInBufferSize)) {
				status = STATUS_UNSUCCESSFUL;
			}
			if(IS_STATUSSUCCESS(status)) {
				status = xHc201wFindDevice(
						pFind,
						structArgment.nOutBufferSize,
						&structArgment.lpBytesReturned
						);
				if(copy_to_user(structArgment.lpOutBuffer, pFind, structArgment.nOutBufferSize)) {
					status = STATUS_UNSUCCESSFUL;
				}
			}
			kfree(pFind);
		}


		break;

	case IOCTL_READ_SROM: /*******************************************************************/

		xHc201wDebugPrintFunction(DBG_IO, DBG_INFO, ": IOCTL_READ_SROM");

		{
			PUCHAR pSROMAcc = kcalloc(structArgment.nInBufferSize, 1, GFP_KERNEL);
			if((pSROMAcc == NULL)||copy_from_user(pSROMAcc, structArgment.lpInBuffer, structArgment.nInBufferSize)) {
				status = STATUS_UNSUCCESSFUL;
			}
			if(IS_STATUSSUCCESS(status)) {
				status = xHc201wReadSRom (
							&g_dDeviceExtension,
							pSROMAcc,
							structArgment.nInBufferSize);

				if(copy_to_user(structArgment.lpInBuffer, pSROMAcc, structArgment.nInBufferSize)) {
					status = STATUS_UNSUCCESSFUL;
				}
			}
			kfree(pSROMAcc);
		}

		break;

	case IOCTL_WRITE_SROM: /*******************************************************************/

		xHc201wDebugPrintFunction(DBG_IO, DBG_INFO, ": IOCTL_WRITE_SROM");

		{
			PUCHAR pSROMAcc = kcalloc(structArgment.nInBufferSize, 1, GFP_KERNEL);
			if((pSROMAcc == NULL)||copy_from_user(pSROMAcc, structArgment.lpInBuffer, structArgment.nInBufferSize)) {
				status = STATUS_UNSUCCESSFUL;
			}
			if(IS_STATUSSUCCESS(status)) {
					status = xHc201wWriteSRom (
								&g_dDeviceExtension,
								pSROMAcc,
								structArgment.nInBufferSize);

				if(copy_to_user(structArgment.lpInBuffer, pSROMAcc, structArgment.nInBufferSize)) {
					status = STATUS_UNSUCCESSFUL;
				}
			}
			kfree(pSROMAcc);
		}
		break;

	case	IOCTL_GET_READSTATUS: /*******************************************************************/

		xHc201wDebugPrintFunction(DBG_IO, DBG_INFO, ": IOCTL_GET_READSTATUS");

		if(structArgment.nInBufferSize < sizeof(UINT)){
			status = STATUS_INVALID_PARAMETER;
		}
		else if(structArgment.nOutBufferSize < sizeof_XHCUTIL_GETRESULT(0)){
			status = STATUS_INVALID_PARAMETER;
		}
		else{
			PUCHAR pResult = kcalloc(structArgment.nInBufferSize, 1, GFP_KERNEL);
			if((pResult == NULL)||copy_from_user(pResult, structArgment.lpInBuffer, structArgment.nInBufferSize)) {
				status = STATUS_UNSUCCESSFUL;
			}
			if(IS_STATUSSUCCESS(status)) {
				status = xHc201wGetStatusSROM_PP (
						&g_dDeviceExtension,
						pResult,
						structArgment.nInBufferSize,
						structArgment.nOutBufferSize,
						&structArgment.lpBytesReturned,
						TRUE);
				if(copy_to_user(structArgment.lpInBuffer , pResult, structArgment.nInBufferSize)) {
					status = STATUS_UNSUCCESSFUL;
				}
			}
			kfree(pResult);
		}
		break;

	case	IOCTL_GET_WRITESTATUS: /*******************************************************************/

		xHc201wDebugPrintFunction(DBG_IO, DBG_INFO, ": IOCTL_GET_WRITESTATUS");

		if(structArgment.nInBufferSize < sizeof(UINT)){
			status = STATUS_INVALID_PARAMETER;
		}
		else if(structArgment.nOutBufferSize < sizeof_XHCUTIL_GETRESULT(0)){
			status = STATUS_INVALID_PARAMETER;
		}
		else{
			PUCHAR pResult = kcalloc(structArgment.nInBufferSize, 1, GFP_KERNEL);
			if((pResult == NULL)||copy_from_user(pResult, structArgment.lpInBuffer, structArgment.nInBufferSize)) {
				status = STATUS_UNSUCCESSFUL;
			}
			if(IS_STATUSSUCCESS(status)) {
				status = xHc201wGetStatusSROM_PP (
						&g_dDeviceExtension,
						pResult,
						structArgment.nInBufferSize,
						structArgment.nOutBufferSize,
						&structArgment.lpBytesReturned,
						FALSE);
			   if(copy_to_user(structArgment.lpInBuffer , pResult, structArgment.nInBufferSize)) {
					status = STATUS_UNSUCCESSFUL;
				}
			}
			kfree(pResult);
		}
		break;

	case IOCTL_GET_READDATA : /*******************************************************************/


		xHc201wDebugPrintFunction(DBG_IO, DBG_INFO, ": IOCTL_GET_READDATA");

		if(structArgment.nInBufferSize < sizeof_XHCUTIL_GETRESULT(0)){
			status = STATUS_INVALID_PARAMETER;
		}
		else{
			PUCHAR pSROMAcc = kcalloc(structArgment.nInBufferSize, 1, GFP_KERNEL);
			PUCHAR pBuf	 = kcalloc(structArgment.nOutBufferSize, 1, GFP_KERNEL);
			if((pSROMAcc == NULL)||(pBuf == NULL)||copy_from_user(pSROMAcc, structArgment.lpInBuffer, structArgment.nInBufferSize)) {
				status = STATUS_UNSUCCESSFUL;
			}
			if(IS_STATUSSUCCESS(status)) {
				status = xHc201wGetDataSROM_PP (
						&g_dDeviceExtension,
						pSROMAcc,
						structArgment.nInBufferSize,
						pBuf,
						structArgment.nOutBufferSize,
						&structArgment.lpBytesReturned
						);
				if(copy_to_user(structArgment.lpInBuffer , pSROMAcc, structArgment.nInBufferSize)) {
					status = STATUS_UNSUCCESSFUL;
				}
				if(copy_to_user(structArgment.lpOutBuffer , pBuf, structArgment.nOutBufferSize)) {
					status = STATUS_UNSUCCESSFUL;
				}
			}
			kfree(pSROMAcc);
			kfree(pBuf);
		}

		break;

	case IOCTL_ERASE_SROM: /*******************************************************************/

		xHc201wDebugPrintFunction(DBG_IO, DBG_INFO, ": IOCTL_ERASE_SROM");

		{
			PUCHAR pSROMAcc = kcalloc(structArgment.nInBufferSize, 1, GFP_KERNEL);
			if((pSROMAcc == NULL)||copy_from_user(pSROMAcc, structArgment.lpInBuffer, structArgment.nInBufferSize)) {
				status = STATUS_UNSUCCESSFUL;
			}
			if(IS_STATUSSUCCESS(status)) {
				status = xHc201wChipEraseSROM_PP (
								&g_dDeviceExtension,
								pSROMAcc
								);
				if(copy_to_user(structArgment.lpInBuffer , pSROMAcc, structArgment.nInBufferSize)) {
					status = STATUS_UNSUCCESSFUL;
				}
			}
			kfree(pSROMAcc);
		}

		break;

	case IOCTL_DEVICE_RESET: /*******************************************************************/

		xHc201wDebugPrintFunction(DBG_IO, DBG_INFO, ": IOCTL_DEVICE_RESET");


		if(structArgment.nInBufferSize < sizeof(UINT)){
			status = STATUS_INVALID_PARAMETER;
		}
		else{
			UINT addr;
			if(copy_from_user(&addr, structArgment.lpInBuffer, sizeof(UINT))) {
				status = STATUS_UNSUCCESSFUL;
			}
			if(IS_STATUSSUCCESS(status)) {
				status = xHc201wDeviceReset (
						&g_dDeviceExtension,
						addr
						);
			}
		}

		break;

	case IOCTL_GET_SROM_IDENTIFY: /*******************************************************************/

		xHc201wDebugPrintFunction(DBG_IO, DBG_INFO, ": IOCTL_GET_SROM_IDENTIFY");

		if(structArgment.nInBufferSize < sizeof(UINT)){
			status = STATUS_INVALID_PARAMETER;
		}
		else{
			PUCHAR pSROMAcc = kcalloc(structArgment.nInBufferSize, 1, GFP_KERNEL);
			if((pSROMAcc == NULL)||copy_from_user(pSROMAcc, structArgment.lpInBuffer, structArgment.nInBufferSize)) {
				status = STATUS_UNSUCCESSFUL;
			}
			if(IS_STATUSSUCCESS(status)) {
				status = xHc201wGetSROMIdentify (
						&g_dDeviceExtension,
						pSROMAcc,
						structArgment.nOutBufferSize,
						&structArgment.lpBytesReturned
						);
				if(copy_to_user(structArgment.lpInBuffer , pSROMAcc, structArgment.nInBufferSize)) {
					status = STATUS_UNSUCCESSFUL;
				}
			}
			kfree(pSROMAcc);
		}

		break;

	case IOCTL_SET_SROM_IDENTIFY: /*******************************************************************/

		xHc201wDebugPrintFunction(DBG_IO, DBG_INFO, ": IOCTL_SET_SROM_IDENTIFY");

		if(structArgment.nInBufferSize < sizeof(UINT)){
			status = STATUS_INVALID_PARAMETER;
		}
		else{
			PUCHAR pSROMAcc = kcalloc(structArgment.nInBufferSize, 1, GFP_KERNEL);
			if((pSROMAcc == NULL)||copy_from_user(pSROMAcc, structArgment.lpInBuffer, structArgment.nInBufferSize)) {
				status = STATUS_UNSUCCESSFUL;
			}
			if(IS_STATUSSUCCESS(status)) {
				status = xHc201wSetSerialROMIdentify (
						&g_dDeviceExtension,
						pSROMAcc
						);
				if(copy_to_user(structArgment.lpInBuffer , pSROMAcc, structArgment.nInBufferSize)) {
					status = STATUS_UNSUCCESSFUL;
				}
			}
			kfree(pSROMAcc);
		}

		break;

	case IOCTL_SET_EXTROM_ACCESS_ENABLE: /*******************************************************************/

		xHc201wDebugPrintFunction(DBG_IO, DBG_INFO, ": IOCTL_SET_EXTROM_ACCESS_ENABLE");

		if(structArgment.nInBufferSize < sizeof(UINT)){
			status = STATUS_INVALID_PARAMETER;
		}
		else{
			PUCHAR pSROMAcc = kcalloc(structArgment.nInBufferSize, 1, GFP_KERNEL);
			if((pSROMAcc == NULL)||copy_from_user(pSROMAcc, structArgment.lpInBuffer, structArgment.nInBufferSize)) {
				status = STATUS_UNSUCCESSFUL;
			}
			if(IS_STATUSSUCCESS(status)) {
				status = xHc201wSetExtROMAccessEnable (
						&g_dDeviceExtension,
						pSROMAcc
						);
				if(copy_to_user(structArgment.lpInBuffer , pSROMAcc, structArgment.nInBufferSize)) {
					status = STATUS_UNSUCCESSFUL;
				}
			}
			kfree(pSROMAcc);
		}

		break;

	case IOCTL_SET_EXTROM_ACCESS_DISABLE: /*******************************************************************/

		xHc201wDebugPrintFunction(DBG_IO, DBG_INFO, ": IOCTL_SET_EXTROM_ACCESS_DISABLE");

		if(structArgment.nInBufferSize < sizeof(UINT)){
			status = STATUS_INVALID_PARAMETER;
		}
		else{
			PUCHAR pSROMAcc = kcalloc(structArgment.nInBufferSize, 1, GFP_KERNEL);
			if((pSROMAcc == NULL)||copy_from_user(pSROMAcc, structArgment.lpInBuffer, structArgment.nInBufferSize)) {
				status = STATUS_UNSUCCESSFUL;
			}
			if(IS_STATUSSUCCESS(status)) {
				status = xHc201wSetExtROMAccessDisable (
						&g_dDeviceExtension,
						pSROMAcc
						);
				if(copy_to_user(structArgment.lpInBuffer , pSROMAcc, structArgment.nInBufferSize)) {
					status = STATUS_UNSUCCESSFUL;
				}
			}
			kfree(pSROMAcc);
		}

		break;

	case IOCTL_GET_SROM_RESULT_CODE: /*******************************************************************/

		xHc201wDebugPrintFunction(DBG_IO, DBG_INFO, ": IOCTL_GET_SROM_RESULT_CODE");

		if(structArgment.nInBufferSize < sizeof(UINT)){
			status = STATUS_INVALID_PARAMETER;
		}
		else{
			PUCHAR pSROMAcc = kcalloc(structArgment.nInBufferSize, 1, GFP_KERNEL);
			if((pSROMAcc == NULL)||copy_from_user(pSROMAcc, structArgment.lpInBuffer, structArgment.nInBufferSize)) {
				status = STATUS_UNSUCCESSFUL;
			}
			if(IS_STATUSSUCCESS(status)) {
				status = xHc201wGetROMWriteResultCode (
								&g_dDeviceExtension,
								pSROMAcc,
								structArgment.nOutBufferSize,
								&structArgment.lpBytesReturned
								);
				if(copy_to_user(structArgment.lpInBuffer , pSROMAcc, structArgment.nInBufferSize)) {
					status = STATUS_UNSUCCESSFUL;
				}
			}
			kfree(pSROMAcc);
		}

		break;

	default: /*******************************************************************/

		xHc201wDebugPrintFunction(DBG_IO, DBG_ERR, "INVALID control code.");

		status = STATUS_INVALID_DEVICE_REQUEST;

		break;
	}

	if(copy_to_user((void*)arg, (void*)&structArgment, sizeof(IOCTL_ARGP))) {
		status = STATUS_UNSUCCESSFUL;
	}
	mutex_unlock(&g_dDeviceExtension.IoLock);

	xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "--");

	if(status == STATUS_SUCCESS) {
		return 0;
	}
	else {
		return (-1);
	}
}

///////////////////////////////////////////////////////////////////////////////////////////////////
//	xHc201wFreeResources
//
//	Parameters:
//		PXHC201W_DEVICE_EXTENSION DeviceExtension
//
//	Return value:
//		status
//
static STATUS
xHc201wFreeResources(
	PXHC201W_DEVICE_EXTENSION DeviceExtension
	)
{
	STATUS  status = STATUS_SUCCESS;
	PXHC201W_DEVICE_INFO pDevInfo;
	

	xHc201wDebugPrintFunction(DBG_UNLOAD, DBG_TRACE, "++");

#ifdef __CLOCK_PM_DISABLE
	xHc201wRestoreClkPM(DeviceExtension);
#endif

	while(!list_empty(&DeviceExtension->OpenDeviceList)){

		pDevInfo = (PXHC201W_DEVICE_INFO)list_entry(DeviceExtension->OpenDeviceList.next,
		                                                                    XHC201W_DEVICE_INFO,link);

		xHc201wDisableTarget(DeviceExtension, pDevInfo);
	}
	
	xHc201wDebugPrintFunction(DBG_UNLOAD, DBG_TRACE, "--");


	return status;
}


///////////////////////////////////////////////////////////////////////////////////////////////////
//	xHc201wCloseDispatch
//
//	Parameters:
//		struct inode * inode,
//		struct file * file
//
//	Return value:
//		STATUS_SUCCESS
//
static STATUS
xHc201wCloseDispatch(
    struct inode * inode,
    struct file * file
	)
{
    xHc201wDebugPrintFunction(DBG_CREATECLOSE, DBG_TRACE, "++.");
    xHc201wDebugPrintFunction(DBG_CREATECLOSE, DBG_TRACE, "--");

	return STATUS_SUCCESS;
}

module_init(DriverEntry);
module_exit(xHc201wUnload);

MODULE_DESCRIPTION("xHC-DRV");
MODULE_AUTHOR("RENESAS Electronics Co.");
MODULE_LICENSE("GPL");

