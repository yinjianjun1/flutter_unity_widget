# flutter_unity_widget_example

English | [简体中文](README.zh.md)

Demonstrates how to use the flutter_unity_widget_plus plugin in the
**prebuilt-artifact integration mode**: a single script turns the Unity project
into an `unityLibrary.aar` (Android) and a `UnityFramework.framework` (iOS), and
the Flutter app consumes these artifacts with no Unity toolchain dependency at
app build time.

## Project layout

```
build_unity.sh            # One-shot entry: Unity export + platform build + artifact deploy
android/build_unity.sh    # Gradle publish flow for the exported unityLibrary (AAR)
ios/build_unity.sh        # xcodebuild archive flow for the exported Unity-iPhone project (framework)
unity/DemoApp/            # Example Unity project (Unity 2022.3, il2cpp, ARM64)
lib/                      # Flutter app source (UnityWidget usage)
```

## Requirements

- Unity 2022.3 installed via Unity Hub (the newest editor under
  `/Applications/Unity/Hub/Editor` is picked automatically; override with the
  `UNITY_EDITOR` environment variable)
- Xcode with command line tools (iOS targets)
- Android SDK/NDK/JDK: Unity's bundled toolchain is used automatically; a
  bootstrap Gradle is detected from `./gradlew`, `GRADLE_BIN`, the
  `~/.gradle/wrapper/dists` cache or `PATH`

## Building the artifacts

```bash
./build_unity.sh android        # -> android/unityLibrary/{unityLibrary.aar, unity-classes.jar}
./build_unity.sh ios device     # -> ios/UnityLibrary/UnityFramework{,-Device}.framework
./build_unity.sh ios simulator  # -> ios/UnityLibrary/UnityFramework{,-Simulator}.framework
```

Each target is a two-step pipeline:

1. **Unity export** — Unity runs in batch mode and exports into the staging
   directory `unity/flutter/<platform>/`. The iOS simulator target goes through
   `unity/DemoApp/Assets/Editor/SimulatorExport.cs`, which switches the SDK to
   `SimulatorSDK`, forces the ARM64 simulator architecture (Unity 2022.3
   defaults to x86_64, which produces an arm64-incompatible `libil2cpp.a`), and
   reuses the upstream device export method.
2. **Platform build** — the staged project is built with Gradle
   (`publishReleasePublicationToAndroidBuildRepo`, with idempotent injection of
   the maven-publish config into the exported `build.gradle`) or
   `xcodebuild archive` (with simulator linker flags preserved via
   `OTHER_LDFLAGS`), then artifacts are copied back into `android/unityLibrary/`
   and `ios/UnityLibrary/`.

## Integrating the artifacts

### pubspec.yaml

```yaml
dependencies:
  flutter_unity_widget_plus:
    path: <path to the plugin package>
```

### Android

The plugin consumes the prebuilt AAR itself via `flatDir`; the app must not
reference `unityLibrary` as a Gradle project:

- Do not `include ':unityLibrary'` in `settings.gradle` — the deployed directory
  contains only the AAR/JAR, no `build.gradle`.
- Do not add a second `implementation(name: 'unityLibrary', ext: 'aar')` or
  `unity-classes.jar` dependency in `app/build.gradle` — the plugin already
  declares them, and duplicates cause `Duplicate class` errors. App-level
  dependencies only need `implementation project(':flutter_unity_widget_plus')`.
- Resolve the AAR directory with a root-level `flatDir` repository:
  `dirs "${rootProject.projectDir}/unityLibrary"`.
- Align the Kotlin plugin version with the plugin's Kotlin stdlib (2.1.20 here);
  an older compiler fails on newer stdlib metadata.

### iOS

- Runner links `UnityLibrary/UnityFramework.framework` by path (not
  `BUILT_PRODUCTS_DIR`), so the Embed Frameworks phase copies the prebuilt one.
- Set `IPHONEOS_DEPLOYMENT_TARGET = 15.0` or higher on the Runner target and all
  pods (the current Xcode simulator SDK rejects lower values).
- The framework is arm64-only; exclude x86_64 on the Runner target and all pods:
  `EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64` (quote the conditional key when
  editing `project.pbxproj` by hand).
- Newer SDKs require the UIScene lifecycle: declare `UIApplicationSceneManifest`
  in `Info.plist` and return a `UISceneConfiguration` whose `delegateClass` is
  `FlutterSceneDelegate` from `AppDelegate.application(_:configurationForConnecting:options:)`.
  Unity must still be initialized in `didFinishLaunchingWithOptions` via
  `InitUnityIntegrationWithOptions`.
- Run `pod install` after `flutter pub get`.

## Run

```bash
flutter run
```

Both platform emulators are arm64-only in this configuration:

- iOS Simulator: run `./build_unity.sh ios simulator` first so the deployed
  `UnityFramework.framework` is the simulator flavor.
- Android emulator: use an arm64 system image; the AAR ships only
  `arm64-v8a` native libraries.

For the Flutter-side API (`UnityWidget`, `postMessage`, scene callbacks), see
[example.md](example.md).
