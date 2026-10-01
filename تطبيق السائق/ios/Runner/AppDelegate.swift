import Flutter
import UIKit
import firebase_messaging

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // **إلزامي مع UIScene + FlutterImplicitEngineDelegate (messaging 16.7+).**
    // المكوّنات تُسجَّل بعد didFinishLaunching، وآبل تطلب ضبط
    // UNUserNotificationCenter.delegate قبل العودة من هذه الدالة.
    FLTFirebaseMessagingPlugin.configureNotificationCenterDelegate()

    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    // طلب رمز APNs صراحةً — بدونه لا يُولَّد رمز FCM على الآيفون
    // (`apns-token-not-set`). انظر flutterfire#18555 و#18620.
    application.registerForRemoteNotifications()

    return ok
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
