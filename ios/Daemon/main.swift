import Foundation

// This executable has the same application identity as Runner and runs as
// mobile, so NEVPNManager and Keychain refer to CatVPN's saved VPN profile.
let backend = SystemVPNBackend()
let router = APIRouter(backend: backend)
do {
  let server = try LocalHTTPServer { request, completion in
    router.handle(request, completion: completion)
  }
  server.start()
  withExtendedLifetime(server) { RunLoop.main.run() }
} catch {
  // No request arguments or credentials are written to logs.
  exit(1)
}
