obj-m := dummy_cam.o
KDIR  ?= /lib/modules/$(shell uname -r)/build
PWD   := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

# Install into /lib/modules/<ver>/updates and refresh the module index, so the
# overlay's "raspberrypi,dummy-csi2-sensor" node autoloads dummy_cam on every
# boot. (insmod alone does not survive a reboot.)
install: all
	$(MAKE) -C $(KDIR) M=$(PWD) INSTALL_MOD_DIR=updates modules_install
	depmod -a

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

.PHONY: all install clean
