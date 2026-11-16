#!/usr/bin/env python3
"""Exercise the real Swift HTTP server on a macOS runner, with a fake VPN."""
import concurrent.futures
import http.client
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest


class LocalAPITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="catvpn-api-test-")
        executable = str(Path(cls.directory.name) / "api-test")
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-framework", "Network",
                        "ios/Daemon/LocalHTTPServer.swift", "ios/DaemonTests/main.swift", "-o", executable], check=True)
        cls.process = subprocess.Popen([executable])
        for _ in range(100):
            try:
                if cls.request("GET", "/health")[0] == 200:
                    return
            except OSError:
                pass
            if cls.process.poll() is not None:
                raise RuntimeError("Swift API test server exited")
            time.sleep(0.05)
        cls.process.terminate()
        raise RuntimeError("Swift API test server did not listen")

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait(timeout=5)
        cls.directory.cleanup()

    @staticmethod
    def request(method, path, data=None, headers=None):
        client = http.client.HTTPConnection("127.0.0.1", 18787, timeout=5)
        try:
            body = json.dumps(data) if data is not None else None
            client.request(method, path, body=body, headers=headers or {})
            response = client.getresponse()
            return response.status, json.loads(response.read()), response.getheader("Cache-Control")
        finally:
            client.close()

    def configure(self):
        self.assertEqual(self.request("POST", "/connect", {
            "hostname": "vn53.nordvpn.com", "username": "test-user", "password": "test-password",
        })[0], 200)

    def test_01_profile_required_then_change_ip_without_a_key(self):
        status, body, _ = self.request("GET", "/changeip")
        self.assertEqual(status, 412)
        self.assertEqual(body["error"], "VPN_NOT_CONFIGURED")
        self.configure()
        status, body, cache = self.request("GET", "/changeip?country_id=234")
        self.assertEqual(status, 200)
        self.assertTrue(body["ip_changed"])
        self.assertEqual(body["new_ip"], "192.0.2.2")
        self.assertEqual(body["countryId"], 234)
        self.assertEqual(cache, "no-store")

    def test_parallel_mutations_are_rejected_but_status_is_available(self):
        self.configure()
        with concurrent.futures.ThreadPoolExecutor() as pool:
            first = pool.submit(self.request, "POST", "/v1/change-ip", {})
            for _ in range(30):
                status = self.request("GET", "/status")[1]
                if status["busy"]:
                    break
                time.sleep(0.01)
            self.assertTrue(status["busy"])
            self.assertEqual(status["state"], "CONNECTING")
            self.assertEqual(self.request("GET", "/changeip")[0], 409)
            self.assertEqual(self.request("POST", "/disconnect", {})[0], 409)
            self.assertEqual(first.result()[0], 200)
        self.assertFalse(self.request("GET", "/status")[1]["busy"])

    def test_validation_does_not_start_operations(self):
        for method, path, body, expected in [
            ("GET", "/connect", None, 405), ("GET", "/unknown", None, 404),
            ("GET", "/changeip?country_id=bad", None, 400),
            ("POST", "/changeip", {"country_id": True}, 400),
            ("POST", "/connect", {"hostname": "outside.example", "username": "x", "password": "x"}, 400),
        ]:
            with self.subTest(path=path, body=body):
                self.assertEqual(self.request(method, path, body)[0], expected)
        self.assertFalse(self.request("GET", "/status")[1]["busy"])

    def test_listener_is_not_exposed_on_the_lan(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("8.8.8.8", 80))
            address = probe.getsockname()[0]
        if address.startswith("127."):
            self.skipTest("No non-loopback interface")
        with socket.socket() as connection:
            connection.settimeout(1)
            self.assertNotEqual(connection.connect_ex((address, 18787)), 0)

    def test_remote_browser_and_host_are_rejected(self):
        for headers in [{"Host": "outside.example"}, {"Origin": "https://outside.example"},
                        {"Sec-Fetch-Site": "cross-site"}]:
            self.assertEqual(self.request("GET", "/changeip", headers=headers)[0], 403)

    def test_invalid_framing_is_rejected(self):
        for headers, status in [("Content-Length: 20000\r\n", 400),
                                ("Transfer-Encoding: chunked\r\n", 400),
                                ("Content-Length: 0\r\nContent-Length: 1\r\n", 400),
                                ("X-Large: " + "x" * 9000 + "\r\n", 413)]:
            with self.subTest(status=status), socket.create_connection(("127.0.0.1", 18787), timeout=5) as client:
                client.sendall(("POST /changeip HTTP/1.1\r\nHost: 127.0.0.1:18787\r\n" + headers + "\r\n").encode())
                reply = client.recv(4096)
                self.assertTrue(reply.startswith(f"HTTP/1.1 {status}".encode()), reply)


if __name__ == "__main__":
    if sys.platform != "darwin":
        raise SystemExit("Run these native socket tests on the macOS build runner")
    unittest.main(verbosity=2)
