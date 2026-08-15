package com.example.hlsdownloader.background

import android.content.Context
import com.example.hlsdownloader.core.DownloadProgress

class BackgroundExecutionController(context: Context) {
    private val applicationContext = context.applicationContext

    fun start(operationId: String, progress: DownloadProgress) {
        BackgroundExecutionService.start(applicationContext, operationId, progress)
    }

    fun update(operationId: String, progress: DownloadProgress) {
        BackgroundExecutionService.update(applicationContext, operationId, progress)
    }

    fun stop(operationId: String) {
        BackgroundExecutionService.stop(applicationContext, operationId)
    }
}
