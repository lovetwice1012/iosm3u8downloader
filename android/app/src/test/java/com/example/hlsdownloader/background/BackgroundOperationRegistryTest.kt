package com.example.hlsdownloader.background

import com.example.hlsdownloader.core.DownloadPhase
import com.example.hlsdownloader.core.DownloadProgress
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.util.UUID

class BackgroundOperationRegistryTest {
    @Before
    fun setUp() = BackgroundOperationRegistry.resetForTests()

    @After
    fun tearDown() = BackgroundOperationRegistry.resetForTests()

    @Test
    fun operationOutlivesCallerAndCanBeCancelledByIdentifier() = runBlocking {
        val operationId = UUID.randomUUID().toString()
        val started = CompletableDeferred<Unit>()
        assertTrue(
            BackgroundOperationRegistry.launch(initial(operationId, "https://example.com/a.m3u8")) {
                started.complete(Unit)
                awaitCancellation()
            },
        )

        started.await()
        assertTrue(BackgroundOperationRegistry.isRunning(operationId))
        assertTrue(BackgroundOperationRegistry.cancel(operationId))
        awaitStopped(operationId)
        assertFalse(BackgroundOperationRegistry.isRunning(operationId))
        assertFalse(BackgroundOperationRegistry.snapshot.value.cancelling)
    }

    @Test
    fun onlyOneProcessWideOperationCanOwnTheRegistry() = runBlocking {
        val firstId = UUID.randomUUID().toString()
        val secondId = UUID.randomUUID().toString()
        val started = CompletableDeferred<Unit>()
        BackgroundOperationRegistry.launch(initial(firstId, "https://example.com/first.m3u8")) {
            started.complete(Unit)
            awaitCancellation()
        }
        started.await()

        val secondStarted = BackgroundOperationRegistry.launch(
            initial(secondId, "https://example.com/second.m3u8"),
        ) { error("A rejected operation must never execute") }

        assertFalse(secondStarted)
        assertEquals(firstId, BackgroundOperationRegistry.snapshot.value.operationId)
        BackgroundOperationRegistry.cancel(firstId)
        awaitStopped(firstId)
    }

    @Test
    fun fastCompletionRetainsReattachableOutputAndTerminalState() = runBlocking {
        val operationId = UUID.randomUUID().toString()
        val output = File("build/test-output/reattach.mp4")
        var registeredBeforeExecution = false

        assertTrue(
            BackgroundOperationRegistry.launch(
                initial = initial(operationId, "https://example.com/fast.m3u8"),
                onRegistered = { registeredBeforeExecution = true },
            ) {
                assertTrue(registeredBeforeExecution)
                BackgroundOperationRegistry.update(operationId) {
                    it.copy(
                        progress = DownloadProgress(DownloadPhase.COMPLETED, 3, 3),
                        outputFile = output,
                        downloadedSegmentCount = 3,
                    )
                }
            },
        )

        awaitStopped(operationId)
        val reattached = BackgroundOperationRegistry.snapshot.value
        assertEquals(operationId, reattached.operationId)
        assertEquals("https://example.com/fast.m3u8", reattached.inputUrl)
        assertEquals(DownloadPhase.COMPLETED, reattached.progress.phase)
        assertEquals(output, reattached.outputFile)
        assertEquals(3, reattached.downloadedSegmentCount)
        assertFalse(reattached.running)
        assertFalse(reattached.cancelling)
    }

    private fun initial(operationId: String, input: String) = BackgroundOperationSnapshot(
        operationId = operationId,
        inputUrl = input,
        progress = DownloadProgress(DownloadPhase.RESOLVING, 0, 0),
        running = true,
    )

    private suspend fun awaitStopped(operationId: String) {
        withTimeout(2_000) {
            while (BackgroundOperationRegistry.snapshot.value.operationId == operationId &&
                BackgroundOperationRegistry.snapshot.value.running
            ) {
                delay(5)
            }
        }
    }
}
