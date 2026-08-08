#ifndef HLS_FFMPEG_BRIDGE_H
#define HLS_FFMPEG_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *HLSFFmpegRemuxSessionHandle;

HLSFFmpegRemuxSessionHandle hls_ffmpeg_remux_session_create(
    const char *input_path,
    const char *output_path,
    int preserve_timestamps
);

int64_t hls_ffmpeg_remux_session_execute(
    HLSFFmpegRemuxSessionHandle session,
    char *diagnostic_buffer,
    size_t diagnostic_buffer_size
);

void hls_ffmpeg_remux_session_cancel(HLSFFmpegRemuxSessionHandle session);
void hls_ffmpeg_remux_session_destroy(HLSFFmpegRemuxSessionHandle session);

#ifdef __cplusplus
}
#endif

#endif
