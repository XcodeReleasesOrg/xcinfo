prefix=/usr/local
exec_prefix=$(prefix)
bindir=$(prefix)/bin

export prefix
export exec_prefix
export bindir

SWIFT_BUILD_FLAGS=-c release --arch arm64 --arch x86_64
CODESIGN_IDENTITY ?= -

all:
	swift build $(SWIFT_BUILD_FLAGS)
	codesign --force --sign "$(CODESIGN_IDENTITY)" --identifier com.xcodereleases.xcinfo "$$(swift build $(SWIFT_BUILD_FLAGS) --show-bin-path)/xcinfo"

.PHONY: all install clean cleanup

install:
	install -d $(bindir)
	install -m 0755 "$$(swift build $(SWIFT_BUILD_FLAGS) --show-bin-path)/xcinfo" $(bindir)

clean:
	swift package clean

cleanup: clean
	rm -rf .build
