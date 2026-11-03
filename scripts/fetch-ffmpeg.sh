#!/usr/bin/env bash
# 抓取社区预编译的 iOS 版 FFmpeg 静态库，整理成 Makefile 需要的 build/ffmpeg/{include,lib}
#
# 为什么用预编译产物，而不是在流水线里自己交叉编译 FFmpeg：
#   Linux 上自编译 FFmpeg for iOS 还要连带 x264/x265/libvpx 等外部库与 nasm/yasm，
#   一次失败要重跑很久；而且启用 GPL 库会把整个 App 变成 GPL 义务。
#   kewlbear/FFmpeg-iOS 提供 LGPL 构建的 XCFramework 静态库，解包即可链接。
#
# 只取真机切片（ios-arm64）：模拟器切片对巨魔安装没有意义。
set -euo pipefail

FFMPEG_RELEASE="v0.0.6-b20230416-173821"
BASE_URL="https://github.com/kewlbear/FFmpeg-iOS/releases/download/${FFMPEG_RELEASE}"
LIBS=(avcodec avformat avfilter avutil swscale swresample)
OPTIONAL_LIBS=(avdevice)   # 预编译包不一定提供，且本工程未用到

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/build/ffmpeg"
TMP="${ROOT}/build/_ffmpeg_dl"

rm -rf "${OUT}" "${TMP}"
mkdir -p "${OUT}/include" "${OUT}/lib" "${TMP}"

for lib in "${LIBS[@]}"; do
  echo "==> 下载 ${lib}"
  curl -fL --retry 3 -o "${TMP}/${lib}.zip" "${BASE_URL}/${lib}.zip"
  unzip -q -o "${TMP}/${lib}.zip" -d "${TMP}/${lib}"

  # 结构：lib<name>.xcframework/ios-arm64/lib<name>.a 与 .../Headers
  slice="$(find "${TMP}/${lib}" -type d -name 'ios-arm64*' | grep -v -i simulator | head -n1 || true)"
  if [ -z "${slice}" ]; then
    echo "!! 未找到 ${lib} 的 ios-arm64 切片，解压结果：" >&2
    find "${TMP}/${lib}" -maxdepth 3 | head -n 40 >&2
    exit 1
  fi

  archive="$(find "${slice}" -maxdepth 3 -name "lib${lib}.a" | head -n1 || true)"
  if [ -z "${archive}" ]; then
    archive="$(find "${slice}" -maxdepth 3 -name "${lib}.a" | head -n1 || true)"
    [ -n "${archive}" ] && cp "${archive}" "${OUT}/lib/lib${lib}.a"
  else
    cp "${archive}" "${OUT}/lib/"
  fi

  headers="$(find "${slice}" -maxdepth 3 -type d -name Headers | head -n1 || true)"
  if [ -n "${headers}" ]; then
    # FFmpeg 内部一律写 #include <libavcodec/avcodec.h>，
    # 所以头文件目录必须命名为 lib<name>，不能是 <name>。
    mkdir -p "${OUT}/include/lib${lib}"
    if find "${headers}" -maxdepth 1 -name '*.h' | grep -q .; then
      cp "${headers}"/*.h "${OUT}/include/lib${lib}/"
    else
      cp -R "${headers}/." "${OUT}/include/lib${lib}/"
    fi
  else
    echo "!! ${lib} 切片里没有 Headers 目录" >&2
    exit 1
  fi
done

echo "==> lib/"
ls -1 "${OUT}/lib"
echo "==> include/"
ls -1 "${OUT}/include"

# ---- 自检：把问题挡在编译之前 --------------------------------------------
got="$(find "${OUT}/lib" -name '*.a' | wc -l)"
if [ "${got}" -lt "${#LIBS[@]}" ]; then
  echo "!! 静态库数量不足：得到 ${got}，期望 ${#LIBS[@]}" >&2
  exit 1
fi
if [ ! -f "${OUT}/include/libavformat/avformat.h" ]; then
  echo "!! 缺少 include/libavformat/avformat.h，头文件结构与预期不符，请人工检查 ${OUT}/include" >&2
  exit 1
fi
if ! grep -q "avformat_open_input" "${OUT}/include/libavformat/avformat.h"; then
  echo "!! avformat.h 里没有 avformat_open_input，产物可能损坏" >&2
  exit 1
fi

echo "==> FFmpeg 就绪：${OUT}"
