using UnityEditor;
using UnityEditor.iOS;
using FlutterUnityIntegration.Editor;

namespace UnityExportExtras
{
    /// <summary>
    /// iOS 模拟器导出入口（批处理用）。
    ///
    /// 上游 Build.cs 只有真机导出（DoBuildIOSRelease），本包装器在导出前把
    /// iOS SDK 切到 Simulator，使 il2cpp 产物（libGameAssembly.a）编译为
    /// 模拟器 slice，供 xcodebuild -sdk iphonesimulator 归档 UnityFramework 使用。
    ///
    /// 用法（命令行）:
    ///   Unity -batchmode -quit -buildTarget iOS \
    ///     -executeMethod UnityExportExtras.SimulatorExport.DoBuildIOSSimulator
    /// </summary>
    public static class SimulatorExport
    {
        public static void DoBuildIOSSimulator()
        {
            PlayerSettings.iOS.sdkVersion = iOSSdkVersion.SimulatorSDK;
            // 模拟器架构必须显式设为 ARM64: 默认 X86_64 导出的 libil2cpp.a
            // 只有 x86_64 slice，arm64 归档时被 ld 全部忽略，_il2cpp_init 等
            // dlsym 符号不进产物，运行时必然崩溃
            PlayerSettings.iOS.simulatorSdkArchitecture = AppleMobileArchitectureSimulator.ARM64;
            Build.DoBuildIOSRelease();
        }
    }
}
