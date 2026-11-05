// FMInputPicker.m
#import "FMInputPicker.h"
#import "FFEngine.h"
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>

@interface FMInputPicker () <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, copy) FMPickCompletion completion;
@property (nonatomic, weak) UIViewController *host;
@end

static NSMutableArray<FMInputPicker *> *_FMPickerKeepalive = nil;

@implementation FMInputPicker

+ (void)pickFromViewController:(UIViewController *)vc
                          kind:(FFFormatKind)kind
                    completion:(FMPickCompletion)completion {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择源文件"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    FMInputPicker *picker = [FMInputPicker new];
    picker.host = vc;
    picker.completion = completion;
    if (!_FMPickerKeepalive) _FMPickerKeepalive = [NSMutableArray array];
    [_FMPickerKeepalive addObject:picker]; // delegate 需要存活到本次选取结束

    FMInputPicker *p = picker;
    [sheet addAction:[UIAlertAction actionWithTitle:@"从相册选择"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [p openAlbum:kind]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"从「文件」App 选择"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [p openFiles:kind]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *a) {
        [p finishWithPath:nil error:nil]; // 用户取消，不报错
    }]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        sheet.popoverPresentationController.sourceView = vc.view;
        sheet.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(vc.view.bounds), CGRectGetMidY(vc.view.bounds), 1, 1);
    }
    [vc presentViewController:sheet animated:YES completion:nil];
}

- (void)finishWithPath:(NSString *)path error:(NSError *)err {
    FMPickCompletion cb = self.completion;
    self.completion = nil;
    [_FMPickerKeepalive removeObject:self];
    if (cb) cb(path, err);
}

- (void)fail:(NSString *)msg {
    NSError *e = [NSError errorWithDomain:@"FMInputPicker" code:1
                                 userInfo:@{NSLocalizedDescriptionKey: msg}];
    [self finishWithPath:nil error:e];
}

// ---- 相册 ----------------------------------------------------------------

- (void)openAlbum:(FFFormatKind)kind {
    if (@available(iOS 14.0, *)) {
        PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
        cfg.selectionLimit = 1;
        cfg.filter = (kind == FFFormatKindImage) ? PHPickerFilter.imagesFilter
                                                  : PHPickerFilter.videosFilter;
        PHPickerViewController *pv = [[PHPickerViewController alloc] initWithConfiguration:cfg];
        pv.delegate = self;
        [self.host presentViewController:pv animated:YES completion:nil];
    } else {
        [self fail:@"需要 iOS 14 及以上"];
    }
}

- (void)picker:(PHPickerViewController *)picker
        didFinishPicking:(NSArray<PHPickerResult *> *)results API_AVAILABLE(ios(14.0)) {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.firstObject == nil) { [self finishWithPath:nil error:nil]; return; }

    NSItemProvider *provider = results.firstObject.itemProvider;
    NSString *type = nil;
    for (NSString *tid in provider.registeredTypeIdentifiers) {
        if ([tid isEqualToString:(__bridge NSString *)kUTTypeMovie] ||
            [tid isEqualToString:(__bridge NSString *)kUTTypeMPEG4] ||
            [tid isEqualToString:@"public.mpeg-2-transport-stream"] ||
            [tid isEqualToString:(__bridge NSString *)kUTTypeImage] ||
            [tid isEqualToString:@"public.heic"] ||
            [tid isEqualToString:@"public.audio"]) { type = tid; break; }
    }
    if (!type) type = provider.registeredTypeIdentifiers.firstObject;
    if (!type) { [self fail:@"无法读取所选文件的类型"]; return; }

    __weak typeof(self) ws = self;
    [provider loadFileRepresentationForTypeIdentifier:type
        completionHandler:^(NSURL *url, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) ss = ws;
                if (!ss) return;
                if (!url) { [ss fail:err.localizedDescription ?: @"导出相册文件失败"]; return; }
                // url 已由系统复制到本 App 的 tmp，可直接读取
                NSString *path = [ss normalizeImageIfNeeded:url.path];
                [ss finishWithPath:path error:nil];
            });
        }];
}

// HEIC 等 FFmpeg 构建里没有解码器的图片，先用系统 ImageIO 解成 PNG
- (NSString *)normalizeImageIfNeeded:(NSString *)path {
    NSString *ext = path.pathExtension.lowercaseString;
    if (![ext isEqualToString:@"heic"] && ![ext isEqualToString:@"heif"] &&
        ![ext isEqualToString:@"tif"] && ![ext isEqualToString:@"tiff"]) {
        return path;
    }
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!src) return path;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return path;

    NSString *out = [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"fm_%@.png", NSUUID.UUID.UUIDString]];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:out], CFSTR("public.png"), 1, NULL);
    if (dst) {
        CGImageDestinationAddImage(dst, img, NULL);
        CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    CGImageRelease(img);
    return [NSFileManager.defaultManager fileExistsAtPath:out] ? out : path;
}

// ---- 「文件」App -----------------------------------------------------------

- (void)openFiles:(FFFormatKind)kind {
    (void)kind;
    NSArray *types = @[];
    if (@available(iOS 14.0, *)) {
        // 全格式诉求：放宽到 public.data，避免 MKV/FLV/AVI 等被灰掉选不中
        types = @[UTType.data];
    }
    UIDocumentPickerViewController *dp;
    if (@available(iOS 14.0, *)) {
        dp = [[UIDocumentPickerViewController alloc] initWithContentTypes:types asCopy:YES];
    } else {
        dp = [[UIDocumentPickerViewController alloc]
              initWithDocumentTypes:@[(__bridge NSString *)kUTTypeData] inMode:UIDocumentPickerModeImport];
    }
    dp.delegate = self;
    dp.allowsMultipleSelection = NO;
    [self.host presentViewController:dp animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSString *path = urls.firstObject.path;
    if (!path.length) { [self finishWithPath:nil error:nil]; return; }
    NSString *finalPath = [self normalizeImageIfNeeded:path];
    [self finishWithPath:finalPath error:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    [self finishWithPath:nil error:nil];
}

@end
