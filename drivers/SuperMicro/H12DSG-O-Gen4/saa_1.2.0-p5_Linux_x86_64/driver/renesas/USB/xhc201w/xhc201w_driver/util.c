/*
    File Name : util.c

    xHCI Driver utility


    * Copyright (C) 2010 Renesas Electronics Corporation

*/

///////////////////////////////////////////////////////////////////////////////
//
//      History
//      2010-08-16  rev0.00     base create
//
///////////////////////////////////////////////////////////////////////////////

#include "stdtype.h"
#include "xhcdrv.h"
#include "xhcutlfw.h"
#include "intrface.h"
#include "debug.h"
#include "util.h"

static struct list_head *AddTailList(struct list_head *newlist, struct list_head *head)
{
    struct list_head *list = head;
#ifdef _LIST_DEBUG
    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "++");
#endif

    INIT_LIST_HEAD(newlist);
    if(!list_empty(list)) {
        while(list->next != head) {
#ifdef _LIST_DEBUG
            xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "--------");
            xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "entry=%p", list);
            xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "prev =%p", list->prev);
            xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "next =%p", list->next);
#endif
            list = list->next;
        }
#ifdef _LIST_DEBUG
            xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "--------");
            xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "tail entry=%p", list);
            xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "     prev =%p", list->prev);
            xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "     next =%p", list->next);
#endif
    }

    list_add(newlist, list);

#ifdef _LIST_DEBUG
        xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "--------");
        xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "new  entry=%p", newlist);
        xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "     prev =%p", newlist->prev);
        xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "     next =%p", newlist->next);
#endif

#ifdef _LIST_DEBUG
    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "--");
#endif
    return newlist;
}

static struct list_head *RemoveTailList(struct list_head *head)
{
    struct list_head *list = head;

#ifdef _LIST_DEBUG
    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "++");
#endif

    if(list_empty(head)) {
        // Return NULL because no valid list is found.
    	return NULL;
    }
    else {
        while(list->next != head) {
#ifdef _LIST_DEBUG
            xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "--------");
            xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "entry=%p", list);
            xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "prev =%p", list->prev);
            xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "next =%p", list->next);
#endif
            list = list->next;
        }

#ifdef _LIST_DEBUG
        xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "--------");
        xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "del entry=%p", list);
        xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "    prev =%p", list->prev);
        xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "    next =%p", list->next);
#endif
        list_del(list);
        INIT_LIST_HEAD(list);
    }
#ifdef _LIST_DEBUG
    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "--");
#endif
    return list;
}

//-----------------------------------------------------------------------------
// Bridge list control
STATUS
xHc201wAddBridgeInfo(
    PXHC201W_DEVICE_EXTENSION   deviceExtension,
    PXHC201W_BRIDGE_INFO        pBridgeInfo
    )
{

    PXHC201W_DEVICE_INFO pNew = NULL;

#ifdef _LIST_DEBUG
    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "++");
#endif

    pNew = kcalloc(sizeof(XHC201W_BRIDGE_INFO), 1, GFP_KERNEL);

    if(!pNew){
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    memcpy(pNew, pBridgeInfo, sizeof(XHC201W_BRIDGE_INFO));


#ifdef _LIST_DEBUG
    xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, " Add new list entry=%p, head=%p", &pNew->link, &deviceExtension->BridgeList);
#endif

    spin_lock( &deviceExtension->ListLock );

    AddTailList(&pNew->link, &deviceExtension->BridgeList);
    deviceExtension->BridgeNum++;

    spin_unlock( &deviceExtension->ListLock );

#ifdef _LIST_DEBUG
    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "--");
#endif

    return STATUS_SUCCESS;
}


PXHC201W_BRIDGE_INFO
xHc201wGetBridgeInfo(
    PXHC201W_DEVICE_EXTENSION   deviceExtension,
    struct pci_dev              *Dev
    )
{

    PXHC201W_BRIDGE_INFO pBridgeInfo = NULL;
    PLIST_ENTRY pList;

    spin_lock( &deviceExtension->ListLock );

    pList = deviceExtension->BridgeList.next;

    while(pList != &deviceExtension->BridgeList){

        pBridgeInfo = (PXHC201W_BRIDGE_INFO)list_entry(pList,XHC201W_BRIDGE_INFO,link);

        if(pBridgeInfo->Dev == Dev){
            spin_unlock(&deviceExtension->ListLock);
            return pBridgeInfo;
        }

        pList = pList->next;
    }


    spin_unlock( &deviceExtension->ListLock );

    return NULL;
}

void
xHc201wRemoveAllBridgeInfo(
    PXHC201W_DEVICE_EXTENSION   deviceExtension
    )
{

    PXHC201W_BRIDGE_INFO pBridgeInfo = NULL;
    PLIST_ENTRY pList;

#ifdef _LIST_DEBUG
    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "++");
#endif

    spin_lock( &deviceExtension->ListLock );
#ifdef _LIST_DEBUG
    xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, " Entering  critical section!");
#endif

    while(!list_empty(&deviceExtension->BridgeList)){

        pList = RemoveTailList(&deviceExtension->BridgeList);

        if(pList == NULL) {
            // cannot remove because only empty lists are found.
            break;
        }
        pBridgeInfo = (PXHC201W_BRIDGE_INFO)list_entry(pList,XHC201W_BRIDGE_INFO,link);

        kfree(pBridgeInfo);
        deviceExtension->BridgeNum--;
#ifdef _LIST_DEBUG
        xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, " Remove Bridhe List %p(rest = %d)", pBridgeInfo, deviceExtension->BridgeNum);
#endif
    }

    spin_unlock( &deviceExtension->ListLock );
#ifdef _LIST_DEBUG
    xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, " Terminate critical section!");
    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "--");
#endif

}



//-----------------------------------------------------------------------------
// Device list control

STATUS
xHc201wAddDevInfo(
    PXHC201W_DEVICE_EXTENSION   deviceExtension,
    PXHC201W_DEVICE_INFO        pDevInfo,
    PXHC201W_DEVICE_INFO        *ppNewInfo
    )
{

    PXHC201W_DEVICE_INFO pNew = NULL;


    pNew = kcalloc(sizeof(XHC201W_DEVICE_INFO), 1, GFP_KERNEL);

    if(!pNew){
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    memcpy(pNew,pDevInfo,sizeof(XHC201W_DEVICE_INFO));

    spin_lock( &deviceExtension->ListLock );

    AddTailList(&pNew->link, &deviceExtension->OpenDeviceList);
    deviceExtension->OpenDeviceNum++;

    spin_unlock( &deviceExtension->ListLock );

    if(ppNewInfo){
        *ppNewInfo = pNew;
    }

    return STATUS_SUCCESS;
}


PXHC201W_DEVICE_INFO
xHc201wGetDevInfo(
    PXHC201W_DEVICE_EXTENSION   deviceExtension,
    struct pci_dev              *Dev
    )
{

    PXHC201W_DEVICE_INFO pDevInfo = NULL;
    PLIST_ENTRY pList;

    spin_lock( &deviceExtension->ListLock );

    pList = deviceExtension->OpenDeviceList.next;

    while(pList != &deviceExtension->OpenDeviceList){

        pDevInfo = (PXHC201W_DEVICE_INFO)list_entry(pList,XHC201W_DEVICE_INFO,link);

        if(pDevInfo->Dev == Dev){
            spin_unlock( &deviceExtension->ListLock );
            return pDevInfo;
        }

        pList = pList->next;
    }


    spin_unlock( &deviceExtension->ListLock );

    return NULL;
}

void
xHc201wRemoveDevInfo(
    PXHC201W_DEVICE_EXTENSION   deviceExtension,
    struct pci_dev              *Dev
    )
{

    PXHC201W_DEVICE_INFO pDevInfo = NULL;
    PLIST_ENTRY pList;

    spin_lock( &deviceExtension->ListLock );

    pList = deviceExtension->OpenDeviceList.next;

    while(pList != &deviceExtension->OpenDeviceList){

        pDevInfo = (PXHC201W_DEVICE_INFO)list_entry(pList,XHC201W_DEVICE_INFO,link);

        if(pDevInfo->Dev == Dev){
            // Remove
            list_del(pList);
            kfree(pDevInfo);
            deviceExtension->OpenDeviceNum--;
            break;
        }

        pList = pList->next;
    }


    spin_unlock( &deviceExtension->ListLock );

}


void
xHc201wRemoveDevInfoEx(
    PXHC201W_DEVICE_EXTENSION   deviceExtension,
    PXHC201W_DEVICE_INFO        pDevInfo
    )
{


    spin_lock( &deviceExtension->ListLock );

    list_del(&pDevInfo->link);
    kfree(pDevInfo);
    deviceExtension->OpenDeviceNum--;

    spin_unlock( &deviceExtension->ListLock );

}


void
xHc201wRemoveAllDevInfo(
    PXHC201W_DEVICE_EXTENSION   deviceExtension
    )
{

    PXHC201W_DEVICE_INFO pDevInfo = NULL;
    PLIST_ENTRY pList;

    spin_lock( &deviceExtension->ListLock );

    while(!list_empty(&deviceExtension->OpenDeviceList)){

        pList = RemoveTailList(&deviceExtension->OpenDeviceList);
        if(pList == NULL) {
            // cannot remove because only empty lists are found.
            break;
        }
        pDevInfo = (PXHC201W_DEVICE_INFO)list_entry(pList,XHC201W_DEVICE_INFO,link);

        kfree(pDevInfo);
        deviceExtension->OpenDeviceNum--;
    }

    spin_unlock( &deviceExtension->ListLock );

}


//-----------------------------------------------------------------------------
// Read the specified configuration register
STATUS
xHc201wRdConfig(
    struct pci_dev  *Dev,
    UINT            offset,
    UINT            size,
    PVOID           buffer
    )
{
    STATUS          status;
    UINT            ulResult = 0;
    int             loop;
    PUCHAR          pointer = (PUCHAR)buffer;

#ifdef _READCGF_DEBUG
    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "++");
    xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "pDev = 0x%08X",Dev);
    xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "offset = %d",offset);
    xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "size = %d",size);
    xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "buffer = 0x%08X",pointer);
#endif

    ulResult = 0;
    if(Dev != NULL) {
        for(loop = 0; loop < size; loop++) {
            if(pci_read_config_byte(Dev, offset, (u8*)pointer) != 0) {
                break;
            }
            offset++;       // Update offset address
            pointer++;      // Update pointer
            ulResult++;     // Update size
        }
    }

#ifdef _READCGF_DEBUG
    xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "pci_read_config_byte = %d", ulResult);
#endif
    if(ulResult == 0)
    {
        xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "Bus not found");
        status = STATUS_INVALID_DEVICE_REQUEST;
    }
    else if(ulResult == size) 
    {
        status  = STATUS_SUCCESS;
    }
    else
    {
        //error
        status = STATUS_IO_DEVICE_ERROR;
    }

#ifdef _READCGF_DEBUG
    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "-- STATUS = 0x%08X",status);
#endif

    return status;
}

//-----------------------------------------------------------------------------
// Write the specified configuration register
STATUS
xHc201wWrConfig(
    struct pci_dev  *Dev,
    UINT            offset,
    UINT            size,
    PVOID           buffer
    )
{
    STATUS          status;
    UINT            ulResult = 0;
    int             loop;
    PUCHAR          pointer = (PUCHAR)buffer;

    for(loop = 0; loop < size; loop++) {
         if(pci_write_config_byte(Dev, offset, *(u8*)pointer) != 0) {
            break;
        }
        offset++;       // Update offset address
        pointer++;      // Update pointer
        ulResult++;     // Update size
    }

    if(ulResult == 0)
    {
        xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "Bus not found");
        status = STATUS_INVALID_DEVICE_REQUEST;
    }
    else if(ulResult == size)
    {
        status = STATUS_SUCCESS;
    }
    else
    {
        status = STATUS_IO_DEVICE_ERROR;
    }
    return status;
}



//-----------------------------------
// 

STATUS
xHc201wEnumBridge(
    PXHC201W_DEVICE_EXTENSION deviceExtension
    )
{
    XHC201W_BRIDGE_INFO info;
    PCI_COMMON_CONFIG config;
    USHORT data;
    struct pci_dev  *Dev = NULL;
    STATUS status = STATUS_SUCCESS;

    UCHAR   targetId_BaseClass = 0x06;
    UCHAR   targetId_SubClass  = 0x07;
    UCHAR   targetId_ProgramIf = 0x00;

    UCHAR   targetId_BaseClass2 = 0x06;
    UCHAR   targetId_SubClass2  = 0x04;
    UCHAR   targetId_ProgramIf2 = 0x00;

    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "++. ");


    // Initialize
    xHc201wRemoveAllBridgeInfo(deviceExtension);



    //while((Dev = pci_find_device( PCI_ANY_ID, PCI_ANY_ID, Dev )) != NULL) {
    while((Dev = pci_get_device( PCI_ANY_ID, PCI_ANY_ID, Dev )) != NULL) {
        status = xHc201wRdConfig(Dev, PCI_STATUS, 2, &data);   //read status

        if(status == STATUS_SUCCESS)
        {
            status = xHc201wRdConfig(Dev, 0, sizeof(PCI_COMMON_CONFIG), &config);
            if(status != STATUS_SUCCESS)
            {
                break;
            }

            if( (config.BaseClass == targetId_BaseClass) &&  // Class:0x06 = Bridge
                (config.SubClass  == targetId_SubClass)  &&  // Subclass:0x07 = CardBus
                (config.ProgIf == targetId_ProgramIf))       // Program interface:0x00
            {
                info.Dev          = Dev;
                info.SubBusNumber = config.u.type2.SubordinateBusNumber;
                info.MemoryBase0  = config.u.type2.MemoryBase0;
                info.MemoryLimit0 = config.u.type2.MemoryLimit0;
                info.MemoryBase1  = config.u.type2.MemoryBase1;
                info.MemoryLimit1 = config.u.type2.MemoryLimit1;

                if((info.MemoryBase0 & 0xFFFFFFF0) &&
                    ((info.MemoryLimit0 & 0xFFFFFFF0) >= (info.MemoryBase0 & 0xFFFFFFF0)))
                {
                    info.MemoryEnable0 = TRUE;
                }
                else
                {
                    info.MemoryEnable0 = FALSE;
                }

                if((info.MemoryBase1 & 0xFFFFFFF0) &&
                    ((info.MemoryLimit1 & 0xFFFFFFF0) >= (info.MemoryBase1 & 0xFFFFFFF0)))
                {
                    info.MemoryEnable1 = TRUE;
                }
                else
                {
                    info.MemoryEnable1 = FALSE;
                }

                // Get Cpability Offset
                info.PciExpCapOffset = pci_find_capability(Dev, PCI_CAP_ID_EXP);

                status = xHc201wAddBridgeInfo(deviceExtension,&info);


                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,"SubBusNumber = %d",info.SubBusNumber);
                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,"MemoryBase0 = 0x%08X",info.MemoryBase0);
                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,"MemoryLimit0 = 0x%08X",info.MemoryLimit0);
                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,"MemoryEnable1 = %d",info.MemoryEnable0);
                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,"MemoryBase1 = 0x%08X",info.MemoryBase1);
                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,"MemoryLimit1 = 0x%08X",info.MemoryLimit1);
                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,"MemoryEnable1 = %d",info.MemoryEnable1);
                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,"PciExpCapOffset = 0x%02X",info.PciExpCapOffset);

            }
            else if((config.BaseClass == targetId_BaseClass2) &&  // Class:0x06 = Bridge
                    (config.SubClass  == targetId_SubClass2)  &&  // Subclass:0x04 = PCI bridge
                    (config.ProgIf == targetId_ProgramIf2)        // Program interface:0x00
            ){
                info.Dev          = Dev;
                info.SubBusNumber = config.u.type1.SubordinateBusNumber;
                info.MemoryBase0  = (((UINT)(config.u.type1.MemoryBase & 0xFFF0)) << 16);
                info.MemoryLimit0 = (((UINT)(config.u.type1.MemoryLimit & 0xFFF0)) << 16);
                info.MemoryBase1  = (((UINT)(config.u.type1.PrefetchableMemoryBase & 0xFFF0)) << 16);
                info.MemoryLimit1 = (((UINT)(config.u.type1.PrefetchableMemoryLimit & 0xFFF0)) << 16);

                if((info.MemoryBase0 & 0xFFFFFFF0) &&
                    ((info.MemoryLimit0 & 0xFFFFFFF0) >= (info.MemoryBase0 & 0xFFFFFFF0)))
                {
                    info.MemoryEnable0 = TRUE;
                }
                else
                {
                    info.MemoryEnable0 = FALSE;
                }

                if((info.MemoryBase1 & 0xFFFFFFF0) &&
                    ((info.MemoryLimit1 & 0xFFFFFFF0) >= (info.MemoryBase1 & 0xFFFFFFF0)))
                {
                    info.MemoryEnable1 = TRUE;
                }
                else
                {
                    info.MemoryEnable1 = FALSE;
                }

                // Get Cpability Offset
                info.PciExpCapOffset = pci_find_capability(Dev, PCI_CAP_ID_EXP);

                status = xHc201wAddBridgeInfo(deviceExtension,&info);

                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,"SubBusNumber = %d",info.SubBusNumber);
                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,"MemoryBase0 = 0x%08X",info.MemoryBase0);
                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,"MemoryLimit0 = 0x%08X",info.MemoryLimit0);
                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,"MemoryEnable1 = %d",info.MemoryEnable0);
                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,"MemoryBase1 = 0x%08X",info.MemoryBase1);
                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,"MemoryLimit1 = 0x%08X",info.MemoryLimit1);
                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,"MemoryEnable1 = %d",info.MemoryEnable1);
                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,"PciExpCapOffset = 0x%02X",info.PciExpCapOffset);
            }

        }
        else {
            return STATUS_IO_DEVICE_ERROR; //エラー
        }
    }

    xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,"Total = %d bridge found",deviceExtension->BridgeNum);

    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "--");

    return status;
}

////////////////
//
// 
//
STATUS
xHc201wAssignResource(
    PXHC201W_DEVICE_EXTENSION   deviceExtension,
    struct pci_dev              *Dev,
    UINT                        *pAssignMemory
    )
{

    PXHC201W_BRIDGE_INFO pBridgeInfo;
    BOOLEAN  bConnect = FALSE;
    STATUS status;
    UINT AssignMemory = 0;
    UINT regData;

    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "++");

    if(deviceExtension->BridgeNum){
        xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,   "BusBridgeController is Exist.");
        pBridgeInfo = xHc201wGetBridgeInfo(deviceExtension, Dev);

        if(pBridgeInfo){
            xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,   "This NonConfigHost is BusBridgeController connect. (0x%08X)", pBridgeInfo->Dev);

            bConnect = TRUE;

            if(pBridgeInfo->MemoryEnable0){
                AssignMemory = pBridgeInfo->MemoryBase0; 
                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,   "BusBridgeController Memory Base 0");
            }
            else if (pBridgeInfo->MemoryEnable1){
                AssignMemory = pBridgeInfo->MemoryBase1; 
                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,   "BusBridgeController Memory Base 1");
            }
            else
            {
                xHc201wDebugPrint(DBG_UTIL, DBG_ERR,   "BusBridgeController memory resource error.");
            }

            if(AssignMemory)
            {
                regData = 0;
                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,   "Resource assigne = 0x%08X",AssignMemory);

                xHc201wWrConfig(Dev, PCI_BASE_ADDRESS_0, 4, &AssignMemory);

                // Read check
                xHc201wRdConfig(Dev, PCI_BASE_ADDRESS_0, 4, &regData);
                if((regData & 0xFFFFFFF0) != AssignMemory){
                    // error
                    xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "Resource assigne error = 0x%08X",regData);
                    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "--");

                    status = STATUS_IO_DEVICE_ERROR;
                }
                // success
                else{
                    xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "Resource assigned");

                    *pAssignMemory = AssignMemory;

                    status = STATUS_SUCCESS;
                }
            }
            else
            {

                xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "--");

                status = STATUS_INSUFFICIENT_RESOURCES;
            }
        }
        else{

            xHc201wDebugPrint(DBG_UTIL, DBG_ERR,   "This NonConfigHost is not BusBridgeController connect.");

            status = STATUS_INSUFFICIENT_RESOURCES;
        }

    }
    else{

        xHc201wDebugPrint(DBG_UTIL, DBG_ERR,   "BusBridgeController not found.");

        status = STATUS_INSUFFICIENT_RESOURCES;
    }


    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "--, return = 0x%08X",status);

    return status;
}


/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *    STATUS
 *    xHc201wEnableTarget (
 *          PXHC201W_DEVICE_EXTENSION   deviceExtension,
 *          truct pci_dev              *Dev,
 *          PXHC201W_DEVICE_INFO        *ppDevInfo
 *    );
 *
 * Parameters :
 *
 *    deviceExtension
 *        
 *
 *    addr
 *        Lower 16bit is PCI Address(Bus/Device/Function)
 *
 *    ppDevInfo
 *        Buffer to store the pointer of device information that is added to a list
 *
 * Return Values :
 *
 *    Status
 *
 * Description :
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
STATUS
xHc201wEnableTarget (
    PXHC201W_DEVICE_EXTENSION   deviceExtension,
    struct pci_dev              *Dev,
    PXHC201W_DEVICE_INFO        *ppDevInfo
)
{
    PXHC201W_DEVICE_INFO pDevInfo;
    XHC201W_DEVICE_INFO devInfo;
    PXHC201W_PCI_CONFIG_DATA pPCIConfigData;
    UINT BaseAddresses;
    STATUS status;
    UINT   offset;
    USHORT commandReg;
    UCHAR pmcsrRegLow;
    UINT  AssignMemory;

    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "++, Dev=0x%p", Dev);

    if(ppDevInfo){
        *ppDevInfo = NULL;
    }

    pDevInfo = xHc201wGetDevInfo(deviceExtension, Dev);

    if (pDevInfo)
    {
        xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "Device[0x%08p] is already enabled", Dev);

        xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "--, return = 0x%08X",STATUS_DEVICE_ALREADY_ATTACHED);

        return STATUS_DEVICE_ALREADY_ATTACHED;
    }

    xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "Save PCI Config");

    status = xHc201wRdConfig(Dev, PCI_BASE_ADDRESS_0, 4, &BaseAddresses);
    if(BaseAddresses & 0x00000001){
        return STATUS_INVALID_DEVICE_REQUEST;
    }
    else if((BaseAddresses & 0xFFFFFFF0) == 0){
        status = xHc201wAssignResource(deviceExtension, Dev, &AssignMemory);

        if(!IS_STATUSSUCCESS(status)){
            xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "--, return = 0x%08X",status);
            return status;
        }
    }
    else{
        AssignMemory = BaseAddresses & 0xFFFFFFF0;
    }

    memset(&devInfo, 0, sizeof(XHC201W_DEVICE_INFO));

    devInfo.Dev = Dev;

    devInfo.PhyAddr         = AssignMemory;
    devInfo.bResource0IsIo  = FALSE;
    devInfo.Resource0Length = XHC_PCIEX_SIZE;

//    devInfo.Resource0Base = ioport_map(AssignMemory, XHC_PCIEX_SIZE);
    devInfo.Resource0Base = pci_iomap(Dev, 0, 0);
    if(devInfo.Resource0Base == NULL){
        devInfo.bResource0Mapped = FALSE;
        status = STATUS_INSUFFICIENT_RESOURCES;

        xHc201wDebugPrint(DBG_UTIL, DBG_ERR,   "Resource setting --. IORemap failed. return value is NULL.");
        xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "--, return = 0x%08X",status);

        return status;
    }
    else{
        xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "IORemap success = %08X -> %08X",
                                        Dev->resource[0].start, devInfo.Resource0Base);
        devInfo.bResource0Mapped = TRUE;
    }


    // Configuration setting
    pPCIConfigData = &devInfo.ConfigData;

    // Store PCI Config.
    xHc201wRdConfig(Dev, PCI_COMMAND, 2, &pPCIConfigData->CommandData);
    pPCIConfigData->BaseAddr = BaseAddresses;

    xHc201wDebugPrint(DBG_UTIL, DBG_INFO, "Command data = %04X", pPCIConfigData->CommandData);
    xHc201wDebugPrint(DBG_UTIL, DBG_INFO, "Base Addr = %04X", BaseAddresses);

    commandReg = pPCIConfigData->CommandData | PCI_COMMAND_MASTER | PCI_COMMAND_MEMORY;
    // Enable Memory Space bit and Bus Master bit
    xHc201wWrConfig(Dev, PCI_COMMAND, 2, &commandReg);

    // Search PMCSR reg.
    offset = pci_find_capability(Dev, PCI_CAP_ID_PM);

    if (offset)
    {
        offset += PCI_CAP_ID_PM;

        xHc201wDebugPrint(DBG_UTIL, DBG_INFO, "PMCSR offset = %02X", offset);

        // Store PCI Config.
        pPCIConfigData->PMCSROffset = (UCHAR)offset;
        xHc201wRdConfig(Dev, offset, 2, &pPCIConfigData->PMCSRData);

        xHc201wDebugPrint(DBG_UTIL, DBG_INFO, "PMCSR data = %02X", pPCIConfigData->PMCSRData);

        pmcsrRegLow = (pPCIConfigData->PMCSRData & ~PCI_PM_CAP_PME_MASK) | PCI_PM_CAP_PME_D0;
        // Update only PowerState
        xHc201wWrConfig(Dev, offset, 2, &pmcsrRegLow);
    }
    else{
        xHc201wDebugPrint(DBG_UTIL, DBG_INFO, "PMCSR not found!", offset);
    }

#ifdef __CLOCK_PM_DISABLE
    offset = pci_find_capability(Dev, PCI_CAP_ID_EXP);
    if(offset){
        pPCIConfigData->LinkCTLOffset = (UCHAR)offset + PCI_EXP_LNKCTL;
    }
#endif

    // add to list
    status = xHc201wAddDevInfo(deviceExtension, &devInfo, ppDevInfo);

    if(!IS_STATUSSUCCESS(status)){
        xHc201wDebugPrint(DBG_UTIL, DBG_ERR,   "Add device fail!");
    }
    else{
        xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,   "Add opened device !");
        xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,   "DevAddr = 0x%08p", (*ppDevInfo)->Dev);
        xHc201wDebugPrint(DBG_UTIL, DBG_TRACE,   "Resource0Base = 0x%08X", (*ppDevInfo)->Resource0Base);
    }


    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "--, return = 0x%08X",status);


    return status;
}


/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *    STATUS
 *    xHc201wDisableTarget (
 *          PXHC201W_DEVICE_EXTENSION   deviceExtension,
 *          PXHC201W_DEVICE_INFO        pDevInfo
 *    );
 *
 * Parameters :
 *
 *    deviceExtension
 *        
 *    pDevInfo
 *        
 *
 * Return Values :
 *
 *    status
 *
 * Description :
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
STATUS
xHc201wDisableTarget (
    PXHC201W_DEVICE_EXTENSION   deviceExtension,
    PXHC201W_DEVICE_INFO        pDevInfo
)
{
    PXHC201W_PCI_CONFIG_DATA pPCIConfigData;
    STATUS status = STATUS_SUCCESS;
    UINT     offset;
    USHORT   commandReg;
    UCHAR    pmcsrRegLow;

    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "++");

    if (!pDevInfo)
    {
        xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "--, return = 0x%08X",STATUS_INVALID_HANDLE);

        return STATUS_INVALID_HANDLE;
    }

    xHc201wDebugPrint(DBG_UTIL, DBG_INFO, "Address = %04p", pDevInfo->Dev);

    // Release mapped resource
    if(pDevInfo->bResource0Mapped){
//        ioport_unmap(pDevInfo->Resource0Base);
        pci_iounmap(pDevInfo->Dev, pDevInfo->Resource0Base);
        pDevInfo->bResource0Mapped = FALSE;
    }

    // Recover Configuration setting
    pPCIConfigData = &pDevInfo->ConfigData;

    xHc201wDebugPrint(DBG_UTIL, DBG_INFO, "Command data = %04X", pPCIConfigData->CommandData);
    xHc201wDebugPrint(DBG_UTIL, DBG_INFO, "PMCSR offset = %02X", pPCIConfigData->PMCSROffset);
    xHc201wDebugPrint(DBG_UTIL, DBG_INFO, "PMCSR data = %02X", pPCIConfigData->PMCSRData);


    // Get command reg
    xHc201wRdConfig(pDevInfo->Dev, PCI_COMMAND, 2, &commandReg);

    // Recover Memory Space bit
    commandReg &= ~PCI_COMMAND_MEMORY;
    if (pPCIConfigData->CommandData & PCI_COMMAND_MEMORY)
    {
        commandReg |= PCI_COMMAND_MEMORY;
    }
    // Recover Bus Master bit
    commandReg &= ~PCI_COMMAND_MASTER;
    if (pPCIConfigData->CommandData & PCI_COMMAND_MASTER)
    {
        commandReg |= PCI_COMMAND_MASTER;
    }

    // Write to command reg.
    xHc201wWrConfig(pDevInfo->Dev, PCI_COMMAND, 2, &commandReg);

    // Offset PMCSR reg.
    offset = pPCIConfigData->PMCSROffset;

    if (offset)
    {
        xHc201wRdConfig(pDevInfo->Dev, offset, 2,&pmcsrRegLow);
        pmcsrRegLow &= ~PCI_PM_CAP_PME_MASK;
        pmcsrRegLow |= (pPCIConfigData->PMCSRData & PCI_PM_CAP_PME_MASK);

        xHc201wWrConfig(pDevInfo->Dev, offset, 2, &pmcsrRegLow);
    }

    xHc201wWrConfig(pDevInfo->Dev, PCI_BASE_ADDRESS_0, 4, &pPCIConfigData->BaseAddr);

    // Remove from list
	xHc201wRemoveDevInfoEx(deviceExtension, pDevInfo);

    xHc201wDebugPrintFunction(DBG_UTIL, DBG_TRACE, "--, return = 0x%08X",status);

    return status;
}

/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *  NTSTATUS
 *  xHc201wDisableClkPM(
 *      PXHC201W_DEVICE_EXTENSION   deviceExtension,
 *      USHORT venID,
 *      USHORT devID
 *      )
 *
 * Parameters :
 *
 *  deviceExtension
 *      
 *  venID
 *      vendorID of target device
 *
 *  devID
 *      deviceID of target device
 *
 * Return Values :
 *
 *  status code
 *
 * Description :
 *
 *  Clock Power Management disable
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
STATUS
xHc201wDisableClkPM(
    PXHC201W_DEVICE_EXTENSION   deviceExtension,
    USHORT venID,
    USHORT devID
    )
{
    PCI_COMMON_CONFIG config;
    UCHAR *pData = (UCHAR*)&config;
    UINT   offset;
    USHORT linkControl;
    PXHC201W_CLKPM_INFO pClkPMInfo;
    STATUS status = STATUS_SUCCESS;
    struct pci_dev              *Dev;

    xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "++");

    xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Target VendorID = 0x%04X",venID);
    xHc201wDebugPrint(DBG_IO, DBG_TRACE, "Target DeviceID = 0x%04X",devID);

    Dev = NULL;

    //while((Dev = pci_find_device(venID, devID, Dev)) != NULL) {
    while((Dev = pci_get_device(venID, devID, Dev)) != NULL) {

        status = xHc201wRdConfig(Dev, 0, 0x4, pData);
        if(IS_STATUSSUCCESS(status))                //device is present
        {
            xHc201wDebugPrint(DBG_IO, DBG_TRACE,"[%p] device found", Dev);

            status = xHc201wRdConfig(Dev, 0, sizeof(PCI_COMMON_CONFIG), pData);
            if(IS_STATUSSUCCESS(status))                //device is present
            {

                offset = pci_find_capability(Dev, PCI_CAP_ID_EXP);
                if(offset){
                    offset += PCI_EXP_LNKCTL;   // Link Control

                    linkControl = *(USHORT*)&pData[offset];

                    xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "LinkControl(offset = 0x%02X) = 0x%04X",offset, linkControl);

                    if(linkControl & PCI_EXP_LNKCTL_CLKREQ_EN){

                        linkControl &= ~PCI_EXP_LNKCTL_CLKREQ_EN;

                        status = xHc201wWrConfig(Dev, offset, 2, &linkControl);

                        if(IS_STATUSSUCCESS(status)){
                            pClkPMInfo = kcalloc(sizeof(XHC201W_CLKPM_INFO), 1, GFP_KERNEL);

                            if(pClkPMInfo){

                                pClkPMInfo->Dev     = Dev;
                                pClkPMInfo->Offset  = offset;

                                spin_lock( &deviceExtension->ListLock );
                                AddTailList(&pClkPMInfo->link, &deviceExtension->ClkPMDeviceList);
                                spin_unlock( &deviceExtension->ListLock );

                                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "Disable Clock PM");
                                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "Add Clock PM Device List.");

                            }
                        }
                    }
                }
            }
        }
    }

    xHc201wDebugPrintFunction(DBG_IO, DBG_TRACE, "--. status = 0x%08X",STATUS_SUCCESS);


    return status;
}


/*
 *----------------------------------------------------------------------------
 *
 * Function :
 *
 *  NTSTATUS
 *  xHc201wRestoreClkPM(
 *      PXHC201W_DEVICE_EXTENSION   deviceExtension,
 *      )
 *
 * Parameters :
 *
 *  deviceExtension
 *
 *  venID
 *      vendorID of target device
 *
 *  devID
 *      deviceID of target device
 *
 * Return Values :
 *
 *  status code
 *
 * Description :
 *
 *  Clock Power Management disable
 *
 * Remarks :
 *
 *
 *
 *----------------------------------------------------------------------------
 */
STATUS
xHc201wRestoreClkPM(
    PXHC201W_DEVICE_EXTENSION   deviceExtension
    )
{

    PXHC201W_CLKPM_INFO pClkPMInfo = NULL;
    PLIST_ENTRY pList;
    USHORT linkControl;
    STATUS status = STATUS_SUCCESS;

    while(!list_empty(&deviceExtension->ClkPMDeviceList)){

        spin_lock( &deviceExtension->ListLock );

        pList = RemoveTailList(&deviceExtension->ClkPMDeviceList);
        if(pList == NULL) {
            break;
        }
        pClkPMInfo = (PXHC201W_CLKPM_INFO)list_entry(pList, XHC201W_CLKPM_INFO, link);

        xHc201wDebugPrint(DBG_IO, DBG_TRACE,"[%X] Clock PM restore device found", pClkPMInfo->Dev);

        status = xHc201wRdConfig(pClkPMInfo->Dev, pClkPMInfo->Offset, 2, &linkControl);

        if(IS_STATUSSUCCESS(status)){
            xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "LinkControl(offset = 0x%02X) = 0x%04X",pClkPMInfo->Offset, linkControl);

            if((linkControl & PCI_EXP_LNKCTL_CLKREQ_EN) == 0){

                xHc201wDebugPrint(DBG_UTIL, DBG_TRACE, "Restore Clock PM");

                linkControl |= PCI_EXP_LNKCTL_CLKREQ_EN;
                status = xHc201wWrConfig(pClkPMInfo->Dev, pClkPMInfo->Offset, 2, &linkControl);
            }
        }

        kfree(pClkPMInfo);
        spin_unlock( &deviceExtension->ListLock );
    }

    return status;
}




