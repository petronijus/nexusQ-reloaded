import Flutter
import UIKit
import UserNotifications
import flutter_local_notifications
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Bonjour discovery bridge (`nexusq/bonjour`) — held for the app's lifetime,
  /// like the engine itself. See BonjourDiscovery.swift for why iOS cannot use
  /// the shared multicast_dns path.
  private var bonjour: BonjourDiscovery?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Release alerts (lib/update/release_background.dart). The background task
    // runs in its own headless engine, which needs the plugins registered too.
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    // The identifier is also in Info.plist (BGTaskSchedulerPermittedIdentifiers)
    // and Dart (releaseCheckTask). iOS decides when it actually runs; 6 h is
    // the earliest it may.
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "org.nexusq.release-check",
      earliestBeginInSeconds: NSNumber(value: 6 * 60 * 60))
    // With the UIScene life cycle the handlers must be registered before this
    // method returns (the plugin's own callback comes too late).
    WorkmanagerPlugin.registerLaunchHandlers()
    // Show our notifications while the app is in the foreground as well.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NexusQBonjour") {
      bonjour = BonjourDiscovery.register(messenger: registrar.messenger())
    }
  }
}
