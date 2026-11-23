"""Ir2 Companion protocol v1: the crypto both sides share, and a reference client.

Standard library only. See docs/PROTOCOL.md.
"""

import hashlib
import hmac
import json
import os
import re
import http.client

PORT = 47115
SALT = b"ir2-companion/v1"
CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
DEVICE_ID = re.compile(r"^[0-9a-f]{32}$")
# errors the car sends before it knows the phone's key: never signed, never trusted for more than "it failed"
UNSIGNED_ERRORS = {"unauthorized", "no_pairing", "pairing_locked", "too_large"}

PALETTE = [  # the car's 64 ambient colours (HMG-API hmgapi.vehicle.Commands.PALETTE, US EV6 260507)
    0x1043f4, 0x102ef2, 0x1020ef, 0x211cef, 0x2f1cef, 0x401cef, 0x521cef, 0x641cef,
    0x781cef, 0x881def, 0x9b21ef, 0xa923ef, 0xb723ea, 0xc121e0, 0xcc1fd2, 0xd51bc0,
    0xdd17ae, 0xe41399, 0xeb0e99, 0xef0a74, 0xf60660, 0xfa0451, 0xfe0145, 0xff321d,
    0xff4423, 0xff5027, 0xff6930, 0xff7835, 0xff8f3e, 0xffa646, 0xffc04f, 0xffd356,
    0xffe55c, 0xfff362, 0xfefd66, 0xffffff, 0xf4fd66, 0xe8fd66, 0xd9fd66, 0xcbfd63,
    0xb7f962, 0xa8f362, 0x95eb62, 0x84e562, 0x75df62, 0x68dd62, 0x5dde69, 0x51e176,
    0x47e785, 0x3eee98, 0x35f5a9, 0x2cfabd, 0x25facf, 0x1efae1, 0x19faed, 0x14faf9,
    0x10f4fc, 0x10e6fc, 0x10d2fc, 0x10bbfc, 0x10a3fc, 0x108afc, 0x106ffc, 0x1059f8,
]


def nearest(rgb):
    """The palette colour HMG-API sends for rgb (squared RGB distance, first wins)."""
    best, best_d = PALETTE[0], None
    for c in PALETTE:
        d = sum(((c >> s & 255) - (rgb >> s & 255)) ** 2 for s in (16, 8, 0))
        if best_d is None or d < best_d:
            best, best_d = c, d
    return best


def new_code():
    """16 Crockford base32 characters, 80 random bits."""
    n = int.from_bytes(os.urandom(10), "big")
    return "".join(CROCKFORD[(n >> (5 * i)) & 31] for i in reversed(range(16)))


def show_code(code):
    return "-".join(code[i:i + 4] for i in range(0, 16, 4))


def normalize_code(text):
    s = text.upper().replace("-", "").replace(" ", "")
    return s.replace("O", "0").replace("I", "1").replace("L", "1")


def hkdf_sha256(ikm, salt, info, length=32):
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out, block, i = b"", b"", 1
    while len(out) < length:
        block = hmac.new(prk, block + info + bytes([i]), hashlib.sha256).digest()
        out += block
        i += 1
    return out[:length]


def device_key(code, device_id):
    return hkdf_sha256(normalize_code(code).encode(), SALT, ("device-key:" + device_id).encode())


def sign_request(key, method, path, device_id, counter, body):
    canonical = "\n".join([method.upper(), path, device_id, str(counter), hashlib.sha256(body).hexdigest()])
    return hmac.new(key, canonical.encode(), hashlib.sha256).hexdigest()


def sign_response(key, counter, status, body):
    canonical = "\n".join(["response", str(counter), str(status), hashlib.sha256(body).hexdigest()])
    return hmac.new(key, canonical.encode(), hashlib.sha256).hexdigest()


class ProtocolError(Exception):
    def __init__(self, status, code, message=""):
        super().__init__("%s %s: %s" % (status, code, message))
        self.status, self.code, self.message = status, code, message


class Client:
    """What the iPhone app does, in Python: used by the tests and handy from a laptop."""

    def __init__(self, host, port=PORT, device_id=None, key=None, counter=0, timeout=10):
        self.host, self.port, self.timeout = host, port, timeout
        self.device_id = device_id or os.urandom(16).hex()
        self.key, self.counter = key, counter

    def _send(self, method, path, body, headers):
        conn = http.client.HTTPConnection(self.host, self.port, timeout=self.timeout)
        try:
            conn.request(method, path, body=body, headers=headers)
            r = conn.getresponse()
            return r.status, r.read(), r.getheader("X-Ir2-Signature")
        finally:
            conn.close()

    def info(self):
        status, data, _ = self._send("GET", "/v1/info", None, {})
        if status != 200:
            raise ProtocolError(status, "http", data.decode(errors="replace"))
        return json.loads(data)

    def call(self, method, path, obj=None, key=None, counter=None, verify=True):
        key = key or self.key
        if key is None:
            raise ValueError("not paired")
        if counter is None:
            self.counter += 1
            counter = self.counter
        body = b"" if obj is None else json.dumps(obj).encode()
        headers = {
            "X-Ir2-Device": self.device_id,
            "X-Ir2-Counter": str(counter),
            "X-Ir2-Signature": sign_request(key, method, path, self.device_id, counter, body),
        }
        if body:
            headers["Content-Type"] = "application/json"
        status, data, sig = self._send(method, path, body, headers)
        payload = json.loads(data) if data else {}
        unsigned_ok = status != 200 and sig is None and payload.get("error") in UNSIGNED_ERRORS
        if verify and not unsigned_ok:
            want = sign_response(key, counter, status, data)
            if not sig or not hmac.compare_digest(sig, want):
                raise ProtocolError(status, "bad_response_signature", "the answer isn't from the paired car")
        if status != 200:
            raise ProtocolError(status, payload.get("error", "http"), payload.get("message", ""))
        return payload

    def pair(self, code, device_name="Test phone"):
        key = device_key(code, self.device_id)
        self.counter = 1
        r = self.call("POST", "/v1/pair", {"device_id": self.device_id, "device_name": device_name},
                      key=key, counter=1)
        self.key = key
        return r

    def status(self):
        return self.call("GET", "/v1/status")

    def settings(self):
        return self.call("GET", "/v1/settings")

    def put_settings(self, values):
        return self.call("PUT", "/v1/settings", {"values": values})

    def ambient(self, color=None, brightness=None, save=False):
        body = {"save": save}
        if color is not None:
            body["color"] = color
        if brightness is not None:
            body["brightness"] = brightness
        return self.call("POST", "/v1/ambient", body)

    def release(self):
        return self.call("POST", "/v1/ambient/release")

    def unpair(self):
        return self.call("POST", "/v1/unpair")
