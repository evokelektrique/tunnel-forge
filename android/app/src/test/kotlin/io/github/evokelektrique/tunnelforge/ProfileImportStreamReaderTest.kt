package io.github.evokelektrique.tunnelforge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.nio.charset.CharacterCodingException
import java.util.concurrent.atomic.AtomicLong

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
        val totalRead = AtomicLong(0L)
        val endlessStream = object : InputStream() {
            override fun read(): Int {
                totalRead.incrementAndGet()
                return 'x'.code
            }

            override fun read(b: ByteArray, off: Int, len: Int): Int {
                b.fill('x'.code.toByte(), off, off + len)
                totalRead.addAndGet(len.toLong())
                return len
            }
        }

        val maxBytes = 1024
        assertThrows(ProfileImportTooLargeException::class.java) {
            ProfileImportStreamReader.readBoundedUtf8Text(endlessStream, maxBytes = maxBytes)
        }

        assertEquals(maxBytes + 1L, totalRead.get())
    }

    @Test
    fun rejectsInvalidUtf8Sequences() {
        val invalidUtf8 = byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0x80.toByte())
        val input = ByteArrayInputStream(invalidUtf8)

        val error =
            assertThrows(IllegalArgumentException::class.java) {
                ProfileImportStreamReader.readBoundedUtf8Text(input, maxBytes = 64)
            }

        assertTrue(
            "Expected CharacterCodingException cause, was ${error.cause}",
            error.cause is CharacterCodingException,
        )
    }
}
