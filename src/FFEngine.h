// FFEngine.h —— 基于 FFmpeg libav* 的媒体探测 / 转码 / 剪辑引擎
// 全部调用都在后台线程执行，UI 只负责触发与展示进度。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 引擎错误域
extern NSString *const FFEngineErrorDomain;

/// progress 0~1；返回 NO 可请求取消（下一帧生效）
typedef BOOL (^FFProgressBlock)(double progress, NSString *hint);

/// 一次转换/剪辑任务的全部参数
@interface FFRequest : NSObject

// 输入输出
@property (nonatomic, copy) NSString *inputPath;
/// YES 表示 inputPath 指向 FFmpeg concat 列表文件（.ffconcat），用于多段合并
@property (nonatomic, assign) BOOL inputIsConcatList;
@property (nonatomic, copy) NSString *outputPath;
/// 目标容器名（mov / matroska / avi / gif / ipod / wav / flac ...），为空则按输出文件扩展名推断
@property (nonatomic, copy, nullable) NSString *muxerName;

// 剪辑区间（秒）。start<=0 或 duration<=0 表示不限制
@property (nonatomic, assign) double start;
@property (nonatomic, assign) double duration;

// 编码选择："copy"=直通；nil=按容器默认；其余为编码器名，如
// h264_videotoolbox / mpeg4 / aac / png / mjpeg / bmp
@property (nonatomic, copy, nullable) NSString *videoCodec;
@property (nonatomic, copy, nullable) NSString *audioCodec;

// 画面参数（0 = 保持源）
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
/// 同时>0 时强制输出为该尺寸：等比缩放后居中补黑边（多段合并统一画面用）
@property (nonatomic, assign) int padWidth;
@property (nonatomic, assign) int padHeight;
@property (nonatomic, assign) double fps;       // 0 = 保持源
@property (nonatomic, assign) int rotate;       // 0 / 90 / 180 / 270，顺时针
@property (nonatomic, assign) int videoBitrate; // bps，0 = 编码器默认
@property (nonatomic, assign) int audioBitrate; // bps，0 = 编码器默认
/// >0 时强制该采样率（多段合并统一音频参数用）
@property (nonatomic, assign) int sampleRate;
/// 强制指定输入容器名（如 "concat"）；为空则由 FFmpeg 自动探测
@property (nonatomic, copy, nullable) NSString *inputFormatName;
/// 已知总时长（秒）。concat 列表容器读不到时长时用它算进度
@property (nonatomic, assign) double durationHint;

// 开关
@property (nonatomic, assign) BOOL audioOnly;   // 只保留/提取音频
@property (nonatomic, assign) BOOL noAudio;     // 去音轨（如转 GIF）
@property (nonatomic, assign) BOOL stillImage;  // 单帧图片转码模式

@end

@interface FFEngine : NSObject

/// 探测媒体信息：格式名、时长、码率 + streams 数组（每个是 NSDictionary）
+ (nullable NSDictionary *)probeFile:(NSString *)path error:(NSError **)error;

/// 执行转换。同步阻塞（调用方请放到后台队列）。成功返回 YES。
+ (BOOL)execute:(FFRequest *)req
       progress:(nullable FFProgressBlock)progress
          error:(NSError **)error;

/// 生成 FFmpeg concat 列表文件（用于多段合并），返回其路径；失败返回 nil
/// 走 concat demuxer，要求各段编码参数一致；不一致时请改用合并接口
+ (nullable NSString *)writeConcatListForPaths:(NSArray<NSString *> *)paths
                                         error:(NSError **)error;

/// 多段合并：把多个视频按顺序拼成一个，内部统一到目标分辨率/帧率后重编码
/// 传入 1 个路径时等价于普通转码
+ (BOOL)concatFiles:(NSArray<NSString *> *)paths
             toFile:(NSString *)outputPath
            request:(nullable FFRequest *)baseReq
           progress:(nullable FFProgressBlock)progress
              error:(NSError **)error;

/// 判断编码器是否在当前 FFmpeg 构建里可用（用于 UI 置灰与提示）
+ (BOOL)encoderAvailable:(NSString *)name;

/// 当前 FFmpeg 支持的解码器数量（用于首页展示能力概览）
+ (NSInteger)decoderCount;

/// 输出目录（沙盒 Documents/Output，"文件"App 可见）
+ (NSString *)outputDir;

/// 临时目录（存放输入副本与 concat 列表）
+ (NSString *)tempDir;

/// 把相册/外部文件拷到沙盒临时目录，返回本地路径
+ (nullable NSString *)stageInputFromURL:(NSURL *)url error:(NSError **)error;

/// 可读的 FFmpeg 版本串
+ (NSString *)ffmpegVersion;

@end

NS_ASSUME_NONNULL_END
