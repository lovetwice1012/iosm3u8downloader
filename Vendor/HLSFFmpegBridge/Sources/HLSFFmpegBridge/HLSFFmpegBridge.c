#include "HLSFFmpegBridge.h"

#include <ffmpegkit/ffmpegkit_wrapper.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    FFmpegSessionHandle handle;
    atomic_int cancel_requested;
    atomic_int execution_finished;
} HLSFFmpegRemuxSession;

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

HLSFFmpegRemuxSessionHandle hls_ffmpeg_remux_session_create(
    const char *input_path,
    const char *output_path,
    int preserve_timestamps
) {
    if (input_path == NULL || output_path == NULL) {
        return NULL;
    }

    hls_ffmpeg_initialize_once();

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
    const char *preserved_arguments[] = {
        "-hide_banner",
        "-nostdin",
        "-loglevel", "warning",
        "-y",
        "-copyts",
        "-fflags", "+genpts",
        "-i", input_path,
        "-map", "0:v:0?",
        "-map", "0:a:0?",
        "-sn",
        "-dn",
        "-c", "copy",
        "-avoid_negative_ts", "disabled",
        "-movflags", "+faststart",
        output_path
    };

    const char **arguments;
    int argument_count;
    if (preserve_timestamps) {
        arguments = preserved_arguments;
        argument_count = (int)(sizeof(preserved_arguments) / sizeof(preserved_arguments[0]));
    } else {
        arguments = normalized_arguments;
        argument_count = (int)(sizeof(normalized_arguments) / sizeof(normalized_arguments[0]));
    }

    FFmpegSessionHandle handle = ffmpeg_kit_create_session_from_argv(
        argument_count,
        arguments
    );
    if (handle == NULL) {
        return NULL;
    }

    HLSFFmpegRemuxSession *session = calloc(1, sizeof(HLSFFmpegRemuxSession));
    if (session == NULL) {
        ffmpeg_kit_handle_release(handle);
        return NULL;
    }
    session->handle = handle;
    atomic_init(&session->cancel_requested, 0);
    atomic_init(&session->execution_finished, 0);
    return session;
}

int64_t hls_ffmpeg_remux_session_execute(
    HLSFFmpegRemuxSessionHandle session_handle,
    char *diagnostic_buffer,
    size_t diagnostic_buffer_size
) {
    HLSFFmpegRemuxSession *session = session_handle;
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
    if (atomic_load(&session->cancel_requested)) {
        hls_copy_diagnostic_tail(
            "FFmpeg session was cancelled before execution.",
            diagnostic_buffer,
            diagnostic_buffer_size
        );
        atomic_store(&session->execution_finished, 1);
        return 255;
    }

    ffmpeg_kit_session_execute(session->handle);
    int64_t return_code = ffmpeg_kit_session_get_return_code(session->handle);
    if (return_code != 0) {
        char *logs = ffmpeg_kit_session_get_logs_as_string(session->handle);
        hls_copy_diagnostic_tail(logs, diagnostic_buffer, diagnostic_buffer_size);
        if (logs != NULL) {
            ffmpeg_kit_free(logs);
        }
    }
    atomic_store(&session->execution_finished, 1);
    return return_code;
}

void hls_ffmpeg_remux_session_cancel(HLSFFmpegRemuxSessionHandle session_handle) {
    HLSFFmpegRemuxSession *session = session_handle;
    if (session != NULL && session->handle != NULL) {
        atomic_store(&session->cancel_requested, 1);
        for (int attempt = 0; attempt < 250; attempt++) {
            if (atomic_load(&session->execution_finished)) {
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
    HLSFFmpegRemuxSession *session = session_handle;
    if (session == NULL) {
        return;
    }
    if (session->handle != NULL) {
        ffmpeg_kit_handle_release(session->handle);
        session->handle = NULL;
    }
    free(session);
}
