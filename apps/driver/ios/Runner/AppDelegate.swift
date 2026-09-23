import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    // **إلزامي مع UIScene + FlutterImplicitEngineDelegate.**
    //
    // `didFinishLaunching` / `scene:willConnect` قد تمرّ قبل أن يُسجَّل
    // مكوّن `firebase_messaging`، فيُتخطّى طلب رمز APNs صامتاً — ولا
    // يُولَّد رمز FCM أبداً (`apns-token-not-set`). أندرويد لا يتأثّر؛
    // آيفون وحده يصير أصمّ. انظر flutterfire#18555 و#18620.
    //
    // لا نضبط `UNUserNotificationCenter.delegate` هنا عمداً: نتركه
    // لـ`flutter_local_notifications` وفايربيز حتى لا يبتلع أحدهما
    // إشعارات الآخر في المقدّمة (flutterfire#18699).
    application.registerForRemoteNotifications()

    return ok
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
