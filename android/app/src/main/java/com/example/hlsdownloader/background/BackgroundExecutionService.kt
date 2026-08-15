package com.example.hlsdownloader.background

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.example.hlsdownloader.core.DownloadPhase
import com.example.hlsdownloader.core.DownloadProgress
import com.example.hlsdownloader.ui.MainActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Keeps a user-started discovery/download/remux operation alive after the UI
 * leaves the foreground. [BackgroundOperationRegistry] owns the structured
 * coroutine; this service owns its visible foreground execution lease and
 * exposes cancellation from the notification.
 */
class BackgroundExecutionService : Service() {
    private var activeOperationId: String? = null
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    override fun onCreate() {
        super.onCreate()
        createChannel()
        serviceScope.launch {
            BackgroundOperationRegistry.snapshot.collectLatest { snapshot ->
                val activeId = activeOperationId ?: return@collectLatest
                if (snapshot.operationId != activeId || (!snapshot.running && !snapshot.cancelling)) {
                    tearDownForeground()
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val operationId = intent?.getStringExtra(EXTRA_OPERATION_ID) ?: return START_NOT_STICKY
        when (intent.action) {
            ACTION_STOP -> {
                // A terminal STOP can arrive after the registry observer has
                // already torn the service down. If that intent recreates the
                // service, it must still stop instead of becoming stranded.
                if (activeOperationId == null || operationId == activeOperationId) {
                    tearDownForeground()
                }
            }
            ACTION_CANCEL -> {
                if (operationId == activeOperationId) {
                    // Keep the foreground lease while structured cancellation
                    // and file cleanup run. The operation's terminal STOP (or
                    // the registry observer) is the sole teardown path.
                    BackgroundOperationRegistry.cancel(operationId)
                }
            }
            ACTION_START, ACTION_UPDATE -> {
                activeOperationId = operationId
                val progress = DownloadProgress(
                    phase = intent.downloadPhase(),
                    completedItems = intent.getIntExtra(EXTRA_COMPLETED, 0),
                    totalItems = intent.getIntExtra(EXTRA_TOTAL, 0),
                )
                ServiceCompat.startForeground(
                    this,
                    NOTIFICATION_ID,
                    notification(progress, operationId),
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC or
                            if (Build.VERSION.SDK_INT >= 35) {
                                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING
                            } else {
                                0
                            }
                    } else {
                        0
                    },
                )
                val registered = BackgroundOperationRegistry.snapshot.value
                if (registered.operationId != operationId ||
                    (!registered.running && !registered.cancelling)
                ) {
                    tearDownForeground()
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTimeout(startId: Int, fgsType: Int) {
        activeOperationId?.let { operationId ->
            BackgroundOperationRegistry.update(operationId) { current ->
                val timeoutLine = "background: foreground service timed out"
                current.copy(
                    diagnosticLog = listOf(current.diagnosticLog, timeoutLine)
                        .filter(String::isNotBlank)
                        .joinToString("\n"),
                )
            }
            BackgroundOperationRegistry.cancel(operationId)
        }
        activeOperationId = null
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf(startId)
    }

    override fun onDestroy() {
        // If the service is destroyed without going through a terminal STOP,
        // do not leave an in-process download running without its required
        // foreground execution lease.
        activeOperationId?.let(BackgroundOperationRegistry::cancel)
        activeOperationId = null
        serviceScope.cancel()
        super.onDestroy()
    }

    private fun notification(progress: DownloadProgress, operationId: String): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("HLS Downloader")
            .setContentText(progress.phase.notificationTitle)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "キャンセル",
                PendingIntent.getService(
                    this,
                    operationId.hashCode(),
                    Intent(this, BackgroundExecutionService::class.java).apply {
                        action = ACTION_CANCEL
                        putExtra(EXTRA_OPERATION_ID, operationId)
                    },
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )

        if (progress.phase == DownloadPhase.DOWNLOADING && progress.totalItems > 0) {
            builder.setProgress(progress.totalItems, progress.completedItems.coerceAtMost(progress.totalItems), false)
        } else {
            builder.setProgress(0, 0, true)
        }
        return builder.build()
    }

    private fun tearDownForeground() {
        activeOperationId = null
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun createChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                getString(com.example.hlsdownloader.R.string.download_notification_channel),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = getString(
                    com.example.hlsdownloader.R.string.download_notification_description,
                )
                setShowBadge(false)
            },
        )
    }

    private fun Intent.downloadPhase(): DownloadPhase =
        getStringExtra(EXTRA_PHASE)
            ?.let { value -> DownloadPhase.entries.firstOrNull { it.name == value } }
            ?: DownloadPhase.RESOLVING

    private val DownloadPhase.notificationTitle: String
        get() = when (this) {
            DownloadPhase.IDLE -> "処理を準備中"
            DownloadPhase.RESOLVING -> "リンクを解析中"
            DownloadPhase.DOWNLOADING -> "動画断片をダウンロード中"
            DownloadPhase.COMPOSING -> "MP4に結合中"
            DownloadPhase.COMPLETED -> "完了処理中"
        }

    companion object {
        private const val CHANNEL_ID = "hls-download-progress"
        private const val NOTIFICATION_ID = 41021
        private const val ACTION_START = "com.example.hlsdownloader.background.START"
        private const val ACTION_UPDATE = "com.example.hlsdownloader.background.UPDATE"
        private const val ACTION_STOP = "com.example.hlsdownloader.background.STOP"
        private const val ACTION_CANCEL = "com.example.hlsdownloader.background.CANCEL"
        private const val EXTRA_OPERATION_ID = "operation_id"
        private const val EXTRA_PHASE = "phase"
        private const val EXTRA_COMPLETED = "completed"
        private const val EXTRA_TOTAL = "total"

        fun start(context: Context, operationId: String, progress: DownloadProgress) {
            val intent = intent(context, ACTION_START, operationId, progress)
            ContextCompat.startForegroundService(context, intent)
        }

        fun update(context: Context, operationId: String, progress: DownloadProgress) {
            val intent = intent(context, ACTION_UPDATE, operationId, progress)
            runCatching { context.startService(intent) }
        }

        fun stop(context: Context, operationId: String) {
            runCatching {
                context.startService(
                    Intent(context, BackgroundExecutionService::class.java).apply {
                        action = ACTION_STOP
                        putExtra(EXTRA_OPERATION_ID, operationId)
                    },
                )
            }
        }

        private fun intent(
            context: Context,
            action: String,
            operationId: String,
            progress: DownloadProgress,
        ): Intent = Intent(context, BackgroundExecutionService::class.java).apply {
            this.action = action
            putExtra(EXTRA_OPERATION_ID, operationId)
            putExtra(EXTRA_PHASE, progress.phase.name)
            putExtra(EXTRA_COMPLETED, progress.completedItems)
            putExtra(EXTRA_TOTAL, progress.totalItems)
        }
    }
}
