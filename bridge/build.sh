#!/bin/sh
# Builds the Ir2 Companion mod: the car app (APK) and the bridge service (dex jar), laid
# out as an HMG-API mod folder, plus a zip of it.
#
#   ANDROID_HOME=~/Library/Android/sdk bridge/build.sh
#
# Needs the Android SDK (any build-tools 30+, any platform android.jar) and a JDK 8+.
# The APK is signed with $IR2_APK_KEYSTORE (password $IR2_APK_KEYSTORE_PASS), or with a key
# made in bridge/.keys/ the first time. Keep that key: Android only updates an app signed
# with the same one.
#
# Then sign the mod package with your HMG-API author key, using HMG-API's mod SDK:
#   hmgapi-mod-sdk/bin/mkmodpkg.sh out/ir2-companion <author key>
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
: "${ANDROID_HOME:?set ANDROID_HOME to the Android SDK}"
BT=$(ls -d "$ANDROID_HOME"/build-tools/* | sort -V | tail -1)
ANDROID_JAR=$(ls "$ANDROID_HOME"/platforms/android-*/android.jar | sort -V | tail -1)
VERSION=$(python3 -c 'import json; print(json.load(open("bridge/mod.json"))["version"])')
W=out/build
M=out/ir2-companion
rm -rf "$W" "$M"
mkdir -p "$W/classes" "$W/svc-classes" "$W/dex-app" "$W/dex-svc" "$M/app" "$M/svc"
echo "build-tools $(basename "$BT"), $(basename "$(dirname "$ANDROID_JAR")")"

# Java: compiled against Android's own classes (java.*, android.*, org.json), Java 8 bytecode, no lambdas
javac -source 8 -target 8 -Xlint:-options -bootclasspath "$ANDROID_JAR" -d "$W/classes" \
    $(ls bridge/java/dev/ir2/companion/*.java | grep -v DevMain) bridge/app/java/dev/ir2/companion/*.java

# the service jar: everything but the activity
cp -r "$W/classes/." "$W/svc-classes/"
rm -f "$W"/svc-classes/dev/ir2/companion/PairActivity*.class
(cd "$W/svc-classes" && jar cf ../svc.jar .)
(cd "$W/classes" && jar cf ../app.jar .)
"$BT/d8" --release --min-api 19 --lib "$ANDROID_JAR" --output "$W/dex-svc" "$W/svc.jar"
"$BT/d8" --release --min-api 19 --lib "$ANDROID_JAR" --output "$W/dex-app" "$W/app.jar"
(cd "$W/dex-svc" && jar cfM "$ROOT/$M/svc/ir2-bridge.jar" classes.dex)

# the APK
"$BT/aapt2" compile --dir bridge/app/res -o "$W/res.zip"
"$BT/aapt2" link -I "$ANDROID_JAR" --manifest bridge/app/AndroidManifest.xml \
    --min-sdk-version 19 --target-sdk-version 19 -o "$W/base.apk" "$W/res.zip"
(cd "$W/dex-app" && zip -q -X "$ROOT/$W/base.apk" classes.dex)
"$BT/zipalign" -f 4 "$W/base.apk" "$W/aligned.apk"

KS=${IR2_APK_KEYSTORE:-bridge/.keys/ir2-companion.p12}
PASS=${IR2_APK_KEYSTORE_PASS:-ir2-companion}
if [ ! -f "$KS" ]; then
    mkdir -p "$(dirname "$KS")"
    keytool -genkeypair -keystore "$KS" -storetype PKCS12 -storepass "$PASS" -alias ir2 \
        -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Ir2 Companion" >/dev/null 2>&1
    echo "made a new APK signing key: $KS (keep it, and keep it out of git)"
fi
# Android 4.4 checks only the v1 (JAR) signature
"$BT/apksigner" sign --ks "$KS" --ks-pass "pass:$PASS" --min-sdk-version 19 \
    --v1-signing-enabled true --v2-signing-enabled false --v3-signing-enabled false \
    --out "$M/app/Ir2Companion.apk" "$W/aligned.apk"
"$BT/apksigner" verify --min-sdk-version 19 "$M/app/Ir2Companion.apk"

cp bridge/mod.json bridge/settings.json "$M/"
(cd out && rm -f "ir2-companion-$VERSION.zip" && zip -q -r -X "ir2-companion-$VERSION.zip" ir2-companion)
echo "mod folder: $M"
echo "zip:        out/ir2-companion-$VERSION.zip (sign it with HMG-API's mkmodpkg.sh before installing)"
