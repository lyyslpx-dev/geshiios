# 格式大师 iOS 版（FormatMaster iOS）

一个面向 **iOS 14 + TrollStore（巨魔）** 的本地媒体工具箱，功能对齐桌面版 FormatMaster 的核心能力：

- **全格式转换**：视频 / 音频 / 图片互转（MP4、MKV、AVI、MOV、WebM、GIF、MP3、AAC、FLAC、WAV、OGG、M4A、WMA、RM、WMV、TS、3GP、BMP、PNG、JPG……由 FFmpeg 解码器覆盖，转码输出取决于目标容器）
- **视频剪辑**：裁剪区间、改分辨率、调帧率、旋转 90/180/270、去音轨、转 GIF
- **多段合并**：按顺序把多个视频拼成一个，自动统一分辨率（等比缩放加黑边）与帧率、采样率
- **媒体信息**：查看容器与每条流的编码、时长、码率、分辨率、像素格式等

底层为 **FFmpeg 静态链接**（解码覆盖全格式），视频编码优先走 **VideoToolbox 硬件编码**（h264/hevc），不可用时自动回退 mpeg4 软编。

---

## 一、安装（iPhone / iPad）

前提：设备为 **iOS 14.0 ~ 14.8.1** 且已部署 TrollStore（TrollInstallerX）。

1. 通过 GitHub Actions 产物页（或本地构建）拿到 `FormatMaster-iOS14-x.y.z.ipa`
2. 传到设备（AirDrop / 「文件」App / iTunes 共享均可）
3. 点击该 ipa → 自动弹出 TrollStore → **Install**
4. 桌面出现"格式大师"图标即成功

> 巨魔安装**不需要签名**，产物未签名可直接安装。iOS 14 上 TrollStore 存在已知稳定性风险，安装前请完整备份设备数据。

---

## 二、构建：云端自动打包（无需 Mac，推荐）

1. 把本目录推送到你的 GitHub 仓库（任意公开/私有仓库均可）：

   ```bash
   git init
   git add .
   git commit -m "格式大师 iOS 初版"
   git branch -M main
   git remote add origin https://github.com/<你的账号>/<仓库名>.git
   git push -u origin main
   ```

2. 仓库页面 → **Actions** → 选"构建 iOS 应用包" → **Run workflow**（或直接 push 触发）
3. 约几分钟后，在运行记录底部下载工件 **格式大师-iOS14-未签名ipa**
4. 解压得到 `.ipa`，按上面第一步安装

流水线环境为 ubuntu：Theos 官方安装器会自动拉取 Linux 版 clang 交叉工具链与 iOS SDK，FFmpeg 取社区预编译的 iOS arm64 LGPL 静态库，全程无需 macOS。

## 三、构建：Linux / WSL2 本地打包

```bash
# 依赖
sudo apt-get install build-essential fakeroot curl git rsync perl zip unzip xz-utils

# Theos（非交互安装，自动带 iOS 交叉工具链 + SDK）
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
export THEOS=~/theos PATH=$PATH:$THEOS/bin

cd FormatMasteriOS
bash scripts/fetch-ffmpeg.sh     # 拉 FFmpeg iOS 静态库到 build/ffmpeg
make FINAL=1 -j$(nproc)          # 交叉编译
bash scripts/make-ipa.sh         # 组装 Payload 打成未签名 ipa → build/*.ipa
```

---

## 四、目录结构

```
FormatMasteriOS/
├── Makefile                     # Theos 工程定义（arm64 / iOS 14 / 链接 FFmpeg）
├── FormatMaster-Info.plist      # 应用配置（文件共享、相册权限、导入类型）
├── .github/workflows/
│   └── build-ipa.yml            # GitHub Actions 云端打包流水线
├── scripts/
│   ├── fetch-ffmpeg.sh          # 抓取社区预编译 iOS FFmpeg 静态库
│   └── make-ipa.sh              # 产物组装为未签名 ipa（巨魔可直接装）
└── src/
    ├── main.m / AppDelegate.*   # 入口
    ├── RootViewController.*     # 首页：四项功能入口
    ├── ConvertViewController.*  # 全格式转换
    ├── EditViewController.*     # 视频剪辑（裁剪/缩放/帧率/旋转/GIF）
    ├── MergeViewController.*    # 多段合并（统一分辨率拼接）
    ├── InfoViewController.*     # 媒体信息探测
    ├── FMInputPicker.*          # 相册 / 「文件」App 双通道取文件
    ├── FFEngine.*               # FFmpeg 引擎：探测 / 转码 / 剪辑 / 合并
    └── FFPresets.*              # 目标格式预设表
```

## 五、许可与合规

- 本工程按 **MIT** 发布；链入的 FFmpeg 为社区预编译 **LGPL** 构建。发布时请随附 FFmpeg 的 LGPL 许可证文本与源码获取方式（本页即可）。
- 刻意 **未启用 x264/x265（GPL）**：视频编码用 Apple 自带的 VideoToolbox 硬编 + FFmpeg 自带的 mpeg4 软编兜底，避免整个应用被传染为 GPL。
- 不聚合、不修改 FFmpeg 源码，仅调用其公开 API，符合 LGPL 动态/静态使用义务中对"使用库"的定义（静态链接场景需按上文提供对象文件重链接权利，建议开源本应用源码即满足）。

## 六、已知限制（iOS 14 / 免费版）

- 仅 arm64 真机：iOS 14 最低需要 A9 芯片（iPhone 6s / SE 一代及以后；iPhone 5s 等 A7 机型升不到 iOS 14）；系统需停留在 14.0~14.8.1 才能用巨魔安装
- GIF 宽度上限 480px（老设备内存保护）；转 GIF 默认 15fps
- 裁剪起点按关键帧就近对齐，精确到帧的裁剪暂不提供
- 多段合并要求各片段均有视频轨；分辨率不一致时以最大片段为画布加黑边
- 尚未支持：字幕烧录、水印、变速、倒放（引擎管线预留，后续迭代）
