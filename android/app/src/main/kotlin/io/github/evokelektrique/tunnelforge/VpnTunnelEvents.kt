package io.github.evokelektrique.tunnelforge

import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.AnyThread
import androidx.annotation.Keep
import androidx.annotation.MainThread
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean

/** Pushes tunnel lifecycle updates to Flutter on the main thread (same [MethodChannel] as [MainActivity]). */
object VpnTunnelEvents {
    private const val LOG_BATCH_INTERVAL_MS = 200L
    private const val MAX_BATCH_ENTRIES = 500

    @Volatile
    private var channel: MethodChannel? = null

    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    private val pendingTerminal = PendingTerminalHolder()
    private val pendingLogEntries = ConcurrentLinkedQueue<Map<String, Any?>>()
    private val flushScheduled = AtomicBoolean(false)
    private val flushRunnable = Runnable { flushEngineLogsOnMain(drainAll = false) }

    private val noopResult =
        object : MethodChannel.Result {
            override fun success(result: Any?) {}

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}

            override fun notImplemented() {}
        }

    fun attach(c: MethodChannel) {
        channel = c
    }

    fun detach(c: MethodChannel) {
        if (channel === c) {
            channel = null
        }
    }

    fun consumePendingTerminal(): Map<String, Any?>? = pendingTerminal.consume()

    @AnyThread
    private fun invokeOnMain(
        method: String,
        payload: Map<String, Any?>,
        flushPendingLogsFirst: Boolean = false,
    ) {
        val ch = recordDropIfDetached(method, payload) ?: return
        mainHandler.post {
            if (flushPendingLogsFirst && !pendingLogEntries.isEmpty()) {
                flushEngineLogsOnMain(drainAll = true)
            }
            deliverOnMain(ch, method, payload)
        }
    }

    private fun recordDropIfDetached(method: String, payload: Map<String, Any?>): MethodChannel? {
        val ch = channel
        if (ch != null) return ch
        if (method == VpnContract.ON_TUNNEL_STATE) {
            pendingTerminal.recordIfTerminal(
                payload[VpnContract.ARG_TUNNEL_STATE] as? String,
                payload,
                System.currentTimeMillis(),
            )
        }
        Log.w(TAG, sanitizeLogMessage("event_drop reason=no_channel method=$method"))
        return null
    }

    @MainThread
    private fun deliverOnMain(ch: MethodChannel, method: String, payload: Map<String, Any?>) {
        try {
            ch.invokeMethod(method, payload, noopResult)
        } catch (e: Exception) {
            Log.w(
                TAG,
                sanitizeLogMessage(
                    "event_drop reason=invoke_exception method=$method err=${e.javaClass.simpleName}:${e.message}",
                ),
            )
        }
    }

    @AnyThread
    fun emit(state: String, detail: String?, attemptId: String? = null, failure: Map<String, Any>? = null) {
        DiagnosticLog.write(
            Log.INFO,
            VpnContract.LOG_SOURCE_KOTLIN,
            TAG,
            "tunnel_state state=$state attempt=${attemptId ?: ""} detail=${detail ?: ""}",
        )
        invokeOnMain(
            VpnContract.ON_TUNNEL_STATE,
            mapOf(
                VpnContract.ARG_ATTEMPT_ID to (attemptId ?: ""),
                VpnContract.ARG_TUNNEL_STATE to state,
                VpnContract.ARG_TUNNEL_DETAIL to (detail ?: ""),
                VpnContract.ARG_TUNNEL_FAILURE to failure,
            ),
            flushPendingLogsFirst = true,
        )
    }

    @AnyThread
    fun emitProxyExposureChanged(exposure: ProxyExposureInfo) {
        invokeOnMain(
            VpnContract.ON_PROXY_EXPOSURE_CHANGED,
            mapOf(
                VpnContract.ARG_PROXY_EXPOSURE_ACTIVE to exposure.active,
                VpnContract.ARG_PROXY_EXPOSURE_BIND_ADDRESS to exposure.bindAddress,
                VpnContract.ARG_PROXY_EXPOSURE_DISPLAY_ADDRESS to exposure.displayAddress,
                VpnContract.ARG_PROXY_EXPOSURE_HTTP_PORT to exposure.httpPort,
                VpnContract.ARG_PROXY_EXPOSURE_SOCKS_PORT to exposure.socksPort,
                VpnContract.ARG_PROXY_EXPOSURE_LAN_REQUESTED to exposure.lanRequested,
                VpnContract.ARG_PROXY_EXPOSURE_LAN_ACTIVE to exposure.lanActive,
                VpnContract.ARG_PROXY_EXPOSURE_WARNING to exposure.warning,
            ),
        )
    }

    /** Kotlin host: same payload shape as JNI [emitEngineLogFromNative]. */
    fun emitEngineLog(
        priority: Int,
        tag: String,
        message: String,
        source: String = VpnContract.LOG_SOURCE_KOTLIN,
    ) {
        val sanitizedMessage = sanitizeLogMessage(message)
        DiagnosticLog.write(priority, source, tag, sanitizedMessage)
        if (!shouldForwardEngineLog(priority)) return
        pendingLogEntries.add(
            mapOf(
                VpnContract.ARG_ENGINE_LOG_LEVEL to priority,
                VpnContract.ARG_ENGINE_LOG_SOURCE to source,
                VpnContract.ARG_ENGINE_LOG_TAG to tag,
                VpnContract.ARG_ENGINE_LOG_MESSAGE to sanitizedMessage,
            ),
        )
        if (flushScheduled.compareAndSet(false, true)) {
            mainHandler.postDelayed(flushRunnable, LOG_BATCH_INTERVAL_MS)
        }
    }

    @MainThread
    private fun flushEngineLogsOnMain(drainAll: Boolean) {
        flushScheduled.set(false)
        do {
            val batch = ArrayList<Map<String, Any?>>(MAX_BATCH_ENTRIES)
            while (batch.size < MAX_BATCH_ENTRIES) {
                val entry = pendingLogEntries.poll() ?: break
                batch.add(entry)
            }
            if (batch.isNotEmpty()) {
                val payload = mapOf(VpnContract.ARG_ENGINE_LOG_ENTRIES to batch)
                val ch = recordDropIfDetached(VpnContract.ON_ENGINE_LOG_BATCH, payload)
                if (ch != null) {
                    deliverOnMain(ch, VpnContract.ON_ENGINE_LOG_BATCH, payload)
                }
            }
        } while (drainAll && !pendingLogEntries.isEmpty())
        if (!pendingLogEntries.isEmpty() && flushScheduled.compareAndSet(false, true)) {
            mainHandler.postDelayed(flushRunnable, LOG_BATCH_INTERVAL_MS)
        }
    }

    @Keep
    @JvmStatic
    fun emitEngineLogFromNative(priority: Int, tag: String, message: String) {
        emitEngineLog(priority, tag, message, source = VpnContract.LOG_SOURCE_NATIVE)
    }

    internal fun shouldForwardEngineLog(priority: Int): Boolean =
        EngineLogPolicy.shouldForward(priority)

    private const val TAG = "VpnTunnelEvents"
}
