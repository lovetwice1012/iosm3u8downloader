package com.example.hlsdownloader.background

import com.example.hlsdownloader.core.DownloadPhase
import com.example.hlsdownloader.core.DownloadProgress
import com.example.hlsdownloader.core.HlsCandidate
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File

/**
 * Process-local state for a user-started discovery/download operation.
 *
 * Keeping the visible result here, rather than in one ViewModel instance,
 * lets a recreated Activity immediately reattach to the running operation or
 * its completed result. This is deliberately not persistent work: Android can
 * still terminate the process and the operation is not resumed after reboot.
 */
data class BackgroundOperationSnapshot(
    val operationId: String? = null,
    val inputUrl: String = "",
    val discoveredInput: String? = null,
    val progress: DownloadProgress = DownloadProgress(DownloadPhase.IDLE, 0, 0),
    val candidates: List<HlsCandidate> = emptyList(),
    val outputFile: File? = null,
    val downloadedSegmentCount: Int = 0,
    val errorMessage: String? = null,
    val diagnosticLog: String = "",
    val running: Boolean = false,
    val cancelling: Boolean = false,
)

/**
 * Owns the sole process-wide background operation independently of an
 * Activity/ViewModel. Registration, completion and state changes are guarded
 * by one lock so a fast operation cannot finish before ownership is recorded.
 */
object BackgroundOperationRegistry {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Any()
    private val _snapshot = MutableStateFlow(BackgroundOperationSnapshot())
    private var currentJob: Job? = null

    val snapshot: StateFlow<BackgroundOperationSnapshot> = _snapshot.asStateFlow()

    /**
     * Atomically registers and starts an operation. [onRegistered] runs after
     * registration and before the coroutine starts, which allows callers to
     * acquire the foreground-service lease without a fast-completion race.
     *
     * Returns false when another process-wide operation already owns the slot.
     */
    fun launch(
        initial: BackgroundOperationSnapshot,
        onRegistered: () -> Unit = {},
        block: suspend CoroutineScope.() -> Unit,
    ): Boolean {
        require(initial.operationId != null) { "An operation id is required" }
        require(initial.running) { "A launched operation must start in the running state" }

        lateinit var job: Job
        synchronized(lock) {
            if (currentJob != null || _snapshot.value.running || _snapshot.value.cancelling) {
                return false
            }
            job = scope.launch(start = CoroutineStart.LAZY, block = block)
            currentJob = job
            _snapshot.value = initial.copy(cancelling = false)
            job.invokeOnCompletion {
                synchronized(lock) {
                    if (currentJob === job) currentJob = null
                    if (_snapshot.value.operationId == initial.operationId) {
                        _snapshot.value = _snapshot.value.copy(running = false, cancelling = false)
                    }
                }
            }
        }

        try {
            onRegistered()
        } catch (error: Throwable) {
            job.cancel()
            throw error
        }
        job.start()
        return true
    }

    /** Updates only when [operationId] still owns the visible state. */
    fun update(
        operationId: String,
        transform: (BackgroundOperationSnapshot) -> BackgroundOperationSnapshot,
    ): Boolean = synchronized(lock) {
        val current = _snapshot.value
        if (current.operationId != operationId) return@synchronized false
        _snapshot.value = transform(current).copy(operationId = operationId)
        true
    }

    fun cancel(operationId: String): Boolean {
        val job = synchronized(lock) {
            val current = _snapshot.value
            if (current.operationId != operationId || currentJob == null) return false
            _snapshot.value = current.copy(running = true, cancelling = true)
            currentJob
        }
        job?.cancel()
        return job != null
    }

    fun cancelCurrent(): Boolean = snapshot.value.operationId?.let(::cancel) ?: false

    /** Clears an old result without ever disturbing a running operation. */
    fun clearIfIdle(): Boolean = synchronized(lock) {
        if (currentJob != null || _snapshot.value.running || _snapshot.value.cancelling) {
            return@synchronized false
        }
        _snapshot.value = BackgroundOperationSnapshot()
        true
    }

    fun isRunning(operationId: String): Boolean = synchronized(lock) {
        _snapshot.value.operationId == operationId && _snapshot.value.running && currentJob != null
    }

    internal fun resetForTests() {
        val job = synchronized(lock) {
            val active = currentJob
            currentJob = null
            _snapshot.value = BackgroundOperationSnapshot()
            active
        }
        job?.cancel()
    }
}
