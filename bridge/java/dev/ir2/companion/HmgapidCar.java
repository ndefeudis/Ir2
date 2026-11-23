package dev.ir2.companion;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;

import org.json.JSONException;
import org.json.JSONObject;

/**
 * The car through HMG-API's client, /system/bin/hmgapid. hmgapid knows this service by its
 * session and answers for this mod only: its own settings, the readings and commands its
 * mod.json lists. No root.
 */
public final class HmgapidCar implements Car {
    static final String HMGAPID = "/system/bin/hmgapid";

    static final class Result {
        final int code;
        final String text;

        Result(int code, String text) {
            this.code = code;
            this.text = text;
        }
    }

    Result run(String... args) throws IOException {
        String[] cmd = new String[args.length + 1];
        cmd[0] = HMGAPID;
        System.arraycopy(args, 0, cmd, 1, args.length);
        Process p = new ProcessBuilder(cmd).redirectErrorStream(true).start();
        try {
            p.getOutputStream().close();
            InputStream in = p.getInputStream();
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) > 0 && out.size() < 256 * 1024) out.write(buf, 0, n);
            int code = p.waitFor();
            return new Result(code, out.toString("UTF-8").trim());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IOException("interrupted");
        } finally {
            p.destroy();
        }
    }

    @Override
    public String ambient(String... args) throws IOException {
        String[] a = new String[args.length + 2];
        a[0] = "vehicle-do";
        a[1] = "ambient_light";
        System.arraycopy(args, 0, a, 2, args.length);
        Result r = run(a);
        if (r.code == 0 || r.text.startsWith("refused")) return r.text;
        throw new IOException("hmgapid vehicle-do: exit " + r.code + ": " + r.text);
    }

    @Override
    public Boolean parked() {
        try {
            Result r = run("vehicle", "gear.park");
            if (r.code != 0) return null;
            for (String l : r.text.split("\n")) {
                String t = l.trim();
                if (t.equals("gear.park 1")) return Boolean.TRUE;
                if (t.equals("gear.park 0")) return Boolean.FALSE;
            }
        } catch (IOException e) {
            // no answer
        }
        return null;
    }

    @Override
    public JSONObject loadSettings() throws IOException {
        Result r = run("setting-get");
        if (r.code != 0) throw new IOException("hmgapid setting-get: exit " + r.code + ": " + r.text);
        try {
            return new JSONObject(r.text.length() == 0 ? "{}" : r.text);
        } catch (JSONException e) {
            throw new IOException("settings aren't JSON: " + e.getMessage());
        }
    }

    @Override
    public void saveSettings(JSONObject values) throws IOException {
        Result r = run("setting-set", values.toString());
        if (r.code != 0) throw new IOException("hmgapid setting-set: exit " + r.code + ": " + r.text);
    }
}
