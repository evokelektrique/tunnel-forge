package io.github.evokelektrique.tunnelforge

import android.util.Log
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.time.ZoneOffset

class DiagnosticLogTest {
    @Test
    fun appendFormatsHeaderAndTabIndentsContinuationLines() {
        val dir = Files.createTempDirectory("diag_log_format").toFile()
        try {
            val store =
                DiagnosticLogStore(
                    logsDir = dir,
                    maxSegmentBytes = 4096,
                    clock = { 1_700_000_000_123L },
                    zoneId = ZoneOffset.UTC,
                )
            store.write(
                priority = Log.INFO,
                source = "kotlin",
                tag = "TunnelVpnService",
                message = "line one\nline two\nline three",
            )
            store.close()

            val primary = File(dir, DiagnosticLogStore.PRIMARY_FILE_NAME)
            val content = primary.readText()
            assertEquals(
                "2023-11-14T22:13:20.123+0000 INFO kotlin/TunnelVpnService line one\n\tline two\n\tline three\n",
                content,
            )
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun writeRedactsSecretsBeforeReachingDisk() {
        val dir = Files.createTempDirectory("diag_log_redact").toFile()
        try {
            val store = DiagnosticLogStore(logsDir = dir, zoneId = ZoneOffset.UTC)
            store.write(
                priority = Log.WARN,
                source = "dart",
                tag = "Auth",
                message = "failed password=supersecret server=vpn.example.com",
            )
            store.close()

            val content = File(dir, DiagnosticLogStore.PRIMARY_FILE_NAME).readText()
            assertFalse(content.contains("supersecret"))
            assertFalse(content.contains("vpn.example.com"))
            assertTrue(content.contains("password=[REDACTED]"))
            assertTrue(content.contains("server=[REDACTED_HOST]"))
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun rotatesAtSegmentLimitAndReadTailSpansSegments() {
        val dir = Files.createTempDirectory("diag_log_rotate").toFile()
        try {
            var now = 1_700_000_000_000L
            val store =
                DiagnosticLogStore(
                    logsDir = dir,
                    maxSegmentBytes = 120,
                    clock = { now++ },
                    zoneId = ZoneOffset.UTC,
                )
            for (i in 1..6) {
                store.write(
                    priority = Log.INFO,
                    source = "kotlin",
                    tag = "Test",
                    message = "entry-$i",
                )
            }
            store.close()

            val backup = File(dir, DiagnosticLogStore.BACKUP_FILE_NAME)
            val primary = File(dir, DiagnosticLogStore.PRIMARY_FILE_NAME)
            assertTrue(backup.isFile)
            assertTrue(primary.isFile)

            val tailAll = store.readTail(100)
            assertTrue(tailAll.contains("entry-6"))
            assertTrue(tailAll.contains("entry-4"))

            val tailTwo = store.readTail(2)
            assertEquals(2, tailTwo.lines().size)
            assertTrue(tailTwo.contains("entry-5"))
            assertTrue(tailTwo.contains("entry-6"))

            val cacheDir = Files.createTempDirectory("diag_export").toFile()
            try {
                val exported = store.exportTo(cacheDir)
                assertNotNull(exported)
                val exportedText = exported!!.readText()
                assertTrue(exportedText.contains("entry-4"))
                assertTrue(exportedText.contains("entry-6"))
            } finally {
                cacheDir.deleteRecursively()
            }
        } finally {
            dir.deleteRecursively()
        }
    }
}
