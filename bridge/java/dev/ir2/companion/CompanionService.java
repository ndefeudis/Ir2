package dev.ir2.companion;

import java.io.File;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * The mod's service (mod.json "services"): runs as the car app's uid, started by HMG-API once
 * Android is up, restarted if it stops. Argument: the car app's files folder.
 */
public final class CompanionService {
    private CompanionService() {}

    public static void main(String[] args) throws Exception {
        File dir = new File(args.length > 0 ? args[0] : "/data/data/dev.ir2.companion/files");
        String modDir = System.getenv("HMGAPI_MOD_DIR");
        File schemaFile = new File(modDir == null ? "." : modDir, "settings.json");
        JSONObject sj = Store.readJson(schemaFile);
        JSONArray schema = sj == null ? null : sj.optJSONArray("settings");
        if (schema == null) {
            Bridge.log("no settings.json at " + schemaFile);
            System.exit(1);
        }

        final Bridge bridge = new Bridge(new HmgapidCar(), new Store(dir), schema, Bridge.SYSTEM_CLOCK);
        bridge.start();

        Thread sync = new Thread(new Runnable() {
            public void run() {
                while (true) {
                    try {
                        Thread.sleep(2000);
                    } catch (InterruptedException e) {
                        return;
                    }
                    bridge.syncRevocations();
                }
            }
        }, "ir2-sync");
        sync.setDaemon(true);
        sync.start();

        HttpServer server = new HttpServer(bridge, "0.0.0.0", Proto.PORT, false);
        Bridge.log("version " + Bridge.VERSION + ", listening on " + server.port() + " (hotspot peers only)");
        server.serve();
    }
}
