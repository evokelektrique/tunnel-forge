package io.github.evokelektrique.tunnelforge

import android.net.Uri
import java.nio.file.FileSystems
import java.nio.file.InvalidPathException

/** Validated external `content://` URI ready for read-only `.tfp` stream resolution. */
internal data class ValidatedProfileImportUri(val uri: Uri)

/** Validates incoming `.tfp` profile import URIs before resolving them via [android.content.ContentResolver]. */
internal object ProfileImportUriValidator {
    const val DEFAULT_OWN_PACKAGE = "io.github.evokelektrique.tunnelforge"

    /** Validates [uri] and returns a [ValidatedProfileImportUri] wrapper, or throws [SecurityException]. */
    fun validate(
        uri: Uri,
        ownPackageName: String = DEFAULT_OWN_PACKAGE,
    ): ValidatedProfileImportUri {
        requireSafeProfileImportUri(uri, ownPackageName)
        return ValidatedProfileImportUri(uri)
    }

    /** Ensures [uri] is an external `content://` URI that does not target internal data or app-owned providers. */
    fun requireSafeProfileImportUri(
        uri: Uri,
        ownPackageName: String = DEFAULT_OWN_PACKAGE,
    ) {
        requireSafeProfileImportUriParts(
            scheme = uri.scheme,
            authority = uri.authority,
            host = uri.host,
            userInfo = uri.userInfo,
            path = uri.path,
            encodedPath = uri.encodedPath,
            ownPackageName = ownPackageName,
        )
    }

    internal fun requireSafeProfileImportUriParts(
        scheme: String?,
        authority: String?,
        host: String? = null,
        userInfo: String? = null,
        path: String? = null,
        encodedPath: String? = null,
        ownPackageName: String = DEFAULT_OWN_PACKAGE,
    ) {
        val normalizedScheme = scheme?.trim()?.lowercase().orEmpty()
        if (normalizedScheme != "content") {
            throw SecurityException("Unsupported URI scheme for profile import")
        }

        if (!userInfo.isNullOrEmpty()) {
            throw SecurityException("Unsupported content URI user info")
        }

        val normalizedAuthority = authority?.trim().orEmpty()
        if (normalizedAuthority.isEmpty()) {
            throw SecurityException("Missing content URI authority")
        }
        if (normalizedAuthority.any { it.isWhitespace() } ||
            normalizedAuthority.contains('/') ||
            normalizedAuthority.contains('\\') ||
            normalizedAuthority.contains('@')
        ) {
            throw SecurityException("Invalid content URI authority")
        }

        val normalizedPackage = ownPackageName.trim().lowercase()
        if (normalizedPackage.isNotEmpty()) {
            val authorityCandidates =
                listOfNotNull(
                    normalizedAuthority.lowercase(),
                    normalizedAuthority.substringBefore(':').lowercase(),
                    host?.trim()?.lowercase()?.takeIf { it.isNotEmpty() },
                )
            if (authorityCandidates.any {
                    it == normalizedPackage || it.startsWith("$normalizedPackage.")
                }
            ) {
                throw SecurityException("Internal application content URIs are not allowed")
            }
        }

        val rawEncodedPath = encodedPath?.trim().orEmpty()
        if (rawEncodedPath.contains('\u0000') ||
            rawEncodedPath.contains('\\') ||
            rawEncodedPath.lowercase().contains("%2e%2e") ||
            rawEncodedPath.lowercase().contains("%5c")
        ) {
            throw SecurityException("Invalid content URI path")
        }

        val rawPath = path?.trim().orEmpty()
        if (rawPath.isNotEmpty()) {
            if (rawPath.contains('\u0000') || rawPath.contains('\\')) {
                throw SecurityException("Invalid content URI path")
            }
            if (rawPath.split('/').any { it == ".." || it == "." }) {
                throw SecurityException("Invalid content URI path traversal")
            }
            val normalized =
                try {
                    FileSystems.getDefault().getPath(rawPath).normalize()
                } catch (e: InvalidPathException) {
                    throw SecurityException("Invalid content URI path", e)
                }
            val normalizedPosix = normalized.toString().replace('\\', '/').lowercase()
            if (normalized.startsWith("/data") ||
                normalizedPosix == "/data" ||
                normalizedPosix.startsWith("/data/")
            ) {
                throw SecurityException("Restricted content URI path")
            }
        }
    }
}
