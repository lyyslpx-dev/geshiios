# ARCHS/TARGET 必须在 include common.mk 之前
ARCHS = arm64
TARGET = iphone:clang:latest:14.0
DEBUG = 0

# ---------------------------------------------------------------------------
# FFmpeg（LGPL 构建，社区预编译 iOS 静态库）
#   先执行 bash scripts/fetch-ffmpeg.sh，产物落在 build/ffmpeg/{include,lib}
# ---------------------------------------------------------------------------
FFMPEG_DIR ?= $(CURDIR)/build/ffmpeg

ifeq ($(wildcard $(FFMPEG_DIR)/include/libavformat/avformat.h),)
$(error 未找到 $(FFMPEG_DIR) 下的 FFmpeg 头文件 —— 请先执行 bash scripts/fetch-ffmpeg.sh)
endif

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = FormatMaster

FormatMaster_FILES = \
	src/main.m \
	src/AppDelegate.m \
	src/RootViewController.m \
	src/ConvertViewController.m \
	src/EditViewController.m \
	src/MergeViewController.m \
	src/InfoViewController.m \
	src/FMInputPicker.m \
	src/FFEngine.m \
	src/FFPresets.m

FormatMaster_CFLAGS = \
	-fobjc-arc \
	-std=gnu11 \
	-Wno-deprecated-declarations \
	-I$(CURDIR)/src \
	-I$(FFMPEG_DIR)/include

# 链接顺序：被依赖的库在后（avutil 最末，其后才是系统库）
# FFmpeg 静态库常见的外部依赖：zlib/bzlib/iconv/libxml2，以及 VideoToolbox
# 相关代码需要的 libc++。这些都是 iOS SDK 自带的 tbd，缺一个就会在链接期
# 报 "Undefined symbols for architecture arm64"。
FormatMaster_LDFLAGS = \
	-L$(FFMPEG_DIR)/lib \
	-lavformat -lavfilter -lavcodec -lswscale -lswresample -lavutil \
	-lz -lbz2 -liconv -lxml2 -lc++ -lm

FormatMaster_FRAMEWORKS = \
	UIKit Foundation CoreFoundation AVFoundation CoreMedia CoreVideo VideoToolbox \
	AudioToolbox Photos PhotosUI QuickLook UniformTypeIdentifiers MobileCoreServices \
	Security ImageIO CoreGraphics

# 巨魔（TrollStore）安装时会自行重签；Theos 默认的 ldid ad-hoc 签名由
# L1ghtmann 工具链提供（toolchain/linux/iphone/bin/ldid），保持默认即可。

include $(THEOS_MAKE_PATH)/application.mk
