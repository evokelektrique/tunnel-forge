package io.github.evokelektrique.tunnelforge

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

internal object DiagnosticLogFormatter {
    private val timestampFormatter: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSSZ", Locale.US)

    fun formatTimestamp(timestampMs: Long, zoneId: ZoneId = ZoneId.systemDefault()): String =
        timestampFormatter.format(Instant.ofEpochMilli(timestampMs).atZone(zoneId))

    fun levelLabel(priority: Int): String =
        when {
            priority <= Log.DEBUG -> "DEBUG"
            priority == Log.INFO -> "INFO"
            priority == Log.WARN -> "WARNING"
            else -> "ERROR"
        }

    fun formatEntry(
        priority: Int,
        source: String,
        tag: String,
        sanitizedMessage: String,
        timestampMs: Long,
        zoneId: ZoneId = ZoneId.systemDefault(),
    ): String {
        val ts = formatTimestamp(timestampMs, zoneId)
        val level = levelLabel(priority)
        val normalizedSource =
            when (source.trim().lowercase(Locale.US)) {
                VpnContract.LOG_SOURCE_DART -> VpnContract.LOG_SOURCE_DART
                VpnContract.LOG_SOURCE_NATIVE -> VpnContract.LOG_SOURCE_NATIVE
                else -> VpnContract.LOG_SOURCE_KOTLIN
            }
        val normalizedTag = tag.trim().replace(Regex("""\s+"""), "_")
        val normalizedMessage =
            sanitizedMessage
                .replace("\r\n", "\n")
                .replace('\r', '\n')
                .trimEnd('\n')
                .replace("\n", "\n\t")
        return "$ts $level $normalizedSource/$normalizedTag $normalizedMessage\n"
    }
}

/**
 * Single synchronous writer for rotating diagnostic log files (`tf.log` and `tf.1.log`).
 */
internal class DiagnosticLogStore(
    val logsDir: File,
    private val maxSegmentBytes: Long = DEFAULT_MAX_SEGMENT_BYTES,
    private val clock: () -> Long = System::currentTimeMillis,
    private val zoneId: ZoneId = ZoneId.systemDefault(),
) {
    private var outputStream: FileOutputStream? = null
    private var currentSize: Long = 0L

    private val primaryFile: File
        get() = File(logsDir, PRIMARY_FILE_NAME)

    private val backupFile: File
        get() = File(logsDir, BACKUP_FILE_NAME)

    @Synchronized
    fun write(
        priority: Int,
        source: String,
        tag: String,
        message: String,
        timestampMs: Long = clock(),
    ) {
        val sanitized = sanitizeLogMessage(message)
        val line =
            DiagnosticLogFormatter.formatEntry(
                priority = priority,
                source = source,
                tag = tag,
                sanitizedMessage = sanitized,
                timestampMs = timestampMs,
                zoneId = zoneId,
            )
        val bytes = line.toByteArray(StandardCharsets.UTF_8)
        try {
            logsDir.mkdirs()
            ensureOpen()
            if (currentSize > 0L && currentSize + bytes.size > maxSegmentBytes) {
                rotate()
            }
            outputStream?.write(bytes)
            currentSize += bytes.size
        } catch (e: Exception) {
            closeStreamQuietly()
            runCatching { Log.w(TAG, "DiagnosticLog write failed: ${e.javaClass.simpleName}") }
        }
    }

    @Synchronized
    fun readTail(maxLines: Int): String {
        if (maxLines <= 0) return ""
        return try {
            val ring = ArrayDeque<String>(maxLines.coerceAtMost(1024))
            for (file in listOf(backupFile, primaryFile)) {
                if (!file.isFile) continue
                file.bufferedReader(StandardCharsets.UTF_8).useLines { lines ->
                    for (line in lines) {
                        if (ring.size == maxLines) {
                            ring.removeFirst()
                        }
                        ring.addLast(line)
                    }
                }
            }
            ring.joinToString("\n")
        } catch (e: Exception) {
            runCatching { Log.w(TAG, "DiagnosticLog readTail failed: ${e.javaClass.simpleName}") }
            ""
        }
    }

    @Synchronized
    fun exportTo(cacheDir: File): File? {
        return try {
            val segments = listOf(backupFile, primaryFile).filter { it.isFile && it.length() > 0L }
            if (segments.isEmpty()) return null
            cacheDir.mkdirs()
            val outFile = File(cacheDir, "tunnel_forge_logs_${clock()}.txt")
            FileOutputStream(outFile, false).use { out ->
                for (segment in segments) {
                    segment.inputStream().use { input -> input.copyTo(out) }
                }
            }
            outFile
        } catch (e: Exception) {
            runCatching { Log.w(TAG, "DiagnosticLog exportTo failed: ${e.javaClass.simpleName}") }
            null
        }
    }

    @Synchronized
    fun latestTombstone(): File? {
        return try {
            logsDir
                .listFiles { file ->
                    file.isFile &&
                        file.name.startsWith(TOMBSTONE_PREFIX) &&
                        file.name.endsWith(TOMBSTONE_SUFFIX)
                }?.maxByOrNull { it.lastModified() }
        } catch (_: Exception) {
            null
        }
    }

    @Synchronized
    fun exportPaths(cacheDir: File, includeTombstone: Boolean): List<String> {
        val paths = mutableListOf<String>()
        exportTo(cacheDir)?.let { paths.add(it.absolutePath) }
        if (includeTombstone) {
            val tombstone = latestTombstone()
            if (tombstone != null) {
                try {
                    cacheDir.mkdirs()
                    val target = File(cacheDir, tombstone.name)
                    tombstone.inputStream().use { input ->
                        FileOutputStream(target, false).use { out -> input.copyTo(out) }
                    }
                    paths.add(target.absolutePath)
                } catch (e: Exception) {
                    runCatching { Log.w(TAG, "Tombstone copy failed: ${e.javaClass.simpleName}") }
                }
            }
        }
        return paths
    }

    @Synchronized
    fun clear() {
        try {
            closeStreamQuietly()
            if (backupFile.exists()) {
                backupFile.delete()
            }
            if (primaryFile.exists()) {
                FileOutputStream(primaryFile, false).use { }
            }
            currentSize = 0L
        } catch (e: Exception) {
            runCatching { Log.w(TAG, "DiagnosticLog clear failed: ${e.javaClass.simpleName}") }
        }
    }

    @Synchronized
    fun close() {
        closeStreamQuietly()
    }

    private fun ensureOpen() {
        if (outputStream != null) return
        val file = primaryFile
        currentSize = if (file.exists()) file.length() else 0L
        outputStream = FileOutputStream(file, true)
    }

    private fun rotate() {
        closeStreamQuietly()
        if (backupFile.exists()) {
            backupFile.delete()
        }
        if (primaryFile.exists() && !primaryFile.renameTo(backupFile)) {
            primaryFile.inputStream().use { input ->
                FileOutputStream(backupFile, false).use { out -> input.copyTo(out) }
            }
            primaryFile.delete()
        }
        currentSize = 0L
        outputStream = FileOutputStream(primaryFile, true)
    }

    private fun closeStreamQuietly() {
        try {
            outputStream?.close()
        } catch (_: Exception) {
        } finally {
            outputStream = null
        }
    }

    companion object {
        const val DEFAULT_MAX_SEGMENT_BYTES = 1_048_576L
        const val PRIMARY_FILE_NAME = "tf.log"
        const val BACKUP_FILE_NAME = "tf.1.log"
        const val TOMBSTONE_PREFIX = "tombstone_"
        const val TOMBSTONE_SUFFIX = ".pb"
        private const val TAG = "DiagnosticLog"
    }
}

object DiagnosticLog {
    @Volatile
    private var store: DiagnosticLogStore? = null

    fun init(context: Context) {
        if (store != null) return
        synchronized(this) {
            if (store == null) {
                val logsDir = File(context.filesDir, "logs")
                logsDir.mkdirs()
                store = DiagnosticLogStore(logsDir)
            }
        }
    }

    fun logsDir(): File? = store?.logsDir

    fun write(
        priority: Int,
        source: String,
        tag: String,
        message: String,
        timestampMs: Long = System.currentTimeMillis(),
    ) {
        val current = store
        if (current == null) {
            runCatching { Log.println(priority, tag, sanitizeLogMessage(message)) }
            return
        }
        current.write(priority, source, tag, message, timestampMs)
    }

    fun readTail(maxLines: Int): String = store?.readTail(maxLines) ?: ""

    fun exportTo(cacheDir: File): File? = store?.exportTo(cacheDir)

    fun exportPaths(cacheDir: File, includeTombstone: Boolean): List<String> =
        store?.exportPaths(cacheDir, includeTombstone) ?: emptyList()

    fun hasTombstone(): Boolean = store?.latestTombstone() != null

    fun clear() {
        store?.clear()
    }
}
