// FFEngine.m —— FFmpeg libav* 引擎实现（探测 / 转码 / 剪辑）
//
// 执行路径：
//   1. 直通 remux（视频、音频都 copy 且无剪辑/缩放）：不解码，只换容器，秒级完成。
//   2. 重编码管线：解封装 →（关键帧 seek）→ 解码 → libavfilter（fps/scale/transpose/调色板）
//      → 编码（优先 VideoToolbox 硬编，按候选列表自动回退）→ 混流。
//
// 兼容 FFmpeg 4/5/6：channel layout 新旧 API 用版本宏分支。
#import "FFEngine.h"
#import <inttypes.h>

#ifdef __cplusplus
extern "C" {
#endif
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavutil/opt.h>
#include <libavutil/imgutils.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mathematics.h>
#include <libavutil/version.h>
#include <libavutil/utils.h>
#include <libavutil/dict.h>
#ifdef __cplusplus
}
#endif

// ch_layout 新 API 自 avutil 57.28.100（FFmpeg 5.1）引入
#define USE_NEW_CHAPI (LIBAVUTIL_VERSION_INT >= AV_VERSION_INT(57, 28, 100))

NSString *const FFEngineErrorDomain = @"com.formatmaster.ffengine";

static NSError *FErr(NSInteger code, NSString *msg) {
    return [NSError errorWithDomain:FFEngineErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static NSString *avErrToStr(int err) {
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    if (av_strerror(err, buf, sizeof(buf)) == 0) return [NSString stringWithUTF8String:buf];
    return [NSString stringWithFormat:@"AVError %d", err];
}

@implementation FFRequest
- (instancetype)init {
    if ((self = [super init])) { _start = -1; _duration = -1; }
    return self;
}
@end

// ---------------------------------------------------------------------------
// FFEngine：路径工具与能力查询
// ---------------------------------------------------------------------------

@implementation FFEngine

+ (NSString *)outputDir {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *out = [docs stringByAppendingPathComponent:@"Output"];
    [[NSFileManager defaultManager] createDirectoryAtPath:out
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return out;
}

+ (NSString *)tempDir {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"fm_in"];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmp
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return tmp;
}

+ (NSString *)ffmpegVersion {
    return [NSString stringWithUTF8String:av_version_info() ?: "unknown"];
}

+ (NSInteger)decoderCount {
    void *op = NULL;
    NSInteger n = 0;
    const AVCodec *c;
    while ((c = av_codec_iterate(&op)) != NULL) { if (av_codec_is_decoder(c)) n++; }
    return n;
}

+ (NSString *)stageInputFromURL:(NSURL *)url error:(NSError **)error {
    if (![url isFileURL]) {
        if (error) *error = FErr(1, @"只支持本地文件");
        return nil;
    }
    NSString *src = url.path;
    if (![NSFileManager.defaultManager fileExistsAtPath:src]) {
        if (error) *error = FErr(2, [NSString stringWithFormat:@"文件不存在：%@", src]);
        return nil;
    }
    // 「文件」App 的 URL 带安全作用域，FFmpeg 直接 fopen 在部分 iOS 版本会被拒，拷进 tmp 最稳。
    NSString *dst = [NSTemporaryDirectory() stringByAppendingPathComponent:url.lastPathComponent];
    if ([src isEqualToString:dst]) return dst;
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:dst]) [fm removeItemAtPath:dst error:nil];
    if (![fm copyItemAtPath:src toPath:dst error:error]) return nil;
    return dst;
}

+ (BOOL)encoderAvailable:(NSString *)name {
    return avcodec_find_encoder_by_name(name.UTF8String) != NULL;
}

// ---------------------------------------------------------------------------
// probe
// ---------------------------------------------------------------------------

+ (NSDictionary *)probeFile:(NSString *)path error:(NSError **)error {
    AVFormatContext *fmt = NULL;
    int ret = avformat_open_input(&fmt, path.UTF8String, NULL, NULL);
    if (ret < 0) {
        if (error) *error = FErr(10, [NSString stringWithFormat:@"无法打开文件：%@", avErrToStr(ret)]);
        return nil;
    }
    if (avformat_find_stream_info(fmt, NULL) < 0) {
        avformat_close_input(&fmt);
        if (error) *error = FErr(11, @"无法读取流信息（文件可能损坏）");
        return nil;
    }

    NSMutableArray *streams = [NSMutableArray array];
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVStream *st = fmt->streams[i];
        AVCodecParameters *par = st->codecpar;
        if (!par) continue;
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"index"] = @(i);
        d[@"type"] = (par->codec_type == AVMEDIA_TYPE_VIDEO) ? @"视频"
                   : (par->codec_type == AVMEDIA_TYPE_AUDIO) ? @"音频"
                   : (par->codec_type == AVMEDIA_TYPE_SUBTITLE) ? @"字幕" : @"数据";
        const AVCodec *c = avcodec_find_decoder(par->codec_id);
        d[@"codec"] = c ? [NSString stringWithUTF8String:c->name] : @"unknown";
        if (par->codec_type == AVMEDIA_TYPE_VIDEO) {
            d[@"width"] = @(par->width);
            d[@"height"] = @(par->height);
            if (st->avg_frame_rate.num > 0) d[@"fps"] = @(av_q2d(st->avg_frame_rate));
            const char *pf = av_get_pix_fmt_name((AVPixelFormat)par->format);
            d[@"pix_fmt"] = [NSString stringWithUTF8String:pf ?: "unknown"];
        } else if (par->codec_type == AVMEDIA_TYPE_AUDIO) {
            d[@"sample_rate"] = @(par->sample_rate);
#if USE_NEW_CHAPI
            d[@"channels"] = @(par->ch_layout.nb_channels);
#else
            d[@"channels"] = @(par->channels);
#endif
            const char *sf = av_get_sample_fmt_name((AVSampleFormat)par->format);
            d[@"fmt"] = [NSString stringWithUTF8String:sf ?: "unknown"];
        }
        if (st->duration > 0 && st->time_base.den > 0)
            d[@"duration"] = @(av_q2d(st->time_base) * (double)st->duration);
        if (st->bit_rate > 0) d[@"bit_rate"] = @(st->bit_rate);
        [streams addObject:d];
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"format_name"] = fmt->iformat && fmt->iformat->name
        ? [NSString stringWithUTF8String:fmt->iformat->name] : @"?";
    if (fmt->duration > 0) out[@"duration"] = @((double)fmt->duration / AV_TIME_BASE);
    if (fmt->bit_rate > 0) out[@"bit_rate"] = @(fmt->bit_rate);
    out[@"streams"] = streams;

    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    if (fmt->metadata) {
        AVDictionaryEntry *e = NULL;
        while ((e = av_dict_get(fmt->metadata, "", e, AV_DICT_IGNORE_SUFFIX)))
            meta[[NSString stringWithUTF8String:e->key]] = [NSString stringWithUTF8String:e->value];
    }
    out[@"metadata"] = meta;

    avformat_close_input(&fmt);
    return out;
}

// ---------------------------------------------------------------------------
// 内部类型
// ---------------------------------------------------------------------------
typedef struct {
    double        totalDur;     // 输入总时长（秒），<=0 未知
    double        trimStart;    // 精确丢弃起点（秒）
    double        endSec;       // 结束秒（trimStart+duration），0 表示到文件尾
    BOOL          gif;
    BOOL          still;
    BOOL          seeked;       // 已执行输入 seek
    int64_t       seekTargetUs; // AV_TIME_BASE 微秒
    double        videoFps;     // 视频路实际帧率，供无 pts 兜底
    double        baseSec;      // 首个保留帧的秒，用于把时间戳归零
    BOOL          baseSet;      // baseSec 是否已设定
    double        lastProgress;
    volatile BOOL cancel;
    FFProgressBlock progress;
} RunState;

typedef struct {
    int              inIndex;    // 输入流序号；-1 不启用
    AVStream        *inStream;
    AVCodecContext  *dec;
    AVStream        *outStream;
    AVCodecContext  *enc;
    AVFilterGraph   *graph;
    AVFilterContext *src;
    AVFilterContext *sink;
    AVRational       sinkTb;     // 滤镜输出时间基
    int64_t          nextOutPts;  // 源侧帧计数兜底
    int64_t          lastOutPts;  // 输出侧单调递增时间戳
    BOOL             copy;
} FFTrack;

static void track_free(FFTrack *t) {
    if (t->graph) avfilter_graph_free(&t->graph);
    if (t->dec) avcodec_free_context(&t->dec);
    if (t->enc) avcodec_free_context(&t->enc);
    memset(t, 0, sizeof(*t));
    t->inIndex = -1;
}

static void tick_progress(RunState *st, double curSec) {
    if (!st->progress || st->totalDur <= 0) return;
    double p = MIN(0.995, MAX(0, curSec / st->totalDur));
    if (p - st->lastProgress >= 0.01 || p >= 0.995) {
        st->lastProgress = p;
        if (!st->progress(p, @"处理中")) st->cancel = YES;
    }
}

// ---------------------------------------------------------------------------
// 滤镜图
// ---------------------------------------------------------------------------

// buffersrc 参数串（描述"源帧"，不是滤镜链）
static NSString *video_src_args(AVCodecContext *dec, AVRational tb, double fps) {
    double fr = fps > 0 ? fps : (tb.num > 0 && tb.den > 0 ? 1.0 * tb.den / tb.num : 0);
    if (!(fr > 0) || fr > 1000) fr = 25.0;
    return [NSString stringWithFormat:
            @"video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=1/1:frame_rate=%d/1",
            dec->width, dec->height, dec->pix_fmt,
            tb.den > 0 ? tb.den : 1, tb.num > 0 ? tb.num : 1, (int)lround(fr)];
}

static NSString *audio_src_args(AVCodecContext *dec, AVRational tb) {
    int rate = dec->sample_rate > 0 ? dec->sample_rate : 44100;
    NSString *tbStr = [NSString stringWithFormat:@"time_base=%d/%d",
                       tb.den > 0 ? tb.den : 1, tb.num > 0 ? tb.num : 1];
#if USE_NEW_CHAPI
    char buf[128] = {0};
    NSString *ch = (av_channel_layout_describe(&dec->ch_layout, buf, sizeof(buf)) > 0)
                   ? [NSString stringWithUTF8String:buf] : @"stereo";
    return [NSString stringWithFormat:@"%@:sample_rate=%d:sample_fmt=%d:channel_layout=%@",
            tbStr, rate, dec->sample_fmt, ch];
#else
    NSString *layout;
    if (dec->channel_layout) {
        char buf[64] = {0};
        snprintf(buf, sizeof(buf), "0x%" PRIx64, (uint64_t)dec->channel_layout);
        layout = [NSString stringWithFormat:@"channel_layout=%s", buf];
    } else {
        layout = [NSString stringWithFormat:@"channels=%d", dec->channels];
    }
    return [NSString stringWithFormat:@"%@:sample_rate=%d:sample_fmt=%d:%@",
            tbStr, rate, dec->sample_fmt, layout];
#endif
}

// 建 graph：buffersrc(args) → chain → buffersink
static int build_graph(FFTrack *t, BOOL isVideo, NSString *args, NSString *chain, NSError **err) {
    const AVFilter *vf = avfilter_get_by_name(isVideo ? "buffer" : "abuffer");
    const AVFilter *vs = avfilter_get_by_name(isVideo ? "buffersink" : "abuffersink");
    if (!vf || !vs) {
        if (err) *err = FErr(30, @"FFmpeg 构建缺少 buffer/abuffer 滤镜");
        return -1;
    }
    AVFilterGraph *graph = avfilter_graph_alloc();
    graph->nb_threads = 2;

    AVFilterContext *sink = NULL, *src = NULL;
    int ret = avfilter_graph_create_filter(&sink, vs, "out", NULL, NULL, graph);
    if (ret < 0) { avfilter_graph_free(&graph);
        if (err) *err = FErr(32, [NSString stringWithFormat:@"buffersink 失败：%@", avErrToStr(ret)]);
        return -1; }
    ret = avfilter_graph_create_filter(&src, vf, "in", args.UTF8String, NULL, graph);
    if (ret < 0) { avfilter_graph_free(&graph);
        if (err) *err = FErr(31, [NSString stringWithFormat:@"buffersrc 参数不被接受：%@（%@）",
                                  avErrToStr(ret), args]);
        return -1; }

    AVFilterInOut *outputs = avfilter_inout_alloc();
    AVFilterInOut *inputs = avfilter_inout_alloc();
    outputs->name = av_strdup("in");  outputs->filter_ctx = src;  outputs->pad_idx = 0; outputs->next = NULL;
    inputs->name  = av_strdup("out"); inputs->filter_ctx  = sink; inputs->pad_idx  = 0; inputs->next  = NULL;

    ret = avfilter_graph_parse_ptr(graph, chain.UTF8String, &inputs, &outputs, NULL);
    avfilter_inout_free(&inputs);
    avfilter_inout_free(&outputs);
    if (ret < 0) { avfilter_graph_free(&graph);
        if (err) *err = FErr(34, [NSString stringWithFormat:@"滤镜链解析失败：%@（链：%@）",
                                  avErrToStr(ret), chain]);
        return -1; }
    if (avfilter_graph_config(graph, NULL) < 0) { avfilter_graph_free(&graph);
        if (err) *err = FErr(35, @"滤镜图配置失败");
        return -1; }
    t->graph = graph; t->src = src; t->sink = sink;
    return 0;
}

// 视频链：fps → scale → transpose →（GIF 调色板 | 最终像素格式）
static NSString *video_chain(FFRequest *req, BOOL gif, NSString *finalFmt) {
    NSMutableArray *parts = [NSMutableArray array];
    if (req.fps > 0) [parts addObject:[NSString stringWithFormat:@"fps=%.6f", req.fps]];
    switch (req.rotate) {
        case 90:  [parts addObject:@"transpose=1"]; break;
        case 180: [parts addObject:@"transpose=2,transpose=2"]; break;
        case 270: [parts addObject:@"transpose=2"]; break;
        default: break;
    }
    if (req.padWidth > 0 && req.padHeight > 0) {
        // 等比缩放进画布再居中补黑边：多段分辨率不一致时保证输出尺寸统一
        [parts addObject:[NSString stringWithFormat:
            @"scale=%d:%d:force_original_aspect_ratio=decrease:flags=lanczos,"
            @"pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=black",
            req.padWidth, req.padHeight, req.padWidth, req.padHeight]];
    } else if (req.width > 0 || req.height > 0) {
        NSString *w = req.width  > 0 ? [NSString stringWithFormat:@"%d", req.width]  : @"-2";
        NSString *h = req.height > 0 ? [NSString stringWithFormat:@"%d", req.height] : @"-2";
        [parts addObject:[NSString stringWithFormat:@"scale=%@:%@:flags=lanczos", w, h]];
    }
    NSString *base = [parts componentsJoinedByString:@","];
    if (gif) {
        NSString *head = base.length ? [base stringByAppendingString:@","] : @"";
        return [NSString stringWithFormat:
                @"%@format=rgb24,split[s0][s1];[s1]palettegen[p];[s0][p]paletteuse", head];
    }
    if (base.length) return [NSString stringWithFormat:@"%@,format=%@", base, finalFmt];
    return [NSString stringWithFormat:@"format=%@", finalFmt];
}

// ---------------------------------------------------------------------------
// 编码器选择与准备
// ---------------------------------------------------------------------------

static const AVCodec *pick_encoder(NSString *spec, enum AVMediaType type, NSString **outName) {
    for (NSString *raw in [spec componentsSeparatedByString:@","]) {
        NSString *n = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!n.length) continue;
        const AVCodec *c = avcodec_find_encoder_by_name(n.UTF8String);
        if (c) { if (outName) *outName = n; return c; }
    }
    // 按 codec id 兜底
    enum AVCodecID id = AV_CODEC_ID_NONE;
    if (type == AVMEDIA_TYPE_VIDEO) {
        if ([spec hasPrefix:@"h264"]) id = AV_CODEC_ID_H264;
        else if ([spec hasPrefix:@"hevc"]) id = AV_CODEC_ID_HEVC;
        else if ([spec hasPrefix:@"mpeg4"]) id = AV_CODEC_ID_MPEG4;
    } else if (type == AVMEDIA_TYPE_AUDIO) {
        if ([spec hasPrefix:@"aac"]) id = AV_CODEC_ID_AAC;
        else if ([spec hasPrefix:@"flac"]) id = AV_CODEC_ID_FLAC;
    }
    const AVCodec *c = id != AV_CODEC_ID_NONE ? avcodec_find_encoder(id) : NULL;
    if (c && outName) *outName = [NSString stringWithUTF8String:c->name];
    return c;
}

static NSString *defaultVideoCodecSpec(FFRequest *req) {
    if (req.videoCodec.length) return req.videoCodec;
    NSString *m = req.muxerName ?: @"";
    if ([m isEqualToString:@"gif"]) return @"gif";
    if ([m isEqualToString:@"image2"]) {
        NSString *ext = req.outputPath.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"png"]) return @"png";
        if ([ext isEqualToString:@"bmp"]) return @"bmp";
        return @"mjpeg";
    }
    return @"h264_videotoolbox,mpeg4";
}

static NSString *defaultAudioCodecSpec(FFRequest *req) {
    if (req.audioCodec.length) return req.audioCodec;
    return @"aac";
}

// 视频路准备：解码器 + 输出流 + 编码器 + 滤镜图
static BOOL prepare_video_track(AVFormatContext *in, AVFormatContext *out, FFTrack *t,
                                FFRequest *req, RunState *st, NSError **err) {
    AVStream *ist = in->streams[t->inIndex];
    t->inStream = ist;

    const AVCodec *dc = avcodec_find_decoder(ist->codecpar->codec_id);
    if (!dc) { if (err) *err = FErr(50, @"输入视频编码不支持解码（FFmpeg 构建不含该解码器）"); return NO; }
    t->dec = avcodec_alloc_context3(dc);
    if (!t->dec || avcodec_parameters_to_context(t->dec, ist->codecpar) < 0) {
        if (err) *err = FErr(51, @"创建解码上下文失败"); return NO; }
    t->dec->thread_count = 2;
    if (avcodec_open2(t->dec, dc, NULL) < 0) {
        if (err) *err = FErr(52, [NSString stringWithFormat:@"打开解码器失败：%@",
                                  [NSString stringWithUTF8String:dc->name]]); return NO; }

    if (t->copy) {
        t->outStream = avformat_new_stream(out, NULL);
        if (!t->outStream) { if (err) *err = FErr(53, @"创建输出流失败"); return NO; }
        if (avcodec_parameters_copy(t->outStream->codecpar, ist->codecpar) < 0) {
            if (err) *err = FErr(53, @"复制流参数失败"); return NO; }
        t->outStream->time_base = ist->time_base;
        return YES;
    }

    // 输出尺寸：等比缩放（height 视为长边上限），再按 transpose 交换
    int srcW = t->dec->width, srcH = t->dec->height;
    int ow, oh;
    if (req.padWidth > 0 && req.padHeight > 0) {
        ow = req.padWidth; oh = req.padHeight;   // 滤镜已 scale+pad 到该画布
    } else if (req.width > 0 && srcW > 0) {
        ow = req.width;
        oh = (int)lround((double)srcH * ow / srcW);
    } else if (req.height > 0 && srcW > 0 && srcH > 0) {
        double scale = fmin(1.0, (double)req.height / fmax(srcW, srcH));
        ow = (int)lround(srcW * scale);
        oh = (int)lround(srcH * scale);
    } else {
        ow = srcW; oh = srcH;
    }
    if (req.rotate == 90 || req.rotate == 270) { int tmp = ow; ow = oh; oh = tmp; }
    if (ow <= 0 || oh <= 0) { if (err) *err = FErr(54, @"无法确定输出分辨率"); return NO; }
    ow &= ~1; oh &= ~1; // 偶数
    if (st->gif && ow > 480) { oh = (int)((double)oh * 480 / ow) & ~1; ow = 480; }

    double fps = req.fps;
    if (st->gif && fps <= 0) fps = 15;
    if (fps <= 0 && ist->avg_frame_rate.num > 0) fps = av_q2d(ist->avg_frame_rate);
    if (fps <= 0 || fps > 240) fps = 25;
    st->videoFps = fps;

    NSString *encName = nil;
    NSString *spec = defaultVideoCodecSpec(req);
    const AVCodec *ec = pick_encoder(spec, AVMEDIA_TYPE_VIDEO, &encName);
    if (!ec) { if (err) *err = FErr(55, [NSString stringWithFormat:@"当前 FFmpeg 构建没有可用视频编码器（%@）", spec]); return NO; }

    t->outStream = avformat_new_stream(out, ec);
    if (!t->outStream) { if (err) *err = FErr(53, @"创建输出流失败"); return NO; }

    t->enc = avcodec_alloc_context3(ec);
    t->enc->width = ow;
    t->enc->height = oh;
    t->enc->sample_aspect_ratio = (AVRational){1, 1};
    t->enc->pix_fmt = st->gif ? AV_PIX_FMT_PAL8 : AV_PIX_FMT_YUV420P;
    if ([encName isEqualToString:@"png"])  t->enc->pix_fmt = AV_PIX_FMT_RGB24;
    if ([encName isEqualToString:@"bmp"])  t->enc->pix_fmt = AV_PIX_FMT_BGR24;
    if ([encName isEqualToString:@"mjpeg"]) t->enc->pix_fmt = AV_PIX_FMT_YUVJ420P;
    t->enc->framerate = (AVRational){(int)lround(fps), 1};
    t->enc->time_base = (AVRational){1, (int)lround(fps)};
    t->outStream->time_base = t->enc->time_base;
    int64_t br = req.videoBitrate > 0 ? req.videoBitrate : (st->gif || st->still ? 0 : 4000000);
    if (br > 0) t->enc->bit_rate = br;
    t->enc->gop_size = 60;
    t->enc->max_b_frames = 0; // 硬编与低内存场景更稳
    if (out->oformat->flags & AVFMT_GLOBALHEADER)
        t->enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;

    // 滤镜图（fps 决定 CFR；最终 format 与编码器 pix_fmt 对齐）
    NSString *finalFmt = av_get_pix_fmt_name(t->enc->pix_fmt) ?: "yuv420p";
    NSString *args = video_src_args(t->dec, ist->time_base, fps);
    NSString *chain = video_chain(req, st->gif, finalFmt);
    if (build_graph(t, YES, args, chain, err) < 0) return NO;
    t->sinkTb = av_buffersink_get_time_base(t->sink);

    if (avcodec_open2(t->enc, ec, NULL) < 0) {
        if (err) *err = FErr(56, [NSString stringWithFormat:@"打开视频编码器失败：%@（可能不支持当前分辨率）", encName]);
        return NO;
    }
    if (avcodec_parameters_from_context(t->outStream->codecpar, t->enc) < 0) {
        if (err) *err = FErr(57, @"同步输出流参数失败"); return NO; }
    return YES;
}

// 音频路准备
static BOOL prepare_audio_track(AVFormatContext *in, AVFormatContext *out, FFTrack *t,
                                FFRequest *req, NSError **err) {
    AVStream *ist = in->streams[t->inIndex];
    t->inStream = ist;

    const AVCodec *dc = avcodec_find_decoder(ist->codecpar->codec_id);
    if (!dc) { if (err) *err = FErr(50, @"输入音频编码不支持解码"); return NO; }
    t->dec = avcodec_alloc_context3(dc);
    if (!t->dec || avcodec_parameters_to_context(t->dec, ist->codecpar) < 0) {
        if (err) *err = FErr(51, @"创建音频解码上下文失败"); return NO; }
    if (avcodec_open2(t->dec, dc, NULL) < 0) {
        if (err) *err = FErr(52, @"打开音频解码器失败"); return NO; }

    if (t->copy) {
        t->outStream = avformat_new_stream(out, NULL);
        if (!t->outStream) { if (err) *err = FErr(53, @"创建输出流失败"); return NO; }
        if (avcodec_parameters_copy(t->outStream->codecpar, ist->codecpar) < 0) {
            if (err) *err = FErr(53, @"复制流参数失败"); return NO; }
        t->outStream->time_base = ist->time_base;
        return YES;
    }

    NSString *encName = nil;
    NSString *spec = defaultAudioCodecSpec(req);
    const AVCodec *ec = pick_encoder(spec, AVMEDIA_TYPE_AUDIO, &encName);
    if (!ec) { if (err) *err = FErr(58, [NSString stringWithFormat:@"当前 FFmpeg 构建没有可用音频编码器（%@）", spec]); return NO; }

    t->outStream = avformat_new_stream(out, ec);
    if (!t->outStream) { if (err) *err = FErr(53, @"创建输出流失败"); return NO; }

    t->enc = avcodec_alloc_context3(ec);
    t->enc->sample_rate = req.sampleRate > 0 ? req.sampleRate
                        : (t->dec->sample_rate > 0 ? t->dec->sample_rate : 44100);
    t->enc->sample_fmt = ec->sample_fmts ? ec->sample_fmts[0] : AV_SAMPLE_FMT_FLTP;
    t->enc->bit_rate = req.audioBitrate > 0 ? req.audioBitrate : 128000;
    t->enc->time_base = (AVRational){1, t->enc->sample_rate};
    t->outStream->time_base = t->enc->time_base;
#if USE_NEW_CHAPI
    av_channel_layout_default(&t->enc->ch_layout,
                              t->dec->ch_layout.nb_channels > 0 ? t->dec->ch_layout.nb_channels : 2);
    if (t->enc->ch_layout.nb_channels > 2) av_channel_layout_default(&t->enc->ch_layout, 2);
#else
    t->enc->channels = t->dec->channels > 0 ? t->dec->channels : 2;
    if (t->enc->channels > 2) t->enc->channels = 2;
    t->enc->channel_layout = t->enc->channels == 1 ? AV_CH_LAYOUT_MONO : AV_CH_LAYOUT_STEREO;
#endif
    if (out->oformat->flags & AVFMT_GLOBALHEADER)
        t->enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;

    // aformat 与编码器要求对齐 + aresample 完成声道/格式转换
    const char *sf = av_get_sample_fmt_name(t->enc->sample_fmt) ?: "fltp";
    NSString *chain = [NSString stringWithFormat:
                       @"aformat=sample_fmts=%s:sample_rates=%d,aresample=async=1",
                       sf, t->enc->sample_rate];
    if (build_graph(t, NO, audio_src_args(t->dec, ist->time_base), chain, err) < 0) return NO;
    t->sinkTb = av_buffersink_get_time_base(t->sink);

    if (avcodec_open2(t->enc, ec, NULL) < 0) {
        if (err) *err = FErr(59, [NSString stringWithFormat:@"打开音频编码器失败：%@", encName]);
        return NO;
    }
    if (avcodec_parameters_from_context(t->outStream->codecpar, t->enc) < 0) {
        if (err) *err = FErr(57, @"同步输出流参数失败"); return NO; }
    return YES;
}

// ---------------------------------------------------------------------------
// 帧 → 滤镜 → 编码 → 写出
// ---------------------------------------------------------------------------

static int encode_and_write(FFTrack *t, AVFormatContext *out, AVFrame *frame, NSError **err) {
    if (frame) {
        int64_t ptsOut;
        if (frame->pts != AV_NOPTS_VALUE)
            ptsOut = av_rescale_q(frame->pts, t->sinkTb, t->enc->time_base);
        else
            ptsOut = t->lastOutPts + 1;
        if (ptsOut <= t->lastOutPts) ptsOut = t->lastOutPts + 1; // 保证严格递增
        frame->pts = ptsOut;
        frame->pkt_dts = AV_NOPTS_VALUE;
        t->lastOutPts = ptsOut;
    }
    int ret = avcodec_send_frame(t->enc, frame);
    if (ret < 0 && ret != AVERROR(EAGAIN)) {
        if (err) *err = FErr(60, [NSString stringWithFormat:@"送帧给编码器失败：%@", avErrToStr(ret)]);
        return ret;
    }
    AVPacket *op = av_packet_alloc();
    while (avcodec_receive_packet(t->enc, op) == 0) {
        op->stream_index = t->outStream->index;
        av_packet_rescale_ts(op, t->enc->time_base, t->outStream->time_base);
        if (av_interleaved_write_frame(out, op) < 0) {
            av_packet_free(&op);
            if (err) *err = FErr(61, @"写出编码包失败");
            return -1;
        }
    }
    av_packet_free(&op);
    return 0;
}

// 从滤镜 sink 取帧并编码写出；frame==NULL 表示滤镜 flush
static int drain_filter_encode(FFTrack *t, AVFormatContext *out, RunState *st, NSError **err) {
    AVFrame *of = av_frame_alloc();
    while (!st->cancel) {
        int r = av_buffersink_get_frame_flags(t->sink, of, 0);
        if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) break;
        if (r < 0) break; // 滤镜耗尽或异常：结束本轮
        if (encode_and_write(t, out, of, err) < 0) { av_frame_free(&of); return -1; }
        av_frame_unref(of);
    }
    av_frame_free(&of);
    return st->cancel ? -2 : 0;
}

// 解出所有可用帧 → 推滤镜（含裁剪丢弃逻辑）
static int pump_decoder(FFTrack *t, AVFormatContext *in, AVFormatContext *out,
                        FFRequest *req, RunState *st, BOOL *done, NSError **err) {
    AVFrame *f = av_frame_alloc();
    int ret;
    while ((ret = avcodec_receive_frame(t->dec, f)) == 0) {
        // 计算帧秒：解码输出 pts 位于输入流 time_base
        double sec = -1;
        if (f->pts != AV_NOPTS_VALUE && t->inStream->time_base.den > 0)
            sec = av_q2d(t->inStream->time_base) * (double)f->pts;
        if (sec < 0) {
            // 无 pts：按已输出帧数 ÷ 帧率估算（CFR 场景下近似正确）
            double fpsEst = (req.fps > 0) ? req.fps : (st->videoFps > 0 ? st->videoFps : 25.0);
            sec = (double)t->nextOutPts / fpsEst;
        }
        t->nextOutPts++;

        BOOL keep = YES;
        if (st->trimStart > 0 && sec < st->trimStart - 0.02) keep = NO;
        if (st->endSec > 0 && sec >= st->endSec) { *done = YES; av_frame_free(&f); return 0; }

        tick_progress(st, sec);
        if (st->cancel) { av_frame_free(&f); return -2; }

        if (keep) {
            if (!st->baseSet) { st->baseSec = sec; st->baseSet = YES; }
            double rel = MAX(0, sec - st->baseSec);
            if (t->inStream->time_base.den > 0 && t->inStream->time_base.num > 0) {
                f->pts = (int64_t)llround(rel / av_q2d(t->inStream->time_base));
            } else {
                f->pts = AV_NOPTS_VALUE;
            }
            f->best_effort_timestamp = f->pts;
            if (av_buffersrc_add_frame_flags(t->src, f, AV_BUFFERSRC_FLAG_KEEP_REF) < 0) {
                av_frame_free(&f);
                if (err) *err = FErr(62, @"送帧进滤镜失败");
                return -1;
            }
            int r = drain_filter_encode(t, out, st, err);
            if (r != 0) { av_frame_free(&f); return r; }
            if (st->still) { *done = YES; av_frame_free(&f); return 0; }
        }
        av_frame_unref(f);
    }
    av_frame_free(&f);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) return 0;
    if (err) *err = FErr(63, [NSString stringWithFormat:@"解码失败：%@", avErrToStr(ret)]);
    return -1;
}

// 尾部 flush：解码器 → 滤镜 → 编码器 全部排空
static int flush_all(FFTrack *t, AVFormatContext *in, AVFormatContext *out,
                     FFRequest *req, RunState *st, NSError **err) {
    if (t->inIndex < 0) return 0;
    if (!t->copy) {
        avcodec_send_packet(t->dec, NULL);
        BOOL done = NO;
        if (pump_decoder(t, in, out, req, st, &done, err) == -2) return -2;
        // 滤镜 flush
        av_buffersrc_add_frame_flags(t->src, NULL, 0);
        if (drain_filter_encode(t, out, st, err) == -2) return -2;
        // 编码器 flush
        if (encode_and_write(t, out, NULL, err) < 0) return -1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// execute 主入口
// ---------------------------------------------------------------------------

+ (BOOL)execute:(FFRequest *)req progress:(FFProgressBlock)progress error:(NSError **)error {
    if (!req.inputPath.length || !req.outputPath.length) {
        if (error) *error = FErr(40, @"输入或输出路径为空");
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:req.inputPath]) {
        if (error) *error = FErr(41, @"输入文件不存在");
        return NO;
    }
    [fm removeItemAtPath:req.outputPath error:nil];

    AVFormatContext *in = NULL, *out = NULL;
    AVIOContext *avio = NULL;
    FFTrack vtr = {0}, atr = {0};
    vtr.inIndex = atr.inIndex = -1;
    BOOL ok = NO, wroteHeader = NO;
    NSError *stageErr = nil;
    RunState st = {0};
    st.progress = progress;
    st.gif = [req.muxerName isEqualToString:@"gif"];
    st.still = req.stillImage;
    st.trimStart = req.start > 0 ? req.start : 0;
    if (req.duration > 0) st.endSec = (req.start > 0 ? req.start : 0) + req.duration;

    // ---- 打开输入 ----
    // 合并列表：强制用 concat 解封装器，并关闭"只允许同目录"的安全限制
    const AVInputFormat *inFmt = NULL;
    AVDictionary *openOpts = NULL;
    if (req.inputFormatName.length) {
        inFmt = av_find_input_format(req.inputFormatName.UTF8String);
        if (!inFmt) {
            if (error) *error = FErr(42, [NSString stringWithFormat:@"当前 FFmpeg 构建没有 %@ 输入格式", req.inputFormatName]);
            goto cleanup;
        }
        if ([req.inputFormatName isEqualToString:@"concat"])
            av_dict_set(&openOpts, "safe", "0", 0);
    }
    if (avformat_open_input(&in, req.inputPath.UTF8String, inFmt, &openOpts) < 0) {
        av_dict_free(&openOpts);
        if (error) *error = FErr(42, @"无法打开输入（不支持该格式或文件损坏）");
        goto cleanup;
    }
    av_dict_free(&openOpts);
    if (avformat_find_stream_info(in, NULL) < 0) {
        if (error) *error = FErr(43, @"无法读取流信息");
        goto cleanup;
    }
    st.totalDur = in->duration > 0 ? (double)in->duration / AV_TIME_BASE : 0;
    if (req.durationHint > 0) st.totalDur = req.durationHint;
    if (st.totalDur <= 0) {
        for (unsigned i = 0; i < in->nb_streams; i++) {
            AVStream *s = in->streams[i];
            if (s->duration > 0 && s->time_base.den > 0)
                st.totalDur = MAX(st.totalDur, av_q2d(s->time_base) * (double)s->duration);
        }
    }

    for (unsigned i = 0; i < in->nb_streams; i++) {
        enum AVMediaType mt = in->streams[i]->codecpar->codec_type;
        if (vtr.inIndex < 0 && mt == AVMEDIA_TYPE_VIDEO && !req.audioOnly) vtr.inIndex = (int)i;
        if (atr.inIndex < 0 && mt == AVMEDIA_TYPE_AUDIO && !req.noAudio && !st.gif && !st.still) atr.inIndex = (int)i;
    }
    if (vtr.inIndex < 0 && atr.inIndex < 0) {
        if (error) *error = FErr(44, @"输入里没有可处理的视频或音频流");
        goto cleanup;
    }

    // ---- 输出容器 ----
    if (avformat_alloc_output_context2(&out, NULL,
            req.muxerName.length ? req.muxerName.UTF8String : NULL,
            req.outputPath.UTF8String) < 0 || !out) {
        if (error) *error = FErr(45, @"无法创建输出容器（检查目标格式）");
        goto cleanup;
    }

    // copy 直通仅在无任何编辑参数时启用
    {
        BOOL noEdit = !(req.start > 0 || req.duration > 0 || req.fps > 0 ||
                        req.width > 0 || req.height > 0 || req.rotate != 0 ||
                        st.gif || st.still);
        vtr.copy = noEdit && vtr.inIndex >= 0 && [req.videoCodec isEqualToString:@"copy"];
        atr.copy = noEdit && (atr.inIndex < 0 || [req.audioCodec isEqualToString:@"copy"]);
        if (vtr.copy && !vtr.outStream) { /* prepare 里创建 */ }
        // 直通要求源编码兼容目标容器；不兼容由写头失败兜底报错
    }

    if (vtr.inIndex >= 0 && !prepare_video_track(in, out, &vtr, req, &st, &stageErr)) {
        if (error) *error = stageErr; goto cleanup;
    }
    if (atr.inIndex >= 0 && !prepare_audio_track(in, out, &atr, req, &stageErr)) {
        if (error) *error = stageErr; goto cleanup;
    }
    if (!vtr.outStream && !atr.outStream) {
        if (error) *error = FErr(64, @"没有可用的输出流");
        goto cleanup;
    }

    if (!(out->oformat->flags & AVFMT_NOFILE)) {
        if (avio_open(&avio, req.outputPath.UTF8String, AVIO_FLAG_WRITE) < 0) {
            if (error) *error = FErr(46, @"无法创建输出文件（路径或权限问题）");
            goto cleanup;
        }
        out->pb = avio;
    }
    if (avformat_write_header(out, NULL) < 0) {
        if (error) *error = FErr(47, @"写容器头失败（源编码可能与目标容器不兼容，改用重编码）");
        goto cleanup;
    }
    wroteHeader = YES;

    // ---- 起点 seek ----
    if (st.trimStart > 0.05 && !vtr.copy && !atr.copy && st.totalDur > 0 &&
        st.trimStart < st.totalDur - 0.05) {
        st.seekTargetUs = (int64_t)(st.trimStart * AV_TIME_BASE);
        if (av_seek_frame(in, -1, st.seekTargetUs, AVSEEK_FLAG_BACKWARD) == 0) {
            st.seeked = YES;
            avcodec_flush_buffers(vtr.dec);
            if (atr.inIndex >= 0) avcodec_flush_buffers(atr.dec);
        }
    }

    // ---- 主循环 ----
    {
        AVPacket *pkt = av_packet_alloc();
        BOOL done = NO;
        while (!done && !st.cancel && av_read_frame(in, pkt) >= 0) {
            FFTrack *trk = (pkt->stream_index == vtr.inIndex) ? &vtr
                         : (pkt->stream_index == atr.inIndex) ? &atr : NULL;
            if (!trk) { av_packet_unref(pkt); continue; }

            if (trk->copy) {
                av_packet_rescale_ts(pkt, in->streams[pkt->stream_index]->time_base,
                                     trk->outStream->time_base);
                pkt->stream_index = trk->outStream->index;
                if (av_interleaved_write_frame(out, pkt) < 0) {
                    av_packet_unref(pkt); av_packet_free(&pkt);
                    if (error) *error = FErr(48, @"写入直通包失败");
                    goto cleanup;
                }
                if (st.progress && st.totalDur > 0 && pkt->pts != AV_NOPTS_VALUE) {
                    // 注：pts 已被 rescale 到输出 tb，用秒进度近似即可
                    tick_progress(&st, av_q2d(trk->outStream->time_base) * (double)pkt->pts);
                    if (st.cancel) { av_packet_unref(pkt); break; }
                }
            } else {
                // 送包：EAGAIN 表示解码器满，先抽干帧再重试一次，避免丢包
                int sret = avcodec_send_packet(trk->dec, pkt);
                if (sret == AVERROR(EAGAIN)) {
                    BOOL tmpDone = NO;
                    if (pump_decoder(trk, in, out, req, &st, &tmpDone, &stageErr) == -2) {
                        av_packet_unref(pkt); break;
                    }
                    sret = avcodec_send_packet(trk->dec, pkt);
                }
                if (sret < 0 && sret != AVERROR(EAGAIN)) {
                    av_packet_unref(pkt);
                    continue; // 坏包：跳过，不中断整个转换
                }
                BOOL frameDone = NO;
                int r = pump_decoder(trk, in, out, req, &st, &frameDone, &stageErr);
                if (r == -2) { av_packet_unref(pkt); break; } // 取消
                if (r < 0) { av_packet_unref(pkt); av_packet_free(&pkt);
                    if (error) *error = stageErr; goto cleanup; }
                if (frameDone) { done = YES; }
            }
            av_packet_unref(pkt);
        }
        av_packet_free(&pkt);

        if (st.cancel) {
            if (error) *error = FErr(49, @"已取消");
            goto cleanup;
        }

        int fr = flush_all(&vtr, in, out, req, &st, &stageErr);
        if (fr == -2) { if (error) *error = FErr(49, @"已取消"); goto cleanup; }
        if (fr < 0) { if (error) *error = stageErr; goto cleanup; }
        fr = flush_all(&atr, in, out, req, &st, &stageErr);
        if (fr == -2) { if (error) *error = FErr(49, @"已取消"); goto cleanup; }
        if (fr < 0) { if (error) *error = stageErr; goto cleanup; }
    }

    if (av_write_trailer(out) < 0) {
        if (error) *error = FErr(65, @"写容器尾失败");
        goto cleanup;
    }
    wroteHeader = NO;
    if (progress) progress(1.0, @"完成");
    ok = YES;
    if (error) *error = nil;

cleanup:
    if (avio) avio_closep(&avio);
    if (out) avformat_free_context(out);
    if (in) avformat_close_input(&in);
    track_free(&vtr);
    track_free(&atr);
    if (!ok) [NSFileManager.defaultManager removeItemAtPath:req.outputPath error:nil];
    return ok;
}

// ---------------------------------------------------------------------------
// 多段合并
// ---------------------------------------------------------------------------

+ (NSString *)writeConcatListForPaths:(NSArray<NSString *> *)paths error:(NSError **)error {
    if (paths.count == 0) { if (error) *error = FErr(70, @"没有要合并的文件"); return nil; }
    NSMutableString *s = [NSMutableString stringWithString:@"ffconcat version 1.0\n"];
    for (NSString *p in paths) {
        if (![NSFileManager.defaultManager fileExistsAtPath:p]) {
            if (error) *error = [NSError errorWithDomain:FFEngineErrorDomain code:71
                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"文件不存在：%@", p.lastPathComponent]}];
            return nil;
        }
        // concat 列表里单引号需用 '\'' 转义
        NSString *esc = [p stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
        [s appendFormat:@"file '%@'\n", esc];
    }
    NSString *list = [[self tempDir] stringByAppendingPathComponent:
        [NSString stringWithFormat:@"merge_%u.ffconcat", (unsigned)(NSDate.date.timeIntervalSince1970 % 1000000)]];
    NSError *werr = nil;
    if (![s writeToFile:list atomically:YES encoding:NSUTF8StringEncoding error:&werr]) {
        if (error) *error = werr; return nil;
    }
    return list;
}

+ (BOOL)concatFiles:(NSArray<NSString *> *)paths
             toFile:(NSString *)outputPath
            request:(FFRequest *)baseReq
           progress:(FFProgressBlock)progress
              error:(NSError **)error {
    if (paths.count == 0) { if (error) *error = FErr(70, @"没有要合并的文件"); return NO; }

    int maxW = 0, maxH = 0, sr = 44100;
    double fps = 0, total = 0;
    BOOL allHaveAudio = YES, allHaveVideo = YES;

    for (NSString *p in paths) {
        NSError *pe = nil;
        NSDictionary *info = [self probeFile:p error:&pe];
        if (!info) {
            if (error) *error = [NSError errorWithDomain:FFEngineErrorDomain code:72
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"无法读取 %@：%@", p.lastPathComponent,
                     pe.localizedDescription ?: @"格式不支持"]}]
            ;
            return NO;
        }
        total += [info[@"duration"] doubleValue];
        BOOL hasV = NO, hasA = NO;
        for (NSDictionary *st in info[@"streams"]) {
            if ([st[@"type"] isEqualToString:@"视频"]) {
                hasV = YES;
                int w = [st[@"width"] intValue], h = [st[@"height"] intValue];
                if (w > maxW) maxW = w;
                if (h > maxH) maxH = h;
                double f = [st[@"fps"] doubleValue];
                if (f > fps && f <= 120) fps = f;
            } else if ([st[@"type"] isEqualToString:@"音频"]) {
                hasA = YES;
                int r = [st[@"sample_rate"] intValue];
                if (r > 0) sr = sr > 0 ? sr : r;   // 统一到第一个有效采样率
            }
        }
        allHaveVideo = allHaveVideo && hasV;
        allHaveAudio = allHaveAudio && hasA;
    }

    if (!allHaveVideo) {
        if (error) *error = FErr(73, @"其中有文件不含视频轨，无法合并");
        return NO;
    }
    if (maxW <= 0 || maxH <= 0) { if (error) *error = FErr(74, @"无法确定统一分辨率"); return NO; }

    NSString *list = [self writeConcatListForPaths:paths error:error];
    if (!list) return NO;

    FFRequest *req = baseReq ?: [FFRequest new];
    req.inputPath = list;
    req.inputFormatName = @"concat";
    req.outputPath = outputPath;
    req.durationHint = total;
    req.start = -1; req.duration = -1;          // 合并时不做裁剪
    req.inputIsConcatList = YES;
    req.padWidth = maxW & ~1;
    req.padHeight = maxH & ~1;
    if (req.fps <= 0) req.fps = (fps > 0 && fps <= 60) ? fps : 30;
    req.sampleRate = sr;
    req.noAudio = req.noAudio || !allHaveAudio;  // 有片段缺音轨时整体丢音，避免流参数不一致
    if (!req.muxerName.length) req.muxerName = @"mp4";
    if (!req.videoCodec.length) req.videoCodec = @"h264_videotoolbox,mpeg4";
    if (!req.audioCodec.length) req.audioCodec = @"aac";

    BOOL ok = [self execute:req progress:progress error:error];
    [NSFileManager.defaultManager removeItemAtPath:list error:nil];
    return ok;
}

@end
