package dev.ir2.companion;

import java.io.IOException;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.json.JSONTokener;

/**
 * The protocol (docs/PROTOCOL.md): checks every request, then answers it from the car.
 * tools/fakecar/fake_headunit.py's Bridge does exactly the same; test_protocol.py runs against both.
 * One request at a time (synchronized): requests are rare and the car's commands are serial anyway.
 */
public final class Bridge {
    public static final String VERSION = "0.1.0";
    static final int MAX_BODY = 16 * 1024;
    static final int MAX_DEVICES = 4;
    static final int MAX_ATTEMPTS = 5;
    static final long AMBIENT_GAP_MS = 200;
    static final long SETTINGS_CACHE_MS = 2000;
    static final long MAX_COUNTER = (1L << 53) - 1;
    static final Pattern DEVICE_ID = Pattern.compile("[0-9a-f]{32}");
    static final Pattern COUNTER = Pattern.compile("[1-9][0-9]{0,15}");
    static final Pattern HEX6 = Pattern.compile("[0-9a-f]{6}");
    static final Pattern OK_COLOR = Pattern.compile("^ok color ([0-9a-f]{6}).*", Pattern.DOTALL);

    /** an answer: status, JSON body, and the key that signs it (null: unsigned) */
    public static final class Response {
        public final int status;
        public final JSONObject body;
        public final byte[] key;
        public final long counter;

        Response(int status, JSONObject body, byte[] key, long counter) {
            this.status = status;
            this.body = body;
            this.key = key;
            this.counter = counter;
        }

        public byte[] bytes() {
            return Proto.utf8(body.toString());
        }
    }

    static final class Fail extends Exception {
        private static final long serialVersionUID = 1L;
        final int status;
        final String code;
        final boolean signed;
        byte[] key;
        long counter;

        Fail(int status, String code, String message) {
            this(status, code, message, true);
        }

        Fail(int status, String code, String message, boolean signed) {
            super(message);
            this.status = status;
            this.code = code;
            this.signed = signed;
        }

        Fail with(byte[] key, long counter) {
            this.key = key;
            this.counter = counter;
            return this;
        }
    }

    /** the parts of the clock the bridge uses, so tests can move it */
    public interface Clock {
        long wallMs();

        long monoMs();
    }

    public static final Clock SYSTEM_CLOCK = new Clock() {
        public long wallMs() {
            return System.currentTimeMillis();
        }

        public long monoMs() {
            return System.nanoTime() / 1000000L;
        }
    };

    final Car car;
    final Store store;
    final JSONArray schema;
    final Clock clock;
    final Map<String, Store.Device> devices;
    final Map<String, Integer> attempts = new HashMap<String, Integer>();
    JSONObject values;
    long valuesAt = Long.MIN_VALUE / 2;
    long lastAmbient = Long.MIN_VALUE / 2;
    boolean holding;
    String ambientColor;
    Integer ambientBrightness;

    public Bridge(Car car, Store store, JSONArray schema, Clock clock) {
        this.car = car;
        this.store = store;
        this.schema = schema;
        this.clock = clock;
        this.devices = store.loadDevices();
    }

    /** at service start: the light saved from the phone, if the owner asked for it */
    public synchronized void start() {
        try {
            JSONObject v = values(true);
            String color = v.optString("ambient_color", "");
            if (v.optBoolean("ambient_at_start") && HEX6.matcher(color).matches()) {
                String a = car.ambient("color", color);
                String b = car.ambient("brightness", String.valueOf(v.optInt("ambient_brightness", 6)));
                log("at start: " + a + "; " + b);
                if (a.startsWith("ok")) {
                    holding = true;
                    Matcher m = OK_COLOR.matcher(a);
                    ambientColor = m.matches() ? m.group(1) : color;
                }
                if (b.startsWith("ok")) {
                    holding = true;
                    ambientBrightness = v.optInt("ambient_brightness", 6);
                }
            }
        } catch (IOException e) {
            log("at start: " + e.getMessage());
        } catch (Fail f) {
            log("at start: " + f.getMessage());
        }
    }

    /** phones the car app removed; called often (each request, and a timer) */
    public synchronized void syncRevocations() {
        boolean changed = false;
        for (String id : store.takeRevocations()) changed |= devices.remove(id) != null;
        if (changed) saveDevices();
    }

    public synchronized Response handle(String method, String path, Map<String, String> headers, byte[] body) {
        try {
            return handleOrFail(method, path, headers, body);
        } catch (Fail f) {
            return new Response(f.status, error(f.code, f.getMessage()), f.signed ? f.key : null, f.counter);
        } catch (RuntimeException e) {
            log("internal error: " + e);
            return new Response(500, error("internal", "the bridge failed"), null, 0);
        }
    }

    static JSONObject error(String code, String message) {
        try {
            return new JSONObject().put("error", code).put("message", message == null ? "" : message);
        } catch (JSONException e) {
            throw new IllegalStateException(e);
        }
    }

    Response handleOrFail(String method, String path, Map<String, String> headers, byte[] body) throws Fail {
        if (body.length > MAX_BODY) throw new Fail(413, "too_large", "body over 16 KiB", false);
        syncRevocations();
        if ("GET".equals(method) && "/v1/info".equals(path)) {
            try {
                JSONObject o = new JSONObject();
                o.put("protocol", 1);
                o.put("service", "ir2-companion");
                o.put("version", VERSION);
                o.put("name", valuesOrDefaults().optString("car_name", "Ioniq 5"));
                o.put("pairing_open", store.pairing(clock.wallMs()) != null);
                return new Response(200, o, null, 0);
            } catch (JSONException e) {
                throw new IllegalStateException(e);
            }
        }

        String device = header(headers, "x-ir2-device");
        String counterS = header(headers, "x-ir2-counter");
        String sig = header(headers, "x-ir2-signature");
        if (!DEVICE_ID.matcher(device).matches() || !COUNTER.matcher(counterS).matches() || sig.length() == 0) {
            throw new Fail(401, "unauthorized", "missing or malformed signing headers", false);
        }
        long counter = Long.parseLong(counterS);
        if (counter > MAX_COUNTER) throw new Fail(401, "unauthorized", "counter out of range", false);

        if ("POST".equals(method) && "/v1/pair".equals(path)) return pair(device, counter, sig, body);

        Store.Device d = devices.get(device);
        if (d == null) throw new Fail(401, "unauthorized", "this phone isn't paired", false);
        if (!Proto.same(Proto.signRequest(d.key, method, path, device, counter, body), sig)) {
            throw new Fail(401, "unauthorized", "wrong signature", false);
        }
        if (counter <= d.counter) throw new Fail(409, "replay", "counter not above the last one").with(d.key, counter);
        d.counter = counter;
        saveDevices();
        try {
            return new Response(200, route(method, path, device, body), d.key, counter);
        } catch (Fail f) {
            throw f.with(d.key, counter);
        } catch (JSONException e) {
            throw new Fail(400, "bad_request", e.getMessage()).with(d.key, counter);
        }
    }

    static String header(Map<String, String> h, String name) {
        String v = h.get(name);
        return v == null ? "" : v.trim();
    }

    Response pair(String device, long counter, String sig, byte[] body) throws Fail {
        Store.Pairing pr = store.pairing(clock.wallMs());
        if (pr == null) throw new Fail(403, "no_pairing", "no pairing code on the car's screen", false);
        Integer tries = attempts.get(pr.code);
        JSONObject result = tries == null ? store.pairingResult() : null;
        if (result != null && pr.code.equals(result.optString("code")) && "locked".equals(result.optString("state"))) {
            tries = MAX_ATTEMPTS;  // locked before this service restarted
        }
        if (tries != null && tries >= MAX_ATTEMPTS) {
            throw new Fail(403, "pairing_locked", "too many wrong codes: show a new one", false);
        }
        byte[] key = Proto.deviceKey(pr.code, device);
        if (!Proto.same(Proto.signRequest(key, "POST", "/v1/pair", device, counter, body), sig)) {
            int n = tries == null ? 1 : tries + 1;
            attempts.put(pr.code, n);
            if (n >= MAX_ATTEMPTS) {
                store.closePairing(pr.code, "locked", null);
                throw new Fail(403, "pairing_locked", "too many wrong codes: show a new one", false);
            }
            throw new Fail(401, "unauthorized", "wrong pairing code", false);
        }
        String name;
        try {
            JSONObject o = object(body, "device_id", "device_name");
            name = o.opt("device_name") instanceof String ? o.getString("device_name") : null;
            if (!device.equals(o.opt("device_id"))) throw new Fail(400, "bad_request", "device_id doesn't match X-Ir2-Device");
            if (name == null || name.length() < 1 || name.length() > 40) throw new Fail(400, "bad_request", "device_name: 1-40 characters");
            if (!devices.containsKey(device) && devices.size() >= MAX_DEVICES) {
                throw new Fail(403, "too_many_devices", "4 phones are paired: remove one in the car app");
            }
        } catch (Fail f) {
            throw f.with(key, counter);
        } catch (JSONException e) {
            throw new Fail(400, "bad_request", e.getMessage()).with(key, counter);
        }
        devices.put(device, new Store.Device(device, name, key, counter, clock.wallMs()));
        saveDevices();
        attempts.remove(pr.code);
        store.closePairing(pr.code, "paired", name);
        log("paired " + name);
        try {
            return new Response(200, new JSONObject().put("paired", true).put("name", valuesOrDefaults().optString("car_name")), key, counter);
        } catch (JSONException e) {
            throw new IllegalStateException(e);
        }
    }

    JSONObject route(String method, String path, String device, byte[] body) throws Fail, JSONException {
        if ("POST".equals(method) && "/v1/unpair".equals(path)) {
            devices.remove(device);
            saveDevices();
            return new JSONObject().put("unpaired", true);
        }
        if ("GET".equals(method) && "/v1/status".equals(path)) {
            Boolean p = car.parked();
            JSONObject amb = new JSONObject();
            amb.put("holding", holding);
            amb.put("color", ambientColor == null ? JSONObject.NULL : ambientColor);
            amb.put("brightness", ambientBrightness == null ? JSONObject.NULL : ambientBrightness);
            JSONObject guard = new JSONObject().put("only_in_park", values(false).optBoolean("only_in_park", true));
            return new JSONObject().put("parked", p == null ? JSONObject.NULL : p).put("ambient", amb).put("guard", guard);
        }
        if ("GET".equals(method) && "/v1/settings".equals(path)) return settings();
        if ("PUT".equals(method) && "/v1/settings".equals(path)) {
            JSONObject o = object(body, "values");
            if (!(o.opt("values") instanceof JSONObject)) throw new Fail(400, "bad_request", "values: an object");
            JSONObject in = o.getJSONObject("values");
            JSONObject next = new JSONObject(values(true).toString());
            Iterator<?> it = in.keys();
            while (it.hasNext()) {
                String k = (String) it.next();
                next.put(k, check(k, in.get(k)));
            }
            saveValues(next);
            return settings();
        }
        if ("POST".equals(method) && "/v1/ambient".equals(path)) return ambient(object(body, "color", "brightness", "save"));
        if ("POST".equals(method) && "/v1/ambient/release".equals(path)) {
            String msg = carAmbient("release");
            if (!msg.startsWith("ok")) throw new Fail(403, "refused", msg);
            holding = false;
            return new JSONObject().put("released", true);
        }
        throw new Fail(404, "not_found", "no such endpoint");
    }

    JSONObject settings() throws Fail, JSONException {
        JSONObject v = values(false);
        JSONArray shown = new JSONArray();
        JSONObject vals = new JSONObject();
        for (int i = 0; i < schema.length(); i++) {
            JSONObject s = schema.getJSONObject(i);
            if (s.optBoolean("private")) continue;
            shown.put(s);
            String k = s.getString("key");
            vals.put(k, v.has(k) ? v.get(k) : s.opt("default"));
        }
        return new JSONObject().put("schema", shown).put("values", vals);
    }

    Object check(String key, Object v) throws Fail, JSONException {
        JSONObject s = null;
        for (int i = 0; i < schema.length(); i++) {
            JSONObject e = schema.getJSONObject(i);
            if (key.equals(e.optString("key")) && !e.optBoolean("private")) s = e;
        }
        if (s == null) throw new Fail(400, "bad_request", "unknown setting: " + key);
        String t = s.optString("type", "text");
        if ("toggle".equals(t)) {
            if (!(v instanceof Boolean)) throw new Fail(400, "bad_request", key + ": true or false");
        } else if ("number".equals(t)) {
            if (!(v instanceof Integer) && !(v instanceof Long)) throw new Fail(400, "bad_request", key + ": a whole number");
            long n = ((Number) v).longValue();
            if ((s.has("min") && n < s.getLong("min")) || (s.has("max") && n > s.getLong("max"))) {
                throw new Fail(400, "bad_request", key + ": " + s.optString("min") + "-" + s.optString("max"));
            }
        } else if ("choice".equals(t)) {
            JSONArray opts = s.optJSONArray("options");
            boolean found = false;
            for (int i = 0; opts != null && i < opts.length(); i++) {
                JSONObject o = opts.optJSONObject(i);
                if (o != null && o.opt("value") != null && o.opt("value").equals(v)) found = true;
            }
            if (!found) throw new Fail(400, "bad_request", key + ": not one of the choices");
        } else {
            int max = s.optInt("max_length", 200);
            if (!(v instanceof String) || ((String) v).length() > max) {
                throw new Fail(400, "bad_request", key + ": text up to " + max + " characters");
            }
            if (s.has("pattern") && !Pattern.compile(s.getString("pattern")).matcher((String) v).matches()) {
                throw new Fail(400, "bad_request", key + ": not in the expected form");
            }
        }
        return v;
    }

    JSONObject ambient(JSONObject o) throws Fail, JSONException {
        Object color = o.opt("color"), bright = o.opt("brightness"), save = o.has("save") ? o.opt("save") : Boolean.FALSE;
        if (color == null && bright == null) throw new Fail(400, "bad_request", "color or brightness");
        if (color != null && (!(color instanceof String) || !HEX6.matcher((String) color).matches())) {
            throw new Fail(400, "bad_request", "color: 6 lowercase hex digits");
        }
        if (bright != null && (!(bright instanceof Integer) || (Integer) bright < 0 || (Integer) bright > 10)) {
            throw new Fail(400, "bad_request", "brightness: 0-10");
        }
        if (!(save instanceof Boolean)) throw new Fail(400, "bad_request", "save: true or false");
        if (values(false).optBoolean("only_in_park", true)) {
            Boolean p = car.parked();
            if (p == null || !p) throw new Fail(403, "not_parked", p == null ? "the car didn't say it's in P" : "the car isn't in P");
        }
        long now = clock.monoMs();
        if (now - lastAmbient < AMBIENT_GAP_MS) throw new Fail(429, "slow_down", "at most 5 changes a second");
        lastAmbient = now;

        StringBuilder msgs = new StringBuilder();
        String sent = null;
        boolean nearest = false;
        if (color != null) {
            String msg = carAmbient("color", (String) color);
            if (!msg.startsWith("ok")) throw new Fail(403, "refused", msg);
            Matcher m = OK_COLOR.matcher(msg);
            sent = m.matches() ? m.group(1) : (String) color;
            nearest = !sent.equals(color);
            msgs.append(msg);
            holding = true;
            ambientColor = sent;
        }
        if (bright != null) {
            String msg = carAmbient("brightness", String.valueOf(bright));
            if (!msg.startsWith("ok")) throw new Fail(403, "refused", msg);
            if (msgs.length() > 0) msgs.append("; ");
            msgs.append(msg);
            holding = true;
            ambientBrightness = (Integer) bright;
        }
        if ((Boolean) save) {
            JSONObject next = new JSONObject(values(true).toString());
            if (sent != null) next.put("ambient_color", sent);
            if (bright != null) next.put("ambient_brightness", bright);
            saveValues(next);
        }
        JSONObject r = new JSONObject();
        r.put("color", sent == null ? JSONObject.NULL : sent);
        r.put("brightness", bright == null ? JSONObject.NULL : bright);
        r.put("nearest", nearest);
        r.put("message", msgs.toString());
        return r;
    }

    String carAmbient(String... args) throws Fail {
        try {
            return car.ambient(args);
        } catch (IOException e) {
            throw new Fail(503, "car_unavailable", "HMG-API didn't answer: " + e.getMessage());
        }
    }

    // --- settings values ----------------------------------------------------------------

    /** the values, with defaults filled in; from hmgapid at most every 2 s unless fresh is asked for */
    JSONObject values(boolean fresh) throws Fail {
        long now = clock.monoMs();
        if (fresh || values == null || now - valuesAt > SETTINGS_CACHE_MS) {
            try {
                values = withDefaults(car.loadSettings());
                valuesAt = now;
            } catch (IOException e) {
                throw new Fail(503, "car_unavailable", "HMG-API didn't answer: " + e.getMessage());
            } catch (JSONException e) {
                throw new Fail(503, "car_unavailable", "settings: " + e.getMessage());
            }
        }
        return values;
    }

    /** for /v1/info, which mustn't fail: the cached values, or the defaults */
    JSONObject valuesOrDefaults() {
        try {
            return values(false);
        } catch (Fail f) {
            try {
                return withDefaults(new JSONObject());
            } catch (JSONException e) {
                return new JSONObject();
            }
        }
    }

    JSONObject withDefaults(JSONObject v) throws JSONException {
        JSONObject out = new JSONObject(v.toString());
        for (int i = 0; i < schema.length(); i++) {
            JSONObject s = schema.getJSONObject(i);
            String k = s.getString("key");
            if (!out.has(k) && s.has("default")) out.put(k, s.get("default"));
        }
        return out;
    }

    void saveValues(JSONObject next) throws Fail {
        try {
            car.saveSettings(next);
            values = next;
            valuesAt = clock.monoMs();
        } catch (IOException e) {
            throw new Fail(503, "car_unavailable", "HMG-API didn't save: " + e.getMessage());
        }
    }

    void saveDevices() {
        try {
            store.saveDevices(devices);
        } catch (IOException e) {
            log("can't save devices: " + e.getMessage());
        }
    }

    static JSONObject object(byte[] body, String... allowed) throws Fail {
        Object o;
        try {
            o = body.length == 0 ? new JSONObject() : new JSONTokener(new String(body, "UTF-8")).nextValue();
        } catch (Exception e) {
            throw new Fail(400, "bad_request", "body isn't JSON");
        }
        if (!(o instanceof JSONObject)) throw new Fail(400, "bad_request", "body isn't a JSON object");
        JSONObject j = (JSONObject) o;
        Iterator<?> it = j.keys();
        while (it.hasNext()) {
            String k = (String) it.next();
            boolean ok = false;
            for (String a : allowed) ok |= a.equals(k);
            if (!ok) throw new Fail(400, "bad_request", "unknown field: " + k);
        }
        return j;
    }

    static void log(String s) {
        System.out.println("ir2-companion: " + s);
        System.out.flush();
    }
}
