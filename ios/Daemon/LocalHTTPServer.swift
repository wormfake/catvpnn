import Foundation
import Network

struct APIResponse {
  let status: Int
  let body: [String: Any]
  static func ok(_ body: [String: Any]) -> APIResponse { APIResponse(status: 200, body: body) }
  static func error(_ status: Int, _ code: String, _ message: String) -> APIResponse {
    APIResponse(status: status, body: ["error": code, "message": message])
  }
}

struct APIRequest {
  let method: String
  let target: String
  let headers: [String: String]
  let body: Data
}

// One request per connection, bounded headers/body and no request pipelining.
// Bind the socket itself to loopback; a Host-header check alone is not sufficient.
final class LocalHTTPServer {
  private let listener: NWListener
  private var connections: [UUID: HTTPConnection] = [:]
  private let handler: (APIRequest, @escaping (APIResponse) -> Void) -> Void

  init(port: UInt16 = 8787, handler: @escaping (APIRequest, @escaping (APIResponse) -> Void) -> Void) throws {
    self.handler = handler
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    listener = try NWListener(using: parameters)
  }

  func start() {
    listener.stateUpdateHandler = { state in
      if case .failed = state { exit(1) } // launchd retries with its throttle interval.
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self = self, self.connections.count < 32 else { connection.cancel(); return }
      let id = UUID()
      let client = HTTPConnection(connection: connection, handler: self.handler) { [weak self] in
        self?.connections.removeValue(forKey: id)
      }
      self.connections[id] = client
      client.start()
    }
    listener.start(queue: .main)
  }
}

private final class HTTPConnection {
  private let connection: NWConnection
  private let handler: (APIRequest, @escaping (APIResponse) -> Void) -> Void
  private let onClose: () -> Void
  private var buffer = Data()
  private var handled = false
  private var closed = false
  private var deadline: DispatchWorkItem?

  init(connection: NWConnection, handler: @escaping (APIRequest, @escaping (APIResponse) -> Void) -> Void,
       onClose: @escaping () -> Void) {
    self.connection = connection; self.handler = handler; self.onClose = onClose
  }

  func start() {
    connection.start(queue: .main)
    armDeadline(seconds: 10)
    receive()
  }

  private func armDeadline(seconds: Double) {
    deadline?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.close() }
    deadline = work
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
  }

  private func close() {
    guard !closed else { return }
    closed = true; deadline?.cancel(); connection.cancel(); onClose()
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
      guard let self = self, !self.closed, !self.handled else { return }
      if let data = data { self.buffer.append(data) }
      if self.buffer.count > 32768 {
        self.send(.error(413, "TOO_LARGE", "Request exceeds 32 KiB.")); return
      }
      if let separator = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
        guard separator.lowerBound <= 8192 else {
          self.send(.error(413, "TOO_LARGE", "HTTP headers exceed 8 KiB.")); return
        }
        guard let head = String(data: self.buffer[..<separator.lowerBound], encoding: .utf8) else {
          self.send(.error(400, "BAD_REQUEST", "Invalid HTTP headers.")); return
        }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(first[2])), first[1].hasPrefix("/") else {
          self.send(.error(400, "BAD_REQUEST", "Invalid request line.")); return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
          guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
            self.send(.error(400, "BAD_REQUEST", "Invalid header.")); return
          }
          let name = String(line[..<colon]).lowercased()
          guard headers[name] == nil else {
            self.send(.error(400, "BAD_REQUEST", "Duplicate header.")); return
          }
          headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= 16384 else {
          self.send(.error(400, "BAD_REQUEST", "Use Content-Length; body limit is 16 KiB.")); return
        }
        let end = separator.upperBound + length
        if self.buffer.count >= end {
          self.handled = true; self.armDeadline(seconds: 150)
          let request = APIRequest(method: String(first[0]), target: String(first[1]), headers: headers,
                                   body: Data(self.buffer[separator.upperBound..<end]))
          self.handler(request) { [weak self] response in self?.send(response) }
          return
        }
      } else if self.buffer.count > 8192 {
        self.send(.error(413, "TOO_LARGE", "HTTP headers exceed 8 KiB.")); return
      }
      if complete || error != nil { self.close() } else { self.receive() }
    }
  }

  private func send(_ response: APIResponse) {
    guard !closed else { return }
    handled = true
    let data = (try? JSONSerialization.data(withJSONObject: response.body, options: [.sortedKeys])) ?? Data("{}".utf8)
    let reason = response.status == 200 ? "OK" : "Error"
    var packet = Data("HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
    packet.append(data)
    connection.send(content: packet, completion: .contentProcessed { [weak self] _ in self?.close() })
  }
}

protocol VPNAPIBackend: AnyObject {
  func status(_ completion: @escaping (APIResponse) -> Void)
  func connect(hostname: String, username: String, password: String, countryID: Int?, completion: @escaping (APIResponse) -> Void)
  func disconnect(_ completion: @escaping (APIResponse) -> Void)
  func changeIP(countryID: Int?, completion: @escaping (APIResponse) -> Void)
}

final class APIRouter {
  private let backend: VPNAPIBackend
  private var busy = false
  init(backend: VPNAPIBackend) { self.backend = backend }

  func handle(_ request: APIRequest, completion: @escaping (APIResponse) -> Void) {
    // No access key, as requested. Reject non-local browser origins/Host values.
    let host = request.headers["host"]?.lowercased().split(separator: ":").first.map(String.init)
    guard host == "127.0.0.1" || host == "localhost" else {
      completion(.error(403, "LOCAL_ONLY", "Use http://127.0.0.1:8787.")); return
    }
    if let origin = request.headers["origin"],
       !["127.0.0.1", "localhost"].contains(URL(string: origin)?.host ?? "") {
      completion(.error(403, "LOCAL_ONLY", "Remote browser origins are not allowed.")); return
    }
    if request.headers["sec-fetch-site"] == "cross-site" {
      completion(.error(403, "LOCAL_ONLY", "Cross-site browser requests are not allowed.")); return
    }
    guard let url = URLComponents(string: request.target) else {
      completion(.error(400, "BAD_REQUEST", "Invalid URL.")); return
    }
    if url.path == "/health" && request.method == "GET" {
      completion(.ok(["service": "CatVPN API", "version": 1, "loopback_only": true])); return
    }
    if ["/status", "/v1/status"].contains(url.path) && request.method == "GET" {
      backend.status { response in
        var body = response.body
        body["busy"] = self.busy
        if self.busy && response.status == 200 { body["state"] = "CONNECTING" }
        completion(APIResponse(status: response.status, body: body))
      }
      return
    }
    let rotate = ["/changeip", "/change-ip", "/v1/change-ip"].contains(url.path)
    guard rotate || url.path == "/connect" || url.path == "/disconnect" else {
      completion(.error(404, "NOT_FOUND", "Use /health, /status or /changeip.")); return
    }
    guard request.method == "POST" || (rotate && request.method == "GET") else {
      completion(.error(405, "METHOD_NOT_ALLOWED", "Use POST, or GET /changeip.")); return
    }
    guard !busy else {
      completion(.error(409, "VPN_BUSY", "Another VPN operation is in progress.")); return
    }
    struct Input: Decodable {
      var hostname: String?; var username: String?; var password: String?; var country_id: Int?
    }
    guard let input = try? JSONDecoder().decode(Input.self, from: request.body.isEmpty ? Data("{}".utf8) : request.body) else {
      completion(.error(400, "BAD_REQUEST", "Expected a JSON object with an integer country_id.")); return
    }
    var countryID = input.country_id
    if let query = url.queryItems {
      guard query.count == 1, query[0].name == "country_id", let raw = query[0].value, let value = Int(raw), countryID == nil else {
        completion(.error(400, "BAD_COUNTRY", "Use a single numeric country_id.")); return
      }
      countryID = value
    }
    if let countryID = countryID, countryID <= 0 {
      completion(.error(400, "BAD_COUNTRY", "country_id must be positive.")); return
    }
    if url.path == "/connect" {
      guard let hostname = input.hostname, hostname.range(of: "^[a-z0-9-]+\\.nordvpn\\.com$", options: .regularExpression) != nil,
            let username = input.username, !username.isEmpty, username.count <= 512,
            let password = input.password, !password.isEmpty, password.count <= 512 else {
        completion(.error(400, "INVALID_CREDENTIALS", "A NordVPN hostname and service credentials are required.")); return
      }
      busy = true
      backend.connect(hostname: hostname, username: username, password: password, countryID: countryID) {
        self.busy = false; completion($0)
      }
    } else {
      busy = true
      let finish: (APIResponse) -> Void = { self.busy = false; completion($0) }
      if rotate { backend.changeIP(countryID: countryID, completion: finish) }
      else { backend.disconnect(finish) }
    }
  }
}
