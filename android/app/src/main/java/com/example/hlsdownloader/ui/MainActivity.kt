package com.example.hlsdownloader.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.example.hlsdownloader.AppContainer

class MainActivity : ComponentActivity() {
    private val requestNotifications = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { }

    private val viewModel: HlsDownloaderViewModel by viewModels {
        HlsDownloaderViewModel.factory(application, AppContainer.service(applicationContext))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        enableEdgeToEdge()
        setContent {
            HlsDownloaderTheme {
                val state = viewModel.state.collectAsStateWithLifecycle().value
                HlsDownloaderScreen(
                    state = state,
                    onInputChanged = viewModel::onInputChanged,
                    onStart = viewModel::start,
                    onStartPlaybackCapture = viewModel::startPlaybackCapture,
                    onFinishPlaybackCapture = viewModel::finishPlaybackCapture,
                    onCaptureEnteredBackground = viewModel::playbackCaptureDidEnterBackground,
                    onDownload = viewModel::download,
                    onCancel = viewModel::cancel,
                    onLoadThumbnail = viewModel::loadThumbnail,
                    onRefreshLog = viewModel::refreshDiagnosticLog,
                    onClearBrowserData = viewModel::clearBrowserData,
                )
            }
        }
    }
}
