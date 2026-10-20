#include "napi/native_api.h"
#include "hilog/log.h"

#include <cstring>
#include <string>

#include "libtailscale_go.h"

#define BRIDGE_LOG_TAG "TailnetBridge"
#define BRIDGE_LOG_DOMAIN 0x15b0
#define MAKE_FILE_NAME (strrchr(__FILE__, '/') + 1)

#define BRIDGE_LOGI(fmt, ...)                                                                                          \
    OH_LOG_Print(LOG_APP, LOG_INFO, BRIDGE_LOG_DOMAIN, BRIDGE_LOG_TAG, "[%{public}s %{public}d] " fmt,                 \
                 MAKE_FILE_NAME, __LINE__, ##__VA_ARGS__)

#define BRIDGE_LOGE(fmt, ...)                                                                                          \
    OH_LOG_Print(LOG_APP, LOG_ERROR, BRIDGE_LOG_DOMAIN, BRIDGE_LOG_TAG, "[%{public}s %{public}d] " fmt,                \
                 MAKE_FILE_NAME, __LINE__, ##__VA_ARGS__)

static constexpr const int MAX_STRING_LENGTH = 4096;

static std::string GetStringFromValueUtf8(napi_env env, napi_value value)
{
    std::string result;
    char str[MAX_STRING_LENGTH] = {0};
    size_t length = 0;
    napi_get_value_string_utf8(env, value, str, MAX_STRING_LENGTH, &length);
    if (length > 0) {
        return result.append(str, length);
    }
    return result;
}

static napi_value MakeStringFromC(napi_env env, char *cstr)
{
    napi_value out = nullptr;
    napi_create_string_utf8(env, cstr != nullptr ? cstr : "", NAPI_AUTO_LENGTH, &out);
    if (cstr != nullptr) {
        FreeCString(cstr);
    }
    return out;
}

static napi_value JsStartEngine(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string stateDir = GetStringFromValueUtf8(env, args[0]);
    std::string hostname = GetStringFromValueUtf8(env, args[1]);
    std::string proxyUrl = GetStringFromValueUtf8(env, args[2]);
    int32_t tunFd = -1;
    napi_get_value_int32(env, args[3], &tunFd);
    BRIDGE_LOGI("startEngine stateDir=%{public}s hostname=%{public}s externalProxy=%{public}s tunFd=%{public}d",
                stateDir.c_str(), hostname.c_str(), proxyUrl.c_str(), tunFd);

    char *result = StartEngine(const_cast<char *>(stateDir.c_str()), const_cast<char *>(hostname.c_str()),
                               const_cast<char *>(proxyUrl.c_str()), tunFd);
    BRIDGE_LOGI("startEngine result=%{public}s", result != nullptr ? result : "");
    return MakeStringFromC(env, result);
}

static napi_value JsKickRestart(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string stateDir = GetStringFromValueUtf8(env, args[0]);
    std::string hostname = GetStringFromValueUtf8(env, args[1]);
    std::string proxyUrl = GetStringFromValueUtf8(env, args[2]);
    BRIDGE_LOGI("kickRestart stateDir=%{public}s hostname=%{public}s", stateDir.c_str(), hostname.c_str());

    char *result = KickRestartEngine(const_cast<char *>(stateDir.c_str()), const_cast<char *>(hostname.c_str()),
                                     const_cast<char *>(proxyUrl.c_str()));
    BRIDGE_LOGI("kickRestart result=%{public}s", result != nullptr ? result : "");
    return MakeStringFromC(env, result);
}

static napi_value JsStopEngine(napi_env env, napi_callback_info info)
{
    char *result = StopEngine();
    BRIDGE_LOGI("stopEngine result=%{public}s", result != nullptr ? result : "");
    return MakeStringFromC(env, result);
}

static napi_value JsStopEngineQuiet(napi_env env, napi_callback_info info)
{
    char *result = StopEngineQuiet();
    BRIDGE_LOGI("stopEngineQuiet result=%{public}s", result != nullptr ? result : "");
    return MakeStringFromC(env, result);
}

struct StopQuietAsyncContext {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    char *result = nullptr;
};

static void ExecuteStopQuietAsync(napi_env env, void *data)
{
    auto *ctx = static_cast<StopQuietAsyncContext *>(data);
    ctx->result = StopEngineQuiet();
}

static void CompleteStopQuietAsync(napi_env env, napi_status status, void *data)
{
    auto *ctx = static_cast<StopQuietAsyncContext *>(data);
    const char *text = (status == napi_ok && ctx->result != nullptr) ? ctx->result
                                                                    : "{\"ok\":false,\"error\":\"async work failed\"}";
    napi_value value = nullptr;
    napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &value);
    napi_resolve_deferred(env, ctx->deferred, value);
    if (ctx->result != nullptr) {
        FreeCString(ctx->result);
    }
    napi_delete_async_work(env, ctx->work);
    delete ctx;
}

static napi_value JsStopEngineQuietAsync(napi_env env, napi_callback_info info)
{
    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    napi_create_promise(env, &deferred, &promise);
    auto *ctx = new StopQuietAsyncContext();
    ctx->deferred = deferred;
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "stopEngineQuietAsync", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, ExecuteStopQuietAsync, CompleteStopQuietAsync, ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

struct KickAsyncContext {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string stateDir;
    std::string hostname;
    std::string proxyUrl;
    char *result = nullptr;
};

static void ExecuteKickRestartAsync(napi_env env, void *data)
{
    auto *ctx = static_cast<KickAsyncContext *>(data);
    ctx->result = KickRestartEngine(const_cast<char *>(ctx->stateDir.c_str()),
                                    const_cast<char *>(ctx->hostname.c_str()),
                                    const_cast<char *>(ctx->proxyUrl.c_str()));
}

static void CompleteKickRestartAsync(napi_env env, napi_status status, void *data)
{
    auto *ctx = static_cast<KickAsyncContext *>(data);
    const char *text = (status == napi_ok && ctx->result != nullptr) ? ctx->result
                                                                    : "{\"ok\":false,\"error\":\"async work failed\"}";
    napi_value value = nullptr;
    napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &value);
    napi_resolve_deferred(env, ctx->deferred, value);
    if (ctx->result != nullptr) {
        FreeCString(ctx->result);
    }
    napi_delete_async_work(env, ctx->work);
    delete ctx;
}

static napi_value JsKickRestartAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    napi_create_promise(env, &deferred, &promise);
    auto *ctx = new KickAsyncContext();
    ctx->deferred = deferred;
    ctx->stateDir = GetStringFromValueUtf8(env, args[0]);
    ctx->hostname = GetStringFromValueUtf8(env, args[1]);
    ctx->proxyUrl = GetStringFromValueUtf8(env, args[2]);

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "kickRestartAsync", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, ExecuteKickRestartAsync, CompleteKickRestartAsync, ctx,
                           &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

static napi_value JsEngineVersion(napi_env env, napi_callback_info info)
{
    char *result = EngineVersion();
    return MakeStringFromC(env, result);
}

static napi_value JsListSsNodes(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string yamlPath = GetStringFromValueUtf8(env, args[0]);
    char *result = ListSSNodes(const_cast<char *>(yamlPath.c_str()));
    BRIDGE_LOGI("listSsNodes result=%{public}s", result != nullptr ? result : "");
    return MakeStringFromC(env, result);
}

static napi_value JsSelectSsNode(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string yamlPath = GetStringFromValueUtf8(env, args[0]);
    std::string name = GetStringFromValueUtf8(env, args[1]);
    char *result = SelectSSNode(const_cast<char *>(yamlPath.c_str()), const_cast<char *>(name.c_str()));
    BRIDGE_LOGI("selectSsNode result=%{public}s", result != nullptr ? result : "");
    return MakeStringFromC(env, result);
}

static napi_value JsGetStatus(napi_env env, napi_callback_info info)
{
    char *result = GetStatusJSON();
    // 状态内容由 ArkTS 侧按摘要输出，避免每 10s 全量 JSON 重复进入 hilog
    return MakeStringFromC(env, result);
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"startEngine", nullptr, JsStartEngine, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopEngine", nullptr, JsStopEngine, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopEngineQuiet", nullptr, JsStopEngineQuiet, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopEngineQuietAsync", nullptr, JsStopEngineQuietAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"kickRestart", nullptr, JsKickRestart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"kickRestartAsync", nullptr, JsKickRestartAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"engineVersion", nullptr, JsEngineVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getStatus", nullptr, JsGetStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"listSsNodes", nullptr, JsListSsNodes, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"selectSsNode", nullptr, JsSelectSsNode, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module tailnetBridgeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "tailnet_bridge",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterTailnetBridgeModule(void)
{
    napi_module_register(&tailnetBridgeModule);
}
