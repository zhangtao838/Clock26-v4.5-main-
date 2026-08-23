TARGET := iphone:clang:latest:15.0
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = McClock26Prefs

McClock26Prefs_FILES = C26RootListController.m C26SliderCell.m
McClock26Prefs_CFLAGS = -fobjc-arc
McClock26Prefs_INSTALL_PATH = /Library/PreferenceBundles
McClock26Prefs_FRAMEWORKS = UIKit
McClock26Prefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/bundle.mk
