import Foundation

// Runs the production TCP server and router with a deterministic VPN boundary.
// This executable is compiled only for host tests and is never packaged for iOS.
final class FakeVPN: VPNAPIBackend {
  var configured = false
  func status(_ completion: @escaping (APIResponse) -> Void) {
    completion(.ok(["state": configured ? "UP" : "DOWN"]))
  }
  func connect(hostname: String, username: String, password: String, countryID: Int?, completion: @escaping (APIResponse) -> Void) {
    configured = true; completion(.ok(["state": "UP", "serverHostname": hostname]))
  }
  func disconnect(_ completion: @escaping (APIResponse) -> Void) {
    completion(.ok(["state": "DOWN"]))
  }
  func changeIP(countryID: Int?, completion: @escaping (APIResponse) -> Void) {
    guard configured else {
      completion(.error(412, "VPN_NOT_CONFIGURED", "Connect once first.")); return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      completion(.ok(["state": "UP", "old_ip": "192.0.2.1", "new_ip": "192.0.2.2",
                      "ip_changed": true, "countryId": countryID as Any? ?? NSNull()]))
    }
  }
}
let router = APIRouter(backend: FakeVPN())
let server = try LocalHTTPServer(port: 18787) { request, completion in router.handle(request, completion: completion) }
server.start()
withExtendedLifetime(server) { RunLoop.main.run() }
