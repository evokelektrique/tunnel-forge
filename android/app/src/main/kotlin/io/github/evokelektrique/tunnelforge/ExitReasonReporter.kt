package io.github.evokelektrique.tunnelforge

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.time.ZoneId

internal object ExitReasonFormatter {
    fun reasonName(reason: Int): String =
        when (reason) {
            ApplicationExitInfo.REASON_UNKNOWN -> "UNKNOWN"
            ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
            ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
            ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
            ApplicationExitInfo.REASON_CRASH -> "CRASH"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
            ApplicationExitInfo.REASON_ANR -> "ANR"
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
            ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
            ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
            ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
            ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
            ApplicationExitInfo.REASON_OTHER -> "OTHER"
            ApplicationExitInfo.REASON_FREEZER -> "FREEZER"
            ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE -> "PACKAGE_STATE_CHANGE"
            ApplicationExitInfo.REASON_PACKAGE_UPDATED -> "PACKAGE_UPDATED"
            else -> "UNKNOWN($reason)"
        }

    fun priorityForReason(reason: Int): Int =
        if (reason == ApplicationExitInfo.REASON_USER_REQUESTED ||
            reason == ApplicationExitInfo.REASON_USER_STOPPED
        ) {
            Log.INFO
        } else {
            Log.WARN
        }

    fun formatSummary(
        reason: Int,
        status: Int,
        description: String?,
        timestampMs: Long,
        importance: Int,
        pssKb: Long,
        rssKb: Long,
        zoneId: ZoneId = ZoneId.systemDefault(),
    ): String {
        val iso = DiagnosticLogFormatter.formatTimestamp(timestampMs, zoneId)
        val desc = description?.trim().orEmpty().ifEmpty { "none" }
        return "previous exit: reason=${reasonName(reason)} status=$status desc=$desc at $iso importance=$importance pss=${pssKb}KB rss=${rssKb}KB"
    }
}

object ExitReasonReporter {
    private const val TAG = "ExitReason"
    private const val LAST_EXIT_TS_FILE = "last_exit_ts"
    private const val MAX_ANR_TRACE_BYTES = 64 * 1024

    fun report(context: Context) {
        try {
            val am = context.getSystemService(ActivityManager::class.java) ?: return
            val logsDir = DiagnosticLog.logsDir() ?: File(context.filesDir, "logs").also { it.mkdirs() }
            val tsFile = File(logsDir, LAST_EXIT_TS_FILE)
            val lastSeen =
                if (tsFile.isFile) {
                    tsFile.readText(StandardCharsets.UTF_8).trim().toLongOrNull() ?: 0L
                } else {
                    0L
                }
            val exits =
                am.getHistoricalProcessExitReasons(context.packageName, 0, 10)
                    .filter { it.timestamp > lastSeen }
                    .sortedBy { it.timestamp }
            if (exits.isEmpty()) return

            for (info in exits) {
                val summary =
                    ExitReasonFormatter.formatSummary(
                        reason = info.reason,
                        status = info.status,
                        description = info.description,
                        timestampMs = info.timestamp,
                        importance = info.importance,
                        pssKb = info.pss,
                        rssKb = info.rss,
                    )
                DiagnosticLog.write(
                    priority = ExitReasonFormatter.priorityForReason(info.reason),
                    source = VpnContract.LOG_SOURCE_KOTLIN,
                    tag = TAG,
                    message = summary,
                    timestampMs = info.timestamp,
                )
                when (info.reason) {
                    ApplicationExitInfo.REASON_ANR -> writeAnrTrace(info)
                    ApplicationExitInfo.REASON_CRASH_NATIVE -> saveNativeTombstone(logsDir, info)
                }
            }
            tsFile.writeText(exits.last().timestamp.toString(), StandardCharsets.UTF_8)
        } catch (_: Throwable) {
            // Startup diagnostics must never fail app launch.
        }
    }

    private fun writeAnrTrace(info: ApplicationExitInfo) {
        val stream = info.traceInputStream ?: return
        val bytes = stream.use { readCapped(it, MAX_ANR_TRACE_BYTES) }
        if (bytes.isEmpty()) return
        val text = String(bytes, StandardCharsets.UTF_8).trimEnd()
        if (text.isEmpty()) return
        DiagnosticLog.write(
            priority = Log.WARN,
            source = VpnContract.LOG_SOURCE_KOTLIN,
            tag = TAG,
            message = "anr trace:\n$text",
            timestampMs = info.timestamp,
        )
    }

    private fun saveNativeTombstone(logsDir: File, info: ApplicationExitInfo) {
        val stream = info.traceInputStream ?: return
        logsDir
            .listFiles { file ->
                file.isFile &&
                    file.name.startsWith(DiagnosticLogStore.TOMBSTONE_PREFIX) &&
                    file.name.endsWith(DiagnosticLogStore.TOMBSTONE_SUFFIX)
            }?.forEach { it.delete() }
        val tombstoneFile =
            File(
                logsDir,
                "${DiagnosticLogStore.TOMBSTONE_PREFIX}${info.timestamp}${DiagnosticLogStore.TOMBSTONE_SUFFIX}",
            )
        var totalBytes = 0L
        stream.use { input ->
            FileOutputStream(tombstoneFile, false).use { out ->
                totalBytes = input.copyTo(out)
            }
        }
        DiagnosticLog.write(
            priority = Log.WARN,
            source = VpnContract.LOG_SOURCE_KOTLIN,
            tag = TAG,
            message = "native tombstone saved ($totalBytes bytes)",
            timestampMs = info.timestamp,
        )
    }

    private fun readCapped(input: InputStream, maxBytes: Int): ByteArray {
        val buffer = ByteArray(4096)
        val out = ByteArrayOutputStream()
        while (out.size() < maxBytes) {
            val toRead = (maxBytes - out.size()).coerceAtMost(buffer.size)
            val read = input.read(buffer, 0, toRead)
            if (read <= 0) break
            out.write(buffer, 0, read)
        }
        return out.toByteArray()
    }
}
