#!/usr/bin/env python3
"""A fake Gen5W head unit running the Ir2 Companion mod, for building the iPhone app
without the car. Standard library only.

    python3 tools/fakecar/fake_headunit.py            # listens on 0.0.0.0:47115
    python3 tools/fakecar/fake_headunit.py --port 0 --pair-code 0123456789ABCDEF

Type commands on its terminal while it runs:

    pair                 show a new pairing code (as the car's screen would)
    park yes|no|unknown  what the gear.park reading says
    block on|off         HMG-API's "Block mod light control" switch
    revoke <device id>   the car app's "Remove" button
    devices              list paired phones
    quit

It prints "LISTENING <port>" and "PAIRING <code>" lines that the tests read.
It behaves like bridge/ (the real mod): same answers, same checks, same errors.
"""

import argparse
import hashlib
import hmac
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ir2proto as p  # noqa: E402

VERSION = "0.1.0"
MAX_BODY = 16 * 1024
MAX_DEVICES = 4
MAX_ATTEMPTS = 5
AMBIENT_GAP = 0.2
SETTINGS_JSON = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "bridge", "settings.json")


class Fail(Exception):
    def __init__(self, status, code, message, signed=True):
        super().__init__(message)
        self.status, self.code, self.message, self.signed = status, code, message, signed


class FakeCar:
    """What HMG-API and the car answer: gear.park and the ambient_light command."""

    def __init__(self, parked=True):
        self.parked = parked  # True, False or None (no answer)
        self.blocked = False
        self.holder = None
        self.log = []

    def ambient(self, *args):
        self.log.append(args)
        if self.blocked and args[0] != "release":
            return "refused: the owner turned off mod light control (HMG-API app)"
        if args[0] == "release":
            if self.holder is None:
                return "ok not holding the light"
            self.holder = None
            return "ok released"
        self.holder = "ir2-companion"
        if args[0] == "color":
            sent = "%06x" % p.nearest(int(args[1], 16))
            return "ok color " + sent + ("" if sent == args[1] else " (the car's nearest to " + args[1] + ")")
        if args[0] == "brightness":
            return "ok brightness " + args[1]
        return "refused: ambient_light color <rrggbb>|brightness <0-10>|release|owner_change release|keep"


class Bridge:
    """The mod's logic, as bridge/java/dev/ir2/companion/Bridge.java has it."""

    def __init__(self, car, schema, pairing_ttl=300):
        self.car, self.schema, self.pairing_ttl = car, schema, pairing_ttl
        self.values = {s["key"]: s.get("default") for s in schema}
        self.devices = {}
        self.pairing = None  # {"code", "expires", "attempts"}
        self.ambient_state = {"holding": False, "color": None, "brightness": None}
        self.last_ambient = 0.0
        self.lock = threading.Lock()

    # pairing, as the car app's "Pair a phone" button
    def open_pairing(self, code=None):
        with self.lock:
            self.pairing = {"code": p.normalize_code(code or p.new_code()),
                            "expires": time.monotonic() + self.pairing_ttl, "attempts": 0}
            return self.pairing["code"]

    def start(self):
        """What the service does when it starts: the saved light, if the owner asked."""
        v = self.values
        if v.get("ambient_at_start") and v.get("ambient_color"):
            self.car.ambient("color", v["ambient_color"])
            self.car.ambient("brightness", str(v["ambient_brightness"]))
            self.ambient_state.update(holding=True, color=v["ambient_color"], brightness=v["ambient_brightness"])

    def handle(self, method, path, headers, body):
        """Returns (status, payload, key, counter); key is None for an unsigned answer."""
        try:
            return self._handle(method, path, headers, body)
        except Fail as f:
            return (f.status, {"error": f.code, "message": f.message},
                    getattr(f, "key", None) if f.signed else None, getattr(f, "counter", 0))

    def _handle(self, method, path, headers, body):
        if len(body) > MAX_BODY:
            raise Fail(413, "too_large", "body over 16 KiB", signed=False)
        if method == "GET" and path == "/v1/info":
            with self.lock:
                open_ = self.pairing is not None and self.pairing["expires"] > time.monotonic()
            return 200, {"protocol": 1, "service": "ir2-companion", "version": VERSION,
                         "name": self.values["car_name"], "pairing_open": open_}, None, 0

        device = headers.get("x-ir2-device", "")
        counter_s = headers.get("x-ir2-counter", "")
        sig = headers.get("x-ir2-signature", "")
        if not p.DEVICE_ID.match(device) or not re.fullmatch(r"[1-9][0-9]{0,15}", counter_s) or not sig:
            raise Fail(401, "unauthorized", "missing or malformed signing headers", signed=False)
        counter = int(counter_s)
        if counter > 2 ** 53 - 1:
            raise Fail(401, "unauthorized", "counter out of range", signed=False)

        with self.lock:
            if method == "POST" and path == "/v1/pair":
                return self._pair(device, counter, sig, body)
            d = self.devices.get(device)
            if d is None:
                raise Fail(401, "unauthorized", "this phone isn't paired", signed=False)
            want = p.sign_request(d["key"], method, path, device, counter, body)
            if not hmac.compare_digest(want, sig):
                raise Fail(401, "unauthorized", "wrong signature", signed=False)
            if counter <= d["counter"]:
                raise self._signed(Fail(409, "replay", "counter not above the last one"), d["key"], counter)
            d["counter"] = counter
            try:
                return (200, self._route(method, path, device, body), d["key"], counter)
            except Fail as f:
                raise self._signed(f, d["key"], counter)

    @staticmethod
    def _signed(f, key, counter):
        f.key, f.counter = key, counter
        return f

    def _pair(self, device, counter, sig, body):
        pr = self.pairing
        if pr is None or pr["expires"] <= time.monotonic():
            self.pairing = None
            raise Fail(403, "no_pairing", "no pairing code on the car's screen", signed=False)
        if pr["attempts"] >= MAX_ATTEMPTS:
            raise Fail(403, "pairing_locked", "too many wrong codes: show a new one", signed=False)
        key = p.device_key(pr["code"], device)
        if not hmac.compare_digest(p.sign_request(key, "POST", "/v1/pair", device, counter, body), sig):
            pr["attempts"] += 1
            if pr["attempts"] >= MAX_ATTEMPTS:
                raise Fail(403, "pairing_locked", "too many wrong codes: show a new one", signed=False)
            raise Fail(401, "unauthorized", "wrong pairing code", signed=False)
        try:
            obj = self._object(body, {"device_id", "device_name"})
            name = obj.get("device_name")
            if obj.get("device_id") != device:
                raise Fail(400, "bad_request", "device_id doesn't match X-Ir2-Device")
            if not isinstance(name, str) or not 1 <= len(name) <= 40:
                raise Fail(400, "bad_request", "device_name: 1-40 characters")
            if device not in self.devices and len(self.devices) >= MAX_DEVICES:
                raise Fail(403, "too_many_devices", "4 phones are paired: remove one in the car app")
        except Fail as f:
            raise self._signed(f, key, counter)
        self.devices[device] = {"name": name, "key": key, "counter": counter}
        self.pairing = None
        return 200, {"paired": True, "name": self.values["car_name"]}, key, counter

    @staticmethod
    def _object(body, allowed):
        try:
            obj = json.loads(body.decode("utf-8")) if body else {}
        except (UnicodeDecodeError, ValueError):
            raise Fail(400, "bad_request", "body isn't JSON")
        if not isinstance(obj, dict):
            raise Fail(400, "bad_request", "body isn't a JSON object")
        extra = set(obj) - allowed
        if extra:
            raise Fail(400, "bad_request", "unknown field: " + sorted(extra)[0])
        return obj

    def _route(self, method, path, device, body):
        if method == "POST" and path == "/v1/unpair":
            del self.devices[device]
            return {"unpaired": True}
        if method == "GET" and path == "/v1/status":
            return {"parked": self.car.parked, "ambient": dict(self.ambient_state),
                    "guard": {"only_in_park": bool(self.values["only_in_park"])}}
        if method == "GET" and path == "/v1/settings":
            return self._settings()
        if method == "PUT" and path == "/v1/settings":
            obj = self._object(body, {"values"})
            values = obj.get("values")
            if not isinstance(values, dict):
                raise Fail(400, "bad_request", "values: an object")
            checked = {k: self._check(k, v) for k, v in values.items()}
            self.values.update(checked)
            return self._settings()
        if method == "POST" and path == "/v1/ambient":
            return self._ambient(self._object(body, {"color", "brightness", "save"}))
        if method == "POST" and path == "/v1/ambient/release":
            msg = self.car.ambient("release")
            if msg.startswith("refused"):
                raise Fail(403, "refused", msg)
            self.ambient_state["holding"] = False
            return {"released": True}
        raise Fail(404, "not_found", "no such endpoint")

    def _settings(self):
        schema = [s for s in self.schema if not s.get("private")]
        return {"schema": schema, "values": {s["key"]: self.values[s["key"]] for s in schema}}

    def _check(self, key, v):
        s = next((s for s in self.schema if s["key"] == key and not s.get("private")), None)
        if s is None:
            raise Fail(400, "bad_request", "unknown setting: " + key)
        t = s.get("type", "text")
        if t == "toggle":
            if not isinstance(v, bool):
                raise Fail(400, "bad_request", key + ": true or false")
        elif t == "number":
            if isinstance(v, bool) or not isinstance(v, int):
                raise Fail(400, "bad_request", key + ": a whole number")
            if ("min" in s and v < s["min"]) or ("max" in s and v > s["max"]):
                raise Fail(400, "bad_request", "%s: %s-%s" % (key, s.get("min", ""), s.get("max", "")))
        elif t == "choice":
            if v not in [o.get("value") for o in s.get("options", [])]:
                raise Fail(400, "bad_request", key + ": not one of the choices")
        else:
            if not isinstance(v, str) or len(v) > s.get("max_length", 200):
                raise Fail(400, "bad_request", "%s: text up to %d characters" % (key, s.get("max_length", 200)))
            if "pattern" in s and not re.fullmatch(s["pattern"], v):
                raise Fail(400, "bad_request", key + ": not in the expected form")
        return v

    def _ambient(self, obj):
        color, bright, save = obj.get("color"), obj.get("brightness"), obj.get("save", False)
        if color is None and bright is None:
            raise Fail(400, "bad_request", "color or brightness")
        if color is not None and (not isinstance(color, str) or not re.fullmatch(r"[0-9a-f]{6}", color)):
            raise Fail(400, "bad_request", "color: 6 lowercase hex digits")
        if bright is not None and (isinstance(bright, bool) or not isinstance(bright, int) or not 0 <= bright <= 10):
            raise Fail(400, "bad_request", "brightness: 0-10")
        if not isinstance(save, bool):
            raise Fail(400, "bad_request", "save: true or false")
        if self.values["only_in_park"] and self.car.parked is not True:
            raise Fail(403, "not_parked", "the car isn't in P" if self.car.parked is False
                       else "the car didn't say it's in P")
        now = time.monotonic()
        if now - self.last_ambient < AMBIENT_GAP:
            raise Fail(429, "slow_down", "at most 5 changes a second")
        self.last_ambient = now
        msgs, sent, nearest = [], None, False
        if color is not None:
            msg = self.car.ambient("color", color)
            if not msg.startswith("ok"):
                raise Fail(403, "refused", msg)
            m = re.match(r"ok color ([0-9a-f]{6})", msg)
            sent = m.group(1) if m else color
            nearest = sent != color
            msgs.append(msg)
            self.ambient_state.update(holding=True, color=sent)
        if bright is not None:
            msg = self.car.ambient("brightness", str(bright))
            if not msg.startswith("ok"):
                raise Fail(403, "refused", msg)
            msgs.append(msg)
            self.ambient_state.update(holding=True, brightness=bright)
        if save:
            if sent is not None:
                self.values["ambient_color"] = sent
            if bright is not None:
                self.values["ambient_brightness"] = bright
        return {"color": sent, "brightness": bright, "nearest": nearest, "message": "; ".join(msgs)}


def make_handler(bridge, verbose):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _go(self):
            if self.headers.get("Transfer-Encoding"):
                return self._reply(400, {"error": "bad_request", "message": "no chunked bodies"}, None, 0)
            try:
                n = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                n = -1
            if n < 0 or n > MAX_BODY:
                return self._reply(413, {"error": "too_large", "message": "body over 16 KiB"}, None, 0)
            body = self.rfile.read(n) if n else b""
            headers = {k.lower(): v for k, v in self.headers.items()}
            status, payload, key, counter = bridge.handle(self.command, self.path, headers, body)
            self._reply(status, payload, key, counter)

        def _reply(self, status, payload, key, counter):
            data = json.dumps(payload, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            if key is not None:
                self.send_header("X-Ir2-Signature", p.sign_response(key, counter, status, data))
            self.end_headers()
            self.wfile.write(data)
            self.close_connection = True

        do_GET = do_POST = do_PUT = do_DELETE = _go

        def log_message(self, fmt, *args):
            if verbose:
                sys.stderr.write("[fake] %s %s\n" % (self.address_string(), fmt % args))

    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=p.PORT)
    ap.add_argument("--pair-code", help="open pairing at start with this code (tests)")
    ap.add_argument("--parked", choices=["yes", "no", "unknown"], default="yes")
    ap.add_argument("--pairing-ttl", type=int, default=300)
    ap.add_argument("--settings", default=SETTINGS_JSON)
    ap.add_argument("--set", action="append", default=[], metavar="KEY=JSON", help="start with a setting value")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    schema = json.load(open(a.settings))["settings"]
    car = FakeCar({"yes": True, "no": False, "unknown": None}[a.parked])
    bridge = Bridge(car, schema, a.pairing_ttl)
    for kv in a.set:
        k, v = kv.split("=", 1)
        bridge.values[k] = json.loads(v)
    bridge.start()

    server = ThreadingHTTPServer((a.host, a.port), make_handler(bridge, a.verbose))
    print("LISTENING %d" % server.server_address[1], flush=True)
    if a.pair_code:
        print("PAIRING %s" % p.show_code(bridge.open_pairing(a.pair_code)), flush=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    for line in sys.stdin:
        cmd = line.split()
        if not cmd:
            continue
        if cmd[0] == "pair":
            print("PAIRING %s  (valid %d s)" % (p.show_code(bridge.open_pairing()), a.pairing_ttl), flush=True)
        elif cmd[0] == "park" and len(cmd) == 2:
            car.parked = {"yes": True, "no": False}.get(cmd[1])
            print("parked:", car.parked, flush=True)
        elif cmd[0] == "block" and len(cmd) == 2:
            car.blocked = cmd[1] == "on"
            print("light control blocked:", car.blocked, flush=True)
        elif cmd[0] == "revoke" and len(cmd) == 2:
            with bridge.lock:
                bridge.devices.pop(cmd[1], None)
            print("revoked:", cmd[1], flush=True)
        elif cmd[0] == "devices":
            for i, d in bridge.devices.items():
                print(" ", i, d["name"], "counter", d["counter"], flush=True)
        elif cmd[0] == "quit":
            break
        else:
            print("pair | park yes|no|unknown | block on|off | revoke <id> | devices | quit", flush=True)
    else:
        # stdin closed (run in the background): keep serving
        threading.Event().wait()
    server.shutdown()


if __name__ == "__main__":
    main()
