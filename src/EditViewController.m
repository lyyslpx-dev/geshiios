// EditViewController.m —— 视频剪辑：裁剪区间 / 分辨率 / 帧率 / 旋转 / 转 GIF
#import "EditViewController.h"
#import "FMInputPicker.h"
#import "FFEngine.h"
#import "FFPresets.h"
#import <Photos/Photos.h>

@interface EditViewController ()
@property (nonatomic, copy) NSString *inputPath;
@property (nonatomic, copy) NSString *outputPath;
@property (nonatomic, assign) double totalDur;
@property (nonatomic, assign) double startSec;
@property (nonatomic, assign) double durSec;
@property (nonatomic, assign) int heightPx;
@property (nonatomic, assign) double fps;
@property (nonatomic, assign) int rotate;
@property (nonatomic, assign) BOOL asGif;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, copy) void (^cancelFlag)(void);

@property (nonatomic, strong) UILabel *srcLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UILabel *rangeLabel;
@property (nonatomic, strong) UISlider *startSlider;
@property (nonatomic, strong) UISlider *durSlider;
@property (nonatomic, strong) UIButton *optBtn;
@property (nonatomic, strong) UIButton *runBtn;
@property (nonatomic, strong) UIButton *cancelBtn;
@property (nonatomic, strong) UIProgressView *progress;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *saveBtn;
@property (nonatomic, strong) UIButton *shareBtn;
@end

@implementation EditViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"视频剪辑";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UIStackView *sv = [[UIStackView alloc] init];
    sv.axis = UILayoutConstraintAxisVertical;
    sv.spacing = 12;
    sv.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(16, 16, 16, 16);
    sv.preservesSuperviewLayoutMargins = YES;
    [sv setTranslatesAutoresizingMaskIntoConstraints:NO];
    [self.view addSubview:sv];
    [sv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor].active = YES;
    [sv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor].active = YES;
    [sv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor].active = YES;

    UIButton *pick = [self button:@"① 选择视频"];
    [pick addTarget:self action:@selector(chooseInput) forControlEvents:UIControlEventTouchUpInside];
    self.srcLabel = [self label:@"未选择文件"];
    self.metaLabel = [self label:@""];

    self.rangeLabel = [self label:@"② 裁剪区间：整段"];
    self.startSlider = [self slider:self.startSlider action:@selector(startChanged:)];
    self.durSlider = [self slider:self.durSlider action:@selector(durChanged:)];

    self.optBtn = [self button:@"③ 尺寸 / 帧率 / 旋转 / GIF"];
    [self.optBtn addTarget:self action:@selector(openOptions) forControlEvents:UIControlEventTouchUpInside];

    self.runBtn = [self button:@"开始剪辑"];
    self.runBtn.backgroundColor = UIColor.systemBlueColor;
    [self.runBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [self.runBtn addTarget:self action:@selector(run) forControlEvents:UIControlEventTouchUpInside];
    self.runBtn.enabled = NO;

    self.cancelBtn = [self button:@"取消"];
    self.cancelBtn.hidden = YES;
    [self.cancelBtn addTarget:self action:@selector(cancelRun) forControlEvents:UIControlEventTouchUpInside];

    self.progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.statusLabel = [self label:@""];

    self.saveBtn = [self button:@"保存到相册"];
    self.saveBtn.hidden = YES;
    [self.saveBtn addTarget:self action:@selector(saveToPhotos) forControlEvents:UIControlEventTouchUpInside];
    self.shareBtn = [self button:@"分享 / 其他 App 打开"];
    self.shareBtn.hidden = YES;
    [self.shareBtn addTarget:self action:@selector(share) forControlEvents:UIControlEventTouchUpInside];

    for (UIView *v in @[pick, self.srcLabel, self.metaLabel, self.rangeLabel,
                       self.startSlider, self.durSlider, self.optBtn, self.runBtn,
                       self.cancelBtn, self.progress, self.statusLabel,
                       self.saveBtn, self.shareBtn]) {
        [sv addArrangedSubview:v];
    }
}

- (UIButton *)button:(NSString *)t {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    b.backgroundColor = UIColor.secondarySystemBackgroundColor;
    b.layer.cornerRadius = 10;
    [b heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return b;
}

- (UILabel *)label:(NSString *)t {
    UILabel *l = [[UILabel alloc] init];
    l.text = t;
    l.font = [UIFont systemFontOfSize:13];
    l.textColor = UIColor.secondaryLabelColor;
    l.numberOfLines = 0;
    return l;
}

- (UISlider *)slider:(UISlider *)_ action:(SEL)sel {
    UISlider *s = [[UISlider alloc] init];
    s.minimumValue = 0;
    s.maximumValue = 1;
    [s addTarget:self action:sel forControlEvents:UIControlEventValueChanged];
    [s heightAnchor constraintGreaterThanOrEqualToConstant:32].active = YES;
    return s;
}

// ---- 选取 ------------------------------------------------------------------

- (void)chooseInput {
    __weak typeof(self) ws = self;
    [FMInputPicker pickFromViewController:self kind:FFFormatKindVideo
                               completion:^(NSString *path, NSError *err) {
        typeof(self) s = ws;
        if (!s) return;
        if (err) { [s show:err.localizedDescription]; return; }
        if (!path) return;
        s.inputPath = path;
        s.srcLabel.text = [NSString stringWithFormat:@"源：%@", path.lastPathComponent];
        [s loadMeta:path];
    }];
}

- (void)loadMeta:(NSString *)path {
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        NSError *e = nil;
        NSDictionary *info = [FFEngine probeFile:path error:&e];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = ws;
            if (!s) return;
            if (!info) {
                s.metaLabel.text = e.localizedDescription ?: @"读取信息失败";
                s.totalDur = 0;
                s.runBtn.enabled = NO;
                return;
            }
            double dur = [info[@"duration"] doubleValue];
            s.totalDur = dur;
            NSMutableString *ms = [NSMutableString string];
            [ms appendFormat:@"时长 %@ 秒", dur > 0 ? [NSString stringWithFormat:@"%.1f", dur] : @"未知"];
            for (NSDictionary *st in info[@"streams"]) {
                if ([st[@"type"] isEqualToString:@"视频"]) {
                    [ms appendFormat:@"｜%@ %@x%@ @%.0ffps", st[@"codec"], st[@"width"], st[@"height"],
                     [st[@"fps"] doubleValue]];
                } else if ([st[@"type"] isEqualToString:@"音频"]) {
                    [ms appendFormat:@"｜音频 %@ %dHz", st[@"codec"], [st[@"sample_rate"] intValue]];
                }
            }
            s.metaLabel.text = ms;

            if (dur > 0.2) {
                s.startSlider.maximumValue = dur;
                s.durSlider.maximumValue = dur;
                s.durSlider.value = dur;
                s.startSlider.value = 0;
            }
            s.runBtn.enabled = YES;
            [s updateRangeLabel];
        });
    });
}

- (void)startChanged:(UISlider *)s {
    self.startSec = s.value;
    double remain = MAX(0, self.totalDur - s.value);
    if (self.durSlider.value > remain) self.durSlider.value = remain;
    self.durSec = self.durSlider.value;
    [self updateRangeLabel];
}

- (void)durChanged:(UISlider *)s {
    self.durSec = s.value;
    [self updateRangeLabel];
}

- (void)updateRangeLabel {
    if (self.totalDur <= 0) { self.rangeLabel.text = @"② 裁剪区间：整段（时长未知）"; return; }
    double e = MIN(self.totalDur, self.startSec + (self.durSec > 0 ? self.durSec : self.totalDur));
    self.rangeLabel.text = [NSString stringWithFormat:@"② 裁剪区间：%.1f 秒 → %.1f 秒（%.1f 秒）",
                            self.startSec, e, MAX(0, e - self.startSec)];
}

// ---- 选项 ------------------------------------------------------------------

- (void)openOptions {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"剪辑参数"
                                                                message:@"可重复进入逐项设置"
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:[self heightTitle]
                                          style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [ws pickHeight];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:[self fpsTitle]
                                          style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [ws pickFps];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:[self rotateTitle]
                                          style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [ws pickRotate];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:self.asGif ? @"输出：GIF 动图（再按切回 MP4）"
                                                        : @"输出：GIF 动图"
                                          style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        ws.asGif = !ws.asGif;
        [ws.optBtn setTitle:@"③ 尺寸 / 帧率 / 旋转 / GIF" forState:UIControlStateNormal];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"重置为整段"
                                          style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        ws.startSlider.value = 0;
        ws.durSlider.value = ws.totalDur;
        ws.startSec = 0; ws.durSec = ws.totalDur; ws.heightPx = 0; ws.fps = 0; ws.rotate = 0;
        ws.asGif = NO;
        [ws updateRangeLabel];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"完成" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:ac];
}

- (NSString *)heightTitle {
    return self.heightPx > 0
        ? [NSString stringWithFormat:@"分辨率：%dp（再按调整）", self.heightPx] : @"分辨率：保持源";
}
- (NSString *)fpsTitle {
    return self.fps > 0
        ? [NSString stringWithFormat:@"帧率：%.0f fps（再按调整）", self.fps] : @"帧率：保持源";
}
- (NSString *)rotateTitle {
    return [NSString stringWithFormat:@"旋转：%d°", self.rotate];
}

- (void)pickHeight {
    [self chooseFrom:@[@"保持源", @"1080p", @"720p", @"480p", @"360p"] title:@"输出高度"
           withTags:@[@0, @1080, @720, @480, @360] handler:^(id tag) {
        self.heightPx = [tag intValue];
    }];
}

- (void)pickFps {
    [self chooseFrom:@[@"保持源", @"10 fps", @"15 fps", @"24 fps", @"30 fps", @"60 fps"]
               title:@"输出帧率"
           withTags:@[@0, @10, @15, @24, @30, @60] handler:^(id tag) {
        self.fps = [tag doubleValue];
    }];
}

- (void)pickRotate {
    [self chooseFrom:@[@"不旋转", @"顺时针 90°", @"180°", @"逆时针 90°"] title:@"画面旋转"
           withTags:@[@0, @90, @180, @270] handler:^(id tag) {
        self.rotate = [tag intValue];
    }];
}

- (void)chooseFrom:(NSArray<NSString *> *)titles title:(NSString *)title
          withTags:(NSArray<NSNumber *> *)tags handler:(void (^)(id tag))handler {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < titles.count; i++) {
        NSNumber *tag = tags[i];
        [ac addAction:[UIAlertAction actionWithTitle:titles[i] style:UIAlertActionStyleDefault
                                              handler:^(UIAlertAction *a) { handler(tag); }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:ac];
}

- (void)presentSheet:(UIAlertController *)ac {
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        ac.popoverPresentationController.sourceView = self.view;
        ac.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    }
    [self presentViewController:ac animated:YES completion:nil];
}

// ---- 执行 ------------------------------------------------------------------

- (void)run {
    if (self.busy || !self.inputPath.length) return;
    if (self.totalDur > 0 && self.startSec >= self.totalDur - 0.05) {
        [self show:@"起点已超过视频长度"]; return;
    }
    self.busy = YES;
    self.cancelFlag = nil;
    self.saveBtn.hidden = YES;
    self.shareBtn.hidden = YES;
    self.progress.progress = 0;
    self.runBtn.enabled = NO;
    self.cancelBtn.hidden = NO;
    self.statusLabel.text = @"准备中…";

    FFRequest *req = [FFRequest new];
    req.inputPath = self.inputPath;
    NSString *ext = self.asGif ? @"gif" : @"mp4";
    NSString *base = [self.inputPath.lastPathComponent stringByDeletingPathExtension];
    self.outputPath = [[FFEngine outputDir] stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@_cut_%u.%@", base,
         (unsigned)(NSDate.date.timeIntervalSince1970 % 100000), ext]];
    req.outputPath = self.outputPath;
    req.muxerName = ext;
    req.videoCodec = self.asGif ? @"gif" : @"h264_videotoolbox,mpeg4";
    req.audioCodec = self.asGif ? nil : @"aac";
    req.noAudio = self.asGif;
    if (self.heightPx > 0) req.height = self.heightPx;
    if (self.fps > 0) req.fps = self.fps;
    if (self.rotate) req.rotate = self.rotate;
    if (self.asGif && req.fps <= 0) req.fps = 15;

    double from = self.startSec;
    double len = self.durSec > 0 && self.startSec + self.durSec < self.totalDur - 0.05
                 ? self.durSec : (self.totalDur > 0 ? (self.totalDur - from) : -1);
    if (from > 0.05) req.start = from;
    if (len > 0.05 && self.totalDur > 0 && from + len < self.totalDur - 0.05) req.duration = len;

    __block volatile BOOL cancel = NO;
    self.cancelFlag = ^{ cancel = YES; };

    __weak typeof(self) ws = self;
    FFRequest *r = req;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *e = nil;
        BOOL ok = [FFEngine execute:r progress:^BOOL(double p, NSString *hint) {
            if (cancel) return NO;
            typeof(self) s = ws;
            if (s) dispatch_async(dispatch_get_main_queue(), ^{
                s.progress.progress = (float)p;
                s.statusLabel.text = [NSString stringWithFormat:@"%@ %.0f%%", hint, p * 100];
            });
            return YES;
        } error:&e];
        long long size = ok ? [[NSFileManager.defaultManager
                    attributesOfItemAtPath:self.outputPath error:nil][NSFileSize] longLongValue] : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = ws;
            if (!s) return;
            s.busy = NO;
            s.cancelBtn.hidden = YES;
            s.runBtn.enabled = YES;
            [s.runBtn setTitle:@"开始剪辑" forState:UIControlStateNormal];
            if (ok) {
                s.progress.progress = 1;
                s.statusLabel.text = [NSString stringWithFormat:@"完成：%@（%@）",
                    s.outputPath.lastPathComponent,
                    [NSByteCountFormatter stringFromByteCount:size
                        countStyle:NSByteCountFormatterCountStyleFile]];
                s.saveBtn.hidden = NO;
                s.shareBtn.hidden = NO;
            } else {
                s.statusLabel.text = e.localizedDescription ?: @"剪辑失败";
            }
        });
    });
}

- (void)cancelRun {
    if (self.cancelFlag) self.cancelFlag();
    self.statusLabel.text = @"正在取消…";
}

- (void)saveToPhotos {
    if (!self.outputPath.length) return;
    NSURL *u = [NSURL fileURLWithPath:self.outputPath];
    __weak typeof(self) ws = self;
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:u];
    } completionHandler:^(BOOL success, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [ws show:success ? @"已保存到相册" : (err.localizedDescription ?: @"保存失败")];
        });
    }];
}

- (void)share {
    if (!self.outputPath.length) return;
    UIActivityViewController *av = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:self.outputPath]] applicationActivities:nil];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        av.popoverPresentationController.sourceView = self.view;
        av.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    }
    [self presentViewController:av animated:YES completion:nil];
}

- (void)show:(NSString *)msg {
    if (!msg.length) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:NO completion:nil];
}

@end
