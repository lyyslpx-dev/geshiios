// InfoViewController.m —— 媒体信息：选择文件后用 FFprobe 逻辑展示全部流信息
#import "InfoViewController.h"
#import "FMInputPicker.h"
#import "FFEngine.h"
#import "FFPresets.h"

@interface InfoViewController ()
@property (nonatomic, strong) UITextView *text;
@end

@implementation InfoViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"媒体信息";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self action:@selector(pick)];

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:@"选择文件读取信息" forState:UIControlStateNormal];
    btn.backgroundColor = UIColor.secondarySystemBackgroundColor;
    btn.layer.cornerRadius = 10;
    [btn addTarget:self action:@selector(pick) forControlEvents:UIControlEventTouchUpInside];
    [btn setTranslatesAutoresizingMaskIntoConstraints:NO];
    [self.view addSubview:btn];

    self.text = [[UITextView alloc] init];
    self.text.editable = NO;
    self.text.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.text.layer.cornerRadius = 10;
    self.text.backgroundColor = UIColor.secondarySystemBackgroundColor;
    [self.text setTranslatesAutoresizingMaskIntoConstraints:NO];
    [self.view addSubview:self.text];

    UILayoutGuide *sa = self.view.safeAreaLayoutGuide;
    [btn.topAnchor constraintEqualToAnchor:sa.topAnchor constant:12].active = YES;
    [btn.leadingAnchor constraintEqualToAnchor:sa.leadingAnchor constant:16].active = YES;
    [btn.trailingAnchor constraintEqualToAnchor:sa.trailingAnchor constant:-16].active = YES;
    [btn.heightAnchor constraintEqualToConstant:48].active = YES;

    [self.text.topAnchor constraintEqualToAnchor:btn.bottomAnchor constant:12].active = YES;
    [self.text.leadingAnchor constraintEqualToAnchor:sa.leadingAnchor constant:16].active = YES;
    [self.text.trailingAnchor constraintEqualToAnchor:sa.trailingAnchor constant:-16].active = YES;
    [self.text.bottomAnchor constraintEqualToAnchor:sa.bottomAnchor constant:-12].active = YES;

    self.text.text = @"选择一个视频 / 音频 / 图片文件，这里会显示容器、时长、码率，"
                     @"以及每条流的编码、分辨率、帧率、采样率等 FFmpeg 解析结果。";
}

- (void)pick {
    __weak typeof(self) ws = self;
    [FMInputPicker pickFromViewController:self kind:FFFormatKindVideo
                               completion:^(NSString *path, NSError *err) {
        typeof(self) s = ws;
        if (!s) return;
        if (err) { s.text.text = err.localizedDescription; return; }
        if (!path) return;
        s.text.text = @"读取中…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            NSError *e = nil;
            NSDictionary *info = [FFEngine probeFile:path error:&e];
            NSString *body = info ? [s render:info path:path]
                                  : (e.localizedDescription ?: @"读取失败");
            dispatch_async(dispatch_get_main_queue(), ^{ ws.text.text = body; });
        });
    }];
}

- (NSString *)render:(NSDictionary *)info path:(NSString *)path {
    NSMutableString *o = [NSMutableString string];
    [o appendFormat:@"文件：%@\n", path.lastPathComponent];
    long long sz = [[NSFileManager.defaultManager
        attributesOfItemAtPath:path error:nil][NSFileSize] longLongValue];
    [o appendFormat:@"大小：%@\n",
        [NSByteCountFormatter stringFromByteCount:sz
                                       countStyle:NSByteCountFormatterCountStyleFile]];
    [o appendFormat:@"容器：%@\n", info[@"format_name"]];
    double dur = [info[@"duration"] doubleValue];
    [o appendFormat:@"时长：%@\n", dur > 0 ? [NSString stringWithFormat:@"%.2f 秒", dur] : @"未知"];
    if (info[@"bit_rate"]) {
        [o appendFormat:@"总码率：%.0f kbps\n", [info[@"bit_rate"] doubleValue] / 1000.0];
    }
    [o appendString:@"\n—— 流 ——\n"];
    for (NSDictionary *st in info[@"streams"]) {
        [o appendFormat:@"#%@ %@：%@\n", st[@"index"], st[@"type"], st[@"codec"]];
        if (st[@"width"]) {
            [o appendFormat:@"   分辨率 %@x%@  像素格式 %@\n",
             st[@"width"], st[@"height"], st[@"pix_fmt"]];
        }
        if (st[@"fps"]) [o appendFormat:@"   帧率 %.2f\n", [st[@"fps"] doubleValue]];
        if (st[@"sample_rate"]) {
            [o appendFormat:@"   采样率 %@ Hz  声道 %@  格式 %@\n",
             st[@"sample_rate"], st[@"channels"], st[@"fmt"]];
        }
        if (st[@"duration"]) [o appendFormat:@"   流时长 %.2f 秒\n", [st[@"duration"] doubleValue]];
        if (st[@"bit_rate"]) [o appendFormat:@"   码率 %.0f kbps\n", [st[@"bit_rate"] doubleValue] / 1000.0];
    }
    NSDictionary *meta = info[@"metadata"];
    if (meta.count) {
        [o appendString:@"\n—— 元数据 ——\n"];
        [o appendFormat:@"%@\n", meta];
    }
    return o;
}

@end
