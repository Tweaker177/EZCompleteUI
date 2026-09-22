export TARGET := iphone:clang:latest:15.0
export ARCHS = arm64 arm64e
export FINALPACKAGE = 1
export DEBUG = 0
export THEOS_PACKAGE_SCHEME = rootless
export GO_EASY_ON_ME = 1

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = EZCompleteUI

EZCompleteUI_FILES = main.m AppDelegate.m helpers.m ViewController+EZTopButtons.m ViewController+EZKeepAwake.m ViewController.m EZFirstRunTutorialViewController.m EZModelPickerViewController.m EZImageSettingsViewController.m EZAttachMenuViewController.m ChatHistoryViewController.m SettingsViewController.m MemoriesViewController.m EZKeyVault.m SupportRequestViewController.m TextToSpeechViewController.m ElevenLabsCloneViewController.m iCarousel.m ViewController+EZTitleResolver.m UIViewController+EZViewDidLayoutSwizzle.m WaveformView.m EZAuthManager.m EZEntitlementManager.m LoginViewController.m HelperLogViewController.m SystemLogViewController.m EZBubbleCell.m EZSystemCell.m EZCodeBlockCell.m EZCoinStoreViewController.m EZCoinPotView.m EZPhotoGalleryViewController.m EZImageGridCell.m EZCoinUsageViewController.m BRGameModel.m BrainRotViewController.m BRGameView.m BRGameModePickerViewController.m BRRicochetGameModel.m BRRicochetGameView.m BRRicochetViewController.m BRRicochetHighScoresViewController.m BRSynthEngine.m EZTermsAcceptanceViewController.m EZPoliciesViewController.m BRGameLibrary.m BRGamePickerViewController.m BRCustomGameCreatorViewController.m BRAssetSourceSheetViewController.m BRTextInputSheetViewController.m BRGameResultViewController.m BRAssetGenerationSheetViewController.m BRRemoteImageLoader.m EZTTSLibraryManager.m EZTTSManifestEntry.m EZTTSLibraryViewController.m EZTTSLibraryClipCell.m EZTTSClipEditViewController.m EZTTSVoiceService.m EZVoicePickerViewController.m EZWaveformRangeSelector.m BRCommunityAdminViewController.m EZSupabaseConfig.m EZCoinLedgerViewController.m

EZCompleteUI_FRAMEWORKS = UIKit Foundation AVFoundation CoreMIDI Speech QuickLook \
UniformTypeIdentifiers PDFKit QuickLookThumbnailing Security PhotosUI QuartzCore SafariServices ImageIO UserNotifications

EZCompleteUI_CFLAGS = -fobjc-arc -Wno-deprecated -Wno-deprecated-declarations -Wno-error \
    -fmodules-cache-path=$(shell pwd)/.theos/module-cache
EZCompleteUI_CODESIGN_FLAGS = -Sent.plist
EZCompleteUI_INFOPLIST_FILE = Resources/Info.plist
EZCompleteUI_RESOURCE_DIRS = Resources
EZCompleteUI_USER  = mobile
EZCompleteUI_GROUP = mobile
EZCompleteUI_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
