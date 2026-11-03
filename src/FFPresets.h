// FFPresets.h —— 目标格式预设表（决定 UI 选项与默认编码策略）
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FFFormatKind) {
    FFFormatKindVideo = 0,
    FFFormatKindAudio = 1,
    FFFormatKindImage = 2,
};

@interface FFPreset : NSObject
@property (nonatomic, copy) NSString *title;      // UI 显示名，如 "MP4 视频"
@property (nonatomic, copy) NSString *ext;        // 输出扩展名
@property (nonatomic, copy) NSString *muxer;      // FFmpeg muxer 名
@property (nonatomic, assign) FFFormatKind kind;
@property (nonatomic, copy, nullable) NSString *videoCodec; // 默认视频编码器（可含备选，逗号分隔）
@property (nonatomic, copy, nullable) NSString *audioCodec;
@property (nonatomic, copy, nullable) NSString *note;       // 可用性备注
@end

@interface FFPresets : NSObject
/// 按输入文件的"族"返回可选目标预设：video/audio/image
+ (NSArray<FFPreset *> *)presetsForKind:(FFFormatKind)kind;
/// 根据文件扩展名判断它属于哪个族
+ (FFFormatKind)kindOfPath:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
