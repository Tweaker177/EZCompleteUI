export TARGET := iphone:clang:latest:15.0
export ARCHS = arm64 arm64e
export FINALPACKAGE = 1
export THEOS_PACKAGE_SCHEME = rootless
export GO_EASY_ON_ME = 1

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = EZCompleteUI

EZCompleteUI_FILES = main.m AppDelegate.m ViewController.m helpers.m ViewController+EZTopButtons.m SidewaysScrollView.m  ChatHistoryViewController.m SettingsViewController.m MemoriesViewController.m EZKeyVault.m SupportRequestViewController.m TextToSpeechViewController.m ElevenLabsCloneViewController.m iCarousel.m ViewController+EZKeepAwake.m

EZCompleteUI_FRAMEWORKS = UIKit Foundation AVFoundation Speech QuickLook \
UniformTypeIdentifiers PDFKit QuickLookThumbnailing Security PhotosUI

EZCompleteUI_CFLAGS = -fobjc-arc -Wno-deprecated -Wno-deprecated-declarations -Wno-error
EZCompleteUI_CODESIGN_FLAGS = -Sent.plist
EZCompleteUI_INFOPLIST_FILE = Info.plist
EZCompleteUI_USER  = mobile
EZCompleteUI_GROUP = mobile
EZCompleteUI_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

