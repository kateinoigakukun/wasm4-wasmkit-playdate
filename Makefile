# WASM-4 on Playdate, in Embedded Swift.
#
#   make simulator  -> build/wasm4.pdx with pdex.dylib  (host, regular Swift)
#   make device     -> build/wasm4.pdx with pdex.elf    (armv7em, Embedded Swift)
#   make run        -> build the simulator target and open it
#
# The SDK's common.mk is not used: it compiles C sources directly and we need to
# drive swiftc ourselves. link_map.ld is vendored from the SDK (0BSD).
#
# Both targets are Embedded Swift, so the simulator exercises the same dialect
# as the device. This requires the WasmKit fixes carried on the pinned submodule
# commit: upstream's host-only guards test only the operating system, so an
# Embedded build targeting macOS compiled code whose provider was excluded.

SDK ?= $(HOME)/Playdate
TOOLCHAIN ?= $(HOME)/Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain
SWIFTC := $(TOOLCHAIN)/usr/bin/swiftc
PDC := $(SDK)/bin/pdc
ARM_GCC ?= $(shell dirname $(shell which arm-none-eabi-gcc))/arm-none-eabi-
# Swift's bundled clang has no bare-metal sysroot of its own, so the newlib and
# gcc header directories have to be handed to it explicitly.
ARM_ROOT := $(patsubst %/bin/,%,$(dir $(shell readlink -f $(shell which arm-none-eabi-gcc))))
# newlib supplies the C library headers; clang has no bare-metal sysroot.
ARM_INCLUDES := -isystem $(ARM_ROOT)/arm-none-eabi/include

WASMKIT := vendor/WasmKit
CWASMKIT_INC := $(WASMKIT)/Sources/_CWasmKit/include
EMBEDDED_LIB_ROOT := $(TOOLCHAIN)/usr/lib/swift/embedded
EMBEDDED_LIBS := $(EMBEDDED_LIB_ROOT)/armv7em-none-none-eabi
# Embedded Swift emits references to the Unicode tables for String hashing and
# comparison, and they are not part of the per-triple stdlib archive.
SIM_EMBEDDED_LIBS := $(EMBEDDED_LIB_ROOT)/$(shell uname -m)-apple-macos

BUILD := build
PRODUCT := $(BUILD)/wasm4.pdx

# The shelf's list is generated from carts.txt, so a game is added in one
# place. It is listed explicitly as well as globbed, because on a fresh clone
# it does not exist yet and the glob would miss it.
CART_LIST := Sources/W4/CartList.swift
SWIFT_SOURCES := $(filter-out $(CART_LIST),$(wildcard Sources/W4/*.swift)) $(CART_LIST)

$(CART_LIST): carts.txt tools/carts.sh
	@tools/carts.sh

# WasmKit modules, in dependency order. Compiled from the upstream source tree
# exactly as Utilities/build-embedded.sh does rather than through SwiftPM,
# because the device link is driven by swiftc directly.
WASMKIT_MODULES := WasmTypes WasmParser WasmKit

# Our own library modules, compiled the same way. WASM4 is the console
# emulation and must stay free of any Playdate dependency so the same code can
# run in a host test harness.
APP_MODULES := WASM4

# Measured on a revision A device, playing Snake, as milliseconds per
# displayed frame. The panel refreshes at 50 Hz, so 20 ms is the floor.
#
#     as first measured                     39.5 ms    25 fps
#     + exact-capacity host call parameters 37.8 ms    26 fps
#     + direct threading, via musttail      37.8 ms    26 fps
#     + host signature resolved once        31.3 ms    32 fps
#     + unboxed host functions              27.8 ms    36 fps
#     + pacing that predicts the next frame 22.1 ms    45 fps
#     + blitter fast path                   21.7 ms    46 fps
#     + converting only changed rows        20.3 ms    49 fps
#
# -O beats -Osize by 16% to 56% on real carts, and `WASMKIT_OPT=-Osize` was
# tried again after direct threading landed and still lost. The received
# wisdom among Playdate emulator authors is that a smaller dispatch loop wins,
# because the revision A instruction cache is only 4 KB; it does not hold here.
# An earlier synthetic benchmark of a thirteen-instruction loop agreed with the
# wisdom, but only because such a loop touches a handful of opcode handlers and
# so fits in that cache whatever the setting -- it could not have measured the
# thing in question.
#
# What the device costs, for anyone optimising further: a guest instruction
# runs in about 656 cycles against 49 for a loop small enough to stay in cache,
# so the interpreter is bound by instruction fetch from external memory. An
# allocation costs about 27 microseconds, which is why the work above is mostly
# about not allocating.
#
# Note that `-Xcc -falign-functions=32` does nothing here: -Xcc reaches Clang,
# not Swift's own code generation, so it never touches the interpreter.
#
# Changing these does not invalidate objects already built, so run `make clean`
# first or the comparison is against a stale binary.
OPT ?= -O
# The interpreter can be optimised separately from the rest: it is the code
# that thrashes the 4 KB instruction cache, and the drawing code, which wants
# -O unambiguously, is not. Whether that separation is worth anything is
# untested -- `make clean device WASMKIT_OPT=-Osize` is the experiment.
WASMKIT_OPT ?= $(OPT)
EXTRA_SWIFT ?=

SWIFT_BASE := -wmo -parse-as-library -Xfrontend -function-sections $(EXTRA_SWIFT)

# --------------------------------------------------------------- per-config --

MACOS_SDK := $(shell xcrun --show-sdk-path)
# The swift.org toolchain does not resolve the macOS SDK on its own outside
# Xcode, so the sysroot is passed explicitly.
sim_SWIFT := $(SWIFT_BASE) -enable-experimental-feature Embedded \
	-target $(shell uname -m)-apple-macos15.0 -sdk $(MACOS_SDK)
sim_DEFS := -DTARGET_SIMULATOR=1 -DTARGET_EXTENSION=1
sim_CC := clang -g

# Ordinary (non-Embedded) Swift for the host, used by the headless cart runner.
# Embedded Swift has no command-line entry point worth the trouble here, and the
# point of this configuration is to exercise the console logic, not the dialect.
host_SWIFT := $(SWIFT_BASE) -target $(shell uname -m)-apple-macos15.0 -sdk $(MACOS_SDK)
host_DEFS :=
host_CC := clang -g

# -experimental-platform-c-calling-convention=arm_aapcs_vfp is what makes
# Swift's calls into the C API hard-float, matching the firmware. Without it
# every by-value float argument is passed in the wrong registers, and the SDK's
# --no-warn-mismatch means it links anyway and is silently wrong.
dev_SWIFT := $(SWIFT_BASE) \
	-target armv7em-none-none-eabi \
	-enable-experimental-feature Embedded \
	-Xfrontend -experimental-platform-c-calling-convention=arm_aapcs_vfp \
	-Xfrontend -disable-stack-protector \
	-Xcc -mthumb -Xcc -mcpu=cortex-m7 \
	-Xcc -mfloat-abi=hard -Xcc -mfpu=fpv5-sp-d16 \
	-Xcc -D__FPU_USED=1 -Xcc -falign-functions=16 -Xcc -fshort-enums \
	-Xcc -DWASMKIT_TC_USE=musttail \
	$(patsubst %,-Xcc %,$(ARM_INCLUDES))
dev_DEFS := -DTARGET_PLAYDATE=1 -DTARGET_EXTENSION=1
dev_MCFLAGS := -mthumb -mcpu=cortex-m7 -mfloat-abi=hard -mfpu=fpv5-sp-d16 -D__FPU_USED=1
dev_CC := $(ARM_GCC)gcc -g3 $(dev_MCFLAGS) -Os -falign-functions=16 -fomit-frame-pointer \
	-fshort-enums -mword-relocations -fno-common -ffunction-sections -fdata-sections

# $(1) = config name (sim|dev)
define CONFIG_RULES

$(BUILD)/$(1):
	@mkdir -p $$@

# One rule per WasmKit module. -package-name is required: the modules use
# package-level access across the package boundary.
$$(foreach m,$$(WASMKIT_MODULES),$$(eval $$(call MODULE_RULE,$(1),$$(m),$$(WASMKIT)/Sources/$$(m),-package-name wasmkit,$$(WASMKIT_OPT))))
$$(foreach m,$$(APP_MODULES),$$(eval $$(call MODULE_RULE,$(1),$$(m),Sources/$$(m),,$$(OPT))))

$(BUILD)/$(1)/_CWasmKit.o: $$(WASMKIT)/Sources/_CWasmKit/_CWasmKit.c | $(BUILD)/$(1)
	$$($(1)_CC) -c -I$$(CWASMKIT_INC) $$< -o $$@

$(BUILD)/$(1)/TrapGuard.o: $$(WASMKIT)/Sources/_CWasmKit/TrapGuard.c | $(BUILD)/$(1)
	$$($(1)_CC) -c -I$$(CWASMKIT_INC) $$< -o $$@

$(BUILD)/$(1)/playdate.o: Sources/CPlaydate/playdate.c | $(BUILD)/$(1)
	$$($(1)_CC) -c -ISources/CPlaydate/include -I$$(SDK)/C_API $$($(1)_DEFS) $$< -o $$@

$(BUILD)/$(1)/w4.o: $$(SWIFT_SOURCES) $$(WASMKIT_OBJS_$(1)) | $(BUILD)/$(1)
	$$(SWIFTC) $$($(1)_SWIFT) $$(OPT) -swift-version 6 \
		-I Sources/CPlaydate/include -I $(BUILD)/$(1) \
		-Xcc -I$$(SDK)/C_API -Xcc -I$$(CWASMKIT_INC) \
		$$(addprefix -Xcc ,$$($(1)_DEFS)) \
		-c $$(SWIFT_SOURCES) -o $$@

endef

# $(1) = config, $(2) = module name, $(3) = source dir, $(4) = extra flags,
# $(5) = optimisation level
define MODULE_RULE
$(BUILD)/$(1)/$(2).o: $$(shell find $(3) -name '*.swift') | $(BUILD)/$(1)
	$$(SWIFTC) $$($(1)_SWIFT) $(5) $(4) -I $(BUILD)/$(1) \
		-Xcc -I$$(CWASMKIT_INC) \
		$$(shell find $(3) -name '*.swift') \
		-module-name $(2) \
		-emit-module -emit-module-path $(BUILD)/$(1)/$(2).swiftmodule \
		-c -o $$@
endef

WASMKIT_OBJS_sim := $(addprefix $(BUILD)/sim/,$(addsuffix .o,$(WASMKIT_MODULES) $(APP_MODULES)))
WASMKIT_OBJS_host := $(addprefix $(BUILD)/host/,$(addsuffix .o,$(WASMKIT_MODULES) $(APP_MODULES)))
WASMKIT_OBJS_dev := $(addprefix $(BUILD)/dev/,$(addsuffix .o,$(WASMKIT_MODULES) $(APP_MODULES)))

$(eval $(call CONFIG_RULES,sim))
$(eval $(call CONFIG_RULES,dev))
$(eval $(call CONFIG_RULES,host))

# Intra-package module ordering.
$(BUILD)/sim/WasmParser.o: $(BUILD)/sim/WasmTypes.o
$(BUILD)/sim/WasmKit.o: $(BUILD)/sim/WasmParser.o
$(BUILD)/sim/WASM4.o: $(BUILD)/sim/WasmKit.o
$(BUILD)/dev/WasmParser.o: $(BUILD)/dev/WasmTypes.o
$(BUILD)/dev/WasmKit.o: $(BUILD)/dev/WasmParser.o
$(BUILD)/dev/WASM4.o: $(BUILD)/dev/WasmKit.o
$(BUILD)/host/WasmParser.o: $(BUILD)/host/WasmTypes.o
$(BUILD)/host/WasmKit.o: $(BUILD)/host/WasmParser.o
$(BUILD)/host/WASM4.o: $(BUILD)/host/WasmKit.o

# ----------------------------------------------------------------- products --

SIM_OBJS := $(BUILD)/sim/w4.o $(BUILD)/sim/playdate.o $(BUILD)/sim/_CWasmKit.o \
            $(BUILD)/sim/TrapGuard.o $(WASMKIT_OBJS_sim)
DEV_OBJS := $(BUILD)/dev/w4.o $(BUILD)/dev/playdate.o $(BUILD)/dev/_CWasmKit.o \
            $(BUILD)/dev/TrapGuard.o $(BUILD)/dev/setup.o $(BUILD)/dev/atomics.o \
            $(WASMKIT_OBJS_dev)

.PHONY: assets
assets:
	@tools/fetch-assets.sh

.PHONY: simulator device run clean device-check

$(BUILD)/dev/setup.o: $(SDK)/C_API/buildsupport/setup.c | $(BUILD)/dev
	$(dev_CC) -c -I$(SDK)/C_API $(dev_DEFS) $< -o $@

# ARMv7-M has no 64-bit atomic instructions and this toolchain ships no
# libatomic, so WasmKit's i64 atomic handlers would fail to link.
$(BUILD)/dev/atomics.o: Sources/CPlaydate/atomics64.c | $(BUILD)/dev
	$(dev_CC) -c $(dev_DEFS) $< -o $@

$(BUILD)/sim/pdex.dylib: $(SIM_OBJS)
	clang -dynamiclib -rdynamic -lm $^ \
		$(SIM_EMBEDDED_LIBS)/libswiftUnicodeDataTables.a -o $@

$(BUILD)/dev/pdex.elf: $(DEV_OBJS)
	$(ARM_GCC)gcc $^ -nostartfiles $(dev_MCFLAGS) \
		-T buildsupport/link_map.ld \
		-Wl,-Map=$(BUILD)/dev/pdex.map,--cref,--gc-sections,--no-warn-mismatch,--emit-relocs \
		-Wl,--wrap=free \
		$(EMBEDDED_LIBS)/libswiftUnicodeDataTables.a \
		-o $@

simulator: assets $(BUILD)/sim/pdex.dylib
	cp $(BUILD)/sim/pdex.dylib Source/pdex.dylib
	$(PDC) Source $(PRODUCT)

device: assets $(BUILD)/dev/pdex.elf
	cp $(BUILD)/dev/pdex.elf Source/pdex.elf
	$(PDC) Source $(PRODUCT)

# Compile-only check of the device build. Fast, needs no hardware, and is the
# only build that exercises the bare-metal target -- run it on every change.
device-check: $(BUILD)/dev/w4.o
	@echo "OK: device (armv7em Embedded Swift) compiles"

run: simulator
	open -a "$(SDK)/bin/Playdate Simulator.app" $(PRODUCT)

clean:
	rm -rf $(BUILD) Source/pdex.dylib Source/pdex.elf Source/pdex.bin

# ------------------------------------------------------------- cart runner --
#
# Runs every cart headlessly for a fixed number of frames. It exercises the
# interpreter, the host functions and the real carts together, and it needs no
# Playdate and no display.

TEST := $(BUILD)/test

$(TEST):
	@mkdir -p $@

$(TEST)/cartrun: tools/cartrun/main.swift $(WASMKIT_OBJS_host) \
                 $(BUILD)/host/_CWasmKit.o $(BUILD)/host/TrapGuard.o | $(TEST)
	$(SWIFTC) $(filter-out -parse-as-library,$(host_SWIFT)) -swift-version 6 -I $(BUILD)/host \
		-Xcc -I$(CWASMKIT_INC) \
		tools/cartrun/main.swift $(WASMKIT_OBJS_host) \
		$(BUILD)/host/_CWasmKit.o $(BUILD)/host/TrapGuard.o -o $@

.PHONY: smoke
smoke: assets $(TEST)/cartrun
	@$(TEST)/cartrun Source/carts

# ----------------------------------------------------------------- device --
#
# Everything that needs the hardware, one command each: copy the bundle over,
# find the serial port, read the log back.

PLAYDATE_PORT = $(firstword $(wildcard /dev/cu.usbmodem*))

.PHONY: device-port
device-port:
	@test -n "$(PLAYDATE_PORT)" \
		|| { echo "No Playdate found. Attach it, unlock it, and try again."; exit 1; }
	@echo "$(PLAYDATE_PORT)"

# Reads the game console over USB serial, which is where the application's
# messages go on hardware.
.PHONY: device-log
device-log: device-port
	@echo "Reading $(PLAYDATE_PORT). Ctrl-C to stop."
	@cat $(PLAYDATE_PORT)

# Copies the built bundle onto the device through its data partition. macOS
# asks for permission to access removable volumes the first time; if it is
# refused, open build/wasm4.pdx in the Simulator and use Device > Upload Game
# To Device instead.
.PHONY: install
install: device device-port
	$(SDK)/bin/pdutil $(PLAYDATE_PORT) datadisk
	@echo "Waiting for the data disk to mount..."
	@n=0; until [ -d /Volumes/PLAYDATE/Games ] || [ $$n -ge 30 ]; do sleep 1; n=$$((n+1)); done
	@test -d /Volumes/PLAYDATE/Games || { echo "Data disk did not mount."; exit 1; }
	rm -rf /Volumes/PLAYDATE/Games/wasm4.pdx
	cp -R $(PRODUCT) /Volumes/PLAYDATE/Games/
	diskutil eject /Volumes/PLAYDATE
	@echo "Installed. Launch WASM-4 on the device, then run 'make device-log'."

# Runs the continuous integration sequence locally, into a scratch directory,
# without touching the installed SDK. It checks every step of the workflow
# except the toolchain install, which only a runner does.
.PHONY: ci-local
ci-local:
	@set -eux; \
	work=$$(mktemp -d); \
	curl -fsSL -o $$work/PlaydateSDK.zip \
		https://download.panic.com/playdate_sdk/PlaydateSDK-3.1.2.zip; \
	unzip -q $$work/PlaydateSDK.zip -d $$work/dist; \
	pkgutil --expand-full $$work/dist/PlaydateSDK.pkg $$work/expanded >/dev/null; \
	mv $$work/expanded/PlaydateSDK.pkg/Payload/PlaydateSDK $$work/Playdate; \
	test -x $$work/Playdate/bin/pdc; \
	$(MAKE) smoke; \
	$(MAKE) clean; \
	$(MAKE) device SDK=$$work/Playdate; \
	rm -rf $$work; \
	echo "ci-local: the workflow's steps succeed against a freshly installed SDK"
