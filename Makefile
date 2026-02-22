ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:13.0
SDKVERSION = 16.5

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = EverLight

EverLight_FILES = Tweak.mm
EverLight_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable
EverLight_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
EverLight_LIBRARIES = substrate

# Uncomment if targeting rootless jailbreaks (Dopamine / Palera1n / etc.)
# THEOS_PACKAGE_SCHEME = rootless
# EverLight_CFLAGS += -DTHEOS_PACKAGE_SCHEME=rootless

include $(THEOS_MAKE_PATH)/tweak.mk
