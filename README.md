# Ir2

An iPhone app that changes the look of a Hyundai Ioniq 5's head unit, for cars running
[NEMESIS](https://github.com/xwtk/hmg_nemesis) and [HMG-API](https://github.com/Open-HMG/HMG-API).

Version 0.1 does the **ambient light**: pick one of the car's 64 colours and a brightness,
see it live on the car, keep it, give it back to the car's menu, and save presets. Its
settings screen is drawn from the mod's `settings.json`, the way the HMG-API app on the car
draws its own, so new settings appear in the app without an app update.

Made for, and only checked against code for: **US Ioniq 5, Gen5W, firmware 260507**
(HMG-API's map `hyundai/neev/usa/260507`, products `NEEV.USA.`, `NEEV23.USA.`, `NEEV23SE.USA.`).
**Nothing here has run on a car yet.**

## How it fits together

```
iPhone (Ir2 app) ──Wi-Fi──▶ Ir2 Companion (an HMG-API mod on the head unit) ──▶ HMG-API ──▶ the car
```

HMG-API has no network interface of its own: its daemon only answers local callers, and
checks which ones. So this repo has two halves:

| Folder | What |
|---|---|
| `bridge/` | **Ir2 Companion**, an HMG-API mod: a small service listening on the car's Wi-Fi (port 47115), and a car-screen app for pairing phones. It uses only what HMG-API gives any mod: its own settings, the `gear.park` reading and the `ambient_light` command, with HMG-API's own guards. No root. |
| `ios/` | The iPhone app (SwiftUI, iOS 17+) and `Ir2Kit`, the Swift package that speaks the protocol. |
| `tools/fakecar/` | A fake head unit (Python, standard library only), so the app can be built and tried without the car, and the protocol tests. |
| `docs/PROTOCOL.md` | The protocol: pairing, signing, endpoints, errors. |

**Security, in short:** the car shows a one-time 16-character code; phone and car each
derive a key from it and the key never crosses the network. Every request and every answer
is signed with it, and counters stop replays. The service answers only phones on the car's
own Wi-Fi. "Only in Park" (on by default) stops light changes while driving. Details:
`docs/PROTOCOL.md`.

## Try it without the car

```sh
python3 tools/fakecar/fake_headunit.py          # listens on port 47115 and waits for commands
pair                                            # type this: it prints a pairing code
```

Run the iPhone app in the Simulator, enter your Mac's address (`127.0.0.1` in the Simulator),
and type the code. On the fake's terminal, `park no` takes the car out of P and
`block on` acts as HMG-API's "Block mod light control" switch.

## Build the iPhone app (Mac)

```sh
brew install xcodegen
cd ios && xcodegen && open Ir2.xcodeproj
```

Pick your team under *Signing & Capabilities* (a free Apple ID works for your own phone)
and run on your iPhone. The first connection asks for **Local Network** access: allow it.

## Build and install the car mod

You need the Android SDK (`ANDROID_HOME`; Android Studio installs one), a JDK, and
HMG-API's mod SDK (a release asset of HMG-API) for signing the package with your author key.

```sh
ANDROID_HOME=~/Library/Android/sdk bridge/build.sh      # → out/ir2-companion/, out/ir2-companion-0.1.0.zip
hmgapi-mod-sdk/bin/mkmodpkg.sh out/ir2-companion <your author key>
```

Install the signed package from a USB stick through the HMG-API app (**Updates**), as for any
HMG-API mod. HMG-API's plan will show what the mod asks for. Check it, and allow the
firewall rule (car's Wi-Fi, TCP 47115). Then open **Ir2 Companion** from the app menu, tap
**Pair a phone**, and type the code into the iPhone.

Every push also builds the mod and the app in GitHub Actions (`.github/workflows/ci.yml`).
The mod zip is attached to each run as an artifact.

## Tests

```sh
bridge/test.sh                  # the protocol suite against the Python fake AND the real bridge code on a JVM
cd ios/Ir2Kit && swift test     # (Mac) crypto vectors, settings checks, end to end against the fake
```

## What's next

- **On the car:** a first run on the Ioniq 5, with HMG-API's Car Report sent upstream (the
  260507 map for this car is from stock files and hasn't been checked on a car yet).
- **More of the look:** HMG-API only lets a mod change its own settings. To set other mods'
  look settings from the phone (CarPlay Ultra-Lite's theme, Android Auto density mods, the
  tile manager), HMG-API needs an operation that lets the owner grant that. That's a proposal
  for HMG-API's companion-app issue (#60), not something to work around.
- **Theme Studio:** Gen5W Theme Studio's on-car helper takes commands from a world-writable
  file in `/mnt/asec`, which any app on the head unit could write. Ir2 doesn't use it. Raise
  that with its author before wiring a phone to it.
