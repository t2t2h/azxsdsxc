TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = AudioClear

AudioClear_FILES = Tweak.m
AudioClear_FRAMEWORKS = UIKit AVFoundation AudioToolbox Foundation
AudioClear_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
AudioClear_LDFLAGS = -Wl,-install_name,@rpath/AudioClear.dylib

include $(THEOS_MAKE_PATH)/library.mk
