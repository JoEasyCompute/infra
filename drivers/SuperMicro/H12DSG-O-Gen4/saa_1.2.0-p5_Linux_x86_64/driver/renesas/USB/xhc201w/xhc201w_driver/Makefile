#############################################################


KERNEL_VERSION	 =`uname -a | cut -f3 -d" "`
KERNEL_DIR		 =/usr/src/linux-$(KERNEL_VERSION)
BUILD_DIR		:=$(shell pwd)/xhc201w/xhc201w_driver
VERBOSE 		 = 0
EXTRA_CFLAG     += -Wall
#############################################################
#EXTRA_CFLAGS	+= -DDBG
#EXTRA_CFLAGS    += -D_READCGF_DEBUG
#EXTRA_CFLAGS    += -D_LIST_DEBUG
#EXTRA_CFLAGS    += -D_AHB_ACCESS_DEBUG
#############################################################

files 	 = xhcdrv
files 	+= util
files 	+= iorw
files 	+= debug

xhc201-objs = $(files:%=%.o)
obj-m	 = xhc201.o

all: modules

modules:
	$(MAKE) -C $(KERNEL_DIR) M=$(BUILD_DIR) KBUILD_VERBOSE=$(VERBOSE) modules
	cp $(BUILD_DIR)/*.ko ./

