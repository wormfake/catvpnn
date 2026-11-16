import Foundation
import NetworkExtension
import Security

final class SystemVPNBackend: VPNAPIBackend {
  private let manager = NEVPNManager.shared()
  private var loaded = false
  private var observer: NSObjectProtocol?
  private var timeout: DispatchWorkItem?
  private var countryID: Int? {
    get { let value = UserDefaults.standard.integer(forKey: "catvpn_api_country"); return value > 0 ? value : nil }
    set { UserDefaults.standard.set(newValue ?? 0, forKey: "catvpn_api_country") }
  }

  private func failure(_ code: String, _ error: Error?) -> APIResponse {
    .error(502, code, error?.localizedDescription ?? "VPN operation failed.")
  }

  func status(_ completion: @escaping (APIResponse) -> Void) {
    if loaded { completion(.ok(snapshot())); return }
    manager.loadFromPreferences { error in
      self.loaded = error == nil
      completion(error == nil ? .ok(self.snapshot()) : self.failure("VPN_LOAD", error))
    }
  }

  private func snapshot() -> [String: Any] {
    let state: String
    switch manager.connection.status {
    case .connected: state = "UP"
    case .connecting, .reasserting: state = "CONNECTING"
    case .disconnecting: state = "DISCONNECTING"
    default: state = "DOWN"
    }
    return ["state": state, "rxBytes": 0, "txBytes": 0, "revoked": false,
            "supportsTrafficStats": false, "serverHostname": manager.protocolConfiguration?.serverAddress ?? "",
            "countryId": countryID as Any? ?? NSNull()]
  }

  func connect(hostname: String, username: String, password: String, countryID: Int?, completion: @escaping (APIResponse) -> Void) {
    guard let reference = passwordReference(username: username, password: password) else {
      completion(.error(503, "KEYCHAIN_UNAVAILABLE", "Unlock the phone once after reboot and try again.")); return
    }
    let protocolConfig = NEVPNProtocolIKEv2()
    protocolConfig.serverAddress = hostname
    protocolConfig.remoteIdentifier = hostname
    protocolConfig.localIdentifier = username
    protocolConfig.authenticationMethod = .none
    protocolConfig.useExtendedAuthentication = true
    protocolConfig.username = username
    protocolConfig.passwordReference = reference
    protocolConfig.disconnectOnSleep = false
    protocolConfig.enablePFS = true
    for parameters in [protocolConfig.ikeSecurityAssociationParameters, protocolConfig.childSecurityAssociationParameters] {
      parameters.encryptionAlgorithm = .algorithmAES256GCM
      parameters.integrityAlgorithm = .SHA384
      parameters.diffieHellmanGroup = .group20
    }
    manager.loadFromPreferences { error in
      guard error == nil else { completion(self.failure("VPN_LOAD", error)); return }
      self.loaded = true
      self.start(protocolConfig, countryID: countryID, completion: completion)
    }
  }

  func disconnect(_ completion: @escaping (APIResponse) -> Void) {
    manager.loadFromPreferences { error in
      guard error == nil else { completion(self.failure("VPN_LOAD", error)); return }
      self.loaded = true
      self.stop { stopped in
        completion(stopped ? .ok(self.snapshot()) : .error(504, "VPN_STOP_TIMEOUT", "The VPN has not stopped yet."))
      }
    }
  }

  private func stop(_ completion: @escaping (Bool) -> Void) {
    if manager.connection.status == .disconnected || manager.connection.status == .invalid {
      completion(true); return
    }
    manager.connection.stopVPNTunnel()
    waitForStatus(.disconnected, seconds: 15, completion: completion)
  }

  private func start(_ config: NEVPNProtocolIKEv2, countryID: Int?, completion: @escaping (APIResponse) -> Void) {
    stop { stopped in
      guard stopped else {
        completion(.error(504, "VPN_STOP_TIMEOUT", "The previous VPN has not stopped yet.")); return
      }
      self.manager.protocolConfiguration = config
      self.manager.localizedDescription = "CatVPN Nord"
      self.manager.isEnabled = true
      self.manager.saveToPreferences { error in
        guard error == nil else { completion(self.failure("VPN_SAVE", error)); return }
        self.manager.loadFromPreferences { error in
          guard error == nil else { completion(self.failure("VPN_LOAD", error)); return }
          do {
            try self.manager.connection.startVPNTunnel()
            self.waitForStatus(.connected, seconds: 45) { connected in
              guard connected else {
                self.manager.connection.stopVPNTunnel()
                completion(.error(502, "VPN_CONNECT_FAILED", "IKEv2 did not connect. Check network and NordVPN service credentials.")); return
              }
              self.countryID = countryID
              completion(.ok(self.snapshot()))
            }
          } catch { completion(self.failure("VPN_START", error)) }
        }
      }
    }
  }

  private func waitForStatus(_ target: NEVPNStatus, seconds: Double, completion: @escaping (Bool) -> Void) {
    var finished = false
    var sawConnecting = manager.connection.status == .connecting || manager.connection.status == .reasserting
    let finish: (Bool) -> Void = { success in
      guard !finished else { return }; finished = true
      if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
      self.observer = nil; self.timeout?.cancel(); self.timeout = nil
      completion(success)
    }
    let evaluate: () -> Void = {
      let state = self.manager.connection.status
      if state == target || (target == .disconnected && state == .invalid) { finish(true); return }
      if target == .connected {
        if state == .connecting || state == .reasserting { sawConnecting = true }
        if state == .invalid || (sawConnecting && state == .disconnected) { finish(false) }
      }
    }
    observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main) { _ in evaluate() }
    let work = DispatchWorkItem { finish(false) }; timeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    evaluate()
  }

  func changeIP(countryID requestedCountry: Int?, completion: @escaping (APIResponse) -> Void) {
    manager.loadFromPreferences { error in
      guard error == nil else { completion(self.failure("VPN_LOAD", error)); return }
      self.loaded = true
      guard let original = self.manager.protocolConfiguration as? NEVPNProtocolIKEv2,
            original.passwordReference != nil, let username = original.username, !username.isEmpty,
            let config = original.copy() as? NEVPNProtocolIKEv2 else {
        completion(.error(412, "VPN_NOT_CONFIGURED", "Open CatVPN and connect once before calling /changeip.")); return
      }
      let previousHost = original.serverAddress ?? ""
      let country = requestedCountry ?? self.countryID
      self.recommendedServer(countryID: country, excluding: previousHost) { result in
        switch result {
        case .failure(let error): completion(.error(502, "SERVER_LOOKUP_FAILED", error.localizedDescription))
        case .success(let server):
          // Never disconnect a working tunnel until an alternative is available.
          self.exitIP { oldIP in
            config.serverAddress = server.hostname
            config.remoteIdentifier = server.hostname
            self.start(config, countryID: server.countryID ?? country) { response in
              guard response.status == 200 else { completion(response); return }
              self.exitIP { newIP in
                var body = response.body
                body["previous_hostname"] = previousHost
                body["old_ip"] = oldIP as Any? ?? NSNull()
                body["new_ip"] = newIP as Any? ?? NSNull()
                if let oldIP = oldIP, let newIP = newIP { body["ip_changed"] = oldIP != newIP }
                else { body["ip_changed"] = NSNull() }
                completion(.ok(body))
              }
            }
          }
        }
      }
    }
  }

  private struct Server { let hostname: String; let countryID: Int?; let load: Int }

  private func recommendedServer(countryID: Int?, excluding hostname: String,
                                 completion: @escaping (Result<Server, Error>) -> Void) {
    var url = URLComponents(string: "https://api.nordvpn.com/v1/servers/recommendations")!
    url.queryItems = [URLQueryItem(name: "filters[servers_technologies][identifier]", value: "ikev2"), URLQueryItem(name: "limit", value: "20")]
    if let countryID = countryID { url.queryItems!.append(URLQueryItem(name: "filters[country_id]", value: String(countryID))) }
    fetch(url.url!, seconds: 10) { data in
      guard let data = data, let records = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
        completion(.failure(NSError(domain: "CatVPN", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot load NordVPN recommendations."]))); return
      }
      var seen = Set<String>()
      let candidates: [Server] = records.compactMap { record in
        guard let name = record["hostname"] as? String, name != hostname,
              name.range(of: "^[a-z0-9-]+\\.nordvpn\\.com$", options: .regularExpression) != nil,
              seen.insert(name).inserted,
              let technologies = record["technologies"] as? [[String: Any]],
              technologies.contains(where: { $0["identifier"] as? String == "ikev2" }) else { return nil }
        let location = (record["locations"] as? [[String: Any]])?.first
        let country = location?["country"] as? [String: Any]
        let id = country?["id"] as? Int
        if let countryID = countryID, id != countryID { return nil }
        return Server(hostname: name, countryID: id, load: record["load"] as? Int ?? 100)
      }.sorted { $0.load < $1.load }
      guard let server = candidates.prefix(5).randomElement() else {
        completion(.failure(NSError(domain: "CatVPN", code: 2, userInfo: [NSLocalizedDescriptionKey: "No different IKEv2 server is available for this country."]))); return
      }
      completion(.success(server))
    }
  }

  private func exitIP(_ completion: @escaping (String?) -> Void) {
    fetch(URL(string: "https://api.ipify.org?format=json")!, seconds: 6) { data in
      let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
      let ip = object?["ip"] as? String
      completion(ip?.isEmpty == false ? ip : nil)
    }
  }

  private func fetch(_ url: URL, seconds: Double, completion: @escaping (Data?) -> Void) {
    // A new session avoids reusing a socket opened before the VPN changed.
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = seconds; config.timeoutIntervalForResource = seconds
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: config)
    session.dataTask(with: url) { data, response, error in
      session.finishTasksAndInvalidate()
      let valid = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
      DispatchQueue.main.async { completion(valid ? data : nil) }
    }.resume()
  }

  private func passwordReference(username: String, password: String) -> Data? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.catvpn.nord.catvp.ikev2", kSecAttrAccount as String: username,
      kSecAttrAccessGroup as String: "TEAMID.com.catvpn.nord.catvp"]
    let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { return nil }
    } else if status != errSecSuccess { return nil }
    var lookup = query
    lookup[kSecReturnPersistentRef as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var reference: CFTypeRef?
    guard SecItemCopyMatching(lookup as CFDictionary, &reference) == errSecSuccess else { return nil }
    return reference as? Data
  }
}
