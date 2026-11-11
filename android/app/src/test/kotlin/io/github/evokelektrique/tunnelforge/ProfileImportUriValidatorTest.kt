package io.github.evokelektrique.tunnelforge

import org.junit.Test

class ProfileImportUriValidatorTest {
    @Test
    fun acceptsContentUriWithAuthority() {
        ProfileImportUriValidator.requireSafeProfileImportUriParts(
            scheme = "content",
            authority = "com.example.provider",
        )
    }

    @Test(expected = SecurityException::class)
    fun rejectsFileScheme() {
        ProfileImportUriValidator.requireSafeProfileImportUriParts(
            scheme = "file",
            authority = "",
        )
    }

    @Test(expected = SecurityException::class)
    fun rejectsUnknownScheme() {
        ProfileImportUriValidator.requireSafeProfileImportUriParts(
            scheme = "https",
            authority = "example.com",
        )
    }

    @Test(expected = SecurityException::class)
    fun rejectsMissingScheme() {
        ProfileImportUriValidator.requireSafeProfileImportUriParts(
            scheme = null,
            authority = null,
        )
    }

    @Test(expected = SecurityException::class)
    fun rejectsContentUriWithoutAuthority() {
        ProfileImportUriValidator.requireSafeProfileImportUriParts(
            scheme = "content",
            authority = "",
        )
    }

    @Test
    fun acceptsExternalContentUriWithSafePath() {
        ProfileImportUriValidator.requireSafeProfileImportUriParts(
            scheme = "content",
            authority = "com.example.provider",
            path = "/documents/profile.tfp",
            encodedPath = "/documents/profile.tfp",
        )
    }

    @Test(expected = SecurityException::class)
    fun rejectsOwnPackageAuthorityExact() {
        ProfileImportUriValidator.requireSafeProfileImportUriParts(
            scheme = "content",
            authority = ProfileImportUriValidator.DEFAULT_OWN_PACKAGE,
        )
    }

    @Test(expected = SecurityException::class)
    fun rejectsOwnPackageAuthorityPrefix() {
        ProfileImportUriValidator.requireSafeProfileImportUriParts(
            scheme = "content",
            authority = "${ProfileImportUriValidator.DEFAULT_OWN_PACKAGE}.flutter.share_provider",
            path = "/cache/profile.tfp",
            encodedPath = "/cache/profile.tfp",
        )
    }

    @Test(expected = SecurityException::class)
    fun rejectsCustomOwnPackageAuthorityPrefix() {
        ProfileImportUriValidator.requireSafeProfileImportUriParts(
            scheme = "content",
            authority = "com.custom.app.fileprovider",
            ownPackageName = "com.custom.app",
        )
    }

    @Test(expected = SecurityException::class)
    fun rejectsUserInfoInAuthority() {
        ProfileImportUriValidator.requireSafeProfileImportUriParts(
            scheme = "content",
            authority = "attacker@com.example.provider",
            userInfo = "attacker",
        )
    }

    @Test(expected = SecurityException::class)
    fun rejectsPathTraversalSegments() {
        ProfileImportUriValidator.requireSafeProfileImportUriParts(
            scheme = "content",
            authority = "com.example.provider",
            path = "/documents/../secret.tfp",
            encodedPath = "/documents/../secret.tfp",
        )
    }

    @Test(expected = SecurityException::class)
    fun rejectsEncodedPathTraversalSegments() {
        ProfileImportUriValidator.requireSafeProfileImportUriParts(
            scheme = "content",
            authority = "com.example.provider",
            path = "/documents/profile.tfp",
            encodedPath = "/documents/%2e%2e/secret.tfp",
        )
    }

    @Test(expected = SecurityException::class)
    fun rejectsBackslashInPath() {
        ProfileImportUriValidator.requireSafeProfileImportUriParts(
            scheme = "content",
            authority = "com.example.provider",
            path = "/documents/..\\secret.tfp",
            encodedPath = "/documents/..%5Csecret.tfp",
        )
    }

    @Test(expected = SecurityException::class)
    fun rejectsNullByteInPath() {
        ProfileImportUriValidator.requireSafeProfileImportUriParts(
            scheme = "content",
            authority = "com.example.provider",
            path = "/documents/profile.tfp\u0000.txt",
            encodedPath = "/documents/profile.tfp%00.txt",
        )
    }

    @Test(expected = SecurityException::class)
    fun rejectsNormalizedDataDirectoryPath() {
        ProfileImportUriValidator.requireSafeProfileImportUriParts(
            scheme = "content",
            authority = "com.example.provider",
            path = "/data/user/0/io.github.evokelektrique.tunnelforge/files/db",
            encodedPath = "/data/user/0/io.github.evokelektrique.tunnelforge/files/db",
        )
    }

    @Test(expected = SecurityException::class)
    fun rejectsExactDataDirectoryPath() {
        ProfileImportUriValidator.requireSafeProfileImportUriParts(
            scheme = "content",
            authority = "com.example.provider",
            path = "/data",
            encodedPath = "/data",
        )
    }
}
