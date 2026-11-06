# flutter_unity_widget_example

[English](README.md) | 简体中文

演示如何以**预编译产物集成模式**使用 flutter_unity_widget 插件：一条脚本把 Unity
工程导出为 `unityLibrary.aar`（Android）和 `UnityFramework.framework`（iOS），
Flutter 应用直接消费这些产物，应用构建期不依赖任何 Unity 工具链。

## 目录结构

```
build_unity.sh            # 一键入口：Unity 导出 + 平台构建 + 产物部署
android/build_unity.sh    # 导出工程的 Gradle publish 流程（AAR）
ios/build_unity.sh        # 导出工程的 xcodebuild archive 流程（framework）
unity/DemoApp/            # 示例 Unity 工程（Unity 2022.3，il2cpp，ARM64）
lib/                      # Flutter 应用源码（UnityWidget 用法）
```

## 环境要求

- 通过 Unity Hub 安装 Unity 2022.3（自动取
  `/Applications/Unity/Hub/Editor` 下最新的编辑器；可用 `UNITY_EDITOR`
  环境变量覆盖）
- Xcode 及命令行工具（iOS 目标）
- Android SDK/NDK/JDK：自动使用 Unity 自带工具链；引导用 Gradle 按
  `./gradlew`、`GRADLE_BIN`、`~/.gradle/wrapper/dists` 缓存、`PATH` 的
  顺序探测

## 构建产物

```bash
./build_unity.sh android        # -> android/unityLibrary/{unityLibrary.aar, unity-classes.jar}
./build_unity.sh ios device     # -> ios/UnityLibrary/UnityFramework{,-Device}.framework
./build_unity.sh ios simulator  # -> ios/UnityLibrary/UnityFramework{,-Simulator}.framework
```

每个目标都是两步流水线：

1. **Unity 导出** —— Unity 以批量模式运行，导出到暂存目录
   `unity/flutter/<平台>/`。iOS 模拟器目标走
   `unity/DemoApp/Assets/Editor/SimulatorExport.cs`：切换 SDK 为
   `SimulatorSDK`，强制模拟器架构为 ARM64（Unity 2022.3 默认 x86_64，
   会产出与 arm64 不兼容的 `libil2cpp.a`），并复用上游真机导出方法。
2. **平台构建** —— 暂存工程用 Gradle 构建
   （`publishReleasePublicationToAndroidBuildRepo`，向导出的
   `build.gradle` 幂等注入 maven-publish 配置）或 `xcodebuild archive`
   （模拟器通过 `OTHER_LDFLAGS` 保留链接参数），完成后产物回拷到
   `android/unityLibrary/` 和 `ios/UnityLibrary/`。

## 集成产物

### pubspec.yaml

```yaml
dependencies:
  flutter_unity_widget:
    path: <插件包路径>
```

### Android

插件自己通过 `flatDir` 消费预编译 AAR，应用侧不得把 `unityLibrary`
当作 Gradle 工程引用：

- 不要在 `settings.gradle` 中 `include ':unityLibrary'` —— 部署目录里
  只有 AAR/JAR，没有 `build.gradle`。
- 不要在 `app/build.gradle` 里再添加第二份
  `implementation(name: 'unityLibrary', ext: 'aar')` 或
  `unity-classes.jar` 依赖 —— 插件已声明过，重复声明会导致
  `Duplicate class` 错误。应用层依赖只需要
  `implementation project(':flutter_unity_widget')`。
- 在根项目用 `flatDir` 仓库解析 AAR 目录：
  `dirs "${rootProject.projectDir}/unityLibrary"`。
- Kotlin 插件版本与插件的 Kotlin stdlib 对齐（本工程为 2.1.20）；
  旧编译器读不了新 stdlib 的 metadata。

### iOS

- Runner 按路径引用 `UnityLibrary/UnityFramework.framework`（不是
  `BUILT_PRODUCTS_DIR`），Embed Frameworks 阶段才能拷到预编译产物。
- Runner target 与所有 Pods 的 `IPHONEOS_DEPLOYMENT_TARGET` 设为
  15.0 及以上（当前 Xcode 的模拟器 SDK 拒绝更低值）。
- framework 为 arm64-only；Runner target 与所有 Pods 需排除 x86_64：
  `EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64`（手工编辑
  `project.pbxproj` 时条件键必须带引号）。
- 新 SDK 强制 UIScene 生命周期：`Info.plist` 声明
  `UIApplicationSceneManifest`，并在
  `AppDelegate.application(_:configurationForConnecting:options:)`
  中返回 `delegateClass` 为 `FlutterSceneDelegate` 的
  `UISceneConfiguration`。Unity 仍须在 `didFinishLaunchingWithOptions`
  中通过 `InitUnityIntegrationWithOptions` 初始化。
- `flutter pub get` 之后执行 `pod install`。

## 运行

```bash
flutter run
```

本配置下双平台模拟器均为 arm64-only：

- iOS 模拟器：先运行 `./build_unity.sh ios simulator`，使部署的
  `UnityFramework.framework` 为模拟器版本。
- Android 模拟器：使用 arm64 系统镜像；AAR 内只含 `arm64-v8a`
  原生库。

Flutter 侧 API（`UnityWidget`、`postMessage`、场景回调）见
[example.md](example.md)。
