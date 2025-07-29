ARCHS = arm64
TARGET := iphone:clang:16.5:16.5

INSTALL_TARGET_PROCESSES = mediaserverd
THEOS_PACKAGE_SCHEME=rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = vcam

vcam_FILES = Tweak.xm
vcam_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
