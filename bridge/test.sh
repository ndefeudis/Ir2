#!/bin/sh
# Off-car tests: the protocol suite against the Python fake head unit and against this
# bridge's own code on a desktop JVM (with a fake car). Needs python3 and a JDK 8+.
set -e
cd "$(dirname "$0")/.."
CACHE=bridge/.cache
JSON="$CACHE/json-20231013.jar"
mkdir -p "$CACHE"
[ -f "$JSON" ] || curl -sSfL -o "$JSON" https://repo1.maven.org/maven2/org/json/json/20231013/json-20231013.jar

echo "== fake head unit (Python)"
python3 tools/fakecar/test_protocol.py

echo "== bridge (Java, desktop JVM)"
rm -rf "$CACHE/classes" && mkdir -p "$CACHE/classes"
javac --release 8 -Xlint:all -Xlint:-options -d "$CACHE/classes" -cp "$JSON" bridge/java/dev/ir2/companion/*.java
IR2_SERVER_CMD="java -cp $CACHE/classes:$JSON dev.ir2.companion.DevMain" python3 tools/fakecar/test_protocol.py
