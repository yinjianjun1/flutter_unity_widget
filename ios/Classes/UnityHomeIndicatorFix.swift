import UIKit
import ObjectiveC.runtime

extension UIViewController {

    @objc func fu_prefersHomeIndicatorAutoHidden() -> Bool {
        return false
    }

    static func swizzleHomeIndicator() {
        let originalSelector = #selector(getter: UIViewController.prefersHomeIndicatorAutoHidden)
        let swizzledSelector = #selector(UIViewController.fu_prefersHomeIndicatorAutoHidden)

        guard
            let originalMethod = class_getInstanceMethod(UIViewController.self, originalSelector),
            let swizzledMethod = class_getInstanceMethod(UIViewController.self, swizzledSelector)
        else {
            return
        }

        method_exchangeImplementations(originalMethod, swizzledMethod)
    }
}