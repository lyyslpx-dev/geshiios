// FMInputPicker.h —— 输入文件选取（相册 / 「文件」App 双通道）
#import <UIKit/UIKit.h>
#import "FFPresets.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^FMPickCompletion)(NSString *_Nullable localPath, NSError *_Nullable error);

@interface FMInputPicker : NSObject

/// 弹出选择来源菜单；kind 决定相册里可筛选的类型（图片/视频）。音频只走「文件」App。
+ (void)pickFromViewController:(UIViewController *)vc
                          kind:(FFFormatKind)kind
                    completion:(FMPickCompletion)completion;

@end

NS_ASSUME_NONNULL_END
