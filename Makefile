export TARGET := iphone:clang:latest:15.0
export ARCHS = arm64 arm64e
export FINALPACKAGE = 1
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = EZCompleteUI

EZCompleteUI_FILES = main.m AppDelegate.m ViewController.m helpers.m \
                     ChatHistoryViewController.m SettingsViewController.m MemoriesViewController.m 

EZCompleteUI_FRAMEWORKS = UIKit Foundation AVFoundation Speech QuickLook \
                          UniformTypeIdentifiers PDFKit

EZCompleteUI_CFLAGS = -fobjc-arc
EZCompleteUI_CODESIGN_FLAGS = -Sent.plist
EZCompleteUI_INFOPLIST_FILE = Info.plist
EZCompleteUI_USER  = mobile
EZCompleteUI_GROUP = mobile
EZCompleteUI_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

