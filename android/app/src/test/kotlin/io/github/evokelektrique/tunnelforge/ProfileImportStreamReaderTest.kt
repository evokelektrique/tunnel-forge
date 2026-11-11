package io.github.evokelektrique.tunnelforge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.nio.charset.CharacterCodingException

class ProfileImportStreamReaderTest {
    @Test
    fun readsValidUtf8Json() {
        val json = """{"name":"Test Профиль 🔐","servers":[]}"""
        val input = ByteArrayInputStream(json.toByteArray(Charsets.UTF_8))

        val result = ProfileImportStreamReader.readBoundedUtf8Text(input)

        assertEquals(json, result)
    }

    @Test
    fun readsEmptyStreamAsEmptyString() {
        val input = ByteArrayInputStream(ByteArray(0))

        val result = ProfileImportStreamReader.readBoundedUtf8Text(input)

        assertEquals("", result)
    }

    @Test
    fun acceptsExactMaxBytesBoundary() {
        val payload = "a".repeat(64)
        val input = ByteArrayInputStream(payload.toByteArray(Charsets.UTF_8))

        val result = ProfileImportStreamReader.readBoundedUtf8Text(input, maxBytes = 64)

        assertEquals(payload, result)
    }

    @Test(expected = ProfileImportTooLargeException::class)
    fun rejectsOneByteOverLimit() {
        val payload = "a".repeat(65)
        val input = ByteArrayInputStream(payload.toByteArray(Charsets.UTF_8))

        ProfileImportStreamReader.readBoundedUtf8Text(input, maxBytes = 64)
    }

    @Test
    fun abortsInfiniteStreamPromptlyWithoutReadingUnboundedData() {
        var totalRead = 0L
        val endlessStream = object : InputStream() {
            override fun read(): Int {
                totalRead += 1
                return 'x'.code
            }

            override fun read(b: ByteArray, off: Int, len: Int): Int {
                b.fill('x'.code.toByte(), off, off + len)
                totalRead += len
                return len
            }
        }

        val maxBytes = 1024
        var threw = false
        try {
            ProfileImportStreamReader.readBoundedUtf8Text(endlessStream, maxBytes = maxBytes)
        } catch (_: ProfileImportTooLargeException) {
            threw = true
        }

        assertTrue("Expected ProfileImportTooLargeException", threw)
        assertTrue(
            "Expected reader to stop near limit ($maxBytes), but read $totalRead bytes",
            totalRead <= maxBytes + 8192L,
        )
    }

    @Test
    fun rejectsInvalidUtf8Sequences() {
        val invalidUtf8 = byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0x80.toByte())
        val input = ByteArrayInputStream(invalidUtf8)

        val error =
            try {
                ProfileImportStreamReader.readBoundedUtf8Text(input, maxBytes = 64)
                null
            } catch (e: IllegalArgumentException) {
                e
            }

        assertTrue("Expected IllegalArgumentException for invalid UTF-8", error != null)
        assertTrue(
            "Expected CharacterCodingException cause, was ${error?.cause}",
            error?.cause is CharacterCodingException,
        )
    }
}
