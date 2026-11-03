// ConvertViewController.m —— 全格式转换
#import "ConvertViewController.h"
#import "FMInputPicker.h"
#import "FFEngine.h"
#import "FFPresets.h"
#import <Photos/Photos.h>

@interface ConvertViewController ()
@property (nonatomic, strong) NSString *inputPath;
@property (nonatomic, strong) FFPreset *preset;
@property (nonatomic, assign) int64_t videoBitrate;   // 0 = 默认
@property (nonatomic, assign) int targetHeight;       // 0 = 源
@property (nonatomic, strong) UILabel *srcLabel;
@property (nonatomic, strong) UIButton *fmtBtn;
@property (nonatomic, strong) UIButton *brBtn;
@property (nonatomic, strong) UIButton *resBtn;
@property (nonatomic, strong) UIButton *runBtn;
@property (nonatomic, strong) UIProgressView *progress;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *saveBtn;
@property (nonatomic, strong) UIButton *shareBtn;
@property (nonatomic, copy) NSString *outputPath;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, copy) void (^cancelFlag)(void);
@property (nonatomic, strong) UIButton *cancelBtn;
@end

@implementation ConvertViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"格式转换";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UIStackView *sv = [[UIStackView alloc] init];
    sv.axis = UILayoutConstraintAxisVertical;
    sv.spacing = 14;
    sv.layoutMargins = UIEdgeInsetsMake(16, 16, 16, 16);
    sv.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(16, 16, 16, 16);
    sv.preservesSuperviewLayoutMargins = YES;
    [sv setTranslatesAutoresizingMaskIntoConstraints:NO];
    [self.view addSubview:sv];
    [sv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor].active = YES;
    [sv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor].active = YES;
    [sv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor].active = YES;

    UIButton *pick = [self textButton:@"① 选择源文件"];
    [pick addTarget:self action:@selector(chooseInput) forControlEvents:UIControlEventTouchUpInside];
    self.srcLabel = [self infoLabel:@"未选择文件"];
    self.srcLabel.numberOfLines = 3;

    self.fmtBtn = [self textButton:@"② 目标格式：未选择"];
    [self.fmtBtn addTarget:self action:@selector(chooseFormat) forControlEvents:UIControlEventTouchUpInside];

    self.brBtn = [self textButton:@"③ 视频码率：自动"];
    [self.brBtn addTarget:self action:@selector(chooseBitrate) forControlEvents:UIControlEventTouchUpInside];

    self.resBtn = [self textButton:@"④ 输出分辨率：保持源"];
    [self.resBtn addTarget:self action:@selector(chooseResolution) forControlEvents:UIControlEventTouchUpInside];

    self.runBtn = [self textButton:@"开始转换"];
    self.runBtn.backgroundColor = UIColor.systemBlueColor;
    [self.runBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.runBtn.layer.cornerRadius = 10;
    self.runBtn.enabled = NO;
    [self.runBtn addTarget:self action:@selector(run) forControlEvents:UIControlEventTouchUpInside];

    self.progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progress.progress = 0;

    self.statusLabel = [self infoLabel:@""];
    self.statusLabel.numberOfLines = 4;

    self.saveBtn = [self textButton:@"保存到相册"];
    self.saveBtn.hidden = YES;
    [self.saveBtn addTarget:self action:@selector(saveToPhotos) forControlEvents:UIControlEventTouchUpInside];

    self.shareBtn = [self textButton:@"分享 / 其他 App 打开"];
    self.shareBtn.hidden = YES;
    [self.shareBtn addTarget:self action:@selector(share) forControlEvents:UIControlEventTouchUpInside];

    self.cancelBtn = [self textButton:@"取消转换"];
    self.cancelBtn.hidden = YES;
    [self.cancelBtn setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
    [self.cancelBtn addTarget:self action:@selector(cancelRun) forControlEvents:UIControlEventTouchUpInside];

    for (UIView *v in @[pick, self.srcLabel, self.fmtBtn, self.brBtn, self.resBtn,
                       self.runBtn, self.cancelBtn, self.progress, self.statusLabel,
                       self.saveBtn, self.shareBtn]) {
        [sv addArrangedSubview:v];
        [v.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    }

    if (self.pendingURL) [self adoptURL:self.pendingURL];
}

// ---- UI 小工具 ------------------------------------------------------------

- (UIButton *)textButton:(NSString *)t {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.textAlignment = NSTextAlignmentLeft;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    b.backgroundColor = UIColor.secondarySystemBackgroundColor;
    b.layer.cornerRadius = 10;
    return b;
}

- (UILabel *)infoLabel:(NSString *)t {
    UILabel *l = [[UILabel alloc] init];
    l.text = t;
    l.font = [UIFont systemFontOfSize:13];
    l.textColor = UIColor.secondaryLabelColor;
    return l;
}

- (void)chooseInput {
    __weak typeof(self) ws = self;
    [FMInputPicker pickFromViewController:self kind:FFFormatKindVideo
                               completion:^(NSString *path, NSError *err) {
        typeof(self) ss = ws;
        if (!ss) return;
        if (err) { [ss toast:err.localizedDescription]; return; }
        if (path) ss.inputPath = path;
        [ss refreshInput];
    }];
}

- (void)adoptURL:(NSURL *)url {
    NSError *e = nil;
    NSString *p = [FFEngine stageInputFromURL:url error:&e];
    if (p) { self.inputPath = p; [self refreshInput]; }
    else if (e) { [self toast:e.localizedDescription]; }
}

- (void)refreshInput {
    if (!self.inputPath.length) return;
    self.srcLabel.text = [NSString stringWithFormat:@"源：%@", self.inputPath.lastPathComponent];
    self.runBtn.enabled = (self.preset != nil && !self.busy);

    // 按源类型自动给出默认目标格式
    FFFormatKind kind = [FFPresets kindOfPath:self.inputPath];
    NSArray *list = [FFPresets presetsForKind:kind];
    if (!self.preset || ![list containsObject:self.preset]) {
        self.preset = list.count ? list[0] : nil;
    }
    [self updateFormatButton];
}

- (void)updateFormatButton {
    self.fmtBtn.titleLabel.text = nil;
    [self.fmtBtn setTitle:self.preset
        ? [NSString stringWithFormat:@"② 目标格式：%@", self.preset.title]
        : @"② 目标格式：未选择"
        forState:UIControlStateNormal];
    self.runBtn.enabled = (self.inputPath.length && self.preset && !self.busy);
}

- (void)chooseFormat {
    if (!self.inputPath.length) { [self toast:@"请先选择源文件"]; return; }
    FFFormatKind kind = [FFPresets kindOfPath:self.inputPath];
    NSArray<FFPreset *> *list = [FFPresets presetsForKind:kind];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"目标格式"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) ws = self;
    for (FFPreset *p in list) {
        NSString *title = p.note ? [NSString stringWithFormat:@"%@（%@）", p.title, p.note] : p.title;
        [ac addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                              handler:^(UIAlertAction *a) {
            ws.preset = p;
            [ws updateFormatButton];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        ac.popoverPresentationController.sourceView = self.view;
        ac.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    }
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)chooseBitrate {
    NSArray *opts = @[@[@"自动（约 4 Mbps）", @0],
                      @[@"低 1 Mbps", @1000000],
                      @[@"中 2 Mbps", @2000000],
                      @[@"高 8 Mbps", @8000000],
                      @[@"超高 16 Mbps", @16000000]];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"视频码率"
                                                                message:@"音频固定 128 kbps；直通模式忽略码率"
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) ws = self;
    for (NSArray *o in opts) {
        [ac addAction:[UIAlertAction actionWithTitle:o[0] style:UIAlertActionStyleDefault
                                              handler:^(UIAlertAction *a) {
            ws.videoBitrate = [o[1] longLongValue];
            [ws.brBtn setTitle:[NSString stringWithFormat:@"③ 视频码率：%@", o[0]]
                      forState:UIControlStateNormal];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        ac.popoverPresentationController.sourceView = self.view;
        ac.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    }
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)chooseResolution {
    NSArray *opts = @[@[@"保持源", @0], @[@"1080p", @1080], @[@"720p", @720],
                      @[@"480p", @480], @[@"360p", @360]];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"输出分辨率"
                                                                message:@"按高度等比缩放；直通模式忽略"
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) ws = self;
    for (NSArray *o in opts) {
        [ac addAction:[UIAlertAction actionWithTitle:o[0] style:UIAlertActionStyleDefault
                                              handler:^(UIAlertAction *a) {
            ws.targetHeight = [o[1] intValue];
            [ws.resBtn setTitle:[NSString stringWithFormat:@"④ 输出分辨率：%@", o[0]]
                       forState:UIControlStateNormal];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        ac.popoverPresentationController.sourceView = self.view;
        ac.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    }
    [self presentViewController:ac animated:YES completion:nil];
}

// ---- 执行 ------------------------------------------------------------------

- (void)run {
    if (self.busy || !self.inputPath.length || !self.preset) return;
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
    NSString *base = [self.inputPath.lastPathComponent stringByDeletingPathExtension];
    NSString *outName = [NSString stringWithFormat:@"%@_%u.%@", base,
                         (unsigned)(NSDate.date.timeIntervalSince1970 % 100000),
                         self.preset.ext];
    self.outputPath = [[FFEngine outputDir] stringByAppendingPathComponent:outName];
    req.outputPath = self.outputPath;
    req.muxerName = self.preset.muxer;
    req.videoCodec = self.preset.videoCodec;
    req.audioCodec = self.preset.audioCodec;
    req.audioOnly = (self.preset.kind == FFFormatKindAudio);
    req.noAudio = (self.preset.kind == FFFormatKindImage) ||
                  [self.preset.muxer isEqualToString:@"gif"];
    req.stillImage = (self.preset.kind == FFFormatKindImage);
    req.videoBitrate = (int)self.videoBitrate;
    if (self.targetHeight > 0) req.height = self.targetHeight;

    __block volatile BOOL cancel = NO;
    self.cancelFlag = ^{ cancel = YES; };
    self.cancelBtn.hidden = NO;

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
        long long size = ok ? (long long)[NSFileManager.defaultManager
                    attributesOfItemAtPath:self.outputPath error:nil][NSFileSize] : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = ws;
            if (!s) return;
            s.busy = NO;
            s.cancelBtn.hidden = YES;
            [s.runBtn setTitle:@"开始转换" forState:UIControlStateNormal];
            s.runBtn.enabled = YES;
            if (ok) {
                s.progress.progress = 1;
                s.statusLabel.text = [NSString stringWithFormat:@"完成： %@（%@）",
                    s.outputPath.lastPathComponent,
                    [NSByteCountFormatter stringFromCount:size usage:NSByteCountFormatterUseDefault]];
                s.saveBtn.hidden = ([FFPresets kindOfPath:s.outputPath] == FFFormatKindAudio);
                s.shareBtn.hidden = NO;
            } else {
                s.statusLabel.text = e.localizedDescription ?: @"转换失败";
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
    FFFormatKind k = [FFPresets kindOfPath:self.outputPath];
    __weak typeof(self) ws = self;
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        if (k == FFFormatKindImage) {
            [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:u];
        } else if (k == FFFormatKindAudio) {
            // 相册不存纯音频，提示用"分享"保存
        } else {
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:u];
        }
    } completionHandler:^(BOOL success, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [ws toast:success ? @"已保存到相册" : (err.localizedDescription ?: @"保存失败")];
        });
    }];
}

- (void)share {
    if (!self.outputPath.length) return;
    NSURL *u = [NSURL fileURLWithPath:self.outputPath];
    UIActivityViewController *av =
        [[UIActivityViewController alloc] initWithActivityItems:@[u]
                                          applicationActivities:nil];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        av.popoverPresentationController.sourceView = self.view;
        av.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    }
    [self presentViewController:av animated:YES completion:nil];
}

- (void)toast:(NSString *)msg {
    if (!msg.length) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:NO completion:nil];
}

@end
