# Build the VL53L9CX bring-up / streaming app.
APP     := vl53l9_bringup
VENDOR  := vendor/st-uld
CFLAGS  += -O2 -Wall -I$(VENDOR)
LDLIBS  += -lrt -lpthread -lm
SRC     := app/vl53l9_bringup.c \
           $(VENDOR)/vl53l9.c \
           $(VENDOR)/vl53l9_platform.c \
           $(VENDOR)/vl53l9_utils.c

# Device-tree overlays. The Pi 5 overlay #includes dt-bindings, so it has to go
# through the C preprocessor before dtc (dtc alone does not expand #include).
OVERLAYS     := vl53l9-mipi.dtbo vl53l9-mipi-pi5.dtbo
OVERLAY_DIR  ?= /boot/firmware/overlays
DTC          ?= dtc
CPP_DT       := cpp -nostdinc -undef -x assembler-with-cpp -Idriver

$(APP): $(SRC)
	$(CC) $(CFLAGS) $(SRC) -o $@ $(LDLIBS)

%.dtbo: driver/%.dts
	$(CPP_DT) $< | $(DTC) -@ -q -I dts -O dtb -o $@ -

.PHONY: module module_install overlay overlay_install tools clean
module:                 ## build the dummy_cam kernel module
	$(MAKE) -C driver
module_install: module  ## install dummy_cam.ko so it autoloads on every boot (needs root)
	$(MAKE) -C driver install
overlay: $(OVERLAYS)    ## compile both device-tree overlays
overlay_install: overlay ## copy overlays to $(OVERLAY_DIR) (needs root)
	install -m 0644 $(OVERLAYS) $(OVERLAY_DIR)/
tools:                  ## build userspace diagnostic helpers (see tools/)
	$(MAKE) -C tools
clean:
	rm -f $(APP) $(OVERLAYS)
	-$(MAKE) -C driver clean
	-$(MAKE) -C tools clean
