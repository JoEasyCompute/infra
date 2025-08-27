/*
 * BIOS Kernel Device -
 * Copyright (C) 2024 Super Micro Computer, Inc.
 */
// clang-format off
#include <asm/io.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/uaccess.h>
#include <linux/version.h>
#include "supermicro_phymem.h"
// clang-format on

static Exchange_Info_t exchange_info;
static unsigned long buffer;
static ssize_t probe_memory(char __user*, size_t, unsigned long, bool);
static void supermicro_phymem_exit(void);

static ssize_t probe_memory(char __user* ubuff, size_t count,
                            unsigned long phyaddr, bool read) {
    ssize_t bytes = 0;
    size_t sz = 0;
    void* vaddr = NULL;
    int error = 0;
#ifdef __ARCH_HAS_NO_PAGE_ZERO_MAPPED
    if (phyaddr < PAGE_SIZE) {
        sz = PAGE_SIZE - phyaddr;
        if (sz > count) sz = count;
        if (sz > 0) {
            if (read && clear_user(ubuff, sz)) return -EFAULT;
            ubuff += sz;
            phyaddr += sz;
            count -= sz;
            bytes += sz;
        }
    }
#endif
    if (!buffer) {
        pr_info(KERN_ALERT "[supermicro_phymem]: Memory allocation error\n");
        return -ENOMEM;
    }

    while (count > 0) {
        // handle if first page not alligned
        if (-phyaddr & (PAGE_SIZE - 1))
            sz = -phyaddr & (PAGE_SIZE - 1);
        else
            sz = PAGE_SIZE;
        if (sz > count) sz = count;
        //For ia64 systems, if page is mapped uncached, retrive it uncached else data corruption might occur.
        unsigned long start = phyaddr & PAGE_MASK;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 25)
        vaddr = (void __force*)ioremap(start, PAGE_SIZE);
#else
        vaddr = (void __force*)ioremap_nocache(start, PAGE_SIZE);
#endif
        if (!vaddr)
            vaddr = (void __force*)ioremap_prot(start, PAGE_SIZE, 0);
        else
            vaddr = (void*)((unsigned long)vaddr | (phyaddr & ~PAGE_MASK));
        if (!vaddr) {
            pr_info(
                "[supermicro_phymem]: Unable to map physcial address %lX in "
                "kernel space\n",
                phyaddr);
            return -EFAULT;
        }

        if (read) {
            error = copy_to_user(ubuff, vaddr, sz);
            if (error) {
                pr_info(
                    "[supermicro_phymem] : copy_to_user error:%d, from vaddr: "
                    "%lX ",
                    error, (unsigned long)vaddr);
                iounmap((void __iomem*)((unsigned long)vaddr & PAGE_MASK));
                return -EFAULT;
            }
        }
        else {
            error = copy_from_user(vaddr, ubuff, sz);
            if (error) {
                pr_info(
                    "[supermicro_phymem]: copy_from_user error , vaddr: %lX",
                    error, (unsigned long)vaddr);
                iounmap((void __iomem*)((unsigned long)vaddr & PAGE_MASK));
                return -EFAULT;
            }
        }
        iounmap((void __iomem*)((unsigned long)vaddr & PAGE_MASK));
        ubuff += sz;
        phyaddr += sz;
        count -= sz;
        bytes += sz;
    }
    return bytes;
}

static int supermicro_phymem_open(struct inode* inode, struct file* filp) {
    DEBUG_PRINTK("Entering BIOS OPEN \n");
    return 0;
}

static int supermicro_phymem_release(struct inode* inode, struct file* filp) {
    DEBUG_PRINTK("Entering BIOS CLOSE \n");
    return 0;
}

static int isBytePortAllowed(int port) {
    if (port >= 0x70 && port <= 0x75) {
        return 1;
    }
    return 0;
}

static int isLongPortAllowed(int port) {
    if (port == 0xcf8 || port == 0xcfc) {
        return 1;
    }
    return 0;
}

static long supermicro_phymem_ioctl(struct file* filp, unsigned int command,
                                    unsigned long arg) {
    int ret;
    __u8* m_KernelVirtualAddr_p;
    Exchange_Info_t* m_Exchange_Info_p = NULL;

    DEBUG_PRINTK("Entering IOCTOL command 0x%x, arg=0x%lx\n", command, arg);
    m_Exchange_Info_p = &exchange_info;
    if (CMD_MEM_COMMAND_START <= command && command <= CMD_MEM_COMMAND_END) {
        if (copy_from_user(m_Exchange_Info_p, (void __user*)arg,
                           sizeof(Exchange_Info_t))) {
            DEBUG_PRINTK(KERN_ERR "Failed copy exchange info from U to K\n");
            return -EFAULT;
        }
        else {
            m_Exchange_Info_p->ErrCode = 1;  // Set as default.
        }

        char* ptr = m_Exchange_Info_p->KernelVirtualAddr;
        char b50, b51, b70, b71;

        switch (command) {
            case CMD_EXECUTE_ASM:
                ret =
                    copy_from_user((void*)m_Exchange_Info_p->KernelVirtualAddr,
                                   (void __user*)m_Exchange_Info_p->UserAddr,
                                   m_Exchange_Info_p->Size);
                int* aaaa = (int*)m_Exchange_Info_p->KernelVirtualAddr;
                if (aaaa[20] == 1) {
                    unsigned long p = 0xB2;
                    unsigned long h = 0;
                    int* d = m_Exchange_Info_p->KernelVirtualAddr;
                    unsigned long l = d[0];
                    unsigned char c = (unsigned char)(d[1] & 0xFF);

                    __asm__ __volatile__("outb %%al, %%dx;" ::"a"(c), "b"(l),
                                         "c"(h), "d"(p));
                }
                else if (aaaa[20] == 2) {
                    unsigned long e = 0xfafafafa;
                    int* temp = (int*)m_Exchange_Info_p->KernelVirtualAddr;
                    int a = temp[0];
                    int l = temp[1];
                    unsigned long aa = (a) ? 0xC0000001 : 0xC0000002;
                    unsigned long p = 0xB2;
                    unsigned long m = 0xffffffff;
                    unsigned long long v = 0xffffffff;

                    __asm__ __volatile__("outb %%al, %%dx;"
                                         : "=c"(v), "=S"(m)
                                         : "a"(0xD9), "b"(e), "c"(aa), "d"(p),
                                           "S"(l), "D"(0x0));
                    int* data = (int*)m_Exchange_Info_p->KernelVirtualAddr;
                    data[0] = v;
                    data[1] = m;
                }
                else if (aaaa[20] == 3) {
                    unsigned long x = 0xC0000001;
                    unsigned long z = 0xffffffff;
                    unsigned long s = 0x80000;
                    unsigned long b = 0;
                    unsigned long long r;

                    __asm__ __volatile__("outb %%al, %%dx;"
                                         : "=c"(r), "=S"(b)
                                         : "a"(0xD9), "b"(z), "c"(x), "d"(0xB2),
                                           "S"(s), "D"(0x0));
                    unsigned long long* data =
                        (unsigned long long*)
                            m_Exchange_Info_p->KernelVirtualAddr;
                    data[0] = r;
                    data[1] = b;
                }
                else if (aaaa[20] == 4) {
                    __asm__ __volatile__("outb %%al, %%dx;"
                                         : /* no output */
                                         : "a"(aaaa[0]), "d"(0xB2));
                }
                else {
                    unsigned long h = 0xFAFAFAFA;
                    unsigned long l = 0xFAFAFAFA;
                    unsigned long long r = 0xFFFFFFFF;
                    unsigned long t = 0xFFFFFFFF;

                    __asm__ __volatile__("outb %%al, %%dx;"
                                         : "=a"(r), "=b"(l), "=c"(t)
                                         : "a"(0xE7), "b"(0x01), "c"(h),
                                           "d"(0xB2));
                    unsigned long* data =
                        (unsigned long*)m_Exchange_Info_p->KernelVirtualAddr;
                    data[0] = l;
                    data[1] = r;
                    data[2] = t;
                }

                m_Exchange_Info_p->Size = 0x2000;
                ret = copy_to_user((void __user*)m_Exchange_Info_p->UserAddr,
                                   (void*)m_Exchange_Info_p->KernelVirtualAddr,
                                   m_Exchange_Info_p->Size);

                break;
            case CMD_MEM_SET_CMOS_B: {
                ret =
                    copy_from_user((void*)m_Exchange_Info_p->KernelVirtualAddr,
                                   (void __user*)m_Exchange_Info_p->UserAddr,
                                   m_Exchange_Info_p->Size);
                int* a = (int*)m_Exchange_Info_p->KernelVirtualAddr;
                int v = a[0];
                int p = a[1];
                if (isBytePortAllowed(p)) {
                    outb(v, p);
                }
                break;
            }
            case CMD_MEM_GET_CMOS_B: {
                ret =
                    copy_from_user((void*)m_Exchange_Info_p->KernelVirtualAddr,
                                   (void __user*)m_Exchange_Info_p->UserAddr,
                                   m_Exchange_Info_p->Size);
                int* a = (int*)m_Exchange_Info_p->KernelVirtualAddr;
                int p = a[1];
                if (isBytePortAllowed(p)) {
                    a[0] = inb(p);
                }

                unsigned long* data =
                    (unsigned long*)m_Exchange_Info_p->KernelVirtualAddr;
                data[0] = a[0];

                m_Exchange_Info_p->Size = 0x2000;
                ret = copy_to_user((void __user*)m_Exchange_Info_p->UserAddr,
                                   (void*)m_Exchange_Info_p->KernelVirtualAddr,
                                   m_Exchange_Info_p->Size);
                break;
            }
            case CMD_MEM_SET_CMOS_L: {
                ret =
                    copy_from_user((void*)m_Exchange_Info_p->KernelVirtualAddr,
                                   (void __user*)m_Exchange_Info_p->UserAddr,
                                   m_Exchange_Info_p->Size);
                int* a = (int*)m_Exchange_Info_p->KernelVirtualAddr;
                int v = a[0];
                int p = a[1];
                if (isLongPortAllowed(p)) {
                    outl(v, p);
                }
                break;
            }
            case CMD_MEM_GET_CMOS_L: {
                ret =
                    copy_from_user((void*)m_Exchange_Info_p->KernelVirtualAddr,
                                   (void __user*)m_Exchange_Info_p->UserAddr,
                                   m_Exchange_Info_p->Size);
                int* a = (int*)m_Exchange_Info_p->KernelVirtualAddr;
                int p = a[1];
                if (isLongPortAllowed(p)) {
                    a[0] = inl(p);
                }

                unsigned long* data =
                    (unsigned long*)m_Exchange_Info_p->KernelVirtualAddr;
                data[0] = a[0];

                m_Exchange_Info_p->Size = 0x2000;
                ret = copy_to_user((void __user*)m_Exchange_Info_p->UserAddr,
                                   (void*)m_Exchange_Info_p->KernelVirtualAddr,
                                   m_Exchange_Info_p->Size);
                break;
            }
            case CMD_MEM_ALLOC_KERNEL:
                DEBUG_PRINTK("m_KernelVirtualAddr_p = %p\n",
                             m_KernelVirtualAddr_p);
                m_Exchange_Info_p->KernelVirtualAddr = (__u64)buffer;
                m_Exchange_Info_p->KernelPhysicalAddr = virt_to_phys(
                    (volatile void*)m_Exchange_Info_p->KernelVirtualAddr);
                m_Exchange_Info_p->ErrCode = 0;
                break;
            case CMD_MEM_FREE_KERNEL:
                m_Exchange_Info_p->ErrCode = 0;
                break;
            case CMD_MEM_COPY_TO_KERNEL:
                DEBUG_DUMP("Before copy_from_user(), fist 0x20 bytes",
                           (void*)m_Exchange_Info_p->KernelVirtualAddr, 0x20);
                m_Exchange_Info_p->ErrCode =
                    probe_memory((char __user*)m_Exchange_Info_p->UserAddr,
                                 m_Exchange_Info_p->Size,
                                 m_Exchange_Info_p->KernelPhysicalAddr, false);
                DEBUG_DUMP("After copy_from_user(), fist 0x20 bytes",
                           (void*)m_Exchange_Info_p->KernelVirtualAddr, 0x20);
                break;
            case CMD_MEM_COPY_FROM_KERNEL:
                DEBUG_DUMP("Before copy_to_user(), fist 0x20 bytes",
                           (void*)m_Exchange_Info_p->KernelVirtualAddr, 0x20);
                m_Exchange_Info_p->ErrCode =
                    probe_memory((char __user*)m_Exchange_Info_p->UserAddr,
                                 m_Exchange_Info_p->Size,
                                 m_Exchange_Info_p->KernelPhysicalAddr, true);
                break;
            default:
                printk(KERN_ERR "Error command 0x%x\n", command);
                DEBUG_PRINTK("Error command 0x%x\n", command);
                break;
        }

        //DEBUG_DUMP("Before copy_to_user(), Exchange_Info", (__u8 *)m_Exchange_Info_p, sizeof(Exchange_Info_t));
        if (copy_to_user((void __user*)arg, (void*)m_Exchange_Info_p,
                         sizeof(Exchange_Info_t))) {
            printk(KERN_ERR "Failed copy Exchange_Info from K to U\n");
            return -EFAULT;
        }

        return 0;
    }

    return 0;
}

static const struct file_operations supermicro_phymem_fops = {
    .unlocked_ioctl = supermicro_phymem_ioctl,
};

static struct miscdevice supermicro_phymem_dev = {
    .minor = MISC_DYNAMIC_MINOR,
    .name = "supermicro_phymem",
    .fops = &supermicro_phymem_fops};

int __init init_module(void) {
    int ret, i;
    DEBUG_PRINTK("Entering\n");
    buffer = __get_free_pages(GFP_DMA, 5);  // alloc 128 k mem
    for (i = 0; i < 10; i++) {
        DEBUG_PRINTK("GetFreePages count = %d \n", i);
        if (buffer) break;
        buffer = __get_free_pages(GFP_DMA, 5);
    }
    if (!buffer) {
        printk(KERN_ERR "Error get 32 pages.\n");
        ret = ENOMEM;
    }
    ret = misc_register(&supermicro_phymem_dev);
    if (ret) {
        pr_err(
            "[supermicro_phymem]: supermicro_phymem register dev failed!!!\n");
        return ret;
    }
    pr_info("[supermicro_phymem]: supermicro_phymem register done\n");
    return 0;
}

void cleanup_module(void) {
    misc_deregister(&supermicro_phymem_dev);
    if (buffer) free_pages(buffer, 5);
    pr_info("[supermicro_phymem]: supermicro_phymem exit done\n");
}

MODULE_LICENSE("GPL");
