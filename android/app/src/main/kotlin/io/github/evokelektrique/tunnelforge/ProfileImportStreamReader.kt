package io.github.evokelektrique.tunnelforge

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/** Reads incoming `.tfp` streams with a strict byte limit to prevent memory exhaustion on untrusted providers. */
internal object ProfileImportStreamReader {
    const val DEFAULT_MAX_BYTES = 256 * 1024
    private const val BUFFER_SIZE = 8 * 1024

    /** Reads at most [maxBytes] from [input] and decodes the payload as strict UTF-8 text. */
    fun readBoundedUtf8Text(
        input: InputStream,
        maxBytes: Int = DEFAULT_MAX_BYTES,
    ): String {
        require(maxBytes > 0) { "maxBytes must be positive" }
        val buffer = ByteArray(BUFFER_SIZE)
        val out = ByteArrayOutputStream(minOf(maxBytes, BUFFER_SIZE))
        var totalRead = 0
        while (true) {
            val remaining = maxBytes - totalRead
            val toRead = minOf(buffer.size, remaining + 1)
            val count = input.read(buffer, 0, toRead)
            if (count < 0) break
            totalRead += count
            if (totalRead > maxBytes) {
                throw ProfileImportTooLargeException(maxBytes)
            }
            out.write(buffer, 0, count)
        }
        val decoder =
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
        return try {
            decoder.decode(java.nio.ByteBuffer.wrap(out.toByteArray())).toString()
        } catch (e: CharacterCodingException) {
            throw IllegalArgumentException("Profile file is not valid UTF-8", e)
        }
    }
}

internal class ProfileImportTooLargeException(maxBytes: Int) :
    IllegalArgumentException("Profile file exceeds maximum size of $maxBytes bytes")
