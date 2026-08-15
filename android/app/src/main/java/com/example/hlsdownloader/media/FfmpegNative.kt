package com.example.hlsdownloader.media

internal object FfmpegNative {
    init {
        System.loadLibrary("ffmpegkit")
        System.loadLibrary("hlsffmpeg")
    }

    external fun create(arguments: Array<String>): Long
    external fun execute(sessionId: Long): Long
    external fun logs(sessionId: Long): String
    external fun cancel(sessionId: Long)
    external fun destroy(sessionId: Long)
}
