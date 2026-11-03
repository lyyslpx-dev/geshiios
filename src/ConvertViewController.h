// ConvertViewController.h
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ConvertViewController : UIViewController
/// 从「文件」App"用其他应用打开"进来时预置的 URL
@property (nonatomic, strong, nullable) NSURL *pendingURL;
@end

NS_ASSUME_NONNULL_END
