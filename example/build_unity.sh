#!/bin/bash
set -e

# ============================================================
# Unity 一键导出 + Flutter 侧构建脚本
#
# 功能:
#   调用 Unity 批处理导出 Android/iOS 工程，再执行 Flutter 侧构建脚本，
#   最终产出 unityLibrary.aar（Android）与 UnityFramework.framework（iOS）
#   并部署回 Flutter 工程。
#
# 用法:
#   ./build_unity.sh                # 交互式菜单选择
#   ./build_unity.sh android        # Android Release：Unity 导出 + Gradle 构建
#   ./build_unity.sh ios device     # iOS 真机 Release：Unity 导出 + Xcode archive
#   ./build_unity.sh ios simulator  # iOS 模拟器 Release
#   ./build_unity.sh ios-device     # 连写形式，等价于 ios device
#   ./build_unity.sh ios-simulator  # 连写形式，等价于 ios simulator
#
# 选项:
#   $1  android | ios | ios-device | ios-simulator
#   $2  $1 为 ios 时的构建模式 device | simulator（连写形式与菜单不使用 $2）
#
# 流程:
#   1. 清理导出暂存目录 unity/flutter/<平台>
#   2. Unity -batchmode -executeMethod 批量导出。上游 Build.cs 的导出落点是
#      Flutter 工程根的 android/unityLibrary 与 ios/UnityLibrary，导出完成后
#      由 stage_export 整体搬移到 unity/flutter/<平台>/ 并拷入 Flutter 侧脚本
#   3. 执行 unity/flutter/<平台>/build_unity.sh，产物（unityLibrary.aar /
#      UnityFramework.framework）部署回 Flutter 工程 android/、ios/ 目录
#
# 环境变量:
#   UNITY_EDITOR       Unity 可执行文件路径（缺省按安装时间取 Hub 下最新）
#   GRADLE_BIN         Android 侧引导用 Gradle（见 android/build_unity.sh）
#   DEPLOYMENT_TARGET  iOS 最低部署版本（见 ios/build_unity.sh，默认 15.0）
#
# 依赖:
#   Unity Hub 安装的编辑器；Android/iOS 侧脚本各自声明的工具链
#
# 兼容性:
#   macOS；Unity 2022.3；全部路径基于脚本所在目录推导，可整体搬迁
#
# 退出状态:
#   0 成功；1 参数错误、Unity 编辑器/工程缺失、Unity 导出失败、
#   Flutter 侧构建失败
#
# 注意:
#   - iOS 模拟器导出走 Assets/Editor/SimulatorExport.cs 包装器（上游
#     Build.cs 无模拟器导出方法），包装器切换 Simulator SDK 后复用真机导出
#   - iOS 未指定模式时按暂存目录是否存在 UnityLibrary-Simulator 自动判定
#   - 构建日志写入 /tmp/unity_*.log
# ============================================================

# ---------- 路径解析（相对路径，脚本可整体迁移） ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UNITY_PROJECT="$SCRIPT_DIR/unity/DemoApp"

# ---------- 动态获取 Unity 编辑器 ----------
UNITY_BIN="${UNITY_EDITOR:-}"
if [ -z "$UNITY_BIN" ] || [ ! -x "$UNITY_BIN" ]; then
  # 按安装时间倒序取最近安装的 Unity 版本（macOS 通用，不依赖 sort -V）
  UNITY_BIN=$(ls -t /Applications/Unity/Hub/Editor/*/Unity.app/Contents/MacOS/Unity 2>/dev/null | head -n 1 || true)
fi

if [ -z "$UNITY_BIN" ] || [ ! -x "$UNITY_BIN" ]; then
  echo -e "\033[31m> 错误: 未找到 Unity 编辑器。\033[0m"
  echo -e "\033[31m> 请通过 Unity Hub 安装 Unity，或设置环境变量 UNITY_EDITOR 指向 Unity 可执行文件。\033[0m"
  exit 1
fi

if [ ! -d "$UNITY_PROJECT" ]; then
  echo -e "\033[31m> 错误: 未找到 Unity 工程目录: ${UNITY_PROJECT}\033[0m"
  exit 1
fi

# ---------- 交互式菜单（无参数时） ----------
if [ $# -eq 0 ]; then
  echo ""
  echo -e "\033[1m请选择构建目标:\033[0m"
  echo "  [1] Android (Release)"
  echo "  [2] iOS (真机 Release)"
  echo "  [3] iOS (模拟器 Release)"
  printf "\033[1m请输入选项（或 q 退出）: \033[0m"
  read -r choice
  echo ""

  case "$choice" in
    1) TARGET="android" ;;
    2) TARGET="ios"; BUILD_MODE="device" ;;
    3) TARGET="ios"; BUILD_MODE="simulator" ;;
    q|Q) echo "已退出。" ; exit 0 ;;
    *) echo -e "\033[31m> 无效选项: ${choice}\033[0m" ; exit 1 ;;
  esac
else
  TARGET="$1"
  # 兼容 "ios-device" / "ios-simulator" 连写形式
  if [ "$TARGET" = "ios-device" ]; then TARGET="ios"; BUILD_MODE="device"; fi
  if [ "$TARGET" = "ios-simulator" ]; then TARGET="ios"; BUILD_MODE="simulator"; fi

  if [ "$TARGET" = "ios" ]; then
    # 连写形式已设置过 BUILD_MODE 时不再被 $2 覆盖
    BUILD_MODE="${BUILD_MODE:-${2:-}}"
    if [ -z "$BUILD_MODE" ]; then
      # 未指定时自动检测：存在 UnityLibrary-Simulator/ 则默认模拟器，否则真机（与 Flutter 侧脚本默认一致）
      if [ -d "$SCRIPT_DIR/unity/flutter/ios/UnityLibrary-Simulator" ]; then
        BUILD_MODE="simulator"
      else
        BUILD_MODE="device"
      fi
    fi
  fi
fi

# ---------- 目标校验 ----------
case "$TARGET" in
  android)
    ;;
  ios)
    case "$BUILD_MODE" in
      device|simulator) ;;
      *) echo -e "\033[31m> 无效的 iOS 目标: ${BUILD_MODE}（可选 device | simulator）\033[0m" ; exit 1 ;;
    esac
    ;;
  *)
    echo -e "\033[31m> 未知目标: ${TARGET}（可选 android | ios [device|simulator]）\033[0m"
    exit 1
    ;;
esac

echo -e "\033[90m> Unity 编辑器: ${UNITY_BIN}\033[0m"
echo -e "\033[90m> Unity 工程:   ${UNITY_PROJECT}\033[0m"

# ---------- 步骤 0: 清理导出暂存目录 ----------
clean_export_dir() {
  local dir="$1"
  if [ -d "$dir" ]; then
    echo -e "  清理暂存目录: ${dir}"
    rm -rf "$dir"
  fi
}

# ---------- stage_export: 搬移导出工程到暂存目录 ----------
# 功能: 将 Unity 导出工程整体搬移到 unity/flutter/<平台>/ 暂存目录，
#       并把对应 Flutter 侧构建脚本拷入该目录
# 用法: stage_export <导出目录> <暂存目录> <脚本路径> <脚本拷入目录>
# 前提: 暂存目录本身必须不存在（父目录可有可无），mv 才是整目录重命名
#       而非移入子目录
stage_export() {
  local src="$1" dst="$2" script_src="$3" script_dst_dir="$4"
  if [ ! -d "$src" ]; then
    echo -e "\033[31m> 错误: Unity 导出产物未找到: ${src}\033[0m"
    exit 1
  fi
  # 只建目标父目录，dst 本身必须不存在，mv 才是整目录重命名而非移入子目录
  mkdir -p "$(dirname "$dst")"
  mv "$src" "$dst"
  cp "$script_src" "$script_dst_dir/"
  echo -e "  ${src} -> ${dst}"
}

# ---------- export_unity: Unity 批量导出 ----------
# 功能: 调用 Unity -batchmode 执行指定的导出方法，并校验导出结果
# 用法: export_unity <构建目标> <导出方法> <日志文件> [Unity 额外参数]
# 参数: 导出方法含 "." 时视为完整限定名（如
#       UnityExportExtras.SimulatorExport.DoBuildIOSSimulator），否则视为
#       上游 Build 类内的方法名
export_unity() {
  local target="$1" method="$2" logfile="$3" extra="${4:-}"
  case "$method" in
    *.*) exec_method="$method" ;;
    *)   exec_method="FlutterUnityIntegration.Editor.Build.$method" ;;
  esac
  echo -e "\n\033[1m> 步骤 1/2: Unity 批量导出（${method##*.}）...\033[0m"
  "$UNITY_BIN" -batchmode -quit $extra \
    -projectPath "$UNITY_PROJECT" \
    -buildTarget "$target" \
    -executeMethod "$exec_method" \
    -logFile "$logfile"

  # 部分失败场景 Unity 退出码仍为 0，以日志内容判定导出结果
  if grep -q "Build completed with a result of 'Failed'" "$logfile" 2>/dev/null; then
    echo -e "\033[31m> Unity 导出失败，请查看日志: ${logfile}\033[0m"
    exit 1
  fi
  echo -e "  Unity 导出完成（日志: ${logfile}）"
}

# ---------- flutter_build: Flutter 侧构建 ----------
# 功能: 进入暂存目录并执行其中的 build_unity.sh
# 用法: flutter_build <暂存目录相对路径> [传给脚本的参数]
flutter_build() {
  local dir="$1" args="${2:-}"
  echo -e "\n\033[1m> 步骤 2/2: Flutter 侧构建（${dir}）...\033[0m"
  cd "$SCRIPT_DIR/$dir"
  ./build_unity.sh $args
}

# ---------- 执行目标 ----------
case "$TARGET" in
  android)
    clean_export_dir "$SCRIPT_DIR/unity/flutter/android"
    export_unity "Android" "DoBuildAndroidLibraryRelease" "/tmp/unity_android.log" "-nographics"
    stage_export \
      "$SCRIPT_DIR/android/unityLibrary" \
      "$SCRIPT_DIR/unity/flutter/android/unityLibrary" \
      "$SCRIPT_DIR/android/build_unity.sh" \
      "$SCRIPT_DIR/unity/flutter/android"
    flutter_build "unity/flutter/android"
    ;;
  ios)
    clean_export_dir "$SCRIPT_DIR/unity/flutter/ios"
    if [ "$BUILD_MODE" = "device" ]; then
      export_unity "iOS" "DoBuildIOSRelease" "/tmp/unity_ios.log"
      stage_export \
        "$SCRIPT_DIR/ios/UnityLibrary" \
        "$SCRIPT_DIR/unity/flutter/ios/UnityLibrary" \
        "$SCRIPT_DIR/ios/build_unity.sh" \
        "$SCRIPT_DIR/unity/flutter/ios"
      flutter_build "unity/flutter/ios" "device"
    else
      # 上游 Build.cs 无模拟器导出方法，走 Assets/Editor/SimulatorExport.cs 包装器
      export_unity "iOS" "UnityExportExtras.SimulatorExport.DoBuildIOSSimulator" "/tmp/unity_ios_sim.log"
      stage_export \
        "$SCRIPT_DIR/ios/UnityLibrary" \
        "$SCRIPT_DIR/unity/flutter/ios/UnityLibrary-Simulator" \
        "$SCRIPT_DIR/ios/build_unity.sh" \
        "$SCRIPT_DIR/unity/flutter/ios"
      flutter_build "unity/flutter/ios" "simulator"
    fi
    ;;
esac

echo -e "\n\033[1;32m[OK] 构建全部完成: ${TARGET}${BUILD_MODE:+ (${BUILD_MODE})}\033[0m"
