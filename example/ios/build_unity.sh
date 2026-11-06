#!/bin/bash
set -e

# ============================================================
# UnityFramework 导出脚本（archive 流程）
#
# 功能:
#   对 Unity 导出的 Unity-iPhone.xcodeproj 执行 xcodebuild archive，
#   校验产物架构与符号后，将 UnityFramework.framework 以平台名
#   （UnityFramework-{Device,Simulator}.framework）与通用名
#   UnityFramework.framework 各部署一份到 Flutter 工程 ios/UnityLibrary/，
#   最后清理构建目录。
#
# 用法:
#   ./build_unity.sh [device|simulator]
#
# 选项:
#   $1  构建目标；缺省自动检测：本目录存在 UnityLibrary-Simulator/ 时为
#       simulator，否则 device
#
# 环境变量:
#   DEPLOYMENT_TARGET  IPHONEOS_DEPLOYMENT_TARGET 覆盖值（默认 15.0）
#
# 依赖:
#   Xcode 命令行工具（xcodebuild / lipo / nm / codesign / ruby）
#
# 兼容性:
#   macOS；仅构建 arm64；Unity 2022.3 导出工程
#
# 退出状态:
#   0 成功；1 参数非法、archive 失败或任一校验不通过
#
# 注意:
#   模拟器构建需修改导出工程 pbxproj（GameAssembly Run Script 注入
#   outputPaths）并覆盖 OTHER_LDFLAGS，均为幂等操作，重复执行安全
# ============================================================

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 目标自动检测: 本目录存在 UnityLibrary-Simulator/ 则默认 simulator，否则 device（可用参数覆盖）
DEFAULT_TARGET="device"
if [ -d "$ROOT_DIR/UnityLibrary-Simulator" ]; then
    DEFAULT_TARGET="simulator"
fi
TARGET=${1:-$DEFAULT_TARGET}

case "$TARGET" in
  device|simulator) ;;
  *) echo -e "\033[31m> 非法目标: $TARGET（可选 device|simulator）\033[0m"; exit 1 ;;
esac

ARCH="arm64"
CONFIGURATION="Release"
UNITYLIBRARY="unityLibrary"
# IPHONEOS_DEPLOYMENT_TARGET 覆盖导出工程的默认值 12.0（低于当前 Xcode
# 模拟器 SDK 的最低部署版本，不覆盖则 archive 直接失败）
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-15.0}"
if [ "$TARGET" == "simulator" ]; then
    SDK="iphonesimulator"
    UNITYLIBRARY="UnityLibrary-Simulator"
    FRAMEWORK_NAME="UnityFramework-Simulator.framework"
    # 模拟器链接参数整体覆盖 OTHER_LDFLAGS，取值说明:
    #   $(OTHER_LDFLAGS_FRAMEWORK)              Unity 工程原有的 framework 链接
    #                                           参数（-framework UIKit 等），
    #                                           整体覆盖时必须保留原值引用
    #   -Wl,-undefined,dynamic_lookup           未解析符号延迟到运行时解析
    #   -Wl,-force_load,...libGameAssembly.a    il2cpp 用户代码产物仅被 dlsym
    #                                           引用，不整体载入则 _il2cpp_init
    #                                           等符号不会进入产物
    #   -ObjC                                   强制加载 ObjC 类别，保证 ObjC 类
    #                                           以全局符号导出
    # libil2cpp.a（Unity il2cpp 运行时）的符号存在编译期引用，dynamic_lookup
    # 下正常链接即可进入产物，无需 force_load；其目标文件为 bitcode，LTO 会
    # 剔除仅被 dlsym 引用的 API，故同时传 LLVM_LTO=NO 与 DEAD_CODE_STRIPPING=NO
    LDFLAGS_OVERRIDE='$(OTHER_LDFLAGS_FRAMEWORK) -Wl,-undefined,dynamic_lookup -Wl,-force_load,$(BUILT_PRODUCTS_DIR)/libGameAssembly.a -ObjC'
else
    SDK="iphoneos"
    FRAMEWORK_NAME="UnityFramework-Device.framework"
    LDFLAGS_OVERRIDE=""
fi

echo -e "\033[1m> 编译目标: $TARGET ($SDK)\033[0m"

UNITY_LIB_DIR="$ROOT_DIR/$UNITYLIBRARY"
BUILD_DIR="$ROOT_DIR/build"
OUTPUT_LIBS_DIR="$ROOT_DIR/../../../ios/UnityLibrary"

ARCHIVE_PATH="$BUILD_DIR/UnityFramework.xcarchive"
FRAMEWORK_SRC="$ARCHIVE_PATH/Products/Library/Frameworks/UnityFramework.framework"
FRAMEWORK_DST="$OUTPUT_LIBS_DIR/$FRAMEWORK_NAME"

echo -e "\033[1m> 清理 build/ 目录\033[0m"
rm -rf "$BUILD_DIR"
echo -e "  清理 build/ 目录完成"

echo -e "\033[1m> 执行 Archiving UnityFramework ($SDK)\033[0m"

OTHER_LDFLAGS_ARGS=()
XCODEBUILD_EXTRA_ARGS=()
if [ "$TARGET" == "simulator" ]; then
    # GameAssembly Run Script 生成 libGameAssembly.a 但未声明 outputPaths，
    # 链接阶段会因构建输入缺失而失败；Unity 导出工程不含该声明，每次构建前
    # 用内联 Ruby 幂等补回
    XCODEBUILD_EXTRA_ARGS=(DEAD_CODE_STRIPPING=NO LLVM_LTO=NO)
    ruby - "$UNITY_LIB_DIR/Unity-iPhone.xcodeproj/project.pbxproj" <<'RUBY'
# 给 GameAssembly Run Script 注入 outputPaths（声明 libGameAssembly.a 为脚本产物）
pbxproj = ARGV[0]
lines = File.read(pbxproj).lines

# 定位 GameAssembly 的 Run Script 行: 真机工程脚本含 lipo（多架构合并），
# 模拟器工程脚本单架构无 lipo，统一以 il2cpp + libGameAssembly 输出为特征
idx = lines.index { |l| l.include?('lipo') || (l.include?('il2cpp') && l.include?('libGameAssembly')) }
if idx.nil?
  warn 'WARN: 未找到 GameAssembly Run Script，跳过注入'
  exit 0
end

# 幂等: 脚本块内已声明 libGameAssembly.a 的 outputPaths 则跳过
if lines[idx..(idx + 20)].any? { |l| l.include?('libGameAssembly.a') && l.include?('outputPaths') }
  puts 'OK: outputPaths 已声明，跳过注入'
  exit 0
end

# 定位脚本块结尾（shellScript 行之后的第一个 "};" 行）
tail = lines[(idx + 1)..]
end_idx = tail.index { |l| l =~ /^\s*\};$/ }
if end_idx.nil?
  warn 'WARN: 未找到脚本块结尾，跳过注入'
  exit 0
end
insert_at = idx + 1 + end_idx

# \$ 转义避免 Ruby 将 $C 解析为全局变量；pbxproj 块属性为 3 层 tab 缩进
lines.insert(insert_at, "\t\t\toutputPaths = ( \"\$(CONFIGURATION_BUILD_DIR)/libGameAssembly.a\" );\n")
File.write(pbxproj, lines.join)
puts 'OK: 已注入 outputPaths (libGameAssembly.a)'
RUBY
    OTHER_LDFLAGS_ARGS=(OTHER_LDFLAGS="$LDFLAGS_OVERRIDE")
fi

xcodebuild archive -project "$UNITY_LIB_DIR/Unity-iPhone.xcodeproj" -scheme UnityFramework \
    -sdk "$SDK" -arch "$ARCH" -configuration "$CONFIGURATION" -archivePath "$ARCHIVE_PATH" \
    IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    CODE_SIGNING_ALLOWED=NO "${XCODEBUILD_EXTRA_ARGS[@]}" "${OTHER_LDFLAGS_ARGS[@]}"

echo -e ""
echo -e "\033[1m> 校验产物完整性（防止残缺版覆盖）\033[0m"

# 校验 1: 架构完整性——脚本仅构建 arm64，产物必须含 arm64 slice
echo -e "  lipo -info: $(lipo -info "$FRAMEWORK_SRC/UnityFramework")"
if ! lipo -archs "$FRAMEWORK_SRC/UnityFramework" | grep -q "arm64"; then
    echo -e "\033[31m> 错误: framework 缺少 arm64 slice（M 芯片模拟器/真机均无法加载）\033[0m"
    exit 1
fi
echo -e "  OK: 已检出 arm64 slice"

# 校验 2: ObjC 类须为全局导出符号，被剥成 local 时宿主链接报 Undefined symbol
if ! nm -g "$FRAMEWORK_SRC/UnityFramework" | grep -q " S _OBJC_CLASS_\$_UnityAppController$"; then
    echo -e "\033[31m> 错误: 产物缺少全局导出符号 _OBJC_CLASS_\$_UnityAppController\033[0m"
    echo -e "\033[31m> 疑似 OTHER_LDFLAGS 丢失 -ObjC\033[0m"
    exit 1
fi
echo -e "  OK: 已检出全局导出符号 _OBJC_CLASS_\$_UnityAppController"

# 校验 3: _il2cpp_init 须可导出——il2cpp runtime 由 Unity 原生 trampoline
#         通过 dlsym 加载，缺失时运行时报 "Could not load symbol il2cpp_init"
if ! nm -g "$FRAMEWORK_SRC/UnityFramework" | grep -q " T _il2cpp_init$"; then
    echo -e "\033[31m> 错误: 产物缺少导出符号 _il2cpp_init（dlsym 加载 il2cpp 失败）\033[0m"
    echo -e "\033[31m> 疑似 OTHER_LDFLAGS 丢失 -force_load libGameAssembly.a\033[0m"
    exit 1
fi
echo -e "  OK: 已检出导出符号 _il2cpp_init"

# 校验 4: 统计 _il2cpp* 导出规模，确认 il2cpp runtime 完整进入产物
IL2CPP_COUNT=$(nm -gU "$FRAMEWORK_SRC/UnityFramework" | grep -c '_il2cpp')
echo -e "  OK: 导出 _il2cpp* 符号共 ${IL2CPP_COUNT} 个"

echo -e "\033[1m> 复制 UnityFramework.framework\033[0m"
mkdir -p "$OUTPUT_LIBS_DIR"

if [ ! -d "$FRAMEWORK_SRC" ]; then
    echo -e "\033[31m> UnityFramework.framework 未找到：$FRAMEWORK_SRC\033[0m"
    exit 1
fi

# 双份部署: 对应平台名（UnityFramework-{Simulator,Device}.framework）与通用名
# UnityFramework.framework 各复制一份，供 iOS 工程按需引用
FRAMEWORK_COMMON_DST="$OUTPUT_LIBS_DIR/UnityFramework.framework"
for dst in "$FRAMEWORK_DST" "$FRAMEWORK_COMMON_DST"; do
  if [ -d "$dst" ]; then
    rm -rf "$dst"
  fi
  cp -R "$FRAMEWORK_SRC" "$dst"
  echo -e "  $FRAMEWORK_SRC 已复制到 $dst"
done

# 模拟器分支: libiPhone-lib.dylib 若为 fat 二进制则瘦身到 arm64 并重签，
# 与主二进制架构一致；两份部署均处理
if [ "$TARGET" == "simulator" ]; then
  for dst in "$FRAMEWORK_DST" "$FRAMEWORK_COMMON_DST"; do
    DYLIB="$dst/libiPhone-lib.dylib"
    if [ -f "$DYLIB" ]; then
      # 幂等: 仅当 dylib 仍为 fat 时才执行 lipo -thin（thin 输入会让 lipo 报错）
      if lipo -info "$DYLIB" | grep -q "are:"; then
        lipo -thin arm64 -output "$DYLIB.thin" "$DYLIB" && mv "$DYLIB.thin" "$DYLIB"
        # lipo 重写 Mach-O 后签名失效，ad-hoc 重签（模拟器构建无需正式证书）
        codesign -f -s - "$DYLIB"
        echo -e "  OK: $(basename "$dst") 内 libiPhone-lib.dylib 已瘦身为 arm64-only 并重签"
      else
        echo -e "  OK: $(basename "$dst") 内 libiPhone-lib.dylib 已为 arm64-only，跳过"
      fi
    fi
  done
fi

echo -e "\033[1m> 清理 build/\033[0m"
rm -rf "$BUILD_DIR"
echo -e "  清理 build/ 目录完成"

echo -e ""
echo -e "\033[1;32m[OK] $FRAMEWORK_NAME 与 UnityFramework.framework 已准备就绪\033[0m"
