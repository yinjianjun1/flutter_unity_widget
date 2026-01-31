//
//  FLTUnityViewController.swift
//  flutter_unity_widget
//
//  Created by Rex Raphael on 30/01/2021.
//

import Foundation
import UnityFramework
import UIKit

// Fullscreen State
public class UnityFullscreenState {
    static let shared = UnityFullscreenState()
    private init() {}

    var isFullscreen: Bool = false
}

// Custom Unity Root VC
final class UnityRootViewController: UIViewController {
    private let unityVC: UIViewController

    init(unityViewController: UIViewController) {
        self.unityVC = unityViewController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(unityVC)
        view.addSubview(unityVC.view)

        unityVC.view.frame = view.bounds
        unityVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        unityVC.didMove(toParent: self)
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        return UnityFullscreenState.shared.isFullscreen
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        return UnityFullscreenState.shared.isFullscreen ? .all : []
    }
}

// Defines unity controllable from Flutter.
public class FLTUnityWidgetController: NSObject, FLTUnityOptionsSink, FlutterPlatformView {
    private var _rootView: FLTUnityView
    private var viewId: Int64 = 0
    private var channel: FlutterMethodChannel?
    private weak var registrar: (NSObjectProtocol & FlutterPluginRegistrar)?
    
    private var _disposed = false

    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        registrar: NSObjectProtocol & FlutterPluginRegistrar
    ) {
        self._rootView = FLTUnityView(frame: frame)
        super.init()

        globalControllers.append(self)

        self.viewId = viewId

        let channelName = String(format: "plugin.xraph.com/unity_view_%lld", viewId)
        self.channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())

        self.channel?.setMethodCallHandler(self.methodHandler)
        self.attachView()
    }

    func methodHandler(_ call: FlutterMethodCall, result: FlutterResult) {
        if call.method == "unity#dispose" {
            self.dispose()
            result(nil)
        } else {
            self.reattachView()
            if call.method == "unity#isReady" {
                result(GetUnityPlayerUtils().unityIsInitiallized())
            } else if call.method == "unity#isLoaded" {
                let _isUnloaded = GetUnityPlayerUtils().isUnityLoaded()
                result(_isUnloaded)
            } else if call.method == "unity#createUnityPlayer" {
                startUnityIfNeeded()
                result(nil)
            } else if call.method == "unity#isPaused" {
                let _isPaused = GetUnityPlayerUtils().isUnityPaused()
                result(_isPaused)
            } else if call.method == "unity#pausePlayer" {
                GetUnityPlayerUtils().pause()
                result(nil)
            } else if call.method == "unity#postMessage" {
                self.postMessage(call: call, result: result)
                result(nil)
            } else if call.method == "unity#resumePlayer" {
                GetUnityPlayerUtils().resume()
                result(nil)
            } else if call.method == "unity#unloadPlayer" {
                GetUnityPlayerUtils().unload()
                result(nil)
            } else if call.method == "unity#quitPlayer" {
                GetUnityPlayerUtils().quit()
                result(nil)
            } else if call.method == "unity#waitForUnity" {
                result(nil)
            } else if call.method == "unity#setFullscreen" {
                if let fullscreen = call.arguments as? Bool {
                    DispatchQueue.main.async {
                        UnityFullscreenState.shared.isFullscreen = fullscreen
                        self.applyUnityRootViewController()
                    }
                }
                result(nil)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
    }

    func setDisabledUnload(enabled: Bool) {

    }

    public func view() -> UIView {
        return _rootView;
    }

    private func setHomeIndicator() {
        if let vc = GetUnityPlayerUtils().ufw?.appController()?.rootViewController {
            vc.setNeedsUpdateOfHomeIndicatorAutoHidden()
        }
    }

    private func startUnityIfNeeded() {
        GetUnityPlayerUtils().createPlayer(completed: { [self] (view: UIView?) in

        })
    }

    private func applyUnityRootViewController() {
        guard
            let appController = GetUnityPlayerUtils().ufw?.appController(),
            let window = appController.window,
            let unityVC = appController.rootViewController
        else {
            return
        }

        if let wrapper = window.rootViewController as? UnityRootViewController {
            wrapper.setNeedsUpdateOfHomeIndicatorAutoHidden()
            return
        }

        let wrapperVC = UnityRootViewController(unityViewController: unityVC)

        window.rootViewController = wrapperVC
        window.makeKeyAndVisible()

        wrapperVC.setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    func attachView() {
        startUnityIfNeeded()

        let unityView = GetUnityPlayerUtils().ufw?.appController()?.rootView
        if let superview = unityView?.superview {
            unityView?.removeFromSuperview()
            superview.layoutIfNeeded()
        }

        if let unityView = unityView {
            _rootView.addSubview(unityView)
            _rootView.layoutIfNeeded()
            self.channel?.invokeMethod("events#onViewReattached", arguments: "")
        }
        GetUnityPlayerUtils().resume()
        applyUnityRootViewController()
    }

    func reattachView() {
        let unityView = GetUnityPlayerUtils().ufw?.appController()?.rootView
        let superview = unityView?.superview
        if superview != _rootView {
            attachView()
        }

        GetUnityPlayerUtils().resume()
    }

    func removeViewIfNeeded() {
        if GetUnityPlayerUtils().ufw == nil {
            return
        }

        let unityView = GetUnityPlayerUtils().ufw?.appController()?.rootView
        if _rootView == unityView?.superview {
            if globalControllers.isEmpty {
                unityView?.removeFromSuperview()
                unityView?.superview?.layoutIfNeeded()
            } else {
                globalControllers.last?.reattachView()
            }
        }
        GetUnityPlayerUtils().resume()
    }

    func dispose() {
        if _disposed {
            return
        }

        globalControllers.removeAll{ value in
            return value == self
        }

        channel?.setMethodCallHandler(nil)
        removeViewIfNeeded()
        
        _disposed = true
    }
    
    /// Handles messages from unity in the current view
    func handleMessage(message: String) {
        self.channel?.invokeMethod("events#onUnityMessage", arguments: message)
    }
    
    
    /// Handles scene changed event from unity in the current view
    func handleSceneChangeEvent(info: Dictionary<String, Any>) {
        self.channel?.invokeMethod("events#onUnitySceneLoaded", arguments: info)
    }
    
    /// Post messages to unity from flutter
    func postMessage(call: FlutterMethodCall, result: FlutterResult) {
        guard let args = call.arguments else {
            result("iOS could not recognize flutter arguments in method: (postMessage)")
            return
        }

        if let myArgs = args as? [String: Any],
           let gObj = myArgs["gameObject"] as? String,
           let method = myArgs["methodName"] as? String,
           let message = myArgs["message"] as? String {
            GetUnityPlayerUtils().postMessageToUnity(gameObject: gObj, unityMethodName: method, unityMessage: message)
            result(nil)
        } else {
            result(FlutterError(code: "-1", message: "iOS could not extract " +
                   "flutter arguments in method: (postMessage)", details: nil))
        }
    }
}
