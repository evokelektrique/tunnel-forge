<p align="center">
  <img src="resources/logo/tf-xxxhdpi.png" alt="TunnelForge logo" width="160">
</p>

<h1 align="center">TunnelForge</h1>

<p align="center">
  L2TP/PPTP VPN for modern Android.
</p>

<p align="center">
  <a href="https://github.com/evokelektrique/tunnel-forge/actions/workflows/ci.yml" style="text-decoration: none;">
    <img alt="CI" src="https://img.shields.io/github/actions/workflow/status/evokelektrique/tunnel-forge/ci.yml?branch=main&label=CI">
  </a>
  <a href="https://codecov.io/github/evokelektrique/tunnel-forge" style="text-decoration: none;">
    <img alt="Coverage" src="https://codecov.io/github/evokelektrique/tunnel-forge/graph/badge.svg?token=2GKLO165LD">
  </a>
  <a href="https://github.com/evokelektrique/tunnel-forge/actions/workflows/codeql.yml" style="text-decoration: none;">
    <img alt="CodeQL" src="https://img.shields.io/github/actions/workflow/status/evokelektrique/tunnel-forge/codeql.yml?branch=main&label=CodeQL">
  </a>
  <a href="https://github.com/evokelektrique/tunnel-forge/releases/latest" style="text-decoration: none;">
    <img alt="Latest Release" src="https://img.shields.io/github/v/release/evokelektrique/tunnel-forge?display_name=tag&label=Release">
  </a>
  <a href="https://github.com/evokelektrique/tunnel-forge/releases" style="text-decoration: none;">
    <img alt="Downloads" src="https://img.shields.io/github/downloads/evokelektrique/tunnel-forge/total?label=Downloads">
  </a>
  <a href="https://github.com/evokelektrique/tunnel-forge/blob/main/LICENSE" style="text-decoration: none;">
    <img alt="License GPL-3.0" src="https://img.shields.io/github/license/evokelektrique/tunnel-forge?label=License">
  </a>
</p>

<p align="center">
  <a href="https://f-droid.org/packages/io.github.evokelektrique.tunnelforge/">
    <img
      src="https://f-droid.org/badge/get-it-on.svg"
      alt="Get it on F-Droid"
      height="80"
    >
  </a>
</p>

<p align="center">
  <a href="#overview">Overview</a> •
  <a href="#screenshots">Screenshots</a> •
  <a href="#install">Install</a> •
  <a href="#development">Development</a> •
  <a href="#security--privacy">Security</a> •
  <a href="#feedback">Feedback</a> •
  <a href="#licensing">Licensing</a>
</p>

## Overview

Android 12 removed the old built-in L2TP and PPTP VPN options. A lot of offices, schools, universities, and private networks still have them in place.

TunnelForge is an Android client for those setups. It connects to existing L2TP/PPTP servers, so you can keep using the server you already have while running a current Android version.

### Key features

- Supports PPTP (root required) and L2TP with optional IPsec (IKEv1)
- Full-device VPN mode
- Proxy-only mode with local HTTP and SOCKS5 listeners
- Per-app routing (Inclusive and Exclusive)
- Multiple profiles with credential storage
- Subscriptions for adding multiple profiles and keeping them up-to-date
- [Share links and subscriptions](docs/share_links.md)
- Connection status and detailed logs
- Custom DNS supporting UDP, TCP, TLS and HTTPS
- Variable MTU

## Screenshots

<table>
  <tr>
    <td align="center" width="33%">
      <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/1.jpg" alt="TunnelForge home screen" width="260">
    </td>
    <td align="center" width="33%">
      <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/2.jpg" alt="TunnelForge profile editor" width="260">
    </td>
    <td align="center" width="33%">
      <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/3.jpg" alt="TunnelForge settings and routing" width="260">
    </td>
  </tr>
</table>

## Install

### F-Droid

[<img src="https://f-droid.org/badge/get-it-on.svg" alt="Get it on F-Droid" height="80">](https://f-droid.org/packages/io.github.evokelektrique.tunnelforge/)

Install TunnelForge from F-Droid to receive updates through your F-Droid client.

### GitHub Releases

You can also download the latest APK directly from
[GitHub Releases](https://github.com/evokelektrique/tunnel-forge/releases/latest)
for manual installation.

> TunnelForge is only the client; you still need access to a compatible
L2TP/IPsec server.

## Development

### Requirements

- Flutter with Dart `3.11+`
- Go `1.25.9+` for the Android gVisor userspace networking module
- Android SDK configured for Flutter Android builds
- Android NDK and CMake, installed through Android Studio or `sdkmanager`
- Android `minSdk 31` or newer for the app target

### Setup

```sh
flutter pub get
cd android/gvisor
go mod download
cd ../..
```

Run the app on a connected Android device or emulator:

```sh
flutter run
```

Share-link grammar and subscription format are documented in [docs/share_links.md](docs/share_links.md).

Linux prerequisites include Android Studio or `sdkmanager` for the Android NDK and CMake. Install Go and Ninja with your package manager.

macOS prerequisites include Android Studio or `sdkmanager` for the Android NDK and CMake. Install the native tools with Homebrew:

```sh
brew install go cmake ninja
```

Windows prerequisites include Android Studio SDK Manager for the Android NDK and CMake. Install Go with the installer or `winget install GoLang.Go`. Gradle runs native tasks without Make or Bash.

### Common Workflows

Run Dart and Flutter commands from the repository root.

#### Linux and macOS

```sh
dart format lib test
flutter analyze
flutter test
cd android
./gradlew :app:formatAndroidNativeC
./gradlew :app:lintDebug
./gradlew :app:testDebugUnitTest
./gradlew :app:testNativeC
./gradlew :app:checkNativeC
cd ..
flutter build apk --debug
flutter build apk --release --split-per-abi
```

#### Windows PowerShell

```powershell
dart format lib test
flutter analyze
flutter test
cd android
.\gradlew.bat :app:formatAndroidNativeC
.\gradlew.bat :app:lintDebug
.\gradlew.bat :app:testDebugUnitTest
.\gradlew.bat :app:testNativeC
.\gradlew.bat :app:checkNativeC
cd ..
flutter build apk --debug
flutter build apk --release --split-per-abi
```

Release signing reads the root `.env` on every OS. Copy the template first:

```sh
cp .env.example .env
```

In PowerShell, use `Copy-Item .env.example .env`.

Set exactly one of `TUNNEL_FORGE_ANDROID_KEYSTORE_PATH` or `TUNNEL_FORGE_ANDROID_KEYSTORE_BASE64`, plus the keystore password, key alias, and key password. For one-off bash variables, use `export NAME=value`. In PowerShell, use `$env:NAME = 'value'`. Signed APKs are written to `build/app/outputs/flutter-apk/`.

### Coverage

```sh
flutter test --coverage
```

## Security & Privacy

- VPN credentials are stored on-device with `flutter_secure_storage`.
- Debug logs stay local, and sensitive tokens are redacted before display or sharing.
- No analytics or crash-reporting SDKs are included in this repo.

## Feedback

Use GitHub Issues or [Telegram channel](https://t.me/TunnelForge) for bugs, feature requests or general feedback. Use the export button and bring your logs file (in full) when submitting an issue.

## Licensing

This project is licensed under `GPL-3.0-only`. See [LICENSE](LICENSE).
