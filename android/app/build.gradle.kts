import com.android.build.gradle.internal.api.ApkVariantOutputImpl
import org.gradle.api.GradleException
import org.gradle.api.tasks.Exec
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val dotEnvProperties = mutableMapOf<String, String>().apply {
    val envFile = rootProject.file("../.env")
    if (envFile.isFile) {
        envFile.forEachLine { rawLine ->
            val line = rawLine.trim()
            if (line.isNotEmpty() && !line.startsWith("#")) {
                val separatorIndex = line.indexOf('=')
                if (separatorIndex != -1) {
                    val key = line.substring(0, separatorIndex).trim()
                    var value = line.substring(separatorIndex + 1).trim()
                    if (value.length >= 2 &&
                        ((value.startsWith("\"") && value.endsWith("\"")) ||
                            (value.startsWith("'") && value.endsWith("'")))
                    ) {
                        value = value.substring(1, value.length - 1)
                    }
                    put(key, value)
                }
            }
        }
    }
}

fun getEnvOrDotEnv(key: String): String? =
    System.getenv(key)?.takeIf { it.isNotBlank() } ?: dotEnvProperties[key]?.takeIf { it.isNotBlank() }

val keystorePath = getEnvOrDotEnv("TUNNEL_FORGE_ANDROID_KEYSTORE_PATH")
val keystoreBase64 = getEnvOrDotEnv("TUNNEL_FORGE_ANDROID_KEYSTORE_BASE64")
val keystorePassword = getEnvOrDotEnv("TUNNEL_FORGE_ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = getEnvOrDotEnv("TUNNEL_FORGE_ANDROID_KEY_ALIAS")
val releaseKeyPassword = getEnvOrDotEnv("TUNNEL_FORGE_ANDROID_KEY_PASSWORD")

val resolvedStoreFile: File? = when {
    !keystorePath.isNullOrBlank() -> {
        val f = File(keystorePath)
        if (f.isAbsolute) f
        else rootProject.file("../$keystorePath").takeIf { it.isFile }
            ?: rootProject.file(keystorePath)
    }
    !keystoreBase64.isNullOrBlank() -> {
        val decoded = Base64.getDecoder().decode(keystoreBase64.trim())
        val tempKeystore = layout.buildDirectory.file("keystore-from-base64.jks").get().asFile
        tempKeystore.parentFile.mkdirs()
        tempKeystore.writeBytes(decoded)
        tempKeystore
    }
    else -> null
}

val releaseSigningInputs =
    mapOf(
        "TUNNEL_FORGE_ANDROID_KEYSTORE_PATH" to (keystorePath ?: if (!keystoreBase64.isNullOrBlank()) "base64" else null),
        "TUNNEL_FORGE_ANDROID_KEYSTORE_PASSWORD" to keystorePassword,
        "TUNNEL_FORGE_ANDROID_KEY_ALIAS" to releaseKeyAlias,
        "TUNNEL_FORGE_ANDROID_KEY_PASSWORD" to releaseKeyPassword,
    )
val hasReleaseSigning =
    releaseSigningInputs.values.all { !it.isNullOrBlank() }

if (!hasReleaseSigning && releaseSigningInputs.values.any { !it.isNullOrBlank() }) {
    throw GradleException(
        "Incomplete Android release signing configuration. Set all of: " +
            releaseSigningInputs.keys.joinToString(", "),
    )
}

if (hasReleaseSigning && (resolvedStoreFile == null || !resolvedStoreFile.exists())) {
    throw GradleException(
        "Android release keystore file not found at: ${resolvedStoreFile?.absolutePath ?: keystorePath}",
    )
}

val localProperties =
    Properties().apply {
        val localPropertiesFile = rootProject.file("local.properties")
        if (localPropertiesFile.isFile) {
            localPropertiesFile.inputStream().use(::load)
        }
    }
val androidSdkPath =
    providers.environmentVariable("ANDROID_HOME").orNull
        ?: providers.environmentVariable("ANDROID_SDK_ROOT").orNull
        ?: localProperties.getProperty("sdk.dir")

// Android NDK prebuilts are split by host OS/CPU. Keep this resolver here so
// native lint/format tasks work on Linux, macOS, and Windows contributors' machines.
fun hostNdkPrebuiltDir(): String {
    val os = System.getProperty("os.name").lowercase()
    val arch = System.getProperty("os.arch").lowercase()
    return when {
        os.contains("windows") -> "windows-x86_64"
        os.contains("mac") && (arch == "aarch64" || arch == "arm64") -> "darwin-aarch64"
        os.contains("mac") -> "darwin-x86_64"
        else -> "linux-x86_64"
    }
}

// Prefer the newest installed NDK tool when PATH does not provide one. This
// keeps clang-tidy aligned with the Android compiler/sysroot used by CMake.
fun findAndroidNdkTool(name: String): File? {
    val ndkRoot = androidSdkPath?.let { file(it).resolve("ndk") } ?: return null
    val isWindows = System.getProperty("os.name").lowercase().contains("windows")
    val prebuiltDir = hostNdkPrebuiltDir()
    val candidates = if (isWindows) listOf("$name.cmd", "$name.exe", name) else listOf(name)
    return ndkRoot
        .listFiles()
        ?.sortedByDescending { it.name }
        ?.flatMap { ndk -> candidates.map { candidate -> ndk.resolve("toolchains/llvm/prebuilt/$prebuiltDir/bin/$candidate") } }
        ?.firstOrNull { it.isFile }
}

fun findAndroidSdkCmakeTool(name: String): File? {
    val cmakeRoot = androidSdkPath?.let { file(it).resolve("cmake") } ?: return null
    val executableName = if (System.getProperty("os.name").lowercase().contains("windows")) "$name.exe" else name
    return cmakeRoot
        .listFiles()
        ?.sortedByDescending { it.name }
        ?.map { versionDir -> versionDir.resolve("bin/$executableName") }
        ?.firstOrNull { it.isFile }
}

fun findWindowsWinLibsTool(name: String): File? {
    if (!System.getProperty("os.name").lowercase().contains("windows")) return null
    val localAppData = System.getenv("LOCALAPPDATA")?.let(::File) ?: return null
    val packageTool =
        localAppData
            .resolve("Microsoft/WinGet/Packages")
            .listFiles { dir -> dir.isDirectory && dir.name.startsWith("BrechtSanders.WinLibs") }
            ?.sortedByDescending { it.name }
            ?.map { pkgDir -> pkgDir.resolve("mingw64/bin/$name.exe") }
            ?.firstOrNull { it.isFile }
    return packageTool ?: localAppData.resolve("Microsoft/WinGet/Links/$name.exe").takeIf { it.isFile }
}

fun androidNdkClang(name: String): String =
    findAndroidNdkTool(name)?.absolutePath ?: name

// Check PATH explicitly so Gradle passes an absolute executable path to Exec.
// Environment variables below still allow CI to pin an exact LLVM version.
fun findPathTool(name: String): String? {
    val executableName = if (System.getProperty("os.name").lowercase().contains("windows")) "$name.exe" else name
    return System.getenv("PATH")
        ?.split(File.pathSeparator)
        ?.map { File(it, executableName) }
        ?.firstOrNull { it.isFile && it.canExecute() }
        ?.absolutePath
}

fun resolveHostTool(envVar: String, name: String, sdkCmakeFallback: Boolean = false): String? =
    providers.environmentVariable(envVar).orNull
        ?: findPathTool(name)
        ?: (if (sdkCmakeFallback) findAndroidSdkCmakeTool(name)?.absolutePath else null)
        ?: findWindowsWinLibsTool(name)?.absolutePath

val nativeCmakeCommand = resolveHostTool("CMAKE", "cmake", sdkCmakeFallback = true) ?: "cmake"
val nativeCtestCommand = resolveHostTool("CTEST", "ctest", sdkCmakeFallback = true) ?: "ctest"
val nativeNinjaCommand = resolveHostTool("NINJA", "ninja", sdkCmakeFallback = true)
val nativeCCompilerCommand = resolveHostTool("CC", "gcc") ?: resolveHostTool("CC", "clang")
val nativeHostToolPathDirs =
    listOfNotNull(nativeCCompilerCommand, nativeNinjaCommand, nativeCmakeCommand, nativeCtestCommand)
        .mapNotNull { File(it).takeIf(File::isAbsolute)?.parentFile?.absolutePath }
        .distinct()

// Resolution order:
// 1. CLANG_FORMAT / CLANG_TIDY for pinned CI or local overrides.
// 2. PATH for standard developer installs.
// 3. Android NDK fallback so Android-only setups still work.
val clangFormatCommand =
    providers.environmentVariable("CLANG_FORMAT").orNull
        ?: findPathTool("clang-format")
        ?: findAndroidNdkTool("clang-format")?.absolutePath
        ?: "clang-format"
val clangTidyCommand =
    providers.environmentVariable("CLANG_TIDY").orNull
        ?: findPathTool("clang-tidy")
        ?: findAndroidNdkTool("clang-tidy")?.absolutePath
        ?: "clang-tidy"
val gradleWrapperCommand =
    if (System.getProperty("os.name").lowercase().contains("windows")) {
        "gradlew.bat"
    } else {
        "./gradlew"
    }
val goCommand =
    providers.environmentVariable("GOROOT").orNull?.let { File(it, if (System.getProperty("os.name").lowercase().contains("windows")) "bin/go.exe" else "bin/go") }?.takeIf { it.isFile }?.absolutePath
        ?: findPathTool("go")
        ?: listOf(
            File("C:/Program Files/Go/bin/go.exe"),
            File("/usr/local/go/bin/go"),
            File("/opt/homebrew/bin/go"),
        ).firstOrNull { it.isFile }?.absolutePath
        ?: "go"
val androidGoJniLibsDir = layout.buildDirectory.dir("androidGoJniLibs")

android {
    val enableClangTidy = providers.gradleProperty("tunnelForgeClangTidy").orNull
    val innerUdpNoChecksum = providers.gradleProperty("tunnelForgeInnerUdpNoChecksum").orNull
    val keymatVariant = providers.gradleProperty("tunnelForgeKeymatVariant").orNull
    val mbedtlsSourceDir = providers.gradleProperty("tunnelForgeMbedtlsSourceDir").orNull
    namespace = "io.github.evokelektrique.tunnelforge"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.evokelektrique.tunnelforge"
        minSdk = 31
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DANDROID_STL=c++_shared",
                    "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
                )
                if (enableClangTidy != null) {
                    arguments += listOf("-DTUNNEL_FORGE_CLANG_TIDY=$enableClangTidy")
                    arguments += listOf("-DCLANG_TIDY_COMMAND=$clangTidyCommand")
                }
                if (innerUdpNoChecksum != null) {
                    arguments += listOf("-DTUNNEL_FORGE_ESP_INNER_UDP_NO_CHECKSUM=$innerUdpNoChecksum")
                }
                if (keymatVariant != null) {
                    arguments += listOf("-DTUNNEL_FORGE_KEYMAT_VARIANT=$keymatVariant")
                }
                if (mbedtlsSourceDir != null) {
                    arguments += listOf("-DTUNNEL_FORGE_MBEDTLS_SOURCE_DIR=$mbedtlsSourceDir")
                }
            }
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = resolvedStoreFile
                storePassword = keystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
        debug {
            // One-shot KEYMAT log after Quick Mode (sensitive). Release builds omit this flag.
            externalNativeBuild {
                cmake {
                    arguments += listOf("-DTUNNEL_FORGE_DEBUG_ESP_KEYMAT=1")
                }
            }
            // A/B inner UDP checksum:
            //   ./gradlew assembleDebug -PtunnelForgeInnerUdpNoChecksum=1  (default behavior, checksum=0)
            //   ./gradlew assembleDebug -PtunnelForgeInnerUdpNoChecksum=0  (compute inner UDP checksum)
            // KEYMAT variant selection:
            //   ./gradlew assembleDebug -PtunnelForgeKeymatVariant=1|2|3
        }
    }

    packaging {
        resources {
            excludes += "META-INF/INDEX.LIST"
            excludes += "META-INF/io.netty.versions.properties"
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDir(androidGoJniLibsDir.get().asFile)
        }
    }

    val abiCodes = mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86_64" to 3)
    applicationVariants.configureEach {
        val variant = this
        variant.outputs.forEach { output ->
            val abiVersionCode = abiCodes[output.filters.find { it.filterType == "ABI" }?.identifier]
            if (abiVersionCode != null) {
                (output as ApkVariantOutputImpl).versionCodeOverride = variant.versionCode * 10 + abiVersionCode
            }
        }
    }
}

dependencies {
    implementation("androidx.annotation:annotation:1.11.0")
    implementation("androidx.core:core-ktx:1.18.0")
    implementation("io.netty:netty-codec-http:4.2.20.Final")
    implementation("io.netty:netty-codec-socks:4.2.20.Final")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.3.0")
}

flutter {
    source = "../.."
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

val androidNativeCSources =
    fileTree("src/main/cpp") {
        include("**/*.c", "**/*.h")
    }
val repoRootDir = rootProject.projectDir.parentFile
val nativeTestBuildDir = repoRootDir.resolve("build/native_test")
val androidGoModuleDir = rootProject.projectDir.resolve("gvisor")

data class AndroidGoAbi(
    val abi: String,
    val goArch: String,
    val clangName: String,
    val goArm: String? = null,
)

val androidGoAbis =
    listOf(
        AndroidGoAbi("arm64-v8a", "arm64", "aarch64-linux-android31-clang"),
        AndroidGoAbi("armeabi-v7a", "arm", "armv7a-linux-androideabi31-clang", goArm = "7"),
        AndroidGoAbi("x86_64", "amd64", "x86_64-linux-android31-clang"),
        AndroidGoAbi("x86", "386", "i686-linux-android31-clang"),
    )

tasks.register("buildAndroidGoNative") {
    group = "build"
    description = "Builds the Android Go native shared library for Android ABIs."
    inputs.files(androidGoModuleDir.resolve("go.mod"), androidGoModuleDir.resolve("go.sum"), androidGoModuleDir.resolve("main.go"))
    outputs.dirs(androidGoAbis.map { androidGoJniLibsDir.get().asFile.resolve(it.abi) })
    doLast {
        if (!androidGoModuleDir.resolve("go.mod").isFile) {
            throw GradleException("Missing android/gvisor/go.mod. Run the documented Go module setup before building.")
        }
        val goBuildCache = layout.buildDirectory.dir("go-cache").get().asFile
        goBuildCache.mkdirs()
        androidGoAbis.forEach { abi ->
            val outDir = androidGoJniLibsDir.get().asFile.resolve(abi.abi)
            outDir.mkdirs()
            val pb = ProcessBuilder(
                goCommand,
                "build",
                "-buildmode=c-shared",
                "-trimpath",
                "-buildvcs=false",
                "-ldflags=-buildid= -s -w -extldflags=-Wl,--build-id=none",
                "-o",
                outDir.resolve("libtunnel_gvisor.so").absolutePath,
                ".",
            ).directory(androidGoModuleDir)
            val env = pb.environment()
            env["CGO_ENABLED"] = "1"
            env["GOOS"] = "android"
            env["GOARCH"] = abi.goArch
            abi.goArm?.let { env["GOARM"] = it }
            env["CC"] = androidNdkClang(abi.clangName)
            env["GOCACHE"] = goBuildCache.absolutePath
            pb.inheritIO()
            val proc = pb.start()
            val exitCode = proc.waitFor()
            if (exitCode != 0) {
                throw GradleException("Failed to build Android Go native library for ${abi.abi} (exit code: $exitCode)")
            }
        }
    }
}

tasks.matching {
    it.name == "preBuild" ||
        it.name.startsWith("externalNativeBuild") ||
        (it.name.startsWith("merge") && it.name.endsWith("JniLibFolders"))
}.configureEach {
    dependsOn("buildAndroidGoNative")
}

// Rewrites Android native C sources in-place using the repo .clang-format file.
tasks.register<Exec>("formatAndroidNativeC") {
    group = "formatting"
    description = "Formats Android native C sources with clang-format."
    commandLine(clangFormatCommand, "-i")
    args(androidNativeCSources.files.sortedBy { it.path })
}

// CI-friendly formatting check: fails if clang-format would change any C source.
tasks.register<Exec>("checkAndroidNativeCFormat") {
    group = "verification"
    description = "Checks Android native C source formatting with clang-format."
    commandLine(clangFormatCommand, "--dry-run", "--Werror")
    args(androidNativeCSources.files.sortedBy { it.path })
}

// Runs the native debug build with clang-tidy enabled through CMake, so analysis
// uses the same NDK includes, defines, and target flags as the Android build.
tasks.register<Exec>("lintAndroidNativeC") {
    group = "verification"
    description = "Builds Android native C sources with clang-tidy enabled."
    workingDir = rootProject.projectDir
    commandLine(gradleWrapperCommand, ":app:externalNativeBuildDebug", "-PtunnelForgeClangTidy=ON")
}

fun Exec.withNativeHostToolPath() {
    if (nativeHostToolPathDirs.isNotEmpty()) {
        val currentPath = System.getenv("PATH")
        val combined = (nativeHostToolPathDirs + listOfNotNull(currentPath)).joinToString(File.pathSeparator)
        environment("PATH", combined)
    }
}

tasks.register<Exec>("configureNativeCTest") {
    group = "verification"
    description = "Configures host-side native C unit tests with CMake."
    withNativeHostToolPath()
    val configureArgs = mutableListOf(nativeCmakeCommand, "-S", repoRootDir.resolve("test/native").absolutePath, "-B", nativeTestBuildDir.absolutePath)
    val isWindows = System.getProperty("os.name").lowercase().contains("windows")
    if (isWindows &&
        providers.environmentVariable("CMAKE_GENERATOR").orNull == null &&
        findPathTool("cl") == null &&
        nativeNinjaCommand != null &&
        nativeCCompilerCommand != null
    ) {
        configureArgs += listOf("-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=$nativeNinjaCommand", "-DCMAKE_C_COMPILER=$nativeCCompilerCommand")
    }
    commandLine(configureArgs)
}

tasks.register<Exec>("buildNativeCTest") {
    group = "verification"
    description = "Builds host-side native C unit tests."
    dependsOn("configureNativeCTest")
    withNativeHostToolPath()
    commandLine(nativeCmakeCommand, "--build", nativeTestBuildDir)
}

tasks.register<Exec>("testNativeC") {
    group = "verification"
    description = "Runs host-side native C unit tests."
    dependsOn("buildNativeCTest")
    withNativeHostToolPath()
    commandLine(nativeCtestCommand, "--test-dir", nativeTestBuildDir, "--output-on-failure")
}

tasks.register("checkNativeC") {
    group = "verification"
    description = "Runs native C format, lint, and unit-test checks."
    dependsOn("checkAndroidNativeCFormat", "lintAndroidNativeC", "testNativeC")
}
