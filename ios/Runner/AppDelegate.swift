import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let channelName = "com.catvpn.nord/vpn"
  private let prefsPrefix = "catvpn_pref_"
  private let apiSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 120
    config.timeoutIntervalForResource = 125
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: config)
  }()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CatVpnIosBridge") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "prepareVpn":
        self.apiRequest(path: "/health", method: "GET", body: nil) { value in
          if let error = value as? FlutterError { result(error) } else { result(true) }
        }

      case "connect":
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing arguments", details: nil))
          return
        }
        let hostname = args["hostname"] as? String ?? ""
        let username = args["username"] as? String ?? ""
        let password = args["password"] as? String ?? ""
        guard !hostname.isEmpty && !username.isEmpty && !password.isEmpty else {
          result("NEED_WG_EXPORT"); return
        }
        var body: [String: Any] = ["hostname": hostname, "username": username, "password": password]
        if let country = args["countryId"] as? Int, country > 0 { body["country_id"] = country }
        self.apiRequest(path: "/connect", method: "POST", body: body) { value in
          if let error = value as? FlutterError { result(error) }
          else { result((value as? [String: Any])?["state"] ?? "DOWN") }
        }

      case "disconnect":
        self.apiRequest(path: "/disconnect", method: "POST", body: [:]) { value in
          if let error = value as? FlutterError { result(error) }
          else { result((value as? [String: Any])?["state"] ?? "DOWN") }
        }

      case "getStatus":
        self.apiRequest(path: "/status", method: "GET", body: nil, result: result)

      case "shareWireGuardFile":
        guard let args = call.arguments as? [String: Any],
              let config = args["config"] as? String else {
          result(false)
          return
        }
        let rawName = (args["fileName"] as? String) ?? "catvpn-nord"
        let safeName = rawName.replacingOccurrences(of: ".nordvpn.com", with: "")
          .replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "-", options: .regularExpression)
        self.presentWireGuardShareSheet(fileName: "\(safeName).conf", content: config, result: result)

      case "savePref":
        if let args = call.arguments as? [String: Any],
           let key = args["key"] as? String,
           let value = args["value"] as? String {
          UserDefaults.standard.set(value, forKey: self.prefsPrefix + key)
        }
        result(true)

      case "loadPrefs":
        var out: [String: String] = [:]
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() {
          if k.hasPrefix(self.prefsPrefix), let strVal = v as? String {
            let cleanKey = String(k.dropFirst(self.prefsPrefix.count))
            out[cleanKey] = strVal
          }
        }
        result(out)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func apiRequest(path: String, method: String, body: [String: Any]?, result: @escaping FlutterResult) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:8787" + path)!)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body = body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    }
    apiSession.dataTask(with: request) { data, response, error in
      DispatchQueue.main.async {
        guard error == nil, let data = data, let response = response as? HTTPURLResponse,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
          result(FlutterError(code: "VPN_API_UNAVAILABLE",
            message: "Dịch vụ CatVPN API chưa chạy. Kiểm tra jailbreak hoặc cài lại gói CatVPN trong Sileo.", details: nil))
          return
        }
        guard response.statusCode == 200 else {
          result(FlutterError(code: json["error"] as? String ?? "VPN_API_ERROR",
            message: json["message"] as? String ?? "Không thực hiện được thao tác VPN.", details: nil))
          return
        }
        result(json)
      }
    }.resume()
  }

  private func presentWireGuardShareSheet(
    fileName: String,
    content: String,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.main.async {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let fileUrl = directory.appendingPathComponent(fileName)
      do {
        guard let presenter = self.topViewController() else {
          result(false)
          return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: fileUrl, options: [.atomic, .completeFileProtection])
        let activityVc = UIActivityViewController(
          activityItems: [fileUrl],
          applicationActivities: nil
        )
        activityVc.completionWithItemsHandler = { _, _, _, _ in
          try? FileManager.default.removeItem(at: directory)
        }
        if let popover = activityVc.popoverPresentationController {
          popover.sourceView = presenter.view
          popover.sourceRect = CGRect(
            x: presenter.view.bounds.midX,
            y: presenter.view.bounds.midY,
            width: 1,
            height: 1
          )
          popover.permittedArrowDirections = []
        }
        presenter.present(activityVc, animated: true) {
          result(true)
        }
      } catch {
        try? FileManager.default.removeItem(at: directory)
        result(false)
      }
    }
  }

  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }
    for scene in scenes {
      let win = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
      if let root = win?.rootViewController {
        var top = root
        while let presented = top.presentedViewController {
          top = presented
        }
        return top
      }
    }
    return nil
  }
}
