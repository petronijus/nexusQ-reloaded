import Flutter
import UIKit

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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NexusQBonjour") {
      bonjour = BonjourDiscovery.register(messenger: registrar.messenger())
    }
  }
}
