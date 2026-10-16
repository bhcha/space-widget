PREFIX ?= /usr/local
APP_NAME = SpaceWidget
BUILD_DIR = .build/release
XCODE_DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

.PHONY: build test verify-build verify-test install uninstall migrate clean

build:
	swift build -c release

test:
	swift test

# Use the installed full Xcode per command without changing global xcode-select.
verify-build:
	env DEVELOPER_DIR="$(XCODE_DEVELOPER_DIR)" swift build -c release

verify-test:
	env DEVELOPER_DIR="$(XCODE_DEVELOPER_DIR)" swift test

install: build
	install -d $(PREFIX)/bin
	install $(BUILD_DIR)/$(APP_NAME) $(PREFIX)/bin/$(APP_NAME)
	codesign --force --sign - $(PREFIX)/bin/$(APP_NAME)

uninstall:
	rm -f $(PREFIX)/bin/$(APP_NAME)

migrate:
	$(BUILD_DIR)/$(APP_NAME) --migrate

clean:
	swift package clean
	rm -rf .build
