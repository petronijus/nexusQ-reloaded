import Flutter
import Network

/// Native Bonjour browse-and-resolve for the device bridge (`_nexusq._tcp`),
/// exposed to Dart as the `nexusq/bonjour` MethodChannel.
///
/// Everywhere else the app discovers the Q with `package:multicast_dns`, but
/// iOS 14+ refuses raw port-5353 multicast sockets unless the app carries the
/// restricted `com.apple.developer.networking.multicast` entitlement (granted
/// by Apple on request only). The sanctioned path is the Bonjour API, which
/// needs nothing beyond the `NSBonjourServices` declaration already in
/// Info.plist — so on iOS, discovery goes through here instead.
///
/// Contract (mirrors `discoverNexusQ` in lib/protocol/discovery.dart):
///   discover {timeoutMs: int} -> {name, host, port} | nil on timeout/failure.
///
/// Resolution strategy: NWBrowser only yields opaque service endpoints; the
/// concrete IPv4 + port comes from opening a throwaway TCP connection to the
/// endpoint (Network.framework resolves Bonjour endpoints on connect) and
/// reading the connection's remote address once it is `.ready`. That doubles as
/// a reachability check — a Q that advertises but does not accept is not
/// reported, and the Dart side gets a host it can definitely connect to.
final class BonjourDiscovery: NSObject {
  static let channelName = "nexusq/bonjour"
  private static let serviceType = "_nexusq._tcp"

  /// All state is confined to this queue; NWBrowser/NWConnection callbacks are
  /// delivered on it, so completion-exactly-once needs no locking.
  private let queue = DispatchQueue(label: "nexusq.bonjour")
  private var browser: NWBrowser?
  private var probe: NWConnection?
  private var pending: FlutterResult?
  private var timeoutTask: DispatchWorkItem?

  static func register(messenger: FlutterBinaryMessenger) -> BonjourDiscovery {
    let instance = BonjourDiscovery()
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "discover":
        let args = call.arguments as? [String: Any]
        let timeoutMs = args?["timeoutMs"] as? Int ?? 4000
        instance.discover(timeoutMs: timeoutMs, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return instance
  }

  private func discover(timeoutMs: Int, result: @escaping FlutterResult) {
    queue.async {
      // A newer call supersedes any in-flight one (the old caller gets nil,
      // matching the Dart contract where a superseded browse just found nothing).
      self.finish(nil)
      self.pending = result

      let timeout = DispatchWorkItem { [weak self] in self?.finish(nil) }
      self.timeoutTask = timeout
      self.queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timeout)

      let params = NWParameters()
      params.includePeerToPeer = false
      let browser = NWBrowser(
        for: .bonjour(type: Self.serviceType, domain: nil), using: params)
      self.browser = browser

      browser.stateUpdateHandler = { [weak self] state in
        // .failed covers "local network permission denied" and radio loss —
        // report "not found" and let the Dart caller fall back to manual entry.
        if case .failed = state { self?.finish(nil) }
      }
      browser.browseResultsChangedHandler = { [weak self] results, _ in
        guard let self, self.probe == nil,
              let first = results.first(where: {
                if case .service = $0.endpoint { return true } else { return false }
              })
        else { return }
        self.resolve(first.endpoint)
      }
      browser.start(queue: self.queue)
    }
  }

  /// Resolve a service endpoint to (host, port) by connecting to it.
  private func resolve(_ endpoint: NWEndpoint) {
    guard case let .service(name, _, _, _) = endpoint else { return }

    // Stop browsing — one instance is all the connect gate wants.
    browser?.cancel()
    browser = nil

    let probe = NWConnection(to: endpoint, using: .tcp)
    self.probe = probe
    probe.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        if case let .hostPort(host, port) = probe.currentPath?.remoteEndpoint,
           let address = Self.address(of: host) {
          self.finish(["name": name, "host": address, "port": Int(port.rawValue)])
        } else {
          self.finish(nil)
        }
      case .failed, .cancelled:
        // Advertised but unreachable — nothing usable; the timeout (or a
        // retry from Dart) owns the final nil so a flapping service can't
        // race a success.
        self.probe = nil
      default:
        break
      }
    }
    probe.start(queue: queue)
  }

  /// The dotted-quad for an NWEndpoint.Host, scope-id stripped ("fe80::1%en0"
  /// and link-local v4 both carry one). IPv4 preferred — the Dart TcpClient
  /// dials plain `host:port` and the bridge listens on v4.
  private static func address(of host: NWEndpoint.Host) -> String? {
    switch host {
    case .ipv4(let v4): return "\(v4)".components(separatedBy: "%").first
    case .ipv6(let v6):
      if let v4 = v6.asIPv4 { return "\(v4)".components(separatedBy: "%").first }
      return "\(v6)".components(separatedBy: "%").first
    case .name(let n, _): return n
    @unknown default: return nil
    }
  }

  /// Completes the pending Dart call exactly once and tears everything down.
  private func finish(_ payload: [String: Any]?) {
    timeoutTask?.cancel()
    timeoutTask = nil
    browser?.cancel()
    browser = nil
    probe?.cancel()
    probe = nil
    if let result = pending {
      pending = nil
      result(payload)
    }
  }
}
