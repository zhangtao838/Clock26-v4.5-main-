TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = McClock26

McClock26_FILES = Tweak.xm LiquidGlassView.m
McClock26_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
McClock26_FRAMEWORKS = UIKit CoreGraphics QuartzCore CoreText Metal MetalKit MetalPerformanceShaders

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
