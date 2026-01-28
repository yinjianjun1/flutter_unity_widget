import UIKit
import Flutter
import ObjectiveC.runtime

public class UnityHomeIndicatorFix: NSObject {
    private static var shouldHideHomeIndicator = false
    private static var isSwizzled = false

    static func register(channel: FlutterMethodChannel) {
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "showHomeIndicator":
                show()
                result(nil)
            case "hideHomeIndicator":
                hide()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    static func setupHomeIndicatorSwizzle() {
        swizzleUnityHomeIndicator()
    }

    private static func show() {
        DispatchQueue.main.async {
            shouldHideHomeIndicator = false
            if let keyWindow = getKeyWindow() {
                keyWindow.rootViewController?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            }
        }
    }

    private static func hide() {
        DispatchQueue.main.async {
            shouldHideHomeIndicator = true
            if let keyWindow = getKeyWindow() {
                keyWindow.rootViewController?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            }
        }
    }

    private static func getKeyWindow() -> UIWindow? {
        if #available(iOS 13.0, *) {
            return UIApplication.shared.connectedScenes
                .filter { $0.activationState == .foregroundActive }
                .compactMap { $0 as? UIWindowScene }
                .first?.windows
                .first { $0.isKeyWindow }
        } else {
            return UIApplication.shared.keyWindow
        }
    }

    private static func swizzleUnityHomeIndicator() {
        guard !isSwizzled else { return }

        let cls: AnyClass? = NSClassFromString("UnityAppController")
        guard let originalCls = cls else {
            return
        }

        let originalSelector = #selector(getter: UIViewController.prefersHomeIndicatorAutoHidden)

        let swizzledBlock: @convention(block) (AnyObject) -> Bool = { _ in
            return shouldHideHomeIndicator
        }

        let swizzledImplementation = imp_implementationWithBlock(unsafeBitCast(swizzledBlock, to: AnyObject.self))

        guard let originalMethod = class_getInstanceMethod(originalCls, originalSelector) else {
            return
        }

        let didAddMethod = class_addMethod(
            originalCls,
            originalSelector,
            swizzledImplementation,
            method_getTypeEncoding(originalMethod)
        )

        if !didAddMethod {
            method_setImplementation(originalMethod, swizzledImplementation)
        }

        isSwizzled = true
    }
}