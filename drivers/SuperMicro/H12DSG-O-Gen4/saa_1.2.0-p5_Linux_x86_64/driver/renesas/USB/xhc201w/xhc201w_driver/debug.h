/*
    File Name : debug.h

    xHC Utility Driver defines

    * Copyright (C) 2010 Renesas Electronics Corporation

*/

///////////////////////////////////////////////////////////////////////////////
//
//      History
//      2010-08-16  rev0.00     base create
//
///////////////////////////////////////////////////////////////////////////////

#ifndef __DEBUG_H__
#define __DEBUG_H__

#include "stdtype.h"

// Definition of debugging area
#define DBG_GENERAL         (1 << 0)
#define DBG_PNP             (1 << 1)
#define DBG_POWER           (1 << 2)
#define DBG_COUNT           (1 << 3)
#define DBG_CREATECLOSE     (1 << 4)
#define DBG_WMI             (1 << 5)
#define DBG_UNLOAD          (1 << 6)
#define DBG_IO              (1 << 7)
#define DBG_INIT            (1 << 8)
#define DBG_UTIL            (1 << 9)
#define DBG_ALL             0xFFFFFFFF

// Definition of debugging level
#define DBG_NONE            0
#define DBG_ERR             1
#define DBG_WARN            2
#define DBG_TRACE           3
#define DBG_INFO            4
#define DBG_VERB            5

#ifdef DBG

void xHc201wDebugPrint(
    UINT     Area,
    UINT     Level,
    PCCHAR   Format,
             ...
    );


#else
#define xHc201wDebugPrint(...)
#endif


// Because __FUNCTION__ doesn't treat as a string literal, the character string uniting (__FUNCTION__ "Xxx=%d") cannot be done in gcc.
// Then, it develops with the memory once and it is assumed the argument of xHc201wDebugPrint.

#define xHc201wDebugPrintFunction(Area, Level, ...)\
{\
    UCHAR body[512];\
    sprintf(body, __VA_ARGS__);\
    xHc201wDebugPrint(Area, Level, "[%s]%s", __FUNCTION__, body);\
}


#endif//__DEBUG_H__
