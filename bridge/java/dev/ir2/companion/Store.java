package dev.ir2.companion;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * The bridge's files, in the car app's own folder (/data/data/dev.ir2.companion/files): the
 * service and the app run as the same uid, and nothing else can read them.
 *
 * <ul>
 * <li>{@code devices.json}: paired phones, their keys and counters. Written by the service only.</li>
 * <li>{@code pairing.json}: the code on the car's screen. Written by the app; the service deletes it once used.</li>
 * <li>{@code pairing-result.json}: what became of that code (paired / locked), for the app's screen. The service's.</li>
 * <li>{@code revoke/<device id>}: the app asks to remove a phone; the service does it and deletes the file.</li>
 * </ul>
 */
public final class Store {
    public static final long PAIRING_TTL_MS = 5 * 60 * 1000;

    public static final class Device {
        public final String id, name;
        public final byte[] key;
        public long counter;
        public final long pairedAt;

        public Device(String id, String name, byte[] key, long counter, long pairedAt) {
            this.id = id;
            this.name = name;
            this.key = key;
            this.counter = counter;
            this.pairedAt = pairedAt;
        }
    }

    public static final class Pairing {
        public final String code;
        public final long expires;

        Pairing(String code, long expires) {
            this.code = code;
            this.expires = expires;
        }
    }

    final File dir;

    public Store(File dir) {
        this.dir = dir;
        dir.mkdirs();
    }

    // --- devices (service) -----------------------------------------------------------

    public Map<String, Device> loadDevices() {
        Map<String, Device> out = new LinkedHashMap<String, Device>();
        JSONObject o = readJson(new File(dir, "devices.json"));
        JSONArray a = o == null ? null : o.optJSONArray("devices");
        if (a == null) return out;
        for (int i = 0; i < a.length(); i++) {
            JSONObject d = a.optJSONObject(i);
            if (d == null) continue;
            String id = d.optString("id"), key = d.optString("key");
            if (!id.matches("[0-9a-f]{32}") || !key.matches("[0-9a-f]{64}")) continue;
            out.put(id, new Device(id, d.optString("name"), Proto.unhex(key), d.optLong("counter"), d.optLong("paired_at")));
        }
        return out;
    }

    public void saveDevices(Map<String, Device> devices) throws IOException {
        JSONArray a = new JSONArray();
        try {
            for (Device d : devices.values()) {
                JSONObject o = new JSONObject();
                o.put("id", d.id);
                o.put("name", d.name);
                o.put("key", Proto.hex(d.key));
                o.put("counter", d.counter);
                o.put("paired_at", d.pairedAt);
                a.put(o);
            }
            writeJson(new File(dir, "devices.json"), new JSONObject().put("devices", a));
        } catch (JSONException e) {
            throw new IOException(e.getMessage());
        }
    }

    /** device ids the app asked to remove; their files are deleted as they're read */
    public List<String> takeRevocations() {
        List<String> out = new ArrayList<String>();
        File[] fs = new File(dir, "revoke").listFiles();
        if (fs == null) return out;
        for (File f : fs) {
            if (f.getName().matches("[0-9a-f]{32}")) out.add(f.getName());
            f.delete();
        }
        return out;
    }

    // --- pairing (app writes, service reads) -------------------------------------------

    /** the code on the screen, or null when there's none, it has run out, or the file looks wrong */
    public Pairing pairing(long now) {
        JSONObject o = readJson(new File(dir, "pairing.json"));
        if (o == null) return null;
        String code = Proto.normalizeCode(o.optString("code"));
        long expires = o.optLong("expires");
        if (code.length() != 16 || expires <= now || expires > now + PAIRING_TTL_MS + 60000) return null;
        for (int i = 0; i < 16; i++) if (Proto.CROCKFORD.indexOf(code.charAt(i)) < 0) return null;
        return new Pairing(code, expires);
    }

    /** the car app's "Pair a phone": a new code, valid five minutes */
    public String openPairing(long now) throws IOException {
        return openPairing(now, Proto.newCode());
    }

    /** the same with a given code (off-car tests) */
    public String openPairing(long now, String code) throws IOException {
        code = Proto.normalizeCode(code);
        try {
            new File(dir, "pairing-result.json").delete();
            writeJson(new File(dir, "pairing.json"), new JSONObject().put("code", code).put("expires", now + PAIRING_TTL_MS));
        } catch (JSONException e) {
            throw new IOException(e.getMessage());
        }
        return code;
    }

    /** what became of a code: "paired" ends it; "locked" keeps it on screen, refused, until a new one */
    public void closePairing(String code, String state, String deviceName) {
        if ("paired".equals(state)) new File(dir, "pairing.json").delete();
        try {
            writeJson(new File(dir, "pairing-result.json"), new JSONObject()
                    .put("code", code).put("state", state).put("device_name", deviceName == null ? "" : deviceName));
        } catch (JSONException e) {
            // nothing to show
        } catch (IOException e) {
            // nothing to show
        }
    }

    public JSONObject pairingResult() {
        return readJson(new File(dir, "pairing-result.json"));
    }

    public void revoke(String deviceId) throws IOException {
        File d = new File(dir, "revoke");
        d.mkdirs();
        if (!new File(d, deviceId).createNewFile() && !new File(d, deviceId).exists()) throw new IOException("can't write " + d);
    }

    // --- files ---------------------------------------------------------------------------

    static JSONObject readJson(File f) {
        if (!f.isFile() || f.length() > 256 * 1024) return null;
        FileInputStream in = null;
        try {
            in = new FileInputStream(f);
            byte[] b = new byte[(int) f.length()];
            int off = 0, n;
            while (off < b.length && (n = in.read(b, off, b.length - off)) > 0) off += n;
            return new JSONObject(new String(b, 0, off, "UTF-8"));
        } catch (IOException e) {
            return null;
        } catch (JSONException e) {
            return null;
        } finally {
            close(in);
        }
    }

    /** write to a temporary file, then rename over: a crash never leaves half a file */
    static void writeJson(File f, JSONObject o) throws IOException {
        File tmp = new File(f.getPath() + ".tmp");
        FileOutputStream out = new FileOutputStream(tmp);
        try {
            out.write(Proto.utf8(o.toString()));
            out.getFD().sync();
        } finally {
            out.close();
        }
        if (!tmp.renameTo(f)) {
            tmp.delete();
            throw new IOException("can't replace " + f);
        }
    }

    static void close(java.io.Closeable c) {
        if (c == null) return;
        try {
            c.close();
        } catch (IOException e) {
            // ignore
        }
    }
}
