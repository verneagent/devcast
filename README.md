# devcast

Build & run mobile/desktop apps on simulators, emulators, and devices — one tool, any project.

Supports **iOS**, **Android**, **Web**, and **macOS**.

## Install

```bash
git clone https://github.com/verneagent/devcast.git
ln -s "$(pwd)/devcast/devcast.sh" /usr/local/bin/devcast
```

Requirements:
- **iOS/macOS**: Xcode with Command Line Tools
- **Android**: `ANDROID_HOME` set, `cmdline-tools` installed (sdkmanager, avdmanager, adb)

## Quick start

```bash
cp devcast/devcast.config.sh.example ./devcast.config.sh
# Edit devcast.config.sh — fill in your bundle IDs and build hooks
./devcast.sh ios list
./devcast.sh ios run
```

## Usage

```
devcast <ios|android|web|mac> <list|explore|run|install> [arg]
```

| Command | iOS / Android | Web / Mac |
|---------|--------------|-----------|
| `list` | Show simulators/AVDs/devices | Informational |
| `explore` | List downloadable runtimes/images | N/A |
| `install [n\|id]` | Download & install runtime/image | N/A |
| `run [n\|id]` | Build, install, launch | Build & serve/launch |

## Configuration

`devcast` reads `./devcast.config.sh` (or `$DEVCAST_CONFIG`). Required:

**Variables:**

| Variable | Platform |
|----------|----------|
| `IOS_BUNDLE_ID` | iOS, macOS |
| `ANDROID_PACKAGE` | Android |
| `ANDROID_MAIN_ACTIVITY` | Android |
| `WEB_PORT` (optional) | Web |

**Build hooks** (must export the artifact path):

| Hook | Must export |
|------|-------------|
| `devcast_build_ios()` | `APP_PATH` |
| `devcast_build_android()` | `APK_PATH` |
| `devcast_build_web()` | `WEB_DIST_DIR` |
| `devcast_build_mac()` | `APP_PATH` |

**Run hooks** (optional — override default install+launch):

`devcast_run_ios()`, `devcast_run_android()`, `devcast_run_web()`, `devcast_run_mac()`

See [`devcast.config.sh.example`](devcast.config.sh.example) for annotated templates.

## How it works

`devcast` handles device management generically (list simulators, boot AVDs, resolve device IDs). Build and run logic is delegated to hooks defined in your project config. This keeps the tool framework-agnostic — Expo, React Native CLI, Flutter, native Xcode/Gradle all work.
