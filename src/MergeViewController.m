// MergeViewController.m —— 多段合并：按顺序追加多个视频，统一尺寸后拼成一个
#import "MergeViewController.h"
#import "FMInputPicker.h"
#import "FFEngine.h"
#import "FFPresets.h"
#import <Photos/Photos.h>

@interface MergeViewController ()
@property (nonatomic, strong) NSMutableArray<NSString *> *paths;
@property (nonatomic, copy) NSString *outputPath;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, copy) void (^cancelFlag)(void);

@property (nonatomic, strong) UILabel *listLabel;
@property (nonatomic, strong) UIButton *addBtn;
@property (nonatomic, strong) UIButton *clearBtn;
@property (nonatomic, strong) UIButton *runBtn;
@property (nonatomic, strong) UIButton *cancelBtn;
@property (nonatomic, strong) UIProgressView *progress;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *saveBtn;
@property (nonatomic, strong) UIButton *shareBtn;
@end

@implementation MergeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.paths = [NSMutableArray array];
    self.title = @"多段合并";
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

    self.listLabel = [self label:@"还没添加片段。点「添加片段」按顺序选视频。"];
    self.addBtn = [self button:@"＋ 添加片段"];
    [self.addBtn addTarget:self action:@selector(addOne) forControlEvents:UIControlEventTouchUpInside];
    self.clearBtn = [self button:@"清空列表"];
    [self.clearBtn addTarget:self action:@selector(clearAll) forControlEvents:UIControlEventTouchUpInside];

    self.runBtn = [self button:@"开始合并"];
    self.runBtn.backgroundColor = UIColor.systemBlueColor;
    [self.runBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [self.runBtn addTarget:self action:@selector(run) forControlEvents:UIControlEventTouchUpInside];
    self.runBtn.enabled = NO;

    self.cancelBtn = [self button:@"取消"];
    self.cancelBtn.hidden = YES;
    [self.cancelBtn addTarget:self action:@selector(cancelRun) forControlEvents:UIControlEventTouchUpInside];

    self.progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.statusLabel = [self label:@"合并会统一分辨率并加黑边，逐段重编码。"];

    self.saveBtn = [self button:@"保存到相册"];
    self.saveBtn.hidden = YES;
    [self.saveBtn addTarget:self action:@selector(saveToPhotos) forControlEvents:UIControlEventTouchUpInside];
    self.shareBtn = [self button:@"分享 / 其他 App 打开"];
    self.shareBtn.hidden = YES;
    [self.shareBtn addTarget:self action:@selector(share) forControlEvents:UIControlEventTouchUpInside];

    for (UIView *v in @[self.listLabel, self.addBtn, self.clearBtn, self.runBtn, self.cancelBtn,
                        self.progress, self.statusLabel, self.saveBtn, self.shareBtn]) {
        [sv addArrangedSubview:v];
    }
}

// ---- 工具 ------------------------------------------------------------------

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

- (void)refreshList {
    if (self.paths.count == 0) {
        self.listLabel.text = @"还没添加片段。点「添加片段」按顺序选视频。";
        self.runBtn.enabled = NO;
        return;
    }
    NSMutableString *ms = [NSMutableString stringWithFormat:@"%lu 个片段：\n", (unsigned long)self.paths.count];
    for (NSUInteger i = 0; i < self.paths.count; i++) {
        [ms appendFormat:@"%lu. %@\n", (unsigned long)(i + 1), self.paths[i].lastPathComponent];
    }
    self.listLabel.text = ms;
    self.runBtn.enabled = self.paths.count >= 1 && !self.busy;
}

// ---- 选取 ------------------------------------------------------------------

- (void)addOne {
    __weak typeof(self) ws = self;
    [FMInputPicker pickFromViewController:self kind:FFFormatKindVideo completion:^(NSString *path, NSError *err) {
        typeof(self) s = ws;
        if (!s) return;
        if (err) { [s show:err.localizedDescription]; return; }
        if (!path) return;
        [s.paths addObject:path];
        [s refreshList];
    }];
}

- (void)clearAll {
    [self.paths removeAllObjects];
    self.saveBtn.hidden = self.shareBtn.hidden = YES;
    [self refreshList];
}

// ---- 执行 ------------------------------------------------------------------

- (void)run {
    if (self.paths.count < 1 || self.busy) return;
    self.busy = YES;
    self.saveBtn.hidden = self.shareBtn.hidden = YES;
    self.runBtn.enabled = NO;
    self.clearBtn.enabled = NO;
    self.addBtn.enabled = NO;
    self.cancelBtn.hidden = NO;
    self.progress.progress = 0;
    self.statusLabel.text = @"合并中…";

    NSString *out = [[FFEngine outputDir] stringByAppendingPathComponent:
        [NSString stringWithFormat:@"merged_%u.mp4", (unsigned)(NSDate.date.timeIntervalSince1970 % 100000)]];
    self.outputPath = out;

    __block volatile BOOL cancel = NO;
    self.cancelFlag = ^{ cancel = YES; };
    NSArray *snapshot = [self.paths copy];

    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *e = nil;
        BOOL ok = [FFEngine concatFiles:snapshot toFile:out request:nil progress:^BOOL(double p, NSString *hint) {
            if (cancel) return NO;
            typeof(self) s = ws;
            if (s) dispatch_async(dispatch_get_main_queue(), ^{
                s.progress.progress = (float)p;
                s.statusLabel.text = [NSString stringWithFormat:@"%@ %.0f%%", hint, p * 100];
            });
            return YES;
        } error:&e];
        long long size = ok ? (long long)[NSFileManager.defaultManager
                    attributesOfItemAtPath:out error:nil][NSFileSize] : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = ws;
            if (!s) return;
            s.busy = NO;
            s.cancelBtn.hidden = YES;
            s.addBtn.enabled = s.clearBtn.enabled = YES;
            [s refreshList];
            if (ok) {
                s.progress.progress = 1;
                s.statusLabel.text = [NSString stringWithFormat:@"完成： %@（%@）",
                    out.lastPathComponent,
                    [NSByteCountFormatter stringFromCount:size usage:NSByteCountFormatterUseDefault]];
                s.saveBtn.hidden = NO; s.shareBtn.hidden = NO;
            } else {
                s.statusLabel.text = e.localizedDescription ?: @"合并失败";
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
