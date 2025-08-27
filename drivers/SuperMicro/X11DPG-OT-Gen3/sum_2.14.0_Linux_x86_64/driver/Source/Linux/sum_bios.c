/*
 * BIOS Kernel Device - 
 *
 * Copyright (C) 2012 Jian Liu - jianmira@gmail.com
 * Copyright (C) 2012 Suer Micro Computer, Inc.
 *  
 */
#include <linux/blkdev.h>
#include <linux/capability.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/fs.h>
#include <linux/gfp.h>
#include <linux/init.h>
#include <linux/major.h>
#include <linux/module.h>
#include <linux/smp.h>
#include <linux/uio.h>
#include <linux/version.h>

#include <asm/uaccess.h>
#include "sum_bios.h"

static Exchange_Info_t exchange_info;
static unsigned long buffer;

static void sum_bios_exit(void);

static int sum_bios_open(struct inode* inode, struct file* filp) {
    DEBUG_PRINTK("Entering BIOS OPEN \n");
    return 0;
}

static int sum_bios_release(struct inode* inode, struct file* filp) {
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

#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 11)
static long sum_bios_ioctl(struct file* filp, unsigned int command,
                           unsigned long arg) {
#else
static int sum_bios_ioctl(struct inode* inode, struct file* filp,
                          unsigned int command, unsigned long arg) {
#endif

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
                ret =
                    copy_from_user((void*)m_Exchange_Info_p->KernelVirtualAddr,
                                   (void __user*)m_Exchange_Info_p->UserAddr,
                                   m_Exchange_Info_p->Size);
                DEBUG_DUMP("After copy_from_user(), fist 0x20 bytes",
                           (void*)m_Exchange_Info_p->KernelVirtualAddr, 0x20);
                m_Exchange_Info_p->ErrCode = 0;
                break;
            case CMD_MEM_COPY_FROM_KERNEL:
                DEBUG_DUMP("Before copy_to_user(), fist 0x20 bytes",
                           (void*)m_Exchange_Info_p->KernelVirtualAddr, 0x20);
                ret = copy_to_user((void __user*)m_Exchange_Info_p->UserAddr,
                                   (void*)m_Exchange_Info_p->KernelVirtualAddr,
                                   m_Exchange_Info_p->Size);
                m_Exchange_Info_p->ErrCode = 0;
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

#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 11)
static const struct file_operations sum_bios_fops = {
    .open = sum_bios_open,
    .release = sum_bios_release,
    .unlocked_ioctl = sum_bios_ioctl,
    .owner = THIS_MODULE,
};
#else
static struct file_operations sum_bios_fops = {
    .open = sum_bios_open,
    .release = sum_bios_release,
    .ioctl = sum_bios_ioctl,
    .owner = THIS_MODULE,
};
#endif

#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 9)
static struct cdev sum_bios_cdev = {
    .kobj =
        {
            .name = "sum_bios",
        },
    .owner = THIS_MODULE,
};
#else
static struct cdev raw_cdev;
#endif

#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 20)
static char* sum_bios_devnode(struct device* dev, 
#if LINUX_VERSION_CODE >= KERNEL_VERSION(3, 3, 0)
	umode_t* mode) {
#else
	mode_t* mode) {
#endif
    DEBUG_PRINTK("Entering dev=%p, mode_t=%p\n", dev, mode);
    return kasprintf(GFP_KERNEL, "sum_bios/%s", dev_name(dev));
}
#endif

static int __init sum_bios_init(void) {
    int ret, i;

    dev_t dev = MKDEV(BIOS_MAJOR, 0);
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
        goto error_region;
    }

    ret = register_chrdev_region(dev, MAX_BIOS_MINORS, "sum_bios");
    if (ret) goto error_region;

    cdev_init(&sum_bios_cdev, &sum_bios_fops);
    ret = cdev_add(&sum_bios_cdev, dev, MAX_BIOS_MINORS);
    if (ret) {
        kobject_put(&sum_bios_cdev.kobj);
        goto error_region;
    }
#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 13)
    sum_bios_class = class_simple_create(THIS_MODULE, "sum_bios");
#else
    sum_bios_class = class_create(THIS_MODULE, "sum_bios");
#endif

    if (IS_ERR(sum_bios_class)) {
        printk(KERN_ERR "Error creating sum bios class.\n");
        cdev_del(&sum_bios_cdev);
        ret = PTR_ERR(sum_bios_class);
        goto error_region;
    }
#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 13)
    class_simple_device_add(sum_bios_class, MKDEV(BIOS_MAJOR, 0), NULL,
                            "flash%d", 0);
#elif LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 20)
    class_device_create(sum_bios_class, NULL, MKDEV(BIOS_MAJOR, 0), NULL,
                        "flash%d", 0);
#else
    sum_bios_class->devnode = sum_bios_devnode;
    device_create(sum_bios_class, NULL, MKDEV(BIOS_MAJOR, 0), NULL, "flash0");
#endif
    DEBUG_PRINTK("Exiting, return 0\n");
    return 0;

error_region:
    sum_bios_exit();
    DEBUG_PRINTK("Exiting, return ret=%d\n", ret);
    return ret;
}

static void sum_bios_exit(void) {
    DEBUG_PRINTK("Entering\n");

#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 13)
    class_simple_device_remove(MKDEV(BIOS_MAJOR, 0));
#elif LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 20)
    class_device_destroy(sum_bios_class, MKDEV(BIOS_MAJOR, 0));
#else
    device_destroy(sum_bios_class, MKDEV(BIOS_MAJOR, 0));
#endif

#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 13)
    class_simple_destroy(sum_bios_class);
#else
    class_destroy(sum_bios_class);
#endif
    cdev_del(&sum_bios_cdev);
    unregister_chrdev_region(MKDEV(BIOS_MAJOR, 0), MAX_BIOS_MINORS);
    DEBUG_PRINTK("Exiting\n");
}

module_init(sum_bios_init);
module_exit(sum_bios_exit);
MODULE_LICENSE("GPL");
