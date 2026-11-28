package io.github.evokelektrique.tunnelforge

import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

internal object RootAccessDetector {
    private const val TAG = "RootDetect"
    internal const val DEFAULT_PROBE_TIMEOUT_MS = 3_000
    private const val DEFAULT_AWAIT_TIMEOUT_MS = 3_500L

    @Volatile
    private var probeFuture: CompletableFuture<Boolean>? = null

    @Volatile
    private var probeFn: (Int) -> Boolean = { timeoutMs ->
        try {
            VpnBridge.nativeProbeRootAccess(timeoutMs)
        } catch (_: Throwable) {
            false
        }
    }

    @Volatile
    private var logDebugFn: (String) -> Unit = { message ->
        try {
            AppLog.d(TAG, message)
        } catch (_: Throwable) {
        }
    }

    fun startAsyncProbe(timeoutMs: Int = DEFAULT_PROBE_TIMEOUT_MS) {
        if (probeFuture != null) return
        val future: CompletableFuture<Boolean>
        synchronized(this) {
            if (probeFuture != null) return
            future = CompletableFuture<Boolean>()
            probeFuture = future
        }
        Thread(
            {
                val detected =
                    try {
                        probeFn(timeoutMs)
                    } catch (_: Throwable) {
                        false
                    }
                logDebugFn("startup root probe completed detected=$detected")
                future.complete(detected)
            },
            "tf-root-probe",
        ).apply { isDaemon = true }.start()
    }

    fun isRootDetected(waitTimeoutMs: Long = DEFAULT_AWAIT_TIMEOUT_MS): Boolean {
        val future =
            probeFuture ?: run {
                startAsyncProbe()
                probeFuture
            } ?: return false
        return try {
            future.get(waitTimeoutMs.coerceAtLeast(0L), TimeUnit.MILLISECONDS)
        } catch (_: Throwable) {
            false
        }
    }

    internal fun resetForTest(
        customProbe: ((Int) -> Boolean)? = null,
        customLogger: ((String) -> Unit)? = null,
    ) {
        synchronized(this) {
            probeFuture = null
            probeFn =
                customProbe ?: { timeoutMs ->
                    try {
                        VpnBridge.nativeProbeRootAccess(timeoutMs)
                    } catch (_: Throwable) {
                        false
                    }
                }
            logDebugFn =
                customLogger ?: { message ->
                    try {
                        AppLog.d(TAG, message)
                    } catch (_: Throwable) {
                    }
                }
        }
    }
}
