/*
    File Name : stdtype.h

    xHC Utility Driver defines


    * Copyright (C) 2010 Renesas Electronics Corporation

*/

///////////////////////////////////////////////////////////////////////////////
//
//      History
//      2010-08-16  rev0.00     base create
//
///////////////////////////////////////////////////////////////////////////////

#ifndef __STDTYPE_H__
#define __STDTYPE_H__

#if 0
#include <linux/autoconf.h>
#if defined(CONFIG_MODVERSIONS) && !defined(MODVERSIONS)
#define MODVERSIONS
#endif

#ifdef MODVERSIONS
#include <linux/modversions.h>
#endif
#endif

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/proc_fs.h>
#include <linux/mutex.h>
#include <linux/list.h>
#include <linux/spinlock_types.h>
#include <linux/list.h>
#include <linux/io.h>
#include <linux/pci.h>
#include <linux/syscalls.h>
#include <linux/uaccess.h>
 
/*************************************************************************/
// type Define
/*************************************************************************/

typedef void                *PVOID,         *LPVOID;
typedef unsigned long       PHYSICAL_ADDRESS;
typedef struct list_head    LIST_ENTRY,     *PLIST_ENTRY;
typedef unsigned long       ULONG,  DWORD,  *PULONG, *LPDWORD;
typedef          long       LONG,   *PLONG;
typedef unsigned int        UINT,   *PUINT;
typedef          int        INT,    *PINT;
typedef unsigned short      USHORT, *PUSHORT;
typedef unsigned char       UCHAR,  *PUCHAR;
typedef          char       CHAR,   *PCHAR;
typedef const    char       CCHAR,  *PCCHAR;
typedef int                 BOOLEAN;
#define TRUE                (0==0)
#define FALSE               (!TRUE)
typedef int                 STATUS;
typedef long                LSTATUS;
typedef spinlock_t          KSPIN_LOCK;
typedef struct mutex        XHC201W_IO_LOCK;

#define STATUS_SUCCESS                  (0)
#define STATUS_UNSUCCESSFUL             (1)
#define STATUS_BUFFER_TOO_SMALL         (2)
#define STATUS_CANCELLED                (3)
#define STATUS_DEVICE_ALREADY_ATTACHED  (4)
#define STATUS_DEVICE_BUSY              (5)
#define STATUS_DEVICE_NOT_READY         (6)
#define STATUS_INSUFFICIENT_RESOURCES   (7)
#define STATUS_INVALID_DEVICE_REQUEST   (8)
#define STATUS_INVALID_DEVICE_STATE     (9)
#define STATUS_INVALID_HANDLE           (10)
#define STATUS_INVALID_PARAMETER        (11)
#define STATUS_IO_DEVICE_ERROR          (12)
#define STATUS_NO_MATCH                 (13)
#define STATUS_NO_SUCH_DEVICE           (14)
#define STATUS_PENDING                  (15)

#define IS_STATUSSUCCESS(a)       (a==STATUS_SUCCESS)


#endif//__STDTYPE_H__
