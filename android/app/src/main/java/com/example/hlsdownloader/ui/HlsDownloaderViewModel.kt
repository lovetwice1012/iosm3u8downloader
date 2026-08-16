package com.example.hlsdownloader.ui

import android.app.Application
import android.os.Environment
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.example.hlsdownloader.background.BackgroundExecutionController
import com.example.hlsdownloader.background.BackgroundOperationSnapshot
import com.example.hlsdownloader.background.BackgroundOperationRegistry
import com.example.hlsdownloader.capture.PlaybackCaptureSession
import com.example.hlsdownloader.capture.PersistentWebProfile
import com.example.hlsdownloader.capture.toDynamicPageInspection
import com.example.hlsdownloader.core.DownloadPhase
import com.example.hlsdownloader.core.DownloadProgress
import com.example.hlsdownloader.core.HlsCandidate
import com.example.hlsdownloader.core.HlsDownloadService
import com.example.hlsdownloader.core.HlsException
import com.example.hlsdownloader.core.UriResolver
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.File
import java.util.UUID

data class HlsDownloaderUiState(
    val inputUrl: String = "",
    val progress: DownloadProgress = DownloadProgress(DownloadPhase.IDLE, 0, 0),
    val candidates: List<HlsCandidate> = emptyList(),
    val thumbnails: Map<String, ByteArray> = emptyMap(),
    val outputFile: File? = null,
    val downloadedSegmentCount: Int = 0,
    val errorMessage: String? = null,
    val diagnosticLog: String = "",
    val isOperationActive: Boolean = false,
    val isCancelling: Boolean = false,
    val isPreparingPlaybackCapture: Boolean = false,
    val isFinalizingPlaybackCapture: Boolean = false,
    val isClearingBrowserData: Boolean = false,
    val browserDataMessage: String? = null,
    val playbackCaptureSession: PlaybackCaptureSession? = null,
) {
    val isBusy: Boolean
        get() = isOperationActive || isCancelling || isPreparingPlaybackCapture ||
            isFinalizingPlaybackCapture || isClearingBrowserData || playbackCaptureSession != null

    val canStart: Boolean
        get() = !isBusy && inputUrl.isNotBlank()
}

class HlsDownloaderViewModel(
    application: Application,
    private val service: HlsDownloadService,
) : AndroidViewModel(application) {
    private val _state = MutableStateFlow(HlsDownloaderUiState())
    val state: StateFlow<HlsDownloaderUiState> = _state.asStateFlow()

    private var foregroundJob: Job? = null
    private var foregroundOperationId: String? = null
    private val backgroundExecution = BackgroundExecutionController(application)
    private var discoveredInput: String? = null
    private var captureInput: String? = null
    private val attemptedThumbnails = mutableSetOf<String>()

    init {
        // A new ViewModel (including one created after Activity recreation)
        // adopts the process-owned operation and its latest visible result.
        viewModelScope.launch {
            BackgroundOperationRegistry.snapshot.collectLatest(::applyBackgroundSnapshot)
        }
        applyBackgroundSnapshot(BackgroundOperationRegistry.snapshot.value)
    }

    fun onInputChanged(value: String) {
        if (BackgroundOperationRegistry.snapshot.value.running) return
        val previous = _state.value.inputUrl.trim()
        val next = value.trim()
        if (previous != next && next != discoveredInput) {
            BackgroundOperationRegistry.clearIfIdle()
            _state.update {
                it.copy(
                    inputUrl = value,
                    candidates = emptyList(),
                    thumbnails = emptyMap(),
                    outputFile = null,
                    downloadedSegmentCount = 0,
                    errorMessage = null,
                    progress = DownloadProgress(DownloadPhase.IDLE, 0, 0),
                )
            }
            discoveredInput = null
            attemptedThumbnails.clear()
        } else {
            _state.update { it.copy(inputUrl = value) }
        }
    }

    fun start() {
        if (!_state.value.canStart) return
        val input = _state.value.inputUrl.trim()
        service.resetDiagnosticLog()
        attemptedThumbnails.clear()
        discoveredInput = null
        val id = UUID.randomUUID().toString()
        launchBackgroundOperation(
            initial = BackgroundOperationSnapshot(
                operationId = id,
                inputUrl = input,
                progress = DownloadProgress(DownloadPhase.RESOLVING, 0, 0),
                diagnosticLog = service.diagnosticLogText(),
                running = true,
            ),
        ) { foregroundLease ->
            val discovery = service.discover(input)
            ensureCurrentBackgroundOperation(id, input)
            if (discovery.isDirectPlaylist && discovery.candidates.firstOrNull() != null) {
                downloadCandidateInternal(discovery.candidates.first(), input, id, foregroundLease)
            } else {
                BackgroundOperationRegistry.update(id) {
                    it.copy(
                        discoveredInput = input,
                        candidates = discovery.candidates,
                        progress = DownloadProgress(DownloadPhase.IDLE, 0, 0),
                    )
                }
            }
        }
    }

    fun download(candidate: HlsCandidate) {
        if (_state.value.isBusy || _state.value.candidates.none { it.id == candidate.id }) return
        val input = discoveredInput ?: _state.value.inputUrl.trim()
        val id = UUID.randomUUID().toString()
        launchBackgroundOperation(
            initial = BackgroundOperationSnapshot(
                operationId = id,
                inputUrl = input,
                discoveredInput = input,
                candidates = _state.value.candidates,
                outputFile = null,
                downloadedSegmentCount = 0,
                errorMessage = null,
                progress = DownloadProgress(DownloadPhase.RESOLVING, 0, 0),
                diagnosticLog = service.diagnosticLogText(),
                running = true,
            ),
        ) { foregroundLease ->
            downloadCandidateInternal(candidate, input, id, foregroundLease)
        }
    }

    fun startPlaybackCapture() {
        if (!_state.value.canStart || BackgroundOperationRegistry.snapshot.value.running) return
        val input = _state.value.inputUrl.trim()
        BackgroundOperationRegistry.clearIfIdle()
        service.resetDiagnosticLog()
        val id = UUID.randomUUID().toString()
        foregroundOperationId = id
        _state.update {
            it.copy(
                outputFile = null,
                downloadedSegmentCount = 0,
                errorMessage = null,
                progress = DownloadProgress(DownloadPhase.RESOLVING, 0, 0),
                isOperationActive = true,
                isPreparingPlaybackCapture = true,
            )
        }
        foregroundJob = viewModelScope.launch {
            var lateSession: PlaybackCaptureSession? = null
            try {
                val rootUrl = UriResolver.normalizeInput(input)
                val session = PlaybackCaptureSession.create(
                    context = getApplication(),
                    rootUrl = rootUrl,
                    seedCookies = service.cookiesFor(rootUrl),
                    interactive = true,
                    diagnosticSink = service::recordDiagnostic,
                )
                lateSession = session
                session.start()
                ensureCurrentForegroundOperation(id, input)
                captureInput = input
                discoveredInput = input
                _state.update {
                    it.copy(
                        playbackCaptureSession = session,
                        isPreparingPlaybackCapture = false,
                        progress = DownloadProgress(DownloadPhase.IDLE, 0, 0),
                    )
                }
                lateSession = null
            } catch (error: Throwable) {
                lateSession?.let { session ->
                    runCatching { session.snapshotAndStop() }
                    session.dispose()
                }
                handleForegroundError(error, id)
            } finally {
                if (foregroundOperationId == id) {
                    _state.update { it.copy(isPreparingPlaybackCapture = false) }
                }
                finishForegroundOperation(id)
            }
        }
    }

    fun finishPlaybackCapture(mergeResults: Boolean = true) {
        val session = _state.value.playbackCaptureSession ?: return
        if (_state.value.isFinalizingPlaybackCapture) return
        _state.update {
            it.copy(
                isFinalizingPlaybackCapture = true,
                isOperationActive = true,
                errorMessage = null,
            )
        }
        val id = UUID.randomUUID().toString()
        foregroundOperationId = id
        foregroundJob = viewModelScope.launch {
            try {
                val snapshot = session.snapshotAndStop()
                val capturedCandidates = service.importDynamicInspection(
                    snapshot.toDynamicPageInspection(),
                    session.rootUrl,
                )
                val inputStillMatches = captureInput == _state.value.inputUrl.trim()
                if (mergeResults && inputStillMatches) {
                    val merged = mergeCandidates(_state.value.candidates, capturedCandidates)
                    _state.update {
                        it.copy(
                            candidates = merged,
                            errorMessage = if (merged.isEmpty()) {
                                "再生通信からHLS候補を検出できませんでした。動画を再生してから、もう一度お試しください。"
                            } else {
                                null
                            },
                        )
                    }
                }
            } catch (error: Throwable) {
                handleForegroundError(error, id)
            } finally {
                if (foregroundOperationId == id) {
                    captureInput = null
                    _state.update {
                        it.copy(
                            playbackCaptureSession = null,
                            isFinalizingPlaybackCapture = false,
                            progress = DownloadProgress(DownloadPhase.IDLE, 0, 0),
                        )
                    }
                }
                session.dispose()
                finishForegroundOperation(id)
            }
        }
    }

    fun playbackCaptureDidEnterBackground() {
        if (_state.value.playbackCaptureSession != null) {
            finishPlaybackCapture()
        } else if (_state.value.isPreparingPlaybackCapture) {
            cancel()
        }
    }

    fun cancel() {
        if (_state.value.isFinalizingPlaybackCapture) return
        foregroundJob?.let { job ->
            _state.update { it.copy(isCancelling = true) }
            job.cancel()
            return
        }
        val id = BackgroundOperationRegistry.snapshot.value.operationId ?: return
        BackgroundOperationRegistry.cancel(id)
    }

    fun refreshDiagnosticLog() {
        val log = service.diagnosticLogText()
        if (foregroundOperationId != null || _state.value.playbackCaptureSession != null) {
            _state.update { it.copy(diagnosticLog = log) }
            return
        }
        val id = BackgroundOperationRegistry.snapshot.value.operationId
        if (id == null || !BackgroundOperationRegistry.update(id) { it.copy(diagnosticLog = log) }) {
            _state.update { it.copy(diagnosticLog = log) }
        }
    }

    fun clearBrowserData() {
        if (_state.value.isBusy) return
        _state.update { it.copy(isClearingBrowserData = true, browserDataMessage = null) }
        viewModelScope.launch {
            try {
                val removedCookies = try {
                    PersistentWebProfile.clearAllData(getApplication())
                } finally {
                    service.clearCookies()
                }
                service.recordDiagnostic(
                    "webview-profile",
                    "persistent browser data cleared cookiesPresent=$removedCookies",
                )
                _state.update {
                    it.copy(browserDataMessage = "Cookie、ログイン状態、サイト保存領域、キャッシュを消去しました。")
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                service.recordDiagnostic(
                    "webview-profile",
                    "persistent browser data clear failed error=${error::class.simpleName ?: "error"}",
                )
                _state.update { it.copy(browserDataMessage = "ブラウザデータを消去できませんでした。") }
            } finally {
                _state.update { it.copy(isClearingBrowserData = false) }
            }
        }
    }

    fun loadThumbnail(candidate: HlsCandidate) {
        if (candidate.thumbnailUrl == null || candidate.id in attemptedThumbnails) return
        attemptedThumbnails += candidate.id
        viewModelScope.launch {
            val data = try {
                service.thumbnailData(candidate)
            } catch (error: CancellationException) {
                attemptedThumbnails -= candidate.id
                throw error
            } catch (_: Throwable) {
                null
            } ?: return@launch
            if (_state.value.candidates.any { it.id == candidate.id }) {
                _state.update { it.copy(thumbnails = it.thumbnails + (candidate.id to data)) }
            }
        }
    }

    override fun onCleared() {
        // BackgroundOperationRegistry, not this ViewModel, owns downloads.
        // Interactive playback capture remains foreground-only.
        foregroundJob?.cancel()
        _state.value.playbackCaptureSession?.let { session ->
            // viewModelScope is cancelled by ViewModel.clear(), so use a short
            // independent Main scope to remove the JavaScript bridge and
            // destroy the WebView on every terminal path.
            val cleanupScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            cleanupScope.launch {
                runCatching { session.snapshotAndStop() }
                session.dispose()
                cleanupScope.cancel()
            }
        }
        super.onCleared()
    }

    private suspend fun downloadCandidateInternal(
        candidate: HlsCandidate,
        input: String,
        id: String,
        foregroundLease: Boolean,
    ) {
        val result = service.download(candidate, outputDirectory()) { progress ->
            if (BackgroundOperationRegistry.update(id) { it.copy(progress = progress) } && foregroundLease) {
                backgroundExecution.update(id, progress)
            }
        }
        ensureCurrentBackgroundOperation(id, input)
        BackgroundOperationRegistry.update(id) {
            it.copy(
                outputFile = result.outputFile,
                downloadedSegmentCount = result.segmentCount,
                progress = DownloadProgress(DownloadPhase.COMPLETED, result.segmentCount, result.segmentCount),
            )
        }
    }

    private fun outputDirectory(): File {
        val application = getApplication<Application>()
        val directory = application.getExternalFilesDir(Environment.DIRECTORY_MOVIES)
            ?: File(application.filesDir, "downloads")
        directory.mkdirs()
        return directory
    }

    private fun ensureCurrentBackgroundOperation(id: String, expectedInput: String) {
        val current = BackgroundOperationRegistry.snapshot.value
        if (current.operationId != id || current.inputUrl.trim() != expectedInput) {
            throw CancellationException("Input or operation changed")
        }
    }

    private fun ensureCurrentForegroundOperation(id: String, expectedInput: String) {
        if (foregroundOperationId != id || _state.value.inputUrl.trim() != expectedInput) {
            throw CancellationException("Input or operation changed")
        }
    }

    private fun handleBackgroundError(error: Throwable, id: String) {
        if (error is CancellationException || error is HlsException.Cancelled) {
            BackgroundOperationRegistry.update(id) {
                it.copy(progress = DownloadProgress(DownloadPhase.IDLE, 0, 0))
            }
        } else {
            BackgroundOperationRegistry.update(id) { current ->
                current.copy(
                    errorMessage = error.message ?: "処理に失敗しました。",
                    progress = DownloadProgress(DownloadPhase.IDLE, 0, 0),
                )
            }
        }
        BackgroundOperationRegistry.update(id) { it.copy(diagnosticLog = service.diagnosticLogText()) }
    }

    private fun handleForegroundError(error: Throwable, id: String) {
        if (foregroundOperationId != id) return
        if (error is CancellationException || error is HlsException.Cancelled) {
            _state.update { it.copy(progress = DownloadProgress(DownloadPhase.IDLE, 0, 0)) }
        } else {
            _state.update {
                it.copy(
                    errorMessage = error.message ?: "処理に失敗しました。",
                    progress = DownloadProgress(DownloadPhase.IDLE, 0, 0),
                )
            }
        }
        refreshDiagnosticLog()
    }

    private fun finishForegroundOperation(id: String) {
        if (foregroundOperationId == id) {
            foregroundJob = null
            foregroundOperationId = null
            _state.update {
                it.copy(
                    isOperationActive = false,
                    isCancelling = false,
                    diagnosticLog = service.diagnosticLogText(),
                )
            }
        }
    }

    private fun launchBackgroundOperation(
        initial: BackgroundOperationSnapshot,
        block: suspend (foregroundLease: Boolean) -> Unit,
    ) {
        val id = requireNotNull(initial.operationId)
        var foregroundLease = false
        val launched = BackgroundOperationRegistry.launch(
            initial = initial,
            onRegistered = {
                foregroundLease = runCatching {
                    backgroundExecution.start(id, initial.progress)
                }.onFailure {
                    service.recordDiagnostic("background", "foreground execution could not start")
                }.isSuccess
            },
        ) {
            try {
                block(foregroundLease)
            } catch (error: Throwable) {
                handleBackgroundError(error, id)
            } finally {
                BackgroundOperationRegistry.update(id) {
                    it.copy(diagnosticLog = service.diagnosticLogText())
                }
                if (foregroundLease) backgroundExecution.stop(id)
            }
        }
        // Synchronize immediately as well as through StateFlow so two quick
        // taps cannot observe stale ViewModel state before collection resumes.
        applyBackgroundSnapshot(BackgroundOperationRegistry.snapshot.value)
        if (!launched) service.recordDiagnostic("background", "another operation is already running")
    }

    private fun applyBackgroundSnapshot(snapshot: BackgroundOperationSnapshot) {
        if (snapshot.operationId == null) return
        discoveredInput = snapshot.discoveredInput
        val candidateIds = snapshot.candidates.mapTo(hashSetOf()) { it.id }
        _state.update { current ->
            current.copy(
                inputUrl = snapshot.inputUrl,
                progress = snapshot.progress,
                candidates = snapshot.candidates,
                thumbnails = current.thumbnails.filterKeys(candidateIds::contains),
                outputFile = snapshot.outputFile,
                downloadedSegmentCount = snapshot.downloadedSegmentCount,
                errorMessage = snapshot.errorMessage,
                diagnosticLog = snapshot.diagnosticLog,
                isOperationActive = snapshot.running,
                isCancelling = snapshot.cancelling,
            )
        }
    }

    private fun mergeCandidates(
        existing: List<HlsCandidate>,
        additions: List<HlsCandidate>,
    ): List<HlsCandidate> {
        val result = existing.toMutableList()
        additions.forEach { candidate ->
            val identity = candidateIdentity(candidate)
            val index = result.indexOfFirst { candidateIdentity(it) == identity }
            if (index < 0) {
                result += candidate
            } else {
                val current = result[index]
                result[index] = current.copy(
                    request = if (current.request.sameOriginQueryFallback != null) current.request else candidate.request,
                    requestReferer = current.requestReferer ?: candidate.requestReferer,
                    document = current.document ?: candidate.document,
                    title = current.title ?: candidate.title,
                    thumbnailUrl = current.thumbnailUrl ?: candidate.thumbnailUrl,
                    iframeDepth = minOf(current.iframeDepth, candidate.iframeDepth),
                )
            }
        }
        return result
    }

    private fun candidateIdentity(candidate: HlsCandidate): String =
        "${candidate.playlistUrl.newBuilder().fragment(null).build()}\n" +
            (candidate.requestReferer ?: candidate.pageUrl).newBuilder().fragment(null).build()

    companion object {
        fun factory(application: Application, service: HlsDownloadService): ViewModelProvider.Factory =
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T =
                    HlsDownloaderViewModel(application, service) as T
            }
    }
}
