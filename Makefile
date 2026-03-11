TARGET := iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = EZCompleteUI
FINALPACKAGE= 1

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = EZCompleteUI

EZCompleteUI_FILES = main.m AppDelegate.m ViewController.m
EZCompleteUI_FRAMEWORKS = UIKit Foundation CoreGraphics AVFoundation QuickLook
EZCompleteUI_CFLAGS = -fobjc-arc
EZCompleteUI_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

