#include <jni.h>

#include <android/log.h>
#include <dlfcn.h>
#include <unistd.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

using SessionHandle = void*;
using InitializeFn = void (*)();
using CreateFn = SessionHandle (*)(int, const char**);
using ExecuteFn = void (*)(SessionHandle);
using ReturnCodeFn = int64_t (*)(SessionHandle);
using LogsFn = char* (*)(SessionHandle);
using CancelFn = void (*)(SessionHandle);
using ReleaseFn = void (*)(SessionHandle);
using FreeFn = void (*)(void*);

struct Api {
    void* library = nullptr;
    InitializeFn initialize = nullptr;
    CreateFn create = nullptr;
    ExecuteFn execute = nullptr;
    ReturnCodeFn return_code = nullptr;
    LogsFn logs = nullptr;
    CancelFn cancel = nullptr;
    ReleaseFn release = nullptr;
    FreeFn free_value = nullptr;
    bool ready = false;
};

Api g_api;
std::once_flag g_api_once;

template <typename T>
T symbol(void* library, const char* name) {
    return reinterpret_cast<T>(dlsym(library, name));
}

void initialize_api() {
    g_api.library = dlopen("libffmpegkit.so", RTLD_NOW | RTLD_LOCAL);
    if (g_api.library == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, "HLSFFmpeg", "dlopen failed: %s", dlerror());
        return;
    }
    g_api.initialize = symbol<InitializeFn>(g_api.library, "ffmpeg_kit_initialize");
    g_api.create = symbol<CreateFn>(g_api.library, "ffmpeg_kit_create_session_from_argv");
    g_api.execute = symbol<ExecuteFn>(g_api.library, "ffmpeg_kit_session_execute");
    g_api.return_code = symbol<ReturnCodeFn>(g_api.library, "ffmpeg_kit_session_get_return_code");
    g_api.logs = symbol<LogsFn>(g_api.library, "ffmpeg_kit_session_get_logs_as_string");
    g_api.cancel = symbol<CancelFn>(g_api.library, "ffmpeg_kit_session_cancel");
    g_api.release = symbol<ReleaseFn>(g_api.library, "ffmpeg_kit_handle_release");
    g_api.free_value = symbol<FreeFn>(g_api.library, "ffmpeg_kit_free");
    g_api.ready = g_api.initialize != nullptr && g_api.create != nullptr &&
        g_api.execute != nullptr && g_api.return_code != nullptr && g_api.logs != nullptr &&
        g_api.cancel != nullptr && g_api.release != nullptr && g_api.free_value != nullptr;
    if (g_api.ready) {
        g_api.initialize();
    } else {
        __android_log_print(ANDROID_LOG_ERROR, "HLSFFmpeg", "required FFmpegKit symbol is missing");
    }
}

struct Session {
    explicit Session(SessionHandle value) : handle(value) {}
    ~Session() {
        if (handle != nullptr && g_api.release != nullptr) {
            g_api.release(handle);
        }
    }

    SessionHandle handle;
    std::atomic<bool> cancel_requested{false};
    std::atomic<bool> execution_finished{false};
};

std::mutex g_sessions_mutex;
std::unordered_map<int64_t, std::shared_ptr<Session>> g_sessions;
std::atomic<int64_t> g_next_session_id{1};

std::shared_ptr<Session> session_for(int64_t id) {
    std::lock_guard<std::mutex> lock(g_sessions_mutex);
    auto iterator = g_sessions.find(id);
    return iterator == g_sessions.end() ? nullptr : iterator->second;
}

std::vector<std::string> java_arguments(JNIEnv* env, jobjectArray values) {
    std::vector<std::string> result;
    if (values == nullptr) return result;
    const jsize count = env->GetArrayLength(values);
    result.reserve(static_cast<size_t>(count));
    for (jsize index = 0; index < count; ++index) {
        auto value = static_cast<jstring>(env->GetObjectArrayElement(values, index));
        if (value == nullptr) {
            result.emplace_back();
            continue;
        }
        const char* characters = env->GetStringUTFChars(value, nullptr);
        if (characters == nullptr) {
            env->DeleteLocalRef(value);
            result.clear();
            return result;
        }
        result.emplace_back(characters);
        env->ReleaseStringUTFChars(value, characters);
        env->DeleteLocalRef(value);
    }
    return result;
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_example_hlsdownloader_media_FfmpegNative_create(
    JNIEnv* env,
    jobject,
    jobjectArray arguments
) {
    std::call_once(g_api_once, initialize_api);
    if (!g_api.ready) return 0;

    const std::vector<std::string> storage = java_arguments(env, arguments);
    if (storage.empty() || env->ExceptionCheck()) return 0;
    std::vector<const char*> pointers;
    pointers.reserve(storage.size());
    for (const auto& value : storage) pointers.push_back(value.c_str());

    SessionHandle handle = g_api.create(static_cast<int>(pointers.size()), pointers.data());
    if (handle == nullptr) return 0;
    auto session = std::make_shared<Session>(handle);
    const int64_t id = g_next_session_id.fetch_add(1, std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lock(g_sessions_mutex);
        g_sessions.emplace(id, std::move(session));
    }
    return static_cast<jlong>(id);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_example_hlsdownloader_media_FfmpegNative_execute(JNIEnv*, jobject, jlong session_id) {
    auto session = session_for(static_cast<int64_t>(session_id));
    if (session == nullptr || session->handle == nullptr || !g_api.ready) return -1;
    if (session->cancel_requested.load(std::memory_order_acquire)) {
        session->execution_finished.store(true, std::memory_order_release);
        return 255;
    }
    g_api.execute(session->handle);
    const int64_t result = g_api.return_code(session->handle);
    session->execution_finished.store(true, std::memory_order_release);
    return static_cast<jlong>(result);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_example_hlsdownloader_media_FfmpegNative_logs(JNIEnv* env, jobject, jlong session_id) {
    auto session = session_for(static_cast<int64_t>(session_id));
    if (session == nullptr || session->handle == nullptr || !g_api.ready) {
        return env->NewStringUTF("");
    }
    char* raw_logs = g_api.logs(session->handle);
    if (raw_logs == nullptr) return env->NewStringUTF("");
    std::string value(raw_logs);
    g_api.free_value(raw_logs);
    constexpr size_t maximum_length = 4096;
    if (value.size() > maximum_length) value.erase(0, value.size() - maximum_length);
    return env->NewStringUTF(value.c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_hlsdownloader_media_FfmpegNative_cancel(JNIEnv*, jobject, jlong session_id) {
    auto session = session_for(static_cast<int64_t>(session_id));
    if (session == nullptr || session->handle == nullptr || !g_api.ready) return;
    session->cancel_requested.store(true, std::memory_order_release);
    for (int attempt = 0; attempt < 250; ++attempt) {
        if (session->execution_finished.load(std::memory_order_acquire)) return;
        g_api.cancel(session->handle);
        usleep(1000);
    }
    g_api.cancel(session->handle);
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_hlsdownloader_media_FfmpegNative_destroy(JNIEnv*, jobject, jlong session_id) {
    std::lock_guard<std::mutex> lock(g_sessions_mutex);
    g_sessions.erase(static_cast<int64_t>(session_id));
}
