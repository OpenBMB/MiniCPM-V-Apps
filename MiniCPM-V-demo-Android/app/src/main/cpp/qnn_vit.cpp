// MiniCPM-OCR 4x vision tower on the Hexagon HTP (QNN).
//
// The whole 27-layer ViT plus the merger is precompiled into a context binary
// by QAIRT offline; this file only owns the session: bring the device up once,
// then pack an RGB image into the linear canvas and read kCanvasRows x 1024
// embeddings out. Measured 791 ms per image on SM8975/HTP V85, against 25.3 s
// for the Vulkan ggml path.
//
// The canvas is [1, 3, 14, 14336] -- the CoreML/ANE layout, 1024 patches end to
// end. The grid lives in the inputs, not in the shape, so one binary covers
// every aspect ratio. See qnn_vit.h for why that matters for line-level crops.
//
// See qnn_review/README.md for how the binary is produced and for the accuracy
// measurements that justify replacing the ggml ViT.

#include "qnn_vit.h"

#include <android/log.h>
#include <dlfcn.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "QNN/QnnInterface.h"
#include "QNN/QnnTypes.h"
#include "QNN/QnnDevice.h"
#include "QNN/HTP/QnnHtpDevice.h"
#include "QNN/System/QnnSystemInterface.h"

#define TAG "QnnVit"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

namespace qnnvit {
namespace {

// QNN embedding dimension of the 4x projector (== text model n_embd).
constexpr int kNEmbd = 1024;

// Pixels per channel plane of the packed canvas.
constexpr int kPlane = kPatch * kLinearW;              // 200704

// Large enough that fp16 exp() underflows to exactly 0, small enough to stay
// finite. Keeps the zero-filled tail out of every softmax denominator.
constexpr float kMaskNeg = -3e4f;

// Role of each graph input, resolved by name so a reordering in a future
// export shows up as a clear error instead of silently swapped buffers.
enum InputRole { IN_IMAGE, IN_POS, IN_DS0, IN_DS1, IN_DS2, IN_DS3, IN_BIAS, IN_COUNT };

const char * const kInputNames[IN_COUNT] = {
    "image", "position_ids",
    "merger_ds_idx_0", "merger_ds_idx_1", "merger_ds_idx_2", "merger_ds_idx_3",
    "attn_bias",
};

struct Session {
    std::mutex mu;

    void * lib_backend = nullptr;
    void * lib_system = nullptr;

    Qnn_BackendHandle_t backend = nullptr;
    Qnn_DeviceHandle_t device = nullptr;
    Qnn_ContextHandle_t context = nullptr;
    Qnn_GraphHandle_t graph = nullptr;
    Qnn_LogHandle_t logger = nullptr;

    std::vector<uint8_t> binary;      // keep the context binary alive
    std::vector<Qnn_Tensor_t> inputs;
    std::vector<Qnn_Tensor_t> outputs;
    std::string graph_name;

    // Graph-owned buffers, one per input plus the output.
    std::vector<uint16_t> in_image;   // [3, 14, kLinearW] fp16
    std::vector<int32_t> in_pos;      // [kPatches]
    std::vector<int32_t> in_ds[4];    // [kCanvasRows]
    std::vector<uint16_t> in_bias;    // [kPatches] fp16
    std::vector<uint16_t> out_buf;    // [kCanvasRows, kNEmbd] fp16

    // The auxiliary inputs depend only on the grid, so rebuild them when it
    // changes rather than on every frame.
    int grid_w = -1;
    int grid_h = -1;

    std::vector<float> pending;       // handed to llama_jni as the image embd
    int pending_rows = 0;
    bool has_pending = false;
};

Session g_s;

// The provider vtable. Only reachable through dlopen + getProviders, so it is
// cached at init() and used by encode().
const QNN_INTERFACE_VER_TYPE * g_qnn = nullptr;

// ---------------------------------------------------------------- f16 helpers

inline float f16_to_f32(uint16_t h) {
    const uint32_t sign = (h >> 15) & 1u;
    const uint32_t exp = (h >> 10) & 0x1fu;
    const uint32_t mant = h & 0x3ffu;
    uint32_t bits;
    if (exp == 0) {
        if (mant == 0) {
            bits = sign << 31;
        } else {
            uint32_t e = 0;
            uint32_t m = mant;
            while ((m & 0x400u) == 0) {
                m <<= 1;
                ++e;
            }
            m &= 0x3ffu;
            bits = (sign << 31) | ((127 - 15 - static_cast<int32_t>(e) + 1) << 23) | (m << 13);
        }
    } else if (exp == 0x1f) {
        bits = (sign << 31) | 0x7f800000u | (mant << 13);
    } else {
        bits = (sign << 31) | ((exp - 15 + 127) << 23) | (mant << 13);
    }
    float f;
    memcpy(&f, &bits, sizeof(f));
    return f;
}

inline uint16_t f32_to_f16(float f) {
    uint32_t x;
    memcpy(&x, &f, 4);
    const uint32_t sign = (x >> 16) & 0x8000u;
    int32_t exp = static_cast<int32_t>((x >> 23) & 0xffu) - 127;
    const uint32_t mant = x & 0x7fffffu;
    if (exp > 15) {
        return static_cast<uint16_t>(sign | 0x7c00u);
    }
    if (exp < -14) {
        if (exp < -24) {
            return static_cast<uint16_t>(sign);
        }
        const uint32_t shift = static_cast<uint32_t>(-14 - exp);
        const uint32_t m = (mant | 0x800000u) >> (13 + shift);
        return static_cast<uint16_t>(sign | m);
    }
    const uint32_t rounded = mant + 0x1000u;
    if (rounded & 0x800000u) {
        const int32_t e = exp + 1;
        if (e > 15) {
            return static_cast<uint16_t>(sign | 0x7c00u);
        }
        return static_cast<uint16_t>(sign | (static_cast<uint32_t>(e + 15) << 10));
    }
    return static_cast<uint16_t>(sign | (static_cast<uint32_t>(exp + 15) << 10) | (rounded >> 13));
}

// ---------------------------------------------------------------- QNN helpers

size_t dtype_bytes(Qnn_DataType_t t) {
    switch (t) {
        case QNN_DATATYPE_FLOAT_32:
        case QNN_DATATYPE_INT_32:
        case QNN_DATATYPE_UINT_32:
        case QNN_DATATYPE_SFIXED_POINT_32:
        case QNN_DATATYPE_UFIXED_POINT_32: return 4;
        case QNN_DATATYPE_FLOAT_16:
        case QNN_DATATYPE_BFLOAT_16:
        case QNN_DATATYPE_INT_16:
        case QNN_DATATYPE_UINT_16: return 2;
        case QNN_DATATYPE_UINT_8:
        case QNN_DATATYPE_INT_8:
        case QNN_DATATYPE_SFIXED_POINT_8:
        case QNN_DATATYPE_UFIXED_POINT_8: return 1;
        default: return 2;
    }
}

size_t tensor_numel(const Qnn_Tensor_t & t) {
    size_t n = 1;
    for (uint32_t i = 0; i < t.v2.rank; ++i) {
        n *= t.v2.dimensions[i];
    }
    return n;
}

void log_cb(const char * fmt, QnnLog_Level_t level, uint64_t, va_list args) {
    if (level > QNN_LOG_LEVEL_WARN) {
        return;
    }
    char buf[512];
    vsnprintf(buf, sizeof(buf), fmt, args);
    LOGI("[qnn] %s", buf);
}

bool read_file(const char * path, std::vector<uint8_t> & out) {
    FILE * f = fopen(path, "rb");
    if (!f) {
        LOGE("cannot open %s", path);
        return false;
    }
    fseek(f, 0, SEEK_END);
    const long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size <= 0) {
        fclose(f);
        LOGE("%s is empty", path);
        return false;
    }
    out.resize(static_cast<size_t>(size));
    const size_t got = fread(out.data(), 1, out.size(), f);
    fclose(f);
    if (got != out.size()) {
        LOGE("%s: short read %zu/%zu", path, got, out.size());
        return false;
    }
    return true;
}

bool expect_dims(const Qnn_Tensor_t & t, std::initializer_list<uint32_t> want) {
    if (t.v2.rank != want.size()) {
        return false;
    }
    uint32_t i = 0;
    for (uint32_t d : want) {
        if (t.v2.dimensions[i++] != d) {
            return false;
        }
    }
    return true;
}

void describe(const Qnn_Tensor_t & t, char * buf, size_t n) {
    int off = snprintf(buf, n, "rank=%u dims=[", t.v2.rank);
    for (uint32_t i = 0; i < t.v2.rank && off > 0 && static_cast<size_t>(off) < n; ++i) {
        off += snprintf(buf + off, n - off, "%s%u", i ? "," : "", t.v2.dimensions[i]);
    }
    if (off > 0 && static_cast<size_t>(off) < n) {
        snprintf(buf + off, n - off, "] dtype=0x%x", t.v2.dataType);
    }
}

// Binds one graph input to `data`, keeping the descriptor's own dtype/dims.
void bind_input(Qnn_Tensor_t & t, void * data, size_t bytes) {
    t.v2.type = QNN_TENSOR_TYPE_APP_WRITE;
    t.v2.memType = QNN_TENSORMEMTYPE_RAW;
    t.v2.clientBuf.data = data;
    t.v2.clientBuf.dataSize = static_cast<uint32_t>(bytes);
}

// Builds the graph I/O tensor list from the binary's own descriptors.
bool build_io(Session & s, const QnnSystemContext_GraphInfoV1_t & gi) {
    s.graph_name = gi.graphName ? gi.graphName : "";

    if (gi.numGraphInputs != IN_COUNT || gi.numGraphOutputs != 1) {
        LOGE("unexpected graph arity: %u in / %u out (want %d / 1)",
             gi.numGraphInputs, gi.numGraphOutputs, IN_COUNT);
        return false;
    }

    // Map declared inputs onto roles by name.
    int slot[IN_COUNT];
    for (int & v : slot) {
        v = -1;
    }
    for (uint32_t i = 0; i < gi.numGraphInputs; ++i) {
        const char * name = gi.graphInputs[i].v2.name;
        int role = -1;
        for (int r = 0; r < IN_COUNT; ++r) {
            if (name && strcmp(name, kInputNames[r]) == 0) {
                role = r;
                break;
            }
        }
        if (role < 0) {
            LOGE("input[%u] '%s' is not a name this build knows", i, name ? name : "?");
            return false;
        }
        slot[role] = static_cast<int>(i);
    }

    char buf[128];
    for (int r = 0; r < IN_COUNT; ++r) {
        if (slot[r] < 0) {
            LOGE("graph is missing input '%s'", kInputNames[r]);
            return false;
        }
    }

    const Qnn_Tensor_t & image = gi.graphInputs[slot[IN_IMAGE]];
    if (!expect_dims(image, {1, 3, kPatch, kLinearW}) ||
        image.v2.dataType != QNN_DATATYPE_FLOAT_16) {
        describe(image, buf, sizeof(buf));
        LOGE("input 'image': %s (want [1,3,%d,%d] fp16)", buf, kPatch, kLinearW);
        return false;
    }
    const Qnn_Tensor_t & pos = gi.graphInputs[slot[IN_POS]];
    if (!expect_dims(pos, {kPatches}) || pos.v2.dataType != QNN_DATATYPE_INT_32) {
        describe(pos, buf, sizeof(buf));
        LOGE("input 'position_ids': %s (want [%d] int32)", buf, kPatches);
        return false;
    }
    for (int r = IN_DS0; r <= IN_DS3; ++r) {
        const Qnn_Tensor_t & t = gi.graphInputs[slot[r]];
        if (!expect_dims(t, {kCanvasRows}) || t.v2.dataType != QNN_DATATYPE_INT_32) {
            describe(t, buf, sizeof(buf));
            LOGE("input '%s': %s (want [%d] int32)", kInputNames[r], buf, kCanvasRows);
            return false;
        }
    }
    const Qnn_Tensor_t & bias = gi.graphInputs[slot[IN_BIAS]];
    if (!expect_dims(bias, {kPatches}) || bias.v2.dataType != QNN_DATATYPE_FLOAT_16) {
        describe(bias, buf, sizeof(buf));
        LOGE("input 'attn_bias': %s (want [%d] fp16)", buf, kPatches);
        return false;
    }

    const Qnn_Tensor_t & out = gi.graphOutputs[0];
    if (!expect_dims(out, {kCanvasRows, kNEmbd}) || out.v2.dataType != QNN_DATATYPE_FLOAT_16) {
        describe(out, buf, sizeof(buf));
        LOGE("output 'embeddings': %s (want [%d,%d] fp16)", buf, kCanvasRows, kNEmbd);
        return false;
    }

    s.in_image.assign(3 * kPlane, 0);
    s.in_pos.assign(kPatches, 0);
    for (auto & v : s.in_ds) {
        v.assign(kCanvasRows, 0);
    }
    s.in_bias.assign(kPatches, 0);
    s.out_buf.assign(static_cast<size_t>(kCanvasRows) * kNEmbd, 0);

    s.inputs.assign(gi.graphInputs, gi.graphInputs + gi.numGraphInputs);
    s.outputs.assign(gi.graphOutputs, gi.graphOutputs + gi.numGraphOutputs);

    struct Bound { int role; void * data; size_t bytes; };
    const Bound bound[IN_COUNT] = {
        {IN_IMAGE, s.in_image.data(), s.in_image.size() * 2},
        {IN_POS, s.in_pos.data(), s.in_pos.size() * 4},
        {IN_DS0, s.in_ds[0].data(), s.in_ds[0].size() * 4},
        {IN_DS1, s.in_ds[1].data(), s.in_ds[1].size() * 4},
        {IN_DS2, s.in_ds[2].data(), s.in_ds[2].size() * 4},
        {IN_DS3, s.in_ds[3].data(), s.in_ds[3].size() * 4},
        {IN_BIAS, s.in_bias.data(), s.in_bias.size() * 2},
    };
    for (const Bound & b : bound) {
        Qnn_Tensor_t & t = s.inputs[slot[b.role]];
        const size_t want = tensor_numel(t) * dtype_bytes(t.v2.dataType);
        if (want != b.bytes) {
            LOGE("input '%s' wants %zu bytes, buffer is %zu", kInputNames[b.role], want, b.bytes);
            return false;
        }
        bind_input(t, b.data, b.bytes);
    }

    Qnn_Tensor_t & o = s.outputs[0];
    o.v2.type = QNN_TENSOR_TYPE_APP_READ;
    o.v2.memType = QNN_TENSORMEMTYPE_RAW;
    o.v2.clientBuf.data = s.out_buf.data();
    o.v2.clientBuf.dataSize = static_cast<uint32_t>(s.out_buf.size() * 2);

    return true;
}

// Rebuilds position_ids / merger_ds_idx_* / attn_bias for a pos_h x pos_w grid.
// Mirrors `clip_image_batch_encode` in clip.cpp for PROJECTOR_TYPE_MINICPM_OCR_1_0
// with is_4x (n_merge == 2): the four gather vectors pick (2i+r, 2j+c) with
// stride pos_w, and the canvas tail is masked out of attention.
void prepare_aux(Session & s, int pos_w, int pos_h) {
    if (s.grid_w == pos_w && s.grid_h == pos_h) {
        return;
    }
    const int n_patches = pos_w * pos_h;

    std::fill(s.in_pos.begin(), s.in_pos.end(), 0);
    int id = 0;
    for (int i = 0; i < pos_h; ++i) {
        const int bh = static_cast<int>(std::floor(70.0 * i / pos_h));
        for (int j = 0; j < pos_w; ++j) {
            const int bw = static_cast<int>(std::floor(70.0 * j / pos_w));
            s.in_pos[id++] = bh * 70 + bw;
        }
    }

    const int ds_h = pos_h / 2;
    const int ds_w = pos_w / 2;
    static const int off_r[4] = {0, 0, 1, 1};
    static const int off_c[4] = {0, 1, 0, 1};
    for (int r = 0; r < 4; ++r) {
        std::fill(s.in_ds[r].begin(), s.in_ds[r].end(), 0);
        int k = 0;
        for (int i = 0; i < ds_h; ++i) {
            for (int j = 0; j < ds_w; ++j) {
                s.in_ds[r][k++] = (2 * i + off_r[r]) * pos_w + (2 * j + off_c[r]);
            }
        }
    }

    const uint16_t mask = f32_to_f16(kMaskNeg);
    for (int k = 0; k < kPatches; ++k) {
        s.in_bias[k] = (k < n_patches) ? 0 : mask;
    }

    s.grid_w = pos_w;
    s.grid_h = pos_h;

    LOGI("aux %dx%d: patches=%d rows=%d pos[0:4]=%d,%d,%d,%d "
         "ds0[0:4]=%d,%d,%d,%d ds2[0:4]=%d,%d,%d,%d",
         pos_w, pos_h, n_patches, (pos_h / 2) * (pos_w / 2),
         s.in_pos[0], s.in_pos[1], s.in_pos[2], s.in_pos[3],
         s.in_ds[0][0], s.in_ds[0][1], s.in_ds[0][2], s.in_ds[0][3],
         s.in_ds[2][0], s.in_ds[2][1], s.in_ds[2][2], s.in_ds[2][3]);
}

void release(Session & s) {
    s.graph = nullptr;
    s.context = nullptr;
    s.device = nullptr;
    s.backend = nullptr;
    s.inputs.clear();
    s.outputs.clear();
    s.in_image.clear();
    s.in_pos.clear();
    for (auto & v : s.in_ds) {
        v.clear();
    }
    s.in_bias.clear();
    s.out_buf.clear();
    s.binary.clear();
    s.binary.shrink_to_fit();
    s.pending.clear();
    s.pending_rows = 0;
    s.has_pending = false;
    s.grid_w = -1;
    s.grid_h = -1;
}

}  // namespace

// ---------------------------------------------------------------- public API

bool ready() {
    std::lock_guard<std::mutex> lock(g_s.mu);
    return g_s.graph != nullptr;
}

bool runtime_available() {
    return dlopen("libQnnHtp.so", RTLD_NOW | RTLD_GLOBAL) != nullptr;
}


int init(const char * skel_dir, const char * context_binary, int arch) {
    std::lock_guard<std::mutex> lock(g_s.mu);
    if (g_s.graph) {
        return 0;
    }
    if (arch <= 0) {
        LOGE("init: no Hexagon generation supplied");
        return -1;
    }

    // The DSP skel must be the same QAIRT build as the host libraries; the
    // vendor partition carries an older one, which fails with an undefined
    // `qnn_2_51_XX_skel_handle_invoke`. It lives in app storage because its
    // 0x1000 LOAD alignment breaks 16 KB page compatibility inside jniLibs.
    setenv("ADSP_LIBRARY_PATH", skel_dir, 1);
    LOGI("ADSP_LIBRARY_PATH=%s", skel_dir);

    g_s.lib_backend = dlopen("libQnnHtp.so", RTLD_NOW | RTLD_GLOBAL);
    if (!g_s.lib_backend) {
        LOGE("dlopen libQnnHtp.so: %s", dlerror());
        return -1;
    }
    g_s.lib_system = dlopen("libQnnSystem.so", RTLD_NOW | RTLD_GLOBAL);
    if (!g_s.lib_system) {
        LOGE("dlopen libQnnSystem.so: %s", dlerror());
        return -1;
    }

    auto get_providers = reinterpret_cast<Qnn_ErrorHandle_t (*)(const QnnInterface_t ***, uint32_t *)>(
        dlsym(g_s.lib_backend, "QnnInterface_getProviders"));
    auto get_sys_providers = reinterpret_cast<Qnn_ErrorHandle_t (*)(const QnnSystemInterface_t ***, uint32_t *)>(
        dlsym(g_s.lib_system, "QnnSystemInterface_getProviders"));
    if (!get_providers || !get_sys_providers) {
        LOGE("dlsym QnnInterface_getProviders failed");
        return -1;
    }

    const QnnInterface_t ** providers = nullptr;
    uint32_t n_providers = 0;
    if (get_providers(&providers, &n_providers) != QNN_SUCCESS || n_providers == 0) {
        LOGE("QnnInterface_getProviders failed");
        return -1;
    }
    const QnnInterface_t * provider = nullptr;
    for (uint32_t i = 0; i < n_providers; ++i) {
        const auto & v = providers[i]->apiVersion.coreApiVersion;
        if (v.major == QNN_API_VERSION_MAJOR && v.minor >= QNN_API_VERSION_MINOR) {
            provider = providers[i];
        }
    }
    if (!provider) {
        LOGE("no QNN provider with API %d.%d", QNN_API_VERSION_MAJOR, QNN_API_VERSION_MINOR);
        return -1;
    }
    const QNN_INTERFACE_VER_TYPE & qnn = provider->QNN_INTERFACE_VER_NAME;
    g_qnn = &qnn;

    const QnnSystemInterface_t ** sys_providers = nullptr;
    uint32_t n_sys = 0;
    if (get_sys_providers(&sys_providers, &n_sys) != QNN_SUCCESS || n_sys == 0) {
        LOGE("QnnSystemInterface_getProviders failed");
        return -1;
    }
    const QNN_SYSTEM_INTERFACE_VER_TYPE & sys = sys_providers[0]->QNN_SYSTEM_INTERFACE_VER_NAME;

    // logCreate is the first call that starts the HTP provider, and that
    // provider identifies the SoC by reading /sys/devices/soc0/soc_id. Where
    // SELinux denies that read (stock Android), it fails here and nothing
    // downstream can recover, because backendCreate repeats the same lookup.
    if (qnn.logCreate(log_cb, QNN_LOG_LEVEL_WARN, &g_s.logger) != QNN_SUCCESS) {
        LOGE("logCreate failed: the QNN provider could not start (SoC not readable?)");
        return -1;
    }
    if (qnn.backendCreate(g_s.logger, nullptr, &g_s.backend) != QNN_SUCCESS) {
        LOGE("backendCreate failed");
        return -1;
    }
    // Declare the SoC up front instead of letting the driver look it up.
    // The lookup reads /sys/devices/soc0/soc_id, which SELinux denies to
    // unprivileged apps on stock Android, so the probe path fails there with
    // "No Snapdragon SOC detected". Filling the platform info ourselves is the
    // offline path the QNN headers describe and skips that read entirely.
    static QnnHtpDevice_DeviceInfoExtension_t dev_ext = {};
    dev_ext.devType              = QNN_HTP_DEVICE_TYPE_ON_CHIP;
    dev_ext.onChipDevice.vtcmSize        = 8;
    dev_ext.onChipDevice.socModel        = 0;   // unknown; arch routes the graph
    dev_ext.onChipDevice.signedPdSupport = false;
    dev_ext.onChipDevice.dlbcSupport     = false;
    dev_ext.onChipDevice.arch            = static_cast<QnnHtpDevice_Arch_t>(arch);

    static QnnDevice_CoreInfo_t cores[1] = {};
    cores[0].version              = QNN_DEVICE_CORE_INFO_VERSION_1;
    cores[0].v1.coreId            = QNN_DEVICE_DEFAULT_CORE_ID;
    cores[0].v1.coreType          = 0;
    cores[0].v1.coreInfoExtension = nullptr;

    static QnnDevice_HardwareDeviceInfo_t hw_dev = {};
    hw_dev.version                = QNN_DEVICE_HARDWARE_DEVICE_INFO_VERSION_1;
    hw_dev.v1.deviceId            = QNN_DEVICE_DEFAULT_DEVICE_ID;
    hw_dev.v1.deviceType          = 0;
    hw_dev.v1.numCores            = 1;
    hw_dev.v1.cores               = cores;
    hw_dev.v1.deviceInfoExtension = reinterpret_cast<QnnDevice_DeviceInfoExtension_t>(&dev_ext);

    static QnnDevice_PlatformInfo_t platform = {};
    platform.version         = QNN_DEVICE_PLATFORM_INFO_VERSION_1;
    platform.v1.numHwDevices = 1;
    platform.v1.hwDevices    = &hw_dev;

    static QnnDevice_Config_t dev_cfg[2] = {};
    dev_cfg[0].option       = QNN_DEVICE_CONFIG_OPTION_PLATFORM_INFO;
    dev_cfg[0].hardwareInfo = &platform;
    dev_cfg[1].option       = QNN_DEVICE_CONFIG_OPTION_UNDEFINED;

    const QnnDevice_Config_t * dev_cfg_ptr[2] = { &dev_cfg[0], nullptr };

    if (qnn.deviceCreate(g_s.logger, dev_cfg_ptr, &g_s.device) != QNN_SUCCESS) {
        LOGE("deviceCreate failed for Hexagon v%d", arch);
        return -1;
    }
    LOGI("device created for Hexagon v%d", arch);

    if (!read_file(context_binary, g_s.binary)) {
        return -1;
    }
    LOGI("context binary %s: %.1f MiB", context_binary, g_s.binary.size() / 1048576.0);

    if (qnn.contextCreateFromBinary(g_s.backend, g_s.device, nullptr, g_s.binary.data(),
                                    g_s.binary.size(), &g_s.context, nullptr) != QNN_SUCCESS) {
        LOGE("contextCreateFromBinary failed");
        return -1;
    }

    QnnSystemContext_Handle_t sys_ctx = nullptr;
    const QnnSystemContext_BinaryInfo_t * info = nullptr;
    Qnn_ContextBinarySize_t info_size = 0;
    if (sys.systemContextCreate(&sys_ctx) != QNN_SUCCESS ||
        sys.systemContextGetBinaryInfo(sys_ctx, g_s.binary.data(), g_s.binary.size(),
                                       &info, &info_size) != QNN_SUCCESS) {
        LOGE("systemContextGetBinaryInfo failed");
        return -1;
    }

    const QnnSystemContext_GraphInfo_t * graphs = nullptr;
    uint32_t n_graphs = 0;
    if (info->version == QNN_SYSTEM_CONTEXT_BINARY_INFO_VERSION_3) {
        n_graphs = info->contextBinaryInfoV3.numGraphs;
        graphs = info->contextBinaryInfoV3.graphs;
    } else if (info->version == QNN_SYSTEM_CONTEXT_BINARY_INFO_VERSION_2) {
        n_graphs = info->contextBinaryInfoV2.numGraphs;
        graphs = info->contextBinaryInfoV2.graphs;
    } else {
        n_graphs = info->contextBinaryInfoV1.numGraphs;
        graphs = info->contextBinaryInfoV1.graphs;
    }
    if (n_graphs == 0) {
        LOGE("context binary contains no graph");
        return -1;
    }
    if (!build_io(g_s, graphs[0].graphInfoV1)) {
        return -1;
    }
    if (qnn.graphRetrieve(g_s.context, g_s.graph_name.c_str(), &g_s.graph) != QNN_SUCCESS) {
        LOGE("graphRetrieve('%s') failed", g_s.graph_name.c_str());
        return -1;
    }

    LOGI("NPU vision tower ready (graph '%s', %d inputs, %d rows)",
         g_s.graph_name.c_str(), IN_COUNT, kCanvasRows);
    return 0;
}

void shutdown() {
    std::lock_guard<std::mutex> lock(g_s.mu);
    g_s.graph = nullptr;
    g_s.context = nullptr;
    g_s.device = nullptr;
    g_s.backend = nullptr;
    g_qnn = nullptr;
    release(g_s);
    LOGI("NPU vision tower released");
}

int encode_rgba(const uint8_t * rgba, int pos_w, int pos_h) {
    std::lock_guard<std::mutex> lock(g_s.mu);
    if (!g_s.graph) {
        return -1;
    }
    if (pos_w <= 0 || pos_h <= 0 || pos_w * pos_h > kPatches) {
        LOGE("encode: grid %dx%d does not fit %d patches", pos_w, pos_h, kPatches);
        return -1;
    }

    prepare_aux(g_s, pos_w, pos_h);

    // Interleaved RGBA -> planar RGB fp16 in the (v/255 - 0.5) / 0.5 domain,
    // matching mtmd's img_u8_to_f32 for this model (mean/std are both 0.5).
    //
    // Patch k = i*pos_w + j lands at columns [k*14, k*14+14) of the packed
    // canvas, at native resolution. Everything past the last real patch stays
    // zero, and attn_bias tells the graph to ignore it.
    constexpr float kScale = 1.0f / 127.5f;
    const int src_w = pos_w * kPatch;
    std::fill(g_s.in_image.begin(), g_s.in_image.end(), 0);
    for (int i = 0; i < pos_h; ++i) {
        for (int j = 0; j < pos_w; ++j) {
            const int k = i * pos_w + j;
            for (int y = 0; y < kPatch; ++y) {
                const uint8_t * row = rgba + (static_cast<size_t>(i * kPatch + y) * src_w + j * kPatch) * 4;
                const int dst = y * kLinearW + k * kPatch;
                for (int x = 0; x < kPatch; ++x) {
                    const uint8_t * px = row + x * 4;
                    g_s.in_image[dst + x]            = f32_to_f16(static_cast<float>(px[0]) * kScale - 1.0f);
                    g_s.in_image[kPlane + dst + x]   = f32_to_f16(static_cast<float>(px[1]) * kScale - 1.0f);
                    g_s.in_image[2 * kPlane + dst + x] = f32_to_f16(static_cast<float>(px[2]) * kScale - 1.0f);
                }
            }
        }
    }

    if (!g_qnn) {
        return -1;
    }

    // Self-check the packing on a few known offsets. A wrong row/column stride
    // still produces the right token count, so nothing else would catch it:
    // patch k of row i must start at source row i*14 and column (k%pos_w)*14,
    // and land at canvas column k*14.
    {
        struct Probe { int k; int x; int y; };
        const Probe probes[3] = {
            {0, 0, 0},
            {1, 0, 0},                 // first pixel of patch 1 (source column 14)
            {pos_w, 0, 0},             // first patch of row 1 (source row 14)
        };
        for (const Probe & p : probes) {
            if (p.k >= pos_w * pos_h) {
                continue;
            }
            const int sy = (p.k / pos_w) * kPatch + p.y;
            const int sx = (p.k % pos_w) * kPatch + p.x;
            const uint8_t * src = rgba + (static_cast<size_t>(sy) * src_w + sx) * 4;
            const int dst = p.y * kLinearW + p.k * kPatch + p.x;
            const float want = static_cast<float>(src[0]) * kScale - 1.0f;
            const float got = f16_to_f32(g_s.in_image[dst]);
            if (std::fabs(want - got) > 1e-3f) {
                LOGE("packing probe %d: src(%d,%d)=%.4f -> canvas %.4f",
                     p.k, sx, sy, want, got);
                return -1;
            }
        }
    }

    const Qnn_ErrorHandle_t rc = g_qnn->graphExecute(
        g_s.graph, g_s.inputs.data(), static_cast<uint32_t>(g_s.inputs.size()),
        g_s.outputs.data(), static_cast<uint32_t>(g_s.outputs.size()), nullptr, nullptr);
    if (rc != QNN_SUCCESS) {
        LOGE("graphExecute failed: 0x%llx", static_cast<unsigned long long>(rc));
        return -1;
    }

    // Only the first (pos_h/2)*(pos_w/2) rows are real; the rest gathered pad
    // slots. Slicing here rather than in the caller keeps the token count the
    // one number llama_jni compares against the chunk.
    const int rows = (pos_h / 2) * (pos_w / 2);
    const size_t off = rows * kNEmbd;
    g_s.pending.resize(off);
    for (size_t i = 0; i < off; ++i) {
        g_s.pending[i] = f16_to_f32(g_s.out_buf[i]);
    }
    g_s.pending_rows = rows;
    g_s.has_pending = true;
    return 0;
}

const float * take_pending(int * n_tokens) {
    std::lock_guard<std::mutex> lock(g_s.mu);
    if (!g_s.has_pending) {
        return nullptr;
    }
    g_s.has_pending = false;
    if (n_tokens) {
        *n_tokens = g_s.pending_rows;
    }
    return g_s.pending.data();
}

}  // namespace qnnvit
