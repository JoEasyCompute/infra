/*
	File Name : debug.c
	
	Debug IO
	
    * Copyright (C) 2010 Renesas Electronics Corporation
*/

///////////////////////////////////////////////////////////////////////////////
//
//		History
//      2010-08-16  rev0.00     base create
//
///////////////////////////////////////////////////////////////////////////////

#include "debug.h"

#define PRINTK(LEVEL,frmt,...)  printk(LEVEL frmt,__VA_ARGS__)

// Debugging level and debugging area mask
UINT	g_DebugLevel = DBG_INFO;
UINT	g_DebugArea = DBG_ALL;


#ifdef DBG	// Build only in case of Debug

///////////////////////////////////////////////////////////////////////////////////////////////////
//	xHc201wDebugPrint
//      Debugging message output routine
//
//  Arguments:
//		IN	Area
//				Debugging area (DBG_PNP, DBG_POWER, etc..)
//
//		IN	Level
//				Debugging level (DBG_ERR, DBG_INFO, etc..)
//
//		IN	Format
//				Format of debugging message
//
//  Return value:
//      None
//
void xHc201wDebugPrint(
	UINT	Area,
	UINT	Level,
	PCCHAR	Format,
			...
	)
{
	CHAR    g_DebugBuffer[1024];
	va_list vaList;

	va_start(vaList, Format);

	// The mask and the debugging level of the debugging area are checked.
	if ((g_DebugArea & Area) && (Level <= g_DebugLevel))
	{
		vsprintf(g_DebugBuffer, Format,  vaList);

		if (Level == DBG_ERR)
		{
			PRINTK(KERN_ERR, "XHC201W: ERROR %s !!!!!\n", g_DebugBuffer);
		}
		else if (Level == DBG_WARN)
		{
			PRINTK(KERN_WARNING, "XHC201W: WARNING %s\n", g_DebugBuffer);
		}
		else if (Level == DBG_INFO)
		{
			PRINTK(KERN_INFO, "XHC201W:     %s\n", g_DebugBuffer);
		}
		else
		{
			PRINTK(KERN_DEBUG, "XHC201W: %s\n", g_DebugBuffer);
		}
	}

	va_end(vaList);
	return;
}

#endif

