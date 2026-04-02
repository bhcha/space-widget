PREFIX ?= /usr/local
APP_NAME = SpaceWidget
BUILD_DIR = .build/release

.PHONY: build install uninstall migrate clean

build:
	swift build -c release

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
