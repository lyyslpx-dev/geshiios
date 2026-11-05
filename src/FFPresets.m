// FFPresets.m —— 目标格式预设表
#import "FFPresets.h"

@implementation FFPreset
@end

static FFPreset *P(NSString *title, NSString *ext, NSString *muxer, FFFormatKind kind,
                  NSString *vcodec, NSString *acodec, NSString *note) {
    FFPreset *p = [FFPreset new];
    p.title = title;
    p.ext = ext;
    p.muxer = muxer;
    p.kind = kind;
    p.videoCodec = vcodec;
    p.audioCodec = acodec;
    p.note = note;
    return p;
}

@implementation FFPresets

// 说明：预编译的 FFmpeg 是 LGPL 构建，不含 x264 / x265 / libmp3lame / libvpx / libopus。
// 因此视频编码主力是 Apple 硬件编码器（h264_videotoolbox / hevc_videotoolbox）与 mpeg4，
// 音频编码主力是 aac / alac / flac / pcm / mp2。解码侧则覆盖 FFmpeg 支持的全部格式。
+ (NSArray<FFPreset *> *)presetsForKind:(FFFormatKind)kind {
    switch (kind) {
        case FFFormatKindVideo:
            return @[
                P(@"MP4 · H.264（最通用）", @"mp4", @"mp4",   FFFormatKindVideo, @"h264_videotoolbox", @"aac",       @"硬件编码，速度快"),
                P(@"MP4 · H.265（更省空间）", @"mp4", @"mp4",  FFFormatKindVideo, @"hevc_videotoolbox", @"aac",       @"A9 及以上机型支持"),
                P(@"MOV · H.264（苹果原生）", @"mov", @"mov",  FFFormatKindVideo, @"h264_videotoolbox", @"aac",       nil),
                P(@"Matroska · H.264",       @"mkv", @"matroska", FFFormatKindVideo, @"h264_videotoolbox", @"aac",    nil),
                P(@"AVI · MPEG-4",           @"avi", @"avi",  FFFormatKindVideo, @"mpeg4",             @"mp2",       @"老设备兼容"),
                P(@"MPEG-TS 流媒体",          @"ts",  @"mpegts", FFFormatKindVideo, @"h264_videotoolbox", @"aac",     nil),
                P(@"3GP（彩铃/老手机）",       @"3gp", @"mov",  FFFormatKindVideo, @"mpeg4",             @"aac",       nil),
                P(@"GIF 动图",               @"gif", @"gif",  FFFormatKindVideo, @"gif",               nil,         @"自动去音轨、限帧率"),
                P(@"无损直通（仅换容器）",     @"mp4", @"mp4",  FFFormatKindVideo, @"copy",              @"copy",      @"最快，不重编码；源编码需兼容目标容器"),
            ];
        case FFFormatKindAudio:
            return @[
                P(@"AAC / M4A",   @"m4a",  @"ipod",   FFFormatKindAudio, nil, @"aac",       @"体积小，通用"),
                P(@"MP4 音轨",     @"m4a",  @"mp4",    FFFormatKindAudio, nil, @"aac",       nil),
                P(@"ALAC 无损",    @"m4a",  @"ipod",   FFFormatKindAudio, nil, @"alac",      @"苹果无损"),
                P(@"FLAC 无损",    @"flac", @"flac",   FFFormatKindAudio, nil, @"flac",      nil),
                P(@"WAV 未压缩",   @"wav",  @"wav",    FFFormatKindAudio, nil, @"pcm_s16le", @"体积大"),
                P(@"MP2（兼容 MP3 容器）", @"mp3", @"mp3", FFFormatKindAudio, nil, @"mp2",   @"LGPL 构建不含 LAME，无法生成真正的 MP3"),
                P(@"Ogg Vorbis",   @"ogg",  @"ogg",    FFFormatKindAudio, nil, @"vorbis",    @"需 FFmpeg 构建启用原生 Vorbis 编码器"),
                P(@"直通提取音轨",  @"m4a",  @"ipod",   FFFormatKindAudio, nil, @"copy",      @"不重编码，直接抠出原音轨"),
            ];
        case FFFormatKindImage:
            return @[
                P(@"JPEG",     @"jpg", @"image2", FFFormatKindImage, @"mjpeg",   nil, nil),
                P(@"PNG",      @"png", @"image2", FFFormatKindImage, @"png",     nil, nil),
                P(@"BMP",      @"bmp", @"image2", FFFormatKindImage, @"bmp",     nil, nil),
                P(@"GIF",      @"gif", @"image2", FFFormatKindImage, @"gif",     nil, nil),
                P(@"单帧（取视频某一帧）", @"jpg", @"image2", FFFormatKindImage, @"mjpeg", nil, @"配合「起始时间」使用"),
            ];
    }
    return @[];
}

+ (FFFormatKind)kindOfPath:(NSString *)path {
    static NSSet *video, *audio, *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        video = [NSSet setWithArray:@[@"mp4", @"m4v", @"mov", @"mkv", @"avi", @"flv", @"wmv",
                                      @"webm", @"ts", @"mts", @"3gp", @"3g2", @"mpg", @"mpeg",
                                      @"vob", @"ogv", @"rm", @"rmvb", @"asf", @"f4v", @"divx", @"gif"]];
        audio = [NSSet setWithArray:@[@"mp3", @"aac", @"m4a", @"wav", @"flac", @"ogg", @"oga",
                                      @"opus", @"wma", @"aiff", @"aif", @"alac", @"amr", @"mka",
                                      @"m4b", @"ac3", @"ape", @"wv", @"dts"]];
        image = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"bmp", @"gif", @"webp", @"tif",
                                      @"tiff", @"tga", @"ppm", @"pgm", @"heic", @"heif", @"jp2"]];
    });
    NSString *ext = path.pathExtension.lowercaseString;
    if ([video containsObject:ext]) return FFFormatKindVideo;
    if ([audio containsObject:ext]) return FFFormatKindAudio;
    if ([image containsObject:ext]) return FFFormatKindImage;
    return FFFormatKindVideo; // 未知容器按视频处理，交给 FFmpeg 自己判断
}

@end
