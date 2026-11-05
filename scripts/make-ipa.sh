#!/usr/bin/env bash
# 把 Theos 的编译产物组装成可直接被 TrollStore（巨魔）安装的 .ipa
#
# .ipa 的本质就是 zip：Payload/<AppName>.app/...
# 巨魔利用系统 CoreTrust 漏洞安装，不需要签名，所以这里不做 ldid/codesign。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

APP_NAME="FormatMaster"
VERSION="${BUILD_VERSION:-1.0.0}"
OUT_DIR="${ROOT}/build"
WORK="${OUT_DIR}/ipa"

mkdir -p "${OUT_DIR}"

# ---- 1. 找到 Theos 产出的 .app 或裸二进制 -----------------------------------
# 不同 Theos 版本产物目录不同：.theos/obj/、obj/、.theos/_/ 都出现过，
# 所以直接在工程根下递归搜，排除 build/ 里上一次打包留下的 Payload。
APP_BUNDLE="$(find "${ROOT}" -type d -name "${APP_NAME}.app" \
              -not -path "${OUT_DIR}/*" 2>/dev/null | head -n1 || true)"

# 优先找带 Mach-O 魔数的可执行文件（Theos 在 Linux 上可能命名带前缀下划线）
find_macho() {
  local dir="$1" f
  [ -d "${dir}" ] || return 1
  while IFS= read -r f; do
    # Mach-O 小端 64 位魔数 0xfeedfacf
    if command -v xxd >/dev/null 2>&1; then
      if xxd -l 4 -p "$f" 2>/dev/null | grep -qi 'cffaedfe'; then echo "$f"; return 0; fi
    else
      if od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n' | grep -qi 'cffaedfe'; then echo "$f"; return 0; fi
    fi
  done < <(find "${dir}" -type f \( -name "${APP_NAME}" -o -name "_${APP_NAME}" \) 2>/dev/null)
  return 1
}

BIN=""
if [ -n "${APP_BUNDLE}" ]; then
  echo "==> 使用 Theos 产物：${APP_BUNDLE}"
  BIN="$(find_macho "${APP_BUNDLE}" || true)"
  # .app 里主程序名可能就是 CFBundleExecutable，魔数匹配失败时退而求其次
  if [ -z "${BIN}" ] && [ -f "${APP_BUNDLE}/${APP_NAME}" ]; then
    BIN="${APP_BUNDLE}/${APP_NAME}"
  fi
fi
if [ -z "${BIN}" ]; then
  # 回退：从各候选 obj 目录里找编译出来的主程序，手工拼 bundle
  for d in "${ROOT}/.theos/obj" "${ROOT}/.theos" "${ROOT}/obj" "${ROOT}/build"; do
    BIN="$(find_macho "${d}" || true)"
    [ -n "${BIN}" ] && break
  done
fi
if [ -z "${BIN}" ]; then
  echo "!! 没找到 ${APP_NAME} 的 Mach-O 产物。请先执行 make，并检查产物目录：" >&2
  find "${ROOT}" -maxdepth 4 2>/dev/null | head -n 60 >&2 || true
  exit 1
fi
echo "==> 主程序：${BIN}"

# ---- 2. 组装 Payload --------------------------------------------------------
rm -rf "${WORK}"
mkdir -p "${WORK}/Payload/${APP_NAME}.app"
STAGED="${WORK}/Payload/${APP_NAME}.app"

cp "${BIN}" "${STAGED}/${APP_NAME}"
chmod +x "${STAGED}/${APP_NAME}"

# Info.plist 一律以工程根目录那份为准，避免 Theos 复制的副本不一致
if [ ! -f "${ROOT}/${APP_NAME}-Info.plist" ]; then
  echo "!! 缺少 ${APP_NAME}-Info.plist" >&2
  exit 1
fi
cp "${ROOT}/${APP_NAME}-Info.plist" "${STAGED}/Info.plist"

# 可选资源：图标、根目录 Resources/ 下的内容（排除多余的 Info.plist 副本）
if [ -d "${ROOT}/Resources" ]; then
  cp -R "${ROOT}/Resources/." "${STAGED}/" 2>/dev/null || true
  rm -f "${STAGED}/Info.plist"
  cp "${ROOT}/${APP_NAME}-Info.plist" "${STAGED}/Info.plist"
fi

# ---- 3. 校验 bundle 完整性 --------------------------------------------------
for need in "${APP_NAME}" "Info.plist"; do
  if [ ! -e "${STAGED}/${need}" ]; then
    echo "!! bundle 缺少 ${need}" >&2
    exit 1
  fi
done
# plutil 只在 macOS 有；Linux 上交给巨魔安装时自行校验

# ---- 4. 压成 ipa ------------------------------------------------------------
IPA="${OUT_DIR}/${APP_NAME}-iOS14-${VERSION}.ipa"
rm -f "${IPA}"
( cd "${WORK}" && zip -qry9 "${IPA}" "Payload" )

echo "==> 产出：${IPA}"
ls -lh "${IPA}"
echo
echo "把该文件传到 iPhone，用 TrollStore（巨魔）打开即可安装。"
