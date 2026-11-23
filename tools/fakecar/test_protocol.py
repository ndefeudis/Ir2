#!/usr/bin/env python3
"""Protocol tests, run against a server process.

    python3 tools/fakecar/test_protocol.py                 # the Python fake head unit
    IR2_SERVER_CMD="java -cp … dev.ir2.companion.DevMain" python3 tools/fakecar/test_protocol.py

The server must take --port 0 --pair-code CODE --parked yes|no|unknown, print
"LISTENING <port>", and read "park …" / "block …" / "pair" commands on stdin.
Both bridge/ (the real mod, on a desktop JVM with a fake car) and the fake pass the same tests.
"""

import os
import shlex
import subprocess
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ir2proto as p  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
CODE = "0123-4567-89AB-CDEF"
DEFAULT_CMD = [sys.executable, os.path.join(HERE, "fake_headunit.py")]


class Server:
    def __init__(self, *extra):
        cmd = shlex.split(os.environ["IR2_SERVER_CMD"]) if os.environ.get("IR2_SERVER_CMD") else DEFAULT_CMD
        self.proc = subprocess.Popen(cmd + ["--host", "127.0.0.1", "--port", "0", "--pair-code", CODE] + list(extra),
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        self.port = None
        deadline = time.time() + 20
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                break
            if line.startswith("LISTENING "):
                self.port = int(line.split()[1])
            elif line.startswith("PAIRING ") and self.port is not None:
                break  # the --pair-code line comes after LISTENING
        if self.port is None:
            self.stop()
            raise RuntimeError("server didn't start: %s" % cmd)

    def send(self, command, expect):
        self.proc.stdin.write(command + "\n")
        self.proc.stdin.flush()
        while True:
            line = self.proc.stdout.readline()
            if not line or line.startswith(expect):
                return line.strip()

    def client(self, **kw):
        return p.Client("127.0.0.1", self.port, **kw)

    def stop(self):
        self.proc.kill()
        self.proc.wait()


def gap():
    time.sleep(0.25)  # ambient changes: at most 5 a second


class ProtocolTest(unittest.TestCase):
    def setUp(self):
        self.s = Server()
        self.c = self.s.client()

    def tearDown(self):
        self.s.stop()

    def paired(self):
        self.c.pair(CODE, "Test phone")
        return self.c

    def err(self, code, fn, *a, **kw):
        with self.assertRaises(p.ProtocolError) as cm:
            fn(*a, **kw)
        self.assertEqual(cm.exception.code, code, str(cm.exception))
        return cm.exception

    # --- crypto shared with the iPhone app ---------------------------------
    def test_hkdf_rfc5869_case1(self):
        okm = p.hkdf_sha256(bytes([0x0b] * 22), bytes(range(13)), bytes(range(0xf0, 0xfa)), 42)
        self.assertEqual(okm.hex(), "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
                                    "34007208d5b887185865")

    def test_code_normalising(self):
        self.assertEqual(p.normalize_code("o123-4567-89ab-cdef"), "0123456789ABCDEF")
        self.assertEqual(p.normalize_code("IL23 4567 89AB CDEF"), "1123456789ABCDEF")
        self.assertEqual(p.device_key("0123-4567-89ab-cdef", "00" * 16), p.device_key("0123456789ABCDEF", "00" * 16))

    # --- pairing -------------------------------------------------------------
    def test_info_before_pairing(self):
        info = self.c.info()
        self.assertEqual(info["protocol"], 1)
        self.assertEqual(info["service"], "ir2-companion")
        self.assertEqual(info["name"], "Ioniq 5")
        self.assertTrue(info["pairing_open"])

    def test_pair_and_use(self):
        r = self.paired()
        self.assertEqual(r.status()["guard"], {"only_in_park": True})
        self.assertFalse(self.c.info()["pairing_open"])

    def test_wrong_code(self):
        self.err("unauthorized", self.c.pair, "AAAA-AAAA-AAAA-AAAA")
        self.c.pair(CODE)  # the right one still works after one miss

    def test_code_pairs_once(self):
        self.paired()
        other = self.s.client()
        self.err("no_pairing", other.pair, CODE)

    def test_lockout_after_five(self):
        for _ in range(4):
            self.err("unauthorized", self.c.pair, "AAAA-AAAA-AAAA-AAAA")
        self.err("pairing_locked", self.c.pair, "AAAA-AAAA-AAAA-AAAA")
        self.err("pairing_locked", self.c.pair, CODE)

    def test_four_phones_at_most(self):
        for i in range(4):
            code = self.s.send("pair", "PAIRING").split()[1] if i else CODE
            self.s.client().pair(code, "Phone %d" % i)
        code = self.s.send("pair", "PAIRING").split()[1]
        self.err("too_many_devices", self.s.client().pair, code)

    def test_device_id_must_match(self):
        key = p.device_key(CODE, self.c.device_id)
        self.err("bad_request", self.c.call, "POST", "/v1/pair",
                 {"device_id": "ff" * 16, "device_name": "x"}, key=key, counter=1)

    # --- signing ---------------------------------------------------------------
    def test_unpaired_phone(self):
        stranger = self.s.client(key=os.urandom(32))
        self.err("unauthorized", stranger.status)

    def test_wrong_key(self):
        self.paired()
        forger = self.s.client(device_id=self.c.device_id, key=os.urandom(32), counter=100)
        self.err("unauthorized", forger.status)

    def test_replay(self):
        self.paired()
        self.c.status()
        self.err("replay", self.c.call, "GET", "/v1/status", counter=self.c.counter)
        self.err("replay", self.c.call, "GET", "/v1/status", counter=1)
        self.c.status()  # a larger counter still works

    def test_counter_may_skip(self):
        self.paired()
        self.c.counter = 1000
        self.c.status()

    def test_response_is_signed(self):
        import http.client
        self.paired()
        n = self.c.counter + 1
        sig = p.sign_request(self.c.key, "GET", "/v1/status", self.c.device_id, n, b"")
        conn = http.client.HTTPConnection("127.0.0.1", self.s.port, timeout=5)
        conn.request("GET", "/v1/status", headers={"X-Ir2-Device": self.c.device_id,
                                                   "X-Ir2-Counter": str(n), "X-Ir2-Signature": sig})
        r = conn.getresponse()
        data = r.read()
        self.assertEqual(r.status, 200)
        self.assertEqual(r.getheader("X-Ir2-Signature"), p.sign_response(self.c.key, n, 200, data))
        # a client holding another key refuses the answer
        wrong = self.s.client(device_id=self.c.device_id, key=self.c.key, counter=n)
        wrong_key = os.urandom(32)
        self.assertNotEqual(r.getheader("X-Ir2-Signature"), p.sign_response(wrong_key, n, 200, data))
        del wrong

    def test_errors_after_auth_are_signed(self):
        self.paired()
        self.err("not_found", self.c.call, "GET", "/v1/nothing")  # Client checks the signature

    def test_removed_on_the_car(self):
        self.paired()
        self.c.status()
        self.s.send("revoke " + self.c.device_id, "revoked")
        self.err("unauthorized", self.c.status)

    def test_unpair(self):
        self.paired()
        self.assertEqual(self.c.unpair(), {"unpaired": True})
        self.err("unauthorized", self.c.status)

    # --- settings ----------------------------------------------------------------
    def test_settings_schema(self):
        s = self.paired().settings()
        keys = [e["key"] for e in s["schema"]]
        self.assertEqual(keys, ["car_name", "only_in_park", "ambient_at_start", "ambient_color", "ambient_brightness"])
        self.assertEqual(s["values"]["ambient_brightness"], 6)

    def test_settings_change(self):
        c = self.paired()
        s = c.put_settings({"car_name": "Blue Ioniq", "ambient_at_start": True})
        self.assertEqual(s["values"]["car_name"], "Blue Ioniq")
        self.assertTrue(s["values"]["ambient_at_start"])
        self.assertEqual(c.info()["name"], "Blue Ioniq")

    def test_settings_checked(self):
        c = self.paired()
        self.err("bad_request", c.put_settings, {"nope": 1})
        self.err("bad_request", c.put_settings, {"only_in_park": "yes"})
        self.err("bad_request", c.put_settings, {"ambient_brightness": 11})
        self.err("bad_request", c.put_settings, {"ambient_brightness": True})
        self.err("bad_request", c.put_settings, {"ambient_color": "FF0000"})
        self.err("bad_request", c.put_settings, {"car_name": "x" * 25})
        # all or nothing
        self.err("bad_request", c.put_settings, {"car_name": "Changed", "ambient_brightness": -1})
        self.assertEqual(c.settings()["values"]["car_name"], "Ioniq 5")
        self.err("bad_request", c.call, "PUT", "/v1/settings", {"values": {}, "extra": 1})

    # --- ambient light -----------------------------------------------------------
    def test_ambient_nearest_and_save(self):
        c = self.paired()
        r = c.ambient("ff3300", 4, save=True)
        self.assertEqual(r["color"], "ff321d")
        self.assertTrue(r["nearest"])
        self.assertEqual(r["brightness"], 4)
        st = c.status()["ambient"]
        self.assertEqual(st, {"holding": True, "color": "ff321d", "brightness": 4})
        v = c.settings()["values"]
        self.assertEqual((v["ambient_color"], v["ambient_brightness"]), ("ff321d", 4))
        gap()
        self.assertFalse(c.ambient("ffffff")["nearest"])

    def test_ambient_preview_doesnt_save(self):
        c = self.paired()
        c.ambient("1043f4")
        self.assertEqual(c.settings()["values"]["ambient_color"], "")

    def test_ambient_checked(self):
        c = self.paired()
        self.err("bad_request", c.call, "POST", "/v1/ambient", {})
        self.err("bad_request", c.ambient, "red")
        self.err("bad_request", c.ambient, None, 11)
        self.err("bad_request", c.call, "POST", "/v1/ambient", {"color": "ffffff", "zone": 1})

    def test_ambient_rate(self):
        c = self.paired()
        c.ambient(None, 5)
        self.err("slow_down", c.ambient, None, 6)
        gap()
        c.ambient(None, 6)

    def test_release(self):
        c = self.paired()
        c.ambient("ffffff")
        self.assertEqual(c.release(), {"released": True})
        self.assertFalse(c.status()["ambient"]["holding"])

    def test_only_in_park(self):
        c = self.paired()
        self.s.send("park no", "parked")
        self.assertFalse(c.status()["parked"])
        self.err("not_parked", c.ambient, "ffffff")
        self.assertEqual(c.release(), {"released": True})  # always allowed
        self.s.send("park unknown", "parked")
        self.assertIsNone(c.status()["parked"])
        self.err("not_parked", c.ambient, "ffffff")
        c.put_settings({"only_in_park": False})
        c.ambient("ffffff")

    def test_owner_blocked_light(self):
        c = self.paired()
        self.s.send("block on", "light")
        e = self.err("refused", c.ambient, "ffffff")
        self.assertIn("owner", e.message)


class StartTest(unittest.TestCase):
    def test_saved_light_at_start(self):
        s = Server("--set", "ambient_at_start=true", "--set", 'ambient_color="10f4fc"', "--set", "ambient_brightness=3")
        try:
            c = s.client()
            c.pair(CODE)
            self.assertEqual(c.status()["ambient"], {"holding": True, "color": "10f4fc", "brightness": 3})
        finally:
            s.stop()


if __name__ == "__main__":
    unittest.main(verbosity=2)
