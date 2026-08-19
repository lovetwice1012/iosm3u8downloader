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
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

typedef struct {
    FFmpegSessionHandle handle;
    std::atomic<int> cancel_requested{0};
    std::atomic<int> execution_finished{0};
    std::vector<std::string> diagnostic_secrets;
    std::string output_path;
    int64_t maximum_output_bytes{0};
    bool is_probe{false};
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
    const std::vector<std::string> &secrets,
    char *destination,
    size_t destination_size
) {
    if (source == NULL || secrets.empty()) {
        hls_copy_diagnostic_tail(source, destination, destination_size);
        return;
    }

    std::string sanitized(source);
    const std::string replacement("<redacted>");
    for (const std::string &secret : secrets) {
        if (secret.empty()) {
            continue;
        }
        size_t position = 0;
        while ((position = sanitized.find(secret, position)) != std::string::npos) {
            sanitized.replace(position, secret.length(), replacement);
            position += replacement.length();
        }
    }
    hls_copy_diagnostic_tail(sanitized.c_str(), destination, destination_size);
}

HLSFFmpegRemuxSessionHandle hls_ffmpeg_remux_session_create(
    const char *input_path,
    const char *audio_input_path,
    const char *output_path,
    int64_t maximum_output_bytes
) {
    if (input_path == NULL || output_path == NULL || maximum_output_bytes <= 0) {
        return NULL;
    }

    hls_ffmpeg_initialize_once();
    if (!hls_ffmpeg_try_acquire_session_gate()) {
        return NULL;
    }

    const std::string maximum_output_text = std::to_string(maximum_output_bytes);
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
        "-fs", maximum_output_text.c_str(),
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
        "-fs", maximum_output_text.c_str(),
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
    session->output_path = output_path;
    session->maximum_output_bytes = maximum_output_bytes;
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
    const char *output_path,
    int64_t maximum_output_bytes
) {
    if (video_input_path == NULL
        || output_path == NULL
        || maximum_output_bytes <= 0
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

    const std::string maximum_output_text = std::to_string(maximum_output_bytes);
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
        "-fs", maximum_output_text.c_str(),
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
    session->output_path = output_path;
    session->maximum_output_bytes = maximum_output_bytes;
    session->diagnostic_secrets.emplace_back(video_decryption_key_hex);
    if (audio_decryption_key_hex != NULL) {
        session->diagnostic_secrets.emplace_back(audio_decryption_key_hex);
    }
    return session;
}

HLSFFmpegRemuxSessionHandle hls_ffmpeg_sample_aes_session_create(
    const char *primary_playlist_path,
    const char *audio_playlist_path,
    const char *output_path,
    int32_t output_mode,
    int64_t maximum_output_bytes
) {
    if (primary_playlist_path == NULL
        || output_path == NULL
        || maximum_output_bytes <= 0) {
        return NULL;
    }
    const bool writes_mp4 = output_mode == HLS_FFMPEG_SAMPLE_AES_OUTPUT_MP4;
    const bool writes_wav = output_mode == HLS_FFMPEG_SAMPLE_AES_OUTPUT_WAV_PCM_S16LE;
    if ((!writes_mp4 && !writes_wav) || (writes_wav && audio_playlist_path != NULL)) {
        return NULL;
    }

    hls_ffmpeg_initialize_once();
    if (!hls_ffmpeg_try_acquire_session_gate()) {
        return NULL;
    }

    // The app creates these playlists itself and gives every resource a fixed,
    // local filename.  Restrict nested HLS access to local protocols even if a
    // malformed playlist reaches the bridge.
    const char *local_protocols = "file,crypto";
    const char *readable_extensions =
        "m3u8,key,ts,m2t,m2ts,mts,mpg,mpeg,mpegts,aac,ac3,eac3,ec3,"
        "m4a,m4s,m4v,mov,mp4,cmfa,cmfv,fmp4";
    const char *media_extensions =
        "ts,m2t,m2ts,mts,mpg,mpeg,mpegts,aac,ac3,eac3,ec3,"
        "m4a,m4s,m4v,mov,mp4,cmfa,cmfv,fmp4";
    const std::string maximum_output_text = std::to_string(maximum_output_bytes);
    std::vector<const char *> arguments = {
        "-hide_banner",
        "-nostdin",
        "-loglevel", "warning",
        "-xerror",
        "-abort_on", "empty_output+empty_output_stream",
        "-y",
        "-copyts",
        "-start_at_zero",
        "-fflags", "+genpts",
        "-err_detect", "explode",
        "-protocol_whitelist", local_protocols,
        "-allowed_extensions", readable_extensions,
        "-allowed_segment_extensions", media_extensions,
        "-i", primary_playlist_path
    };
    if (writes_mp4 && audio_playlist_path != NULL) {
        arguments.insert(arguments.end(), {
            "-isync", "0",
            "-fflags", "+genpts",
            "-err_detect", "explode",
            "-protocol_whitelist", local_protocols,
            "-allowed_extensions", readable_extensions,
            "-allowed_segment_extensions", media_extensions,
            "-i", audio_playlist_path
        });
    }
    if (writes_mp4) {
        arguments.insert(arguments.end(), {
            "-map", "0:v:0",
            "-map", audio_playlist_path != NULL ? "1:a:0" : "0:a:0?",
            "-sn",
            "-dn",
            "-c", "copy",
            "-movflags", "+faststart",
            "-f", "mp4",
            "-fs", maximum_output_text.c_str(),
            output_path
        });
    } else {
        arguments.insert(arguments.end(), {
            "-map", "0:a:0",
            "-vn",
            "-sn",
            "-dn",
            "-c:a", "pcm_s16le",
            "-rf64", "auto",
            "-f", "wav",
            "-fs", maximum_output_text.c_str(),
            output_path
        });
    }

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
    session->output_path = output_path;
    session->maximum_output_bytes = maximum_output_bytes;
    session->owns_session_gate = true;
    return session;
}

HLSFFmpegRemuxSessionHandle hls_ffmpeg_audio_wav_session_create(
    const char *input_path,
    const char *decryption_key_hex,
    const char *output_path,
    int64_t maximum_output_bytes
) {
    if (input_path == NULL || output_path == NULL || maximum_output_bytes <= 0) {
        return NULL;
    }
    if (decryption_key_hex != NULL && !hls_is_hex_key(decryption_key_hex)) {
        return NULL;
    }

    hls_ffmpeg_initialize_once();
    if (!hls_ffmpeg_try_acquire_session_gate()) {
        return NULL;
    }

    const std::string maximum_output_text = std::to_string(maximum_output_bytes);
    std::vector<const char *> arguments = {
        "-hide_banner",
        "-nostdin",
        "-loglevel", "warning",
        "-y",
        "-fflags", "+genpts",
        "-protocol_whitelist", "file,crypto"
    };
    if (decryption_key_hex != NULL) {
        arguments.insert(arguments.end(), {
            "-xerror",
            "-err_detect", "explode",
            "-abort_on", "empty_output+empty_output_stream",
            "-decryption_key", decryption_key_hex
        });
    }
    arguments.insert(arguments.end(), {
        "-i", input_path,
        "-map", "0:a:0",
        "-vn",
        "-sn",
        "-dn",
        "-c:a", "pcm_s16le",
        "-rf64", "auto",
        "-f", "wav",
        "-fs", maximum_output_text.c_str(),
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
    session->output_path = output_path;
    session->maximum_output_bytes = maximum_output_bytes;
    session->owns_session_gate = true;
    if (decryption_key_hex != NULL) {
        session->diagnostic_secrets.emplace_back(decryption_key_hex);
    }
    return session;
}

HLSFFmpegRemuxSessionHandle hls_ffmpeg_media_probe_session_create(
    const char *input_path,
    const char *decryption_key_hex,
    int32_t input_kind
) {
    if (input_path == NULL) {
        return NULL;
    }
    const bool probes_media = input_kind == HLS_FFMPEG_PROBE_INPUT_MEDIA_FILE;
    const bool probes_sample_aes =
        input_kind == HLS_FFMPEG_PROBE_INPUT_SAMPLE_AES_PLAYLIST;
    if ((!probes_media && !probes_sample_aes)
        || (decryption_key_hex != NULL && !hls_is_hex_key(decryption_key_hex))
        || (probes_sample_aes && decryption_key_hex != NULL)) {
        return NULL;
    }

    hls_ffmpeg_initialize_once();
    if (!hls_ffmpeg_try_acquire_session_gate()) {
        return NULL;
    }

    const char *local_protocols = "file,crypto";
    const char *readable_extensions =
        "m3u8,key,ts,m2t,m2ts,mts,mpg,mpeg,mpegts,aac,ac3,eac3,ec3,"
        "m4a,m4s,m4v,mov,mp4,cmfa,cmfv,fmp4";
    const char *media_extensions =
        "ts,m2t,m2ts,mts,mpg,mpeg,mpegts,aac,ac3,eac3,ec3,"
        "m4a,m4s,m4v,mov,mp4,cmfa,cmfv,fmp4";
    std::vector<const char *> arguments = {
        "-v", "error"
    };
    if (probes_sample_aes) {
        arguments.insert(arguments.end(), {
            "-protocol_whitelist", local_protocols,
            "-allowed_extensions", readable_extensions,
            "-allowed_segment_extensions", media_extensions
        });
    } else {
        arguments.insert(arguments.end(), {
            "-protocol_whitelist", local_protocols
        });
        if (decryption_key_hex != NULL) {
            arguments.insert(arguments.end(), {
                "-decryption_key", decryption_key_hex
            });
        }
    }
    arguments.insert(arguments.end(), {
        "-show_entries", "stream=codec_type",
        "-of", "csv=p=0",
        input_path
    });

    FFprobeSessionHandle handle = ffprobe_kit_create_session_from_argv(
        (int)arguments.size(),
        arguments.data()
    );
    if (handle == NULL) {
        ffmpeg_kit_clear_sessions();
        hls_ffmpeg_release_session_gate();
        return NULL;
    }
    ffprobe_kit_set_log_callback(handle, hls_ffmpeg_discard_log, NULL);

    HLSFFmpegRemuxSession *session = new (std::nothrow) HLSFFmpegRemuxSession();
    if (session == NULL) {
        hls_ffmpeg_release_failed_session(handle);
        return NULL;
    }
    session->handle = handle;
    session->is_probe = true;
    session->owns_session_gate = true;
    if (decryption_key_hex != NULL) {
        session->diagnostic_secrets.emplace_back(decryption_key_hex);
    }
    return session;
}

HLSFFmpegRemuxSessionHandle hls_ffmpeg_decode_validation_session_create(
    const char *input_path
) {
    if (input_path == NULL) {
        return NULL;
    }

    hls_ffmpeg_initialize_once();
    if (!hls_ffmpeg_try_acquire_session_gate()) {
        return NULL;
    }

    const char *arguments[] = {
        "-hide_banner",
        "-nostdin",
        "-v", "error",
        "-xerror",
        "-err_detect", "explode",
        "-abort_on", "empty_output+empty_output_stream",
        "-protocol_whitelist", "file,crypto",
        "-i", input_path,
        "-map", "0:v:0?",
        "-map", "0:a:0?",
        "-sn",
        "-dn",
        "-f", "null",
        "-"
    };
    FFmpegSessionHandle handle = ffmpeg_kit_create_session_from_argv(
        (int)(sizeof(arguments) / sizeof(arguments[0])),
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

int32_t hls_ffmpeg_remux_session_add_diagnostic_secret(
    HLSFFmpegRemuxSessionHandle session_handle,
    const char *secret
) {
    HLSFFmpegRemuxSession *session = static_cast<HLSFFmpegRemuxSession *>(session_handle);
    if (session == NULL
        || secret == NULL
        || session->handle == NULL
        || ffmpeg_kit_session_get_state(session->handle)
            != FFMPEG_KIT_SESSION_STATE_CREATED) {
        return 0;
    }
    const size_t length = strnlen(secret, 513);
    if (length == 0 || length > 512 || session->diagnostic_secrets.size() >= 256) {
        return 0;
    }
    session->diagnostic_secrets.emplace_back(secret, length);
    return 1;
}

int32_t hls_ffmpeg_media_probe_session_execute(
    HLSFFmpegRemuxSessionHandle session_handle,
    char *diagnostic_buffer,
    size_t diagnostic_buffer_size
) {
    HLSFFmpegRemuxSession *session = static_cast<HLSFFmpegRemuxSession *>(session_handle);
    if (diagnostic_buffer != NULL && diagnostic_buffer_size > 0) {
        diagnostic_buffer[0] = '\0';
    }
    if (session == NULL || session->handle == NULL || !session->is_probe) {
        hls_copy_diagnostic_tail(
            "FFprobe session could not be created.",
            diagnostic_buffer,
            diagnostic_buffer_size
        );
        return -1;
    }
    if (session->cancel_requested.load(std::memory_order_acquire)) {
        hls_copy_diagnostic_tail(
            "FFprobe session was cancelled before execution.",
            diagnostic_buffer,
            diagnostic_buffer_size
        );
        session->execution_finished.store(1, std::memory_order_release);
        return -1;
    }

    ffprobe_kit_session_execute(session->handle);
    const int64_t return_code = ffmpeg_kit_session_get_return_code(session->handle);
    if (return_code != 0) {
        char *logs = ffmpeg_kit_session_get_logs_as_string(session->handle);
        hls_copy_redacted_diagnostic_tail(
            logs,
            session->diagnostic_secrets,
            diagnostic_buffer,
            diagnostic_buffer_size
        );
        if (logs != NULL) {
            ffmpeg_kit_free(logs);
        }
        session->execution_finished.store(1, std::memory_order_release);
        return -1;
    }

    int32_t tracks = 0;
    char *output = ffmpeg_kit_session_get_output(session->handle);
    if (output != NULL) {
        std::string text(output);
        size_t start = 0;
        while (start <= text.length()) {
            const size_t end = text.find_first_of("\r\n", start);
            const size_t count = end == std::string::npos
                ? text.length() - start
                : end - start;
            std::string line = text.substr(start, count);
            line.erase(0, line.find_first_not_of(" \t"));
            const size_t last = line.find_last_not_of(" \t");
            if (last == std::string::npos) {
                line.clear();
            } else {
                line.erase(last + 1);
            }
            if (line == "audio") {
                tracks |= HLS_FFMPEG_TRACK_AUDIO;
            } else if (line == "video") {
                tracks |= HLS_FFMPEG_TRACK_VIDEO;
            }
            if (end == std::string::npos) {
                break;
            }
            start = end + 1;
        }
        ffmpeg_kit_free(output);
    }
    session->execution_finished.store(1, std::memory_order_release);
    if (tracks == 0) {
        hls_copy_diagnostic_tail(
            "No audio or video streams were found.",
            diagnostic_buffer,
            diagnostic_buffer_size
        );
        return -1;
    }
    return tracks;
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
    if (session == NULL || session->handle == NULL || session->is_probe) {
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
    bool output_limit_failed = false;
    if (return_code == 0 && session->maximum_output_bytes > 0) {
        struct stat output_info;
        if (session->output_path.empty()
            || stat(session->output_path.c_str(), &output_info) != 0
            || output_info.st_size <= 0
            || output_info.st_size >= session->maximum_output_bytes) {
            output_limit_failed = true;
            return_code = -1;
            hls_copy_diagnostic_tail(
                "FFmpeg output was empty or reached its storage limit.",
                diagnostic_buffer,
                diagnostic_buffer_size
            );
        }
    }
    if (return_code != 0 && !output_limit_failed) {
        char *logs = ffmpeg_kit_session_get_logs_as_string(session->handle);
        hls_copy_redacted_diagnostic_tail(
            logs,
            session->diagnostic_secrets,
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
                if (session->is_probe) {
                    ffprobe_kit_cancel_session(
                        ffmpeg_kit_session_get_session_id(session->handle)
                    );
                } else {
                    ffmpeg_kit_session_cancel(session->handle);
                }
                return;
            }
            if (state == FFMPEG_KIT_SESSION_STATE_COMPLETED
                || state == FFMPEG_KIT_SESSION_STATE_FAILED) {
                return;
            }
            usleep(1000);
        }
        if (session->is_probe) {
            ffprobe_kit_cancel_session(
                ffmpeg_kit_session_get_session_id(session->handle)
            );
        } else {
            ffmpeg_kit_session_cancel(session->handle);
        }
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
    for (std::string &secret : session->diagnostic_secrets) {
        std::fill(secret.begin(), secret.end(), '\0');
    }
    session->diagnostic_secrets.clear();
    if (session->owns_session_gate) {
        session->owns_session_gate = false;
        hls_ffmpeg_release_session_gate();
    }
    delete session;
}
