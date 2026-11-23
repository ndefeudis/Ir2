package dev.ir2.companion;

import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;

import org.json.JSONArray;
import org.json.JSONObject;
import org.json.JSONTokener;

/**
 * The real bridge on a desktop JVM, with a fake car: what tools/fakecar/test_protocol.py runs
 * the protocol tests against (IR2_SERVER_CMD). Same arguments and stdin commands as the
 * Python fake head unit.
 */
public final class DevMain {
    private DevMain() {}

    static final class FakeCar implements Car {
        volatile Boolean parked = Boolean.TRUE;
        volatile boolean blocked;
        String holder;
        JSONObject saved = new JSONObject();

        static final int[] PALETTE = {
            0x1043f4, 0x102ef2, 0x1020ef, 0x211cef, 0x2f1cef, 0x401cef, 0x521cef, 0x641cef,
            0x781cef, 0x881def, 0x9b21ef, 0xa923ef, 0xb723ea, 0xc121e0, 0xcc1fd2, 0xd51bc0,
            0xdd17ae, 0xe41399, 0xeb0e99, 0xef0a74, 0xf60660, 0xfa0451, 0xfe0145, 0xff321d,
            0xff4423, 0xff5027, 0xff6930, 0xff7835, 0xff8f3e, 0xffa646, 0xffc04f, 0xffd356,
            0xffe55c, 0xfff362, 0xfefd66, 0xffffff, 0xf4fd66, 0xe8fd66, 0xd9fd66, 0xcbfd63,
            0xb7f962, 0xa8f362, 0x95eb62, 0x84e562, 0x75df62, 0x68dd62, 0x5dde69, 0x51e176,
            0x47e785, 0x3eee98, 0x35f5a9, 0x2cfabd, 0x25facf, 0x1efae1, 0x19faed, 0x14faf9,
            0x10f4fc, 0x10e6fc, 0x10d2fc, 0x10bbfc, 0x10a3fc, 0x108afc, 0x106ffc, 0x1059f8,
        };

        static int nearest(int rgb) {
            int best = PALETTE[0];
            long bestD = Long.MAX_VALUE;
            for (int c : PALETTE) {
                int dr = (c >> 16 & 255) - (rgb >> 16 & 255), dg = (c >> 8 & 255) - (rgb >> 8 & 255), db = (c & 255) - (rgb & 255);
                long d = (long) dr * dr + dg * dg + db * db;
                if (d < bestD) {
                    bestD = d;
                    best = c;
                }
            }
            return best;
        }

        public synchronized String ambient(String... a) {
            if (blocked && !"release".equals(a[0])) return "refused: the owner turned off mod light control (HMG-API app)";
            if ("release".equals(a[0])) {
                if (holder == null) return "ok not holding the light";
                holder = null;
                return "ok released";
            }
            holder = "ir2-companion";
            if ("color".equals(a[0])) {
                String sent = String.format("%06x", nearest(Integer.parseInt(a[1], 16)));
                return "ok color " + sent + (sent.equals(a[1]) ? "" : " (the car's nearest to " + a[1] + ")");
            }
            if ("brightness".equals(a[0])) return "ok brightness " + a[1];
            return "refused: ambient_light color <rrggbb>|brightness <0-10>|release|owner_change release|keep";
        }

        public Boolean parked() {
            return parked;
        }

        public synchronized JSONObject loadSettings() throws IOException {
            try {
                return new JSONObject(saved.toString());
            } catch (org.json.JSONException e) {
                throw new IOException(e.getMessage());
            }
        }

        public synchronized void saveSettings(JSONObject values) throws IOException {
            try {
                saved = new JSONObject(values.toString());
            } catch (org.json.JSONException e) {
                throw new IOException(e.getMessage());
            }
        }
    }

    public static void main(String[] args) throws Exception {
        String host = "0.0.0.0", pairCode = null, settings = "bridge/settings.json";
        int port = Proto.PORT;
        FakeCar car = new FakeCar();
        for (int i = 0; i < args.length; i++) {
            String a = args[i];
            if ("--host".equals(a)) host = args[++i];
            else if ("--port".equals(a)) port = Integer.parseInt(args[++i]);
            else if ("--pair-code".equals(a)) pairCode = args[++i];
            else if ("--settings".equals(a)) settings = args[++i];
            else if ("--parked".equals(a)) car.parked = parked(args[++i]);
            else if ("--set".equals(a)) {
                String kv = args[++i];
                int eq = kv.indexOf('=');
                car.saved.put(kv.substring(0, eq), new JSONTokener(kv.substring(eq + 1)).nextValue());
            } else throw new IllegalArgumentException("unknown argument " + a);
        }
        JSONObject sj = Store.readJson(new File(settings));
        if (sj == null) throw new IOException("can't read " + settings);
        JSONArray schema = sj.getJSONArray("settings");

        File dir = File.createTempFile("ir2-dev", "");
        dir.delete();
        Store store = new Store(dir);
        final Bridge bridge = new Bridge(car, store, schema, Bridge.SYSTEM_CLOCK);
        bridge.start();
        final HttpServer server = new HttpServer(bridge, host, port, false);
        System.out.println("LISTENING " + server.port());
        if (pairCode != null) System.out.println("PAIRING " + Proto.showCode(store.openPairing(System.currentTimeMillis(), pairCode)));
        System.out.flush();
        Thread t = new Thread(new Runnable() {
            public void run() {
                server.serve();
            }
        }, "ir2-serve");
        t.setDaemon(true);
        t.start();

        BufferedReader in = new BufferedReader(new InputStreamReader(System.in, "UTF-8"));
        String line;
        while ((line = in.readLine()) != null) {
            String[] c = line.trim().split("\\s+");
            if (c[0].length() == 0) continue;
            if ("pair".equals(c[0])) {
                System.out.println("PAIRING " + Proto.showCode(store.openPairing(System.currentTimeMillis())));
            } else if ("park".equals(c[0]) && c.length == 2) {
                car.parked = parked(c[1]);
                System.out.println("parked: " + car.parked);
            } else if ("block".equals(c[0]) && c.length == 2) {
                car.blocked = "on".equals(c[1]);
                System.out.println("light control blocked: " + car.blocked);
            } else if ("revoke".equals(c[0]) && c.length == 2) {
                store.revoke(c[1]);
                System.out.println("revoked: " + c[1]);
            } else if ("quit".equals(c[0])) {
                break;
            } else {
                System.out.println("pair | park yes|no|unknown | block on|off | revoke <device id> | quit");
            }
            System.out.flush();
        }
        if (line != null) {
            server.close();
            return;
        }
        Thread.sleep(Long.MAX_VALUE);
    }

    static Boolean parked(String s) {
        return "yes".equals(s) ? Boolean.TRUE : "no".equals(s) ? Boolean.FALSE : null;
    }
}
