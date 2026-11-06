#!/bin/bash
set -e

# ============================================================
# unityLibrary 导出脚本（Gradle publish 流程）
#
# 功能:
#   幂等补齐 Unity 导出工程的最小 Gradle 骨架并注入 maven-publish 配置，
#   执行 :unityLibrary:publishReleasePublicationToAndroidBuildRepo，
#   校验 AAR 内 ABI 后部署 unityLibrary.aar 与 unity-classes.jar 到
#   Flutter 工程 android/unityLibrary/，最后清理构建中间产物。
#
# 用法:
#   ./build_unity.sh    # 无参数；须先由根脚本完成 Unity 导出
#
# 位置约定:
#   本脚本位于 unity/flutter/android/；产物部署到上溯 4 级的
#   android/unityLibrary/（由 AAR_DST/UNITY_CLASSES_DST 推导）
#
# 环境变量:
#   GRADLE_BIN  引导用 Gradle 可执行文件（缺省依次探测 ./gradlew、
#               ~/.gradle/wrapper/dists 缓存、系统 PATH）
#
# 依赖:
#   - Unity 编辑器自带 OpenJDK / Android SDK / NDK（/Applications/Unity/Hub/Editor
#     下按安装时间取最新）
#   - AGP 7.4.2 + Gradle 7.5.1（Unity 2022.3 预装版本，AGP 7.4 最低要求
#     Gradle 7.5）
#
# 兼容性:
#   macOS；Unity 2022.3 导出的 unityLibrary 工程
#
# 退出状态:
#   0 成功；1 Gradle/AAR/unity-classes.jar 缺失，或 AAR 缺少
#   arm64-v8a ABI
# ============================================================

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
UNITY_LIB_DIR="$ROOT_DIR/unityLibrary"
GRADLE_FILE="$UNITY_LIB_DIR/build.gradle"
BUILD_DIR="$ROOT_DIR/build"
OUTPUT_LIBS_DIR="$ROOT_DIR/libs"

# 构建产物: Gradle publish 到本地 Maven 仓库（AndroidBuildRepo，位于根项目
# build/）后生成的 AAR
AAR_SRC="$BUILD_DIR/com/unity3d/player/unityLibrary/unspecified/unityLibrary-unspecified.aar"
AAR_DST="$UNITY_LIB_DIR/../../../../android/unityLibrary/unityLibrary.aar"

# Unity 附带 Java 桥接类（UnityPlayerActivity 等），随 AAR 一起部署
UNITY_CLASSES_SRC="$UNITY_LIB_DIR/libs/unity-classes.jar"
UNITY_CLASSES_DST="$UNITY_LIB_DIR/../../../../android/unityLibrary/unity-classes.jar"

# build.gradle 幂等注入标记: 存在 AndroidBuildRepo（maven-publish）与 flatDir 即视为已配置
MARKER="AndroidBuildRepo"
FLATDIR_MARKER="flatDir"
PLUGIN_LINE="apply plugin: 'com.android.library'"

echo -e "\033[1m> 检查 build.gradle 配置\033[0m"

HAS_MAVEN=false
HAS_FLATDIR=false

grep -q "$MARKER" "$GRADLE_FILE" && HAS_MAVEN=true
grep -q "$FLATDIR_MARKER" "$GRADLE_FILE" && HAS_FLATDIR=true

# 幂等追加远程仓库: AGP 任务依赖的组件（如 lint-gradle）托管在
# google()/mavenCentral()，Unity 导出的 build.gradle 只有 flatDir，缺失时补齐
if ! grep -q "mavenCentral()" "$GRADLE_FILE"; then
cat >> "$GRADLE_FILE" <<'EOF'

repositories {
    google()
    mavenCentral()
}
EOF
  echo -e "  已追加 google()/mavenCentral() 仓库"
fi

if $HAS_MAVEN && $HAS_FLATDIR; then
  echo -e "  OK: build.gradle 已包含所有配置，跳过注入"
else
  echo -e "  开始注入 build.gradle 配置"
  temp_file=$(mktemp)
  while IFS= read -r line; do
    echo "$line" >> "$temp_file"
    if [[ "$line" == *"$PLUGIN_LINE"* ]]; then
      if ! $HAS_FLATDIR; then
cat >> "$temp_file" <<'EOF'

repositories {
    flatDir {
        dirs 'libs'
    }
}
EOF
      fi
    fi
  done < "$GRADLE_FILE"
  if ! $HAS_MAVEN; then
cat >> "$temp_file" <<'EOF'

apply plugin: 'maven-publish'

android {
    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

afterEvaluate {
    publishing {
        publications {
            release(MavenPublication) {
                from components["release"]
                groupId = "com.unity3d.player"
                artifactId = "unityLibrary"
            }
        }
    }
}

publishing {
    repositories {
        maven {
            name = "AndroidBuildRepo"
            url = uri("${rootProject.projectDir}/build")
        }
    }
}

# flatDir 依赖无版本号，无法生成合法的 Gradle Module Metadata（.module）；
# 消费端按 flatDir + aar/jar 方式引用，不需要 .module 文件
tasks.withType(GenerateModuleMetadata).configureEach {
    enabled = false
}
EOF
  fi
  mv "$temp_file" "$GRADLE_FILE"
  echo -e "  注入完成"
fi

echo -e "\033[1m> 清理 build/ 目录\033[0m"
rm -rf "$BUILD_DIR"
rm -rf "$OUTPUT_LIBS_DIR"
rm -rf "$ROOT_DIR/../build"
echo -e "  清理 build/ 目录完成"

echo -e "\033[1m> 准备 Gradle 构建环境\033[0m"

# 上游导出仅含 unityLibrary 模块（无顶层 settings.gradle / build.gradle /
# gradle.properties / gradlew），以下幂等补齐最小 Gradle 工程骨架，
# 构建工具链取自 Unity 编辑器自带组件。

cd "$ROOT_DIR"

# JAVA_HOME: 优先 Unity 自带 OpenJDK（AGP 7.x 要求 JDK 11）
UNITY_EDITOR_ROOT=$(ls -dt /Applications/Unity/Hub/Editor/*/ 2>/dev/null | head -1)
UNITY_JDK="${UNITY_EDITOR_ROOT}PlaybackEngines/AndroidPlayer/OpenJDK"
UNITY_SDK="${UNITY_EDITOR_ROOT}PlaybackEngines/AndroidPlayer/Sdk"
if [ -d "$UNITY_JDK" ]; then
  export JAVA_HOME="$UNITY_JDK"
  echo -e "  JAVA_HOME -> $JAVA_HOME"
fi

# local.properties: 幂等写入 SDK/NDK 位置；ndk.dir 供 il2cpp 构建任务
# （BuildIl2CppTask --tool-chain-path）定位工具链
UNITY_NDK="${UNITY_EDITOR_ROOT}PlaybackEngines/AndroidPlayer/NDK"
if [ ! -f "local.properties" ]; then
  {
    [ -d "$UNITY_SDK" ] && echo "sdk.dir=$UNITY_SDK"
    [ -d "$UNITY_NDK" ] && echo "ndk.dir=$UNITY_NDK"
  } > local.properties
  echo -e "  已写入 local.properties（sdk.dir/ndk.dir -> Unity 自带 SDK/NDK）"
elif ! grep -q '^ndk.dir=' local.properties && [ -d "$UNITY_NDK" ]; then
  echo "ndk.dir=$UNITY_NDK" >> local.properties
  echo -e "  已补写 local.properties 的 ndk.dir"
fi

# settings.gradle: 声明 unityLibrary 模块；publish 输出目录为
# ${rootProject.projectDir}/build，与 AAR_SRC 路径约定一致
if [ ! -f "settings.gradle" ]; then
cat > settings.gradle <<'EOF'
pluginManagement {
    repositories {
        gradlePluginPortal()
        google()
        mavenCentral()
    }
}
include ':unityLibrary'
EOF
  echo -e "  已生成 settings.gradle"
fi

# 顶层 build.gradle: 声明 AGP 插件版本（模块 build.gradle 中 plugin 无版本号）
if [ ! -f "build.gradle" ]; then
cat > build.gradle <<'EOF'
plugins {
    id 'com.android.library' version '7.4.2' apply false
}
EOF
  echo -e "  已生成 build.gradle（AGP 7.4.2）"
fi

if [ ! -f "gradle.properties" ]; then
cat > gradle.properties <<'EOF'
org.gradle.jvmargs=-Xmx4096m
org.gradle.parallel=true
android.useAndroidX=true
EOF
  echo -e "  已生成 gradle.properties"
fi

# Gradle 可执行探测: ./gradlew > 环境变量 GRADLE_BIN > ~/.gradle 缓存发行版 > 系统 PATH
if [ -x "./gradlew" ]; then
  GRADLE_CMD="./gradlew"
else
  if [ -n "$GRADLE_BIN" ] && [ -x "$GRADLE_BIN" ]; then
    BOOT_GRADLE="$GRADLE_BIN"
  else
    # 取缓存里版本最高的发行版（dists 目录名 gradle-<ver>-bin/<hash>/gradle-<ver>/bin/gradle）
    BOOT_GRADLE=$(ls -d "$HOME/.gradle/wrapper/dists/gradle-"*"-bin/"*/gradle-*/bin/gradle 2>/dev/null | sort -V | tail -1)
    [ -z "$BOOT_GRADLE" ] && BOOT_GRADLE=$(which gradle 2>/dev/null || true)
  fi
  if [ -z "$BOOT_GRADLE" ] || [ ! -x "$BOOT_GRADLE" ]; then
    echo -e "\033[31m> 错误: 未找到 Gradle。请设置 GRADLE_BIN 环境变量，或先运行一次 Android 构建以填充 ~/.gradle 缓存。\033[0m"
    exit 1
  fi
  echo -e "  引导 Gradle: $BOOT_GRADLE"
  # AGP 7.4.2 要求 Gradle 7.5.x（Unity 2022.3 预装版本）；用引导 Gradle 生成对应 wrapper
  if [ ! -f "gradlew" ]; then
    "$BOOT_GRADLE" wrapper --gradle-version 7.5.1 --distribution-type bin -q
    echo -e "  已生成 gradle wrapper（7.5.1）"
  fi
  GRADLE_CMD="./gradlew"
fi
echo -e "  构建命令: $GRADLE_CMD"

echo -e "\033[1m> 执行 Gradle publish\033[0m"
# publish 失败不在此中断，由后续 AAR 存在性与 ABI 校验兜底
"$GRADLE_CMD" :unityLibrary:publishReleasePublicationToAndroidBuildRepo || true

echo -e ""
echo -e "\033[1m> 校验 AAR 架构（jniLibs ABI，防止缺失 .so 导致运行期 NoClassDefFound/UnsatisfiedLinkError）\033[0m"

echo -e "  AAR 内 .so 库清单:"
unzip -l "$AAR_SRC" | grep -E '\.so$' | awk '{print "    " $4}' | sort

if ! unzip -l "$AAR_SRC" | grep -q "jni/arm64-v8a/"; then
  echo -e "\033[31m> 错误: AAR 缺少 arm64-v8a ABI 库（现代手机全部为 arm64，缺则全机型闪退）\033[0m"
  exit 1
fi
echo -e "  OK: 已检出 arm64-v8a ABI"

echo -e "\033[1m> 复制 unityLibrary.aar\033[0m"
mkdir -p "$OUTPUT_LIBS_DIR"

if [ ! -f "$AAR_SRC" ]; then
  echo -e "\033[31m> unityLibrary.aar 未找到：$AAR_SRC\033[0m"
  exit 1
fi

cp "$AAR_SRC" "$AAR_DST" 2>/dev/null || {
  # 部署目标目录可能不存在（Unity 导出工程整体搬移后），重建后再拷
  mkdir -p "$(dirname "$AAR_DST")"
  cp "$AAR_SRC" "$AAR_DST"
}
echo -e "  $AAR_SRC 已复制到 $AAR_DST"

echo -e "\033[1m> 复制 unity-classes.jar\033[0m"
if [ ! -f "$UNITY_CLASSES_SRC" ]; then
  echo -e "\033[31m> unity-classes.jar 未找到：$UNITY_CLASSES_SRC\033[0m"
  exit 1
fi

cp "$UNITY_CLASSES_SRC" "$UNITY_CLASSES_DST"
echo -e "  $UNITY_CLASSES_SRC 已复制到 $UNITY_CLASSES_DST"

# 清理构建中间产物，仅保留部署到 Flutter 侧的最终产物
echo -e "\033[1m> 清理 build/\033[0m"
rm -rf "$BUILD_DIR"
rm -rf "$OUTPUT_LIBS_DIR"
rm -rf "$ROOT_DIR/../build"
echo -e "  清理 build/ 目录完成"

echo -e ""
echo -e "\033[1;32m[OK] unityLibrary.aar & unity-classes.jar 已准备就绪\033[0m"
