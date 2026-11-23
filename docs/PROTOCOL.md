# Ir2 Companion bridge protocol, version 1

How the iPhone app talks to the **Ir2 Companion** HMG-API mod on a Gen5W head unit.
The mod is the only part that touches the car; the phone never runs commands on the
head unit itself.

```
iPhone app  ──HTTP/JSON over the car's Wi-Fi──▶  Ir2 Companion service (HMG-API mod)
                                                   │  hmgapid setting-get / setting-set
                                                   │  hmgapid vehicle gear.park
                                                   ▼  hmgapid vehicle-do ambient_light …
                                                 HMG-API (its own guards and leases)
```

## Transport

- Plain HTTP/1.1 on TCP port **47115**, on the car's Wi-Fi access point (`wlan0`,
  stock address `192.168.0.1`). The phone is on that network whenever wireless CarPlay
  is connected.
- The mod asks HMG-API for one firewall rule (`input`, `hotspot`, tcp 47115). HMG-API
  shows it in the plan and the owner has to allow it.
- The service also drops any connection whose peer is not on the hotspot
  (`192.168.0.0/24`, IPv6 link-local `fe80::/10`) or loopback, so the modem and the
  car's internal links can never reach it, whatever the firewall does.
- Request bodies are JSON, UTF-8, at most 16 KiB. Responses are JSON, at most 64 KiB.
- One request per connection (`Connection: close`). Requests time out after 10 s.

There is no TLS: Android 4.4 on the head unit has no practical way to make and pin
its own certificate. Instead, every request and response is authenticated with a key
that never crosses the network (below). The values exchanged (a colour, a brightness,
mod settings) are not secret; integrity is what matters, and that is covered.

## Pairing

1. On the car, the owner opens **Ir2 Companion** (a tile in the app menu) and taps
   **Pair a phone**. The car shows a one-time **pairing code**: 16 characters of
   Crockford base32 (80 random bits), shown as `XXXX-XXXX-XXXX-XXXX`, valid for
   5 minutes, and the car's address.
2. The owner types the code into the phone. The phone makes a random **device id**
   (16 random bytes, 32 lowercase hex characters).
3. Both sides derive the **device key**, without sending it:

   ```
   code_n     = the code, uppercased, with "-" and spaces removed, O→0, I→1, L→1
   device_key = HKDF-SHA256(ikm  = UTF-8(code_n),
                            salt = UTF-8("ir2-companion/v1"),
                            info = UTF-8("device-key:" + device_id),
                            L    = 32 bytes)
   ```

4. The phone sends `POST /v1/pair`, signed with `device_key` and counter `1`
   (signing is below). The car derives the same key from the code it is showing and
   checks the signature. On success it stores the device (id, name, key, counter) and
   forgets the code: a code pairs one phone, once.
5. Five wrong attempts on one code end it (`pairing_locked`); the owner shows a new one.
   At most 4 phones can be paired; the car app lists them and can remove each one.

An eavesdropper on the car's Wi-Fi who records the pairing request would have to guess
80 bits to forge anything. The code is shown only on the car's own screen.

## Signing

Every request except `GET /v1/info` carries three headers:

| Header | Value |
|---|---|
| `X-Ir2-Device` | the device id |
| `X-Ir2-Counter` | a decimal integer, larger than any counter this device used before (1 … 2^53−1) |
| `X-Ir2-Signature` | lowercase hex of `HMAC-SHA256(device_key, canonical)` |

```
canonical = METHOD + "\n" + PATH + "\n" + device_id + "\n" + counter + "\n" + hex(SHA-256(body))
```

`METHOD` is uppercase, `PATH` is the request path exactly as sent (no query strings
are used in version 1), and an empty body hashes as the empty string. The car keeps
the highest counter it accepted for each device and refuses anything not above it
(`replay`), so a recorded request can't be sent again. No clock is involved: the head
unit's clock reads 2015 until it gets the time.

The phone keeps its counter in the iOS Keychain next to the key and adds 1 before
each request. Counters only need to increase, not be consecutive.

Every response to a signed request is signed too:

| Header | Value |
|---|---|
| `X-Ir2-Signature` | lowercase hex of `HMAC-SHA256(device_key, "response\n" + counter + "\n" + status + "\n" + hex(SHA-256(body)))` |

`counter` is the request's counter and `status` the HTTP status code (for example
`200`). The phone drops any response whose signature doesn't match, so something else
on the Wi-Fi can't answer in the car's place.

A few errors come before the car knows which key to use, and are not signed:
`unauthorized`, `no_pairing`, `pairing_locked` and `too_large`. The phone accepts them
only as "that failed" (an attacker on the Wi-Fi could fake one, which is no worse
than dropping the connection); a 200 answer is always signed, and an unsigned one is
never accepted.

## Errors

Any status other than 200 has the body `{"error": "<code>", "message": "<text>"}`.
The message is for people and may change; the phone acts on the code.

| Status | `error` | Meaning |
|---|---|---|
| 400 | `bad_request` | malformed JSON, unknown field, value out of range |
| 401 | `unauthorized` | unknown device, missing headers or a wrong signature |
| 403 | `no_pairing` | `/v1/pair` with no code on the car's screen, or it expired |
| 403 | `pairing_locked` | five wrong attempts: show a new code |
| 403 | `too_many_devices` | 4 phones are paired already |
| 403 | `not_parked` | "Only in Park" is on and the car isn't (or can't say it is) in P |
| 403 | `refused` | HMG-API refused the command (the message is HMG-API's reason) |
| 404 | `not_found` | no such endpoint |
| 409 | `replay` | the counter isn't above the last accepted one |
| 413 | `too_large` | body over 16 KiB |
| 429 | `slow_down` | ambient light changes come at most 5 a second from the phone |
| 503 | `car_unavailable` | `hmgapid` isn't answering |

## Endpoints

### `GET /v1/info` (not signed)

```json
{"protocol": 1, "service": "ir2-companion", "version": "0.1.0",
 "name": "Ioniq 5", "pairing_open": false}
```

`name` is the owner's name for the car (the mod's `car_name` setting). Nothing else
about the car is given out before pairing.

### `POST /v1/pair`

Request (signed with the key derived from the code, counter 1):

```json
{"device_id": "3f0c…32 hex…", "device_name": "My iPhone"}
```

`device_id` must equal the `X-Ir2-Device` header. `device_name` is 1-40 characters,
shown in the car app's list. Response: `{"paired": true, "name": "Ioniq 5"}`.

### `POST /v1/unpair`

Removes the calling phone. Response: `{"unpaired": true}`.

### `GET /v1/status`

```json
{
  "parked": true,
  "ambient": {"holding": true, "color": "ff321d", "brightness": 6},
  "guard": {"only_in_park": true}
}
```

- `parked`: `true` / `false` from the car's `gear.park` reading, or `null` when the
  car didn't answer.
- `ambient.holding`: whether this mod holds HMG-API's ambient light lease (a colour
  or brightness from the phone is on). `color` / `brightness` are the last ones the
  phone set through this mod (`null` before that).

### `GET /v1/settings`

The mod's own settings, as HMG-API's `settings.json` describes them (entries marked
`private` are left out), and their current values. The phone draws its settings
screen from this, the same way the HMG-API app on the car does.

```json
{
  "schema": [
    {"key": "only_in_park", "type": "toggle", "default": true,
     "title": "Only in Park", "description": "…"}
  ],
  "values": {"only_in_park": true}
}
```

Types in version 1: `toggle` (boolean), `choice` (string, one of `options[].value`),
`number` (integer, optional `min` / `max`), `text` (string, optional `max_length`,
optional `pattern`, a regular expression the whole value must match).

### `PUT /v1/settings`

```json
{"values": {"car_name": "Blue Ioniq"}}
```

Changes only the keys given. Every key must be in the schema and every value must
fit its type; otherwise nothing changes (`bad_request`). Changing a setting never
changes the car by itself (saved ambient values are used at the next start), so this
is not limited to Park. The response is the same as `GET /v1/settings`.

`min`, `max`, `max_length` and `pattern` are this mod's additions to HMG-API's
`settings.json`; the HMG-API app ignores them and the service enforces them.

### `POST /v1/ambient`

Sets the ambient light. Both fields are optional; at least one must be given.

```json
{"color": "ff3300", "brightness": 6, "save": false}
```

- `color`: 6 lowercase hex digits. The car only shows the 64 colours of its own
  picker, so HMG-API sends the nearest one; the reply says which (`color`).
- `brightness`: 0-10, 0 turns the light off.
- `save`: also keep them as the mod's `ambient_color` / `ambient_brightness`
  settings, which the mod puts back each time it starts if `ambient_at_start` is on.
  Without `save`, it's a preview.
- Only works with **Custom colour** chosen in the car's mood-lamp settings: a car
  theme there overrides it.

Response:

```json
{"color": "ff321d", "brightness": 6, "nearest": true, "message": "ok color ff321d (the car's nearest to ff3300)"}
```

### `POST /v1/ambient/release`

Lets go of the light: HMG-API puts the owner's own colour and brightness back.
Response: `{"released": true}`. Not limited to Park.

## Versioning

`/v1/` paths stay compatible: new optional fields and endpoints may be added, and
clients ignore fields they don't know. A breaking change gets `/v2/` and
`"protocol": 2` in `/v1/info`.
