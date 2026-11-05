// RootViewController.m —— 首页入口：三项功能 + 底部输出目录提示
#import "RootViewController.h"
#import "ConvertViewController.h"
#import "EditViewController.h"
#import "MergeViewController.h"
#import "InfoViewController.h"
#import "FFEngine.h"

@interface RootViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@end

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"格式大师";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                      target:self action:@selector(showOutputDir:)];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 88;
    // iOS 15 起 UITableView 会给 section header 加额外顶部间距，这里清零。
    // 不能用 @available：Theos 的 clang-11 会生成 ___isOSVersionAtLeast 外部引用，
    //   而工具链未链接 compiler-rt，会在链接期报 undefined symbols。
    // 也不能直接访问该属性：部署目标是 iOS 14，会被
    //   -Werror,-Wunguarded-availability-new 判为错误。
    // 改用运行时探测 + KVC：两个限制一起绕开；iOS 14 上 setter 不存在，自动跳过。
    SEL paddingSel = NSSelectorFromString(@"setSectionHeaderTopPadding:");
    if ([self.table respondsToSelector:paddingSel]) {
        [self.table setValue:@0 forKey:@"sectionHeaderTopPadding"];
    }
    [self.view addSubview:self.table];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleOpenFile:)
                                                 name:@"FMOpenFile" object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

static NSArray<NSString *> *Titles(void) {
    return @[@"格式转换", @"视频剪辑", @"多段合并", @"媒体信息"];
}
static NSArray<NSString *> *Subtitles(void) {
    return @[@"视频 / 音频 / 图片 全格式互转",
             @"裁剪区间、改分辨率、调帧率、旋转、转 GIF",
             @"按顺序把多个视频拼成一个（统一分辨率）",
             @"查看编码、时长、码率、分辨率等"];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return 4; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *ID = @"cell";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:ID];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:ID];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    c.textLabel.text = Titles()[ip.row];
    c.detailTextLabel.text = Subtitles()[ip.row];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    UIViewController *vc = nil;
    switch (ip.row) {
        case 0: vc = [ConvertViewController new]; break;
        case 1: vc = [EditViewController new]; break;
        case 2: vc = [MergeViewController new]; break;
        default: vc = [InfoViewController new]; break;
    }
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)handleOpenFile:(NSNotification *)note {
    NSURL *url = note.object;
    ConvertViewController *vc = [ConvertViewController new];
    vc.pendingURL = url;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)showOutputDir:(id)sender {
    NSString *dir = [FFEngine outputDir];
    NSString *msg = [NSString stringWithFormat:@"输出保存在：\n%@", dir];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"结果文件位置"
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"拷贝路径"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = dir;
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
