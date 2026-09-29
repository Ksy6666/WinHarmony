#include "napi/native_api.h"
#include "multimedia/player_framework/native_avcodec_videodecoder.h"
#include "multimedia/player_framework/native_avcodec_base.h"
#include "multimedia/player_framework/native_avformat.h"
#include "multimedia/player_framework/native_avbuffer.h"
#include "multimedia/player_framework/native_avbuffer_info.h"
#include "native_window/external_window.h"
#include <hilog/log.h>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <condition_variable>
#include <queue>
#include <chrono>

#define LOG_TAG "WinRemoteH264"
#define LOG_DOMAIN 0x0000

namespace {

struct InputItem {
    uint32_t index;
    OH_AVBuffer *buffer;
};

struct DecoderState {
    OH_AVCodec *codec = nullptr;
    OHNativeWindow *window = nullptr;
    std::mutex mtx;
    std::condition_variable cv;
    std::queue<InputItem> inQueue;
    int64_t ptsBaseUs = 0;
    bool started = false;
    napi_threadsafe_function renderCb = nullptr;
};

DecoderState g_dec;
std::atomic<int32_t> g_outCount{0};

int64_t NowUs()
{
    return std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

void OnError(OH_AVCodec *codec, int32_t errorCode, void *userData)
{
    (void)codec;
    (void)userData;
    OH_LOG_ERROR(LOG_APP, "decoder error: %{public}d", errorCode);
}

void OnStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData)
{
    (void)codec;
    (void)userData;
    int32_t width = 0;
    int32_t height = 0;
    if (OH_AVFormat_GetIntValue(format, OH_MD_KEY_WIDTH, &width) &&
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_HEIGHT, &height)) {
        OH_LOG_INFO(LOG_APP, "stream changed: %{public}dx%{public}d", width, height);
    }
}

static void RenderCallbackCallJs(napi_env env, napi_value jsCallback, void *context, void *data)
{
    (void)context;
    (void)data;
    if (env != nullptr && jsCallback != nullptr) {
        napi_value undefined = nullptr;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, jsCallback, 0, nullptr, &undefined);
    }
}

void OnNewOutputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData)
{
    (void)userData;
    // Measure queue->render pipeline delay from the buffer pts.
    OH_AVCodecBufferAttr attr;
    if (buffer != nullptr && OH_AVBuffer_GetBufferAttr(buffer, &attr) == AV_ERR_OK) {
        const int64_t delayMs = (NowUs() - g_dec.ptsBaseUs - attr.pts) / 1000;
        const int32_t n = g_outCount.load() + 1;
        if (n <= 10 || n % 120 == 0) {
            OH_LOG_INFO(LOG_APP, "render delay: %{public}dms (frame %{public}d)",
                        static_cast<int32_t>(delayMs), n);
        }
    }
    const int32_t n = ++g_outCount;
    if (n <= 5) {
        OH_LOG_INFO(LOG_APP, "output frame %{public}d -> render", n);
    }
    // Render immediately: remote desktop wants the freshest frame, no reorder.
    OH_VideoDecoder_RenderOutputBuffer(codec, index);
    // Notify JS (ack-on-render): only after a frame is on screen may the
    // server send the next one, so latency can never accumulate.
    napi_threadsafe_function cb = g_dec.renderCb;
    if (cb != nullptr) {
        napi_call_threadsafe_function(cb, nullptr, napi_tsfn_nonblocking);
    }
}

void OnNeedInputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData)
{
    (void)codec;
    (void)userData;
    std::lock_guard<std::mutex> lock(g_dec.mtx);
    g_dec.inQueue.push({index, buffer});
    g_dec.cv.notify_all();
}

struct AuLayout {
    size_t configEnd; // offset where the first VCL NAL start code begins
    bool hasVcl;
    bool hasIdr;
};

// Scan Annex B NAL units. Hardware decoders expect parameter sets (SPS/PPS)
// as a separate CODEC_DATA buffer ahead of the slices, so an access unit that
// bundles SPS+PPS+IDR must be split.
AuLayout ParseAnnexB(const uint8_t *data, size_t size)
{
    AuLayout layout{0, false, false};
    size_t pos = 0;
    while (pos + 3 < size) {
        size_t nalStart = 0;
        if (data[pos] == 0x00 && data[pos + 1] == 0x00 && data[pos + 2] == 0x01) {
            nalStart = pos + 3;
        } else if (pos + 4 < size && data[pos] == 0x00 && data[pos + 1] == 0x00 &&
                   data[pos + 2] == 0x00 && data[pos + 3] == 0x01) {
            nalStart = pos + 4;
        }
        if (nalStart > 0 && nalStart < size) {
            const uint8_t nalType = data[nalStart] & 0x1F;
            if (nalType >= 1 && nalType <= 5) {
                if (!layout.hasVcl) {
                    layout.configEnd = pos;
                }
                layout.hasVcl = true;
                if (nalType == 5) {
                    layout.hasIdr = true;
                }
            }
            pos = nalStart;
            continue;
        }
        pos++;
    }
    if (!layout.hasVcl) {
        layout.configEnd = size;
    }
    return layout;
}

// Take one input buffer from the codec queue and submit [data, data+len).
bool PushOne(const uint8_t *data, size_t len, uint32_t flags, int64_t pts)
{
    InputItem item{};
    {
        std::unique_lock<std::mutex> lock(g_dec.mtx);
        if (g_dec.codec == nullptr || !g_dec.started) {
            return false;
        }
        if (g_dec.inQueue.empty()) {
            g_dec.cv.wait_for(lock, std::chrono::milliseconds(120),
                              [] { return !g_dec.inQueue.empty(); });
        }
        if (g_dec.inQueue.empty()) {
            return false;
        }
        item = g_dec.inQueue.front();
        g_dec.inQueue.pop();
    }

    const int32_t capacity = OH_AVBuffer_GetCapacity(item.buffer);
    if (static_cast<int32_t>(len) > capacity) {
        OH_LOG_WARN(LOG_APP, "frame %{public}zu exceeds buffer capacity %{public}d", len, capacity);
        std::lock_guard<std::mutex> lock(g_dec.mtx);
        g_dec.inQueue.push(item);
        return false;
    }

    uint8_t *addr = OH_AVBuffer_GetAddr(item.buffer);
    if (addr == nullptr) {
        std::lock_guard<std::mutex> lock(g_dec.mtx);
        g_dec.inQueue.push(item);
        return false;
    }
    memcpy(addr, data, len);

    OH_AVCodecBufferAttr attr;
    attr.pts = pts;
    attr.size = static_cast<int32_t>(len);
    attr.offset = 0;
    attr.flags = flags;
    OH_AVBuffer_SetBufferAttr(item.buffer, &attr);

    if (OH_VideoDecoder_PushInputBuffer(g_dec.codec, item.index) != AV_ERR_OK) {
        OH_LOG_WARN(LOG_APP, "push input buffer failed");
        return false;
    }
    return true;
}

napi_value SetRenderCallback(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "callback required");
        return nullptr;
    }
    napi_valuetype type = napi_undefined;
    napi_typeof(env, args[0], &type);
    if (type != napi_function) {
        napi_throw_type_error(env, nullptr, "callback must be a function");
        return nullptr;
    }
    if (g_dec.renderCb != nullptr) {
        napi_release_threadsafe_function(g_dec.renderCb, napi_tsfn_release);
        g_dec.renderCb = nullptr;
    }
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "winremoteRender", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_threadsafe_function(env, args[0], nullptr, resourceName, 0, 1,
                                    nullptr, nullptr, nullptr,
                                    RenderCallbackCallJs, &g_dec.renderCb);
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

napi_value CreateDecoder(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char surfaceIdBuf[64] = {0};
    size_t surfaceIdLen = 0;
    napi_get_value_string_utf8(env, args[0], surfaceIdBuf, sizeof(surfaceIdBuf), &surfaceIdLen);
    int32_t width = 0;
    int32_t height = 0;
    napi_get_value_int32(env, args[1], &width);
    napi_get_value_int32(env, args[2], &height);

    napi_value result = nullptr;
    napi_get_boolean(env, false, &result);

    // Tear down any previous instance first.
    {
        std::lock_guard<std::mutex> lock(g_dec.mtx);
        if (g_dec.codec != nullptr) {
            OH_VideoDecoder_Stop(g_dec.codec);
            OH_VideoDecoder_Destroy(g_dec.codec);
            g_dec.codec = nullptr;
        }
        if (g_dec.window != nullptr) {
            OH_NativeWindow_DestroyNativeWindow(g_dec.window);
            g_dec.window = nullptr;
        }
        std::queue<InputItem> empty;
        std::swap(g_dec.inQueue, empty);
        g_dec.started = false;
        g_dec.ptsBaseUs = 0;
        g_outCount.store(0);
    }

    if (width <= 0 || height <= 0) {
        OH_LOG_ERROR(LOG_APP, "createDecoder: invalid size %{public}dx%{public}d", width, height);
        return result;
    }

    OH_AVCodec *codec = OH_VideoDecoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_AVC);
    if (codec == nullptr) {
        OH_LOG_ERROR(LOG_APP, "create AVC decoder failed");
        return result;
    }

    OH_AVCodecCallback callback;
    callback.onError = OnError;
    callback.onStreamChanged = OnStreamChanged;
    callback.onNeedInputBuffer = OnNeedInputBuffer;
    callback.onNewOutputBuffer = OnNewOutputBuffer;
    if (OH_VideoDecoder_RegisterCallback(codec, callback, nullptr) != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "register callback failed");
        OH_VideoDecoder_Destroy(codec);
        return result;
    }

    OH_AVFormat *format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
    if (OH_VideoDecoder_Configure(codec, format) != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "configure decoder failed");
        OH_AVFormat_Destroy(format);
        OH_VideoDecoder_Destroy(codec);
        return result;
    }
    OH_AVFormat_Destroy(format);

    uint64_t surfaceId = strtoull(surfaceIdBuf, nullptr, 10);
    OHNativeWindow *window = nullptr;
    if (OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId, &window) != 0 || window == nullptr) {
        OH_LOG_ERROR(LOG_APP, "create native window from surface %{public}s failed", surfaceIdBuf);
        OH_VideoDecoder_Destroy(codec);
        return result;
    }
    if (OH_VideoDecoder_SetSurface(codec, window) != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "set surface failed");
        OH_NativeWindow_DestroyNativeWindow(window);
        OH_VideoDecoder_Destroy(codec);
        return result;
    }
    if (OH_VideoDecoder_Prepare(codec) != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "prepare decoder failed");
        OH_NativeWindow_DestroyNativeWindow(window);
        OH_VideoDecoder_Destroy(codec);
        return result;
    }
    if (OH_VideoDecoder_Start(codec) != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "start decoder failed");
        OH_NativeWindow_DestroyNativeWindow(window);
        OH_VideoDecoder_Destroy(codec);
        return result;
    }

    {
        std::lock_guard<std::mutex> lock(g_dec.mtx);
        g_dec.codec = codec;
        g_dec.window = window;
        g_dec.started = true;
        g_dec.ptsBaseUs = NowUs();
    }
    OH_LOG_INFO(LOG_APP, "decoder started, surface=%{public}s size=%{public}dx%{public}d",
                surfaceIdBuf, width, height);

    napi_get_boolean(env, true, &result);
    return result;
}

napi_value PushFrame(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value result = nullptr;
    napi_get_boolean(env, false, &result);

    void *data = nullptr;
    size_t length = 0;
    if (argc < 1 || napi_get_arraybuffer_info(env, args[0], &data, &length) != napi_ok ||
        data == nullptr || length == 0) {
        return result;
    }

    const uint8_t *bytes = static_cast<const uint8_t *>(data);
    const AuLayout layout = ParseAnnexB(bytes, length);
    const int64_t pts = NowUs() - g_dec.ptsBaseUs;

    bool ok = true;
    if (layout.configEnd > 0 && layout.configEnd < length) {
        // Parameter sets (SPS/PPS/SEI) first as CODEC_DATA, then the slices.
        ok = PushOne(bytes, layout.configEnd, AVCODEC_BUFFER_FLAGS_CODEC_DATA, pts);
        if (ok) {
            const uint32_t sliceFlags = layout.hasIdr ? AVCODEC_BUFFER_FLAGS_SYNC_FRAME
                                                      : AVCODEC_BUFFER_FLAGS_NONE;
            ok = PushOne(bytes + layout.configEnd, length - layout.configEnd, sliceFlags, pts);
        }
    } else {
        uint32_t flags = AVCODEC_BUFFER_FLAGS_NONE;
        if (!layout.hasVcl) {
            flags = AVCODEC_BUFFER_FLAGS_CODEC_DATA;
        } else if (layout.hasIdr) {
            flags = AVCODEC_BUFFER_FLAGS_SYNC_FRAME;
        }
        ok = PushOne(bytes, length, flags, pts);
    }

    napi_get_boolean(env, ok, &result);
    return result;
}

napi_value ReleaseDecoder(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_threadsafe_function cb = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_dec.mtx);
        if (g_dec.codec != nullptr) {
            g_dec.started = false;
            OH_VideoDecoder_Stop(g_dec.codec);
            OH_VideoDecoder_Destroy(g_dec.codec);
            g_dec.codec = nullptr;
            OH_LOG_INFO(LOG_APP, "decoder released");
        }
        if (g_dec.window != nullptr) {
            OH_NativeWindow_DestroyNativeWindow(g_dec.window);
            g_dec.window = nullptr;
        }
        std::queue<InputItem> empty;
        std::swap(g_dec.inQueue, empty);
        cb = g_dec.renderCb;
        g_dec.renderCb = nullptr;
    }
    if (cb != nullptr) {
        napi_release_threadsafe_function(cb, napi_tsfn_release);
    }
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"createDecoder", nullptr, CreateDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pushFrame", nullptr, PushFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releaseDecoder", nullptr, ReleaseDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setRenderCallback", nullptr, SetRenderCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "h264decoder",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterH264DecoderModule(void)
{
    napi_module_register(&demoModule);
}
