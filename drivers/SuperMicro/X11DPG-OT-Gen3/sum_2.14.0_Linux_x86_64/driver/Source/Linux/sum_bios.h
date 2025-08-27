/*
 * bios.h
 *
 *  Created on: Aug 13, 2013
 *      Author: root
 */

#ifndef BIOS_H_
#define BIOS_H_

#define DEVICE_BUFFER_SIZE 0x10000  // Byte

#define BIOS_MAJOR 100
#define MAX_BIOS_MINORS 1

#define CMD_MEM_COMMAND_START 0xFF00
#define CMD_MEM_ALLOC_KERNEL 0xFF00
#define CMD_MEM_FREE_KERNEL 0xFF01
#define CMD_MEM_COPY_TO_KERNEL 0xFF02
#define CMD_MEM_COPY_FROM_KERNEL 0xFF03
#define CMD_EXECUTE_ASM 0xFF04
#define CMD_MEM_SET_CMOS_B 0xFF05
#define CMD_MEM_GET_CMOS_B 0xFF06
#define CMD_MEM_SET_CMOS_L 0xFF07
#define CMD_MEM_GET_CMOS_L 0xFF08
#define CMD_MEM_COMMAND_END 0xFF08

#ifndef IS_DEBUG
#define IS_DEBUG 0
#endif

#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 13)
static struct class_simple* sum_bios_class;
#else
static struct class* sum_bios_class;
#endif

#define DEBUG_PRINTK(fmt, args...)                                             \
    do {                                                                       \
        if (IS_DEBUG)                                                          \
            printk(KERN_ERR "Line#%d:%s(): " fmt, __LINE__, __func__, ##args); \
    } while (0)

static void DEBUG_DUMP(char* iMsg, __u8* iPtr, size_t iSize) {
    int idx;
    if (!IS_DEBUG) return;

    printk(KERN_ERR "Dump '%s', iPtr=%p, size=0x%x(%u) =====================\n",
           iMsg, iPtr, (unsigned int)iSize, (unsigned int)iSize);
    printk(KERN_ERR "====================================================\n");
    for (idx = 0; idx < iSize; idx = idx + 16) {
        if ((iSize - idx) >= 16) {
            printk(KERN_ERR
                   "0x%04x: %02x %02x %02x %02x %02x %02x %02x %02x  %02x %02x "
                   "%02x %02x %02x %02x %02x %02x\n",
                   idx, *(iPtr + idx + 0), *(iPtr + idx + 1), *(iPtr + idx + 2),
                   *(iPtr + idx + 3), *(iPtr + idx + 4), *(iPtr + idx + 5),
                   *(iPtr + idx + 6), *(iPtr + idx + 7), *(iPtr + idx + 8),
                   *(iPtr + idx + 9), *(iPtr + idx + 10), *(iPtr + idx + 11),
                   *(iPtr + idx + 12), *(iPtr + idx + 13), *(iPtr + idx + 14),
                   *(iPtr + idx + 15));
        }
        else if (15 == ((iSize - idx) % 16)) {
            printk(KERN_ERR
                   "0x%04x: %02x %02x %02x %02x %02x %02x %02x %02x  %02x %02x "
                   "%02x %02x %02x %02x %02x\n",
                   idx, *(iPtr + idx + 0), *(iPtr + idx + 1), *(iPtr + idx + 2),
                   *(iPtr + idx + 3), *(iPtr + idx + 4), *(iPtr + idx + 5),
                   *(iPtr + idx + 6), *(iPtr + idx + 7), *(iPtr + idx + 8),
                   *(iPtr + idx + 9), *(iPtr + idx + 10), *(iPtr + idx + 11),
                   *(iPtr + idx + 12), *(iPtr + idx + 13), *(iPtr + idx + 14));
        }
        else if (14 == ((iSize - idx) % 16)) {
            printk(KERN_ERR
                   "0x%04x: %02x %02x %02x %02x %02x %02x %02x %02x  %02x %02x "
                   "%02x %02x %02x %02x\n",
                   idx, *(iPtr + idx + 0), *(iPtr + idx + 1), *(iPtr + idx + 2),
                   *(iPtr + idx + 3), *(iPtr + idx + 4), *(iPtr + idx + 5),
                   *(iPtr + idx + 6), *(iPtr + idx + 7), *(iPtr + idx + 8),
                   *(iPtr + idx + 9), *(iPtr + idx + 10), *(iPtr + idx + 11),
                   *(iPtr + idx + 12), *(iPtr + idx + 13));
        }
        else if (13 == ((iSize - idx) % 16)) {
            printk(KERN_ERR
                   "0x%04x: %02x %02x %02x %02x %02x %02x %02x %02x  %02x %02x "
                   "%02x %02x %02x\n",
                   idx, *(iPtr + idx + 0), *(iPtr + idx + 1), *(iPtr + idx + 2),
                   *(iPtr + idx + 3), *(iPtr + idx + 4), *(iPtr + idx + 5),
                   *(iPtr + idx + 6), *(iPtr + idx + 7), *(iPtr + idx + 8),
                   *(iPtr + idx + 9), *(iPtr + idx + 10), *(iPtr + idx + 11),
                   *(iPtr + idx + 12));
        }
        else if (12 == ((iSize - idx) % 16)) {
            printk(KERN_ERR
                   "0x%04x: %02x %02x %02x %02x %02x %02x %02x %02x  %02x %02x "
                   "%02x %02x\n",
                   idx, *(iPtr + idx + 0), *(iPtr + idx + 1), *(iPtr + idx + 2),
                   *(iPtr + idx + 3), *(iPtr + idx + 4), *(iPtr + idx + 5),
                   *(iPtr + idx + 6), *(iPtr + idx + 7), *(iPtr + idx + 8),
                   *(iPtr + idx + 9), *(iPtr + idx + 10), *(iPtr + idx + 11));
        }
        else if (11 == ((iSize - idx) % 16)) {
            printk(KERN_ERR
                   "0x%04x: %02x %02x %02x %02x %02x %02x %02x %02x  %02x %02x "
                   "%02x\n",
                   idx, *(iPtr + idx + 0), *(iPtr + idx + 1), *(iPtr + idx + 2),
                   *(iPtr + idx + 3), *(iPtr + idx + 4), *(iPtr + idx + 5),
                   *(iPtr + idx + 6), *(iPtr + idx + 7), *(iPtr + idx + 8),
                   *(iPtr + idx + 9), *(iPtr + idx + 10));
        }
        else if (10 == ((iSize - idx) % 16)) {
            printk(
                KERN_ERR
                "0x%04x: %02x %02x %02x %02x %02x %02x %02x %02x  %02x %02x\n",
                idx, *(iPtr + idx + 0), *(iPtr + idx + 1), *(iPtr + idx + 2),
                *(iPtr + idx + 3), *(iPtr + idx + 4), *(iPtr + idx + 5),
                *(iPtr + idx + 6), *(iPtr + idx + 7), *(iPtr + idx + 8),
                *(iPtr + idx + 9));
        }
        else if (9 == ((iSize - idx) % 16)) {
            printk(KERN_ERR
                   "0x%04x: %02x %02x %02x %02x %02x %02x %02x %02x  %02x\n",
                   idx, *(iPtr + idx + 0), *(iPtr + idx + 1), *(iPtr + idx + 2),
                   *(iPtr + idx + 3), *(iPtr + idx + 4), *(iPtr + idx + 5),
                   *(iPtr + idx + 6), *(iPtr + idx + 7), *(iPtr + idx + 8));
        }
        else if (8 == ((iSize - idx) % 16)) {
            printk(KERN_ERR "0x%04x: %02x %02x %02x %02x %02x %02x %02x %02x\n",
                   idx, *(iPtr + idx + 0), *(iPtr + idx + 1), *(iPtr + idx + 2),
                   *(iPtr + idx + 3), *(iPtr + idx + 4), *(iPtr + idx + 5),
                   *(iPtr + idx + 6), *(iPtr + idx + 7));
        }
        else if (7 == ((iSize - idx) % 16)) {
            printk(KERN_ERR "0x%04x: %02x %02x %02x %02x %02x %02x %02x\n", idx,
                   *(iPtr + idx + 0), *(iPtr + idx + 1), *(iPtr + idx + 2),
                   *(iPtr + idx + 3), *(iPtr + idx + 4), *(iPtr + idx + 5),
                   *(iPtr + idx + 6));
        }
        else if (6 == ((iSize - idx) % 16)) {
            printk(KERN_ERR "0x%04x: %02x %02x %02x %02x %02x %02x\n", idx,
                   *(iPtr + idx + 0), *(iPtr + idx + 1), *(iPtr + idx + 2),
                   *(iPtr + idx + 3), *(iPtr + idx + 4), *(iPtr + idx + 5));
        }
        else if (5 == ((iSize - idx) % 16)) {
            printk(KERN_ERR "0x%04x: %02x %02x %02x %02x %02x\n", idx,
                   *(iPtr + idx + 0), *(iPtr + idx + 1), *(iPtr + idx + 2),
                   *(iPtr + idx + 3), *(iPtr + idx + 4));
        }
        else if (4 == ((iSize - idx) % 16)) {
            printk(KERN_ERR "0x%04x: %02x %02x %02x %02x\n", idx,
                   *(iPtr + idx + 0), *(iPtr + idx + 1), *(iPtr + idx + 2),
                   *(iPtr + idx + 3));
        }
        else if (3 == ((iSize - idx) % 16)) {
            printk(KERN_ERR "0x%04x: %02x %02x %02x\n", idx, *(iPtr + idx + 0),
                   *(iPtr + idx + 1), *(iPtr + idx + 2));
        }
        else if (2 == ((iSize - idx) % 16)) {
            printk(KERN_ERR "0x%04x: %02x %02x\n", idx, *(iPtr + idx + 0),
                   *(iPtr + idx + 1));
        }
        else if (1 == ((iSize - idx) % 16)) {
            printk(KERN_ERR "0x%04x: %02x\n", idx, *(iPtr + idx + 0));
        }
    }
    printk(KERN_ERR "\n");
    printk(KERN_ERR "====================================================\n");
}
#pragma pack(1)
typedef struct {
    __u64 UserAddr;
    __u64 KernelVirtualAddr;
    __u32 KernelPhysicalAddr;
    __u32 Size;
    __u8 ErrCode;
} Exchange_Info_t;
#pragma pack()

#endif /* BIOS_H_ */
