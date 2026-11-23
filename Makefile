ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SoloPlus
SoloPlus_FILES = SoloPlus.xm
SoloPlus_FRAMEWORKS = UIKit Foundation CoreFoundation CoreGraphics QuartzCore
SoloPlus_LDFLAGS = -lsubstrate -Wl,-rpath,/var/jb/Library/Frameworks -Wl,-rpath,/var/jb/usr/lib
SoloPlus_CFLAGS = -fobjc-arc -Wall -Wno-unused-function -Wno-unused-variable -Wno-deprecated-declarations -Wno-arc-performSelector-leaks
SoloPlus_OBJCCFLAGS = -fno-modules

include $(THEOS_MAKE_PATH)/tweak.mk
