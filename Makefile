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

# 链接顺序：被依赖的库在后（avutil 最末）
# 若链接报 bzip2 相关未定义符号，说明所选 FFmpeg 构建启用了 --enable-bz2，
# 届时补上 -lbz2 并安装提供 libbz2 的 SDK 依赖即可。
FormatMaster_LDFLAGS = \
	-L$(FFMPEG_DIR)/lib \
	-lavformat -lavfilter -lavcodec -lswscale -lswresample -lavutil \
	-lz -lm

FormatMaster_FRAMEWORKS = \
	UIKit Foundation AVFoundation CoreMedia CoreVideo VideoToolbox \
	Photos PhotosUI QuickLook UniformTypeIdentifiers MobileCoreServices \
	Security ImageIO CoreGraphics

# 巨魔（TrollStore）自己完成签名，这里不需要 Theos 调用 codesign/ldid
FORMATMASTER_SIGNATURE =

include $(THEOS_MAKE_PATH)/application.mk
