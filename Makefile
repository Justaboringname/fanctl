CFLAGS = -O2 -Wall -Wextra
APP = build/StatMenu.app
FRAMEWORKS = -framework IOKit -framework CoreFoundation -framework SystemConfiguration -lIOReport
SWIFT_SRC = app/main.swift app/Sampler.swift app/Views.swift app/StatusImage.swift app/FanDaemon.swift

fanctl: fanctl.c smc.c smc.h metrics.c metrics.h power_rate.h
	clang $(CFLAGS) fanctl.c smc.c metrics.c $(FRAMEWORKS) -o $@

app: $(APP)

$(APP): $(SWIFT_SRC) app/Bridging.h app/Info.plist metrics.c metrics.h power_rate.h smc.c smc.h
	mkdir -p build $(APP)/Contents/MacOS
	clang $(CFLAGS) -c smc.c -o build/smc.o
	clang $(CFLAGS) -c metrics.c -o build/metrics.o
	swiftc -O -import-objc-header app/Bridging.h $(SWIFT_SRC) build/smc.o build/metrics.o \
		$(FRAMEWORKS) -o $(APP)/Contents/MacOS/StatMenu
	cp app/Info.plist $(APP)/Contents/Info.plist
	# The app's "copy install command" button points at this checkout, wherever it was cloned.
	plutil -insert FanctlSourceDir -string "$(CURDIR)" $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)
	touch $(APP)

# Prints every metric once per interval, for cross-checking against macmon / vm_stat / netstat.
metricsdump: tools/metricsdump.c metrics.c metrics.h power_rate.h smc.c smc.h
	mkdir -p build
	clang $(CFLAGS) tools/metricsdump.c metrics.c smc.c $(FRAMEWORKS) -o build/metricsdump

# Diagnostics: energyprobe (when the IOReport energy counters advance), triggerscan (which IOReport
# group, if any, refreshes them), smcsample (SMC float keys as CSV).
tools: tools/energyprobe.c tools/triggerscan.c tools/smcsample.c metrics.c metrics.h power_rate.h smc.c smc.h
	mkdir -p build
	clang $(CFLAGS) -Wno-unused-function tools/energyprobe.c smc.c $(FRAMEWORKS) -o build/energyprobe
	clang $(CFLAGS) -Wno-unused-function tools/triggerscan.c smc.c $(FRAMEWORKS) -o build/triggerscan
	clang $(CFLAGS) tools/smcsample.c smc.c -framework IOKit -o build/smcsample

# Renders every popover offscreen (light + dark) to build/render/*.png for layout checks.
render: $(filter-out app/main.swift,$(SWIFT_SRC)) tools/render/main.swift app/Bridging.h metrics.c metrics.h power_rate.h smc.c smc.h
	mkdir -p build
	clang $(CFLAGS) -c smc.c -o build/smc.o
	clang $(CFLAGS) -c metrics.c -o build/metrics.o
	swiftc -O -import-objc-header app/Bridging.h $(filter-out app/main.swift,$(SWIFT_SRC)) tools/render/main.swift \
		build/smc.o build/metrics.o $(FRAMEWORKS) -o build/render-popovers
	./build/render-popovers build/render

# Installs the fan daemon + app; see install.sh.
install:
	sudo ./install.sh

clean:
	rm -rf fanctl build

test: test-power test-fanctl

# Daemon/guard logic against an in-memory fake SMC (no root, no hardware writes).
test-fanctl: tests/fanctl_test.c tests/fake_smc.c fanctl.c metrics.c metrics.h power_rate.h smc.h
	mkdir -p build
	clang $(CFLAGS) -Wno-unused-function tests/fanctl_test.c tests/fake_smc.c metrics.c $(FRAMEWORKS) -o build/fanctl_test
	./build/fanctl_test

test-power:
	mkdir -p build
	clang $(CFLAGS) -Werror tests/power_rate_test.c -o build/power_rate_test
	./build/power_rate_test

.PHONY: app tools metricsdump render install clean test test-fanctl test-power
