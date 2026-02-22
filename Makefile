ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:13.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = EverLight

EverLight_FILES = Tweak.mm
EverLight_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable
EverLight_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
EverLight_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
