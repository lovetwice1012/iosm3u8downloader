#include "HLSFFmpegBridge.h"

#include <ffmpegkit/ffmpegkit_wrapper.h>
#include <algorithm>
#include <atomic>
#include <dispatch/dispatch.h>
#include <new>
#include <pthread.h>
#include <stdlib.h>
#include <string>
#include <string.h>
#include <unistd.h>
#include <vector>

typedef struct {
    FFmpegSessionHandle handle;
    std::atomic<int> cancel_requested{0};
    std::atomic<int> execution_finished{0};
    std::string diagnostic_secret_one;
    std::string diagnostic_secret_two;
    bool owns_session_gate{false};
} HLSFFmpegRemuxSession;

// FFmpegKit keeps completed sessions (including their argv) in a process-wide
// history.  Serialize every bridge session so destroy can safely clear that
// history without removing another in-flight session.  A dispatch semaphore
// may be acquired and released on different threads, unlike a pthread mutex.
static dispatch_semaphore_t hls_ffmpeg_session_gate(void) {
    static dispatch_semaphore_t gate;
    static dispatch_once_t once_token;
    dispatch_once(&once_token, ^{
        gate = dispatch_semaphore_create(1);
    });
    return gate;
}

static bool hls_ffmpeg_try_acquire_session_gate(void) {
    // Never block a Swift cooperative executor (or MainActor) waiting for a
    // different session whose continuation may need that same executor in
    // order to destroy itself and release the gate.
    return dispatch_semaphore_wait(
        hls_ffmpeg_session_gate(),
        DISPATCH_TIME_NOW
    ) == 0;
}

static void hls_ffmpeg_release_session_gate(void) {
    dispatch_semaphore_signal(hls_ffmpeg_session_gate());
}

// Supplying a session callback prevents FFmpegKit's default log redirection
// from printing the command/session output to stdout.  Logs remain attached to
// the session and are fetched only on failure, where secret values are redacted.
static void hls_ffmpeg_discard_log(
    FFmpegSessionHandle session,
    const char *log,
    void *user_data
) {
    (void)session;
    (void)log;
    (void)user_data;
}

static void hls_ffmpeg_release_failed_session(FFmpegSessionHandle handle) {
    if (handle != NULL) {
        ffmpeg_kit_handle_release(handle);
    }
    ffmpeg_kit_clear_sessions();
    hls_ffmpeg_release_session_gate();
}

static void hls_ffmpeg_initialize(void) {
    ffmpeg_kit_initialize();
}

static void hls_ffmpeg_initialize_once(void) {
    static pthread_once_t once_token = PTHREAD_ONCE_INIT;
    pthread_once(&once_token, hls_ffmpeg_initialize);
}

static void hls_copy_diagnostic_tail(
    const char *source,
    char *destination,
    size_t destination_size
) {
    if (destination == NULL || destination_size == 0) {
        return;
    }
    destination[0] = '\0';
    if (source == NULL) {
        return;
    }

    size_t source_length = strlen(source);
    size_t maximum_length = destination_size - 1;
    const char *start = source;
    if (source_length > maximum_length) {
        start += source_length - maximum_length;
        source_length = maximum_length;
    }
    memcpy(destination, start, source_length);
    destination[source_length] = '\0';
}

static void hls_copy_redacted_diagnostic_tail(
    const char *source,
    const std::string &secret_one,
    const std::string &secret_two,
    char *destination,
    size_t destination_size
) {
    if (source == NULL || (secret_one.empty() && secret_two.empty())) {
        hls_copy_diagnostic_tail(source, destination, destination_size);
        return;
    }

    std::string sanitized(source);
    const std::string replacement("<redacted>");
    const std::string *secrets[] = { &secret_one, &secret_two };
    for (const std::string *secret : secrets) {
        if (secret->empty()) {
            continue;
        }
        size_t position = 0;
        while ((position = sanitized.find(*secret, position)) != std::string::npos) {
            sanitized.replace(position, secret->length(), replacement);
            position += replacement.length();
        }
    }
    hls_copy_diagnostic_tail(sanitized.c_str(), destination, destination_size);
}

HLSFFmpegRemuxSessionHandle hls_ffmpeg_remux_session_create(
    const char *input_path,
    const char *audio_input_path,
    const char *output_path
) {
    if (input_path == NULL || output_path == NULL) {
        return NULL;
    }

    hls_ffmpeg_initialize_once();
    if (!hls_ffmpeg_try_acquire_session_gate()) {
        return NULL;
    }

    const char *normalized_arguments[] = {
        "-hide_banner",
        "-nostdin",
        "-loglevel", "warning",
        "-y",
        "-fflags", "+genpts",
        "-i", input_path,
        "-map", "0:v:0?",
        "-map", "0:a:0?",
        "-sn",
        "-dn",
        "-c", "copy",
        "-avoid_negative_ts", "make_zero",
        "-movflags", "+faststart",
        output_path
    };
    const char *combined_arguments[] = {
        "-hide_banner",
        "-nostdin",
        "-loglevel", "warning",
        "-y",
        "-copyts",
        "-start_at_zero",
        "-fflags", "+genpts",
        "-f", "mpegts",
        "-i", input_path,
        "-isync", "0",
        "-fflags", "+genpts",
        "-f", "mpegts",
        "-i", audio_input_path,
        "-map", "0:v:0",
        "-map", "1:a:0",
        "-sn",
        "-dn",
        "-c", "copy",
        "-movflags", "+faststart",
        output_path
    };

    const char **arguments;
    int argument_count;
    if (audio_input_path != NULL) {
        arguments = combined_arguments;
        argument_count = (int)(sizeof(combined_arguments) / sizeof(combined_arguments[0]));
    } else {
        arguments = normalized_arguments;
        argument_count = (int)(sizeof(normalized_arguments) / sizeof(normalized_arguments[0]));
    }

    FFmpegSessionHandle handle = ffmpeg_kit_create_session_from_argv(
        argument_count,
        arguments
    );
    if (handle == NULL) {
        ffmpeg_kit_clear_sessions();
        hls_ffmpeg_release_session_gate();
        return NULL;
    }
    ffmpeg_kit_set_log_callback(handle, hls_ffmpeg_discard_log, NULL);

    HLSFFmpegRemuxSession *session = new (std::nothrow) HLSFFmpegRemuxSession();
    if (session == NULL) {
        hls_ffmpeg_release_failed_session(handle);
        return NULL;
    }
    session->handle = handle;
    session->owns_session_gate = true;
    return session;
}

static bool hls_is_hex_key(const char *value) {
    if (value == NULL || strlen(value) != 32) {
        return false;
    }
    for (size_t index = 0; index < 32; index++) {
        const char character = value[index];
        const bool decimal = character >= '0' && character <= '9';
        const bool lower = character >= 'a' && character <= 'f';
        const bool upper = character >= 'A' && character <= 'F';
        if (!decimal && !lower && !upper) {
            return false;
        }
    }
    return true;
}

HLSFFmpegRemuxSessionHandle hls_ffmpeg_cenc_session_create(
    const char *video_input_path,
    const char *video_decryption_key_hex,
    const char *audio_input_path,
    const char *audio_decryption_key_hex,
    const char *output_path
) {
    if (video_input_path == NULL
        || output_path == NULL
        || !hls_is_hex_key(video_decryption_key_hex)) {
        return NULL;
    }
    const bool has_audio = audio_input_path != NULL || audio_decryption_key_hex != NULL;
    if (has_audio
        && (audio_input_path == NULL || !hls_is_hex_key(audio_decryption_key_hex))) {
        return NULL;
    }

    hls_ffmpeg_initialize_once();
    if (!hls_ffmpeg_try_acquire_session_gate()) {
        return NULL;
    }

    std::vector<const char *> arguments = {
        "-hide_banner",
        "-nostdin",
        "-loglevel", "warning",
        "-y",
        "-copyts",
        "-start_at_zero",
        "-decryption_key", video_decryption_key_hex,
        "-i", video_input_path
    };
    if (has_audio) {
        arguments.insert(arguments.end(), {
            "-isync", "0",
            "-decryption_key", audio_decryption_key_hex,
            "-i", audio_input_path
        });
    }
    arguments.insert(arguments.end(), {
        "-map", "0:v:0",
        "-map", has_audio ? "1:a:0" : "0:a:0?",
        "-sn",
        "-dn",
        "-c", "copy",
        "-movflags", "+faststart",
        output_path
    });

    FFmpegSessionHandle handle = ffmpeg_kit_create_session_from_argv(
        (int)arguments.size(),
        arguments.data()
    );
    if (handle == NULL) {
        ffmpeg_kit_clear_sessions();
        hls_ffmpeg_release_session_gate();
        return NULL;
    }
    ffmpeg_kit_set_log_callback(handle, hls_ffmpeg_discard_log, NULL);

    HLSFFmpegRemuxSession *session = new (std::nothrow) HLSFFmpegRemuxSession();
    if (session == NULL) {
        hls_ffmpeg_release_failed_session(handle);
        return NULL;
    }
    session->handle = handle;
    session->owns_session_gate = true;
    session->diagnostic_secret_one.assign(video_decryption_key_hex);
    if (audio_decryption_key_hex != NULL) {
        session->diagnostic_secret_two.assign(audio_decryption_key_hex);
    }
    return session;
}

int64_t hls_ffmpeg_remux_session_execute(
    HLSFFmpegRemuxSessionHandle session_handle,
    char *diagnostic_buffer,
    size_t diagnostic_buffer_size
) {
    HLSFFmpegRemuxSession *session = static_cast<HLSFFmpegRemuxSession *>(session_handle);
    if (diagnostic_buffer != NULL && diagnostic_buffer_size > 0) {
        diagnostic_buffer[0] = '\0';
    }
    if (session == NULL || session->handle == NULL) {
        hls_copy_diagnostic_tail(
            "FFmpeg session could not be created.",
            diagnostic_buffer,
            diagnostic_buffer_size
        );
        return -1;
    }
    if (session->cancel_requested.load(std::memory_order_acquire)) {
        hls_copy_diagnostic_tail(
            "FFmpeg session was cancelled before execution.",
            diagnostic_buffer,
            diagnostic_buffer_size
        );
        session->execution_finished.store(1, std::memory_order_release);
        return 255;
    }

    ffmpeg_kit_session_execute(session->handle);
    int64_t return_code = ffmpeg_kit_session_get_return_code(session->handle);
    if (return_code != 0) {
        char *logs = ffmpeg_kit_session_get_logs_as_string(session->handle);
        hls_copy_redacted_diagnostic_tail(
            logs,
            session->diagnostic_secret_one,
            session->diagnostic_secret_two,
            diagnostic_buffer,
            diagnostic_buffer_size
        );
        if (logs != NULL) {
            ffmpeg_kit_free(logs);
        }
    }
    session->execution_finished.store(1, std::memory_order_release);
    return return_code;
}

void hls_ffmpeg_remux_session_cancel(HLSFFmpegRemuxSessionHandle session_handle) {
    HLSFFmpegRemuxSession *session = static_cast<HLSFFmpegRemuxSession *>(session_handle);
    if (session != NULL && session->handle != NULL) {
        session->cancel_requested.store(1, std::memory_order_release);
        for (int attempt = 0; attempt < 250; attempt++) {
            if (session->execution_finished.load(std::memory_order_acquire)) {
                return;
            }
            FFmpegKitSessionState state = ffmpeg_kit_session_get_state(session->handle);
            if (state == FFMPEG_KIT_SESSION_STATE_RUNNING) {
                ffmpeg_kit_session_cancel(session->handle);
                return;
            }
            if (state == FFMPEG_KIT_SESSION_STATE_COMPLETED
                || state == FFMPEG_KIT_SESSION_STATE_FAILED) {
                return;
            }
            usleep(1000);
        }
        ffmpeg_kit_session_cancel(session->handle);
    }
}

void hls_ffmpeg_remux_session_destroy(HLSFFmpegRemuxSessionHandle session_handle) {
    HLSFFmpegRemuxSession *session = static_cast<HLSFFmpegRemuxSession *>(session_handle);
    if (session == NULL) {
        return;
    }
    if (session->handle != NULL) {
        ffmpeg_kit_handle_release(session->handle);
        session->handle = NULL;
    }
    // This is the history-only clear.  Do not use
    // ffmpeg_kit_config_clear_sessions(), which also cancels registered work.
    // The global gate guarantees no other bridge session can be affected.
    ffmpeg_kit_clear_sessions();
    std::fill(
        session->diagnostic_secret_one.begin(),
        session->diagnostic_secret_one.end(),
        '\0'
    );
    std::fill(
        session->diagnostic_secret_two.begin(),
        session->diagnostic_secret_two.end(),
        '\0'
    );
    if (session->owns_session_gate) {
        session->owns_session_gate = false;
        hls_ffmpeg_release_session_gate();
    }
    delete session;
}
