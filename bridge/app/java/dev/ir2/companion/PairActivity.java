package dev.ir2.companion;

import java.io.IOException;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.text.DateFormat;
import java.util.Collections;
import java.util.Date;
import java.util.Map;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Bundle;
import android.os.Handler;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import org.json.JSONObject;

/**
 * The car's screen for Ir2 Companion: pair a phone (a one-time code, five minutes), see the
 * paired phones and remove one. Built in code, sized for the 1920x720 screen.
 */
public final class PairActivity extends Activity {
    static final int BG = Color.rgb(16, 18, 22), TEXT = Color.rgb(235, 238, 242), GREY = Color.rgb(150, 156, 166),
            ACCENT = Color.rgb(64, 160, 255), WARN = Color.rgb(255, 170, 60);

    final Handler handler = new Handler();
    Store store;
    TextView address, code, codeNote;
    LinearLayout phones;
    String shownCode;
    long shownUntil;

    final Runnable tick = new Runnable() {
        public void run() {
            refresh();
            handler.postDelayed(this, 1000);
        }
    };

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        store = new Store(getFilesDir());

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.HORIZONTAL);
        root.setBackgroundColor(BG);
        root.setPadding(48, 32, 48, 32);

        LinearLayout left = column();
        left.addView(text("Pair an iPhone", 34, TEXT, true));
        left.addView(text("On the iPhone: connect it to this car's Wi-Fi (wireless CarPlay does that), open the "
                + "Ir2 app, and type the code below.", 20, GREY, false));
        address = text("", 22, TEXT, false);
        left.addView(address);
        code = text("", 64, ACCENT, true);
        code.setTypeface(Typeface.MONOSPACE, Typeface.BOLD);
        code.setPadding(0, 24, 0, 8);
        left.addView(code);
        codeNote = text("", 20, GREY, false);
        left.addView(codeNote);
        Button pair = button("Pair a phone");
        pair.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                try {
                    long now = System.currentTimeMillis();
                    shownCode = store.openPairing(now);
                    shownUntil = now + Store.PAIRING_TTL_MS;
                } catch (IOException e) {
                    codeNote.setText("Can't save the code: " + e.getMessage());
                }
                refresh();
            }
        });
        left.addView(pair);

        LinearLayout right = column();
        right.addView(text("Paired phones", 34, TEXT, true));
        phones = column();
        ScrollView sv = new ScrollView(this);
        sv.addView(phones);
        right.addView(sv);

        root.addView(left, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1.2f));
        root.addView(right, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f));
        setContentView(root);
    }

    @Override
    protected void onResume() {
        super.onResume();
        handler.post(tick);
    }

    @Override
    protected void onPause() {
        handler.removeCallbacks(tick);
        super.onPause();
    }

    void refresh() {
        address.setText("Car address for the app: " + hotspotAddress() + "  (port " + Proto.PORT + ")");
        long now = System.currentTimeMillis();
        JSONObject result = store.pairingResult();
        boolean resultForShown = result != null && shownCode != null && shownCode.equals(result.optString("code"));
        if (resultForShown && "paired".equals(result.optString("state"))) {
            code.setText("Paired");
            codeNote.setText("with " + result.optString("device_name") + ".");
        } else if (resultForShown && "locked".equals(result.optString("state"))) {
            code.setText("Locked");
            codeNote.setTextColor(WARN);
            codeNote.setText("Five wrong codes were tried. Tap Pair a phone for a new one.");
        } else if (shownCode != null && now < shownUntil && store.pairing(now) != null) {
            code.setText(Proto.showCode(shownCode));
            codeNote.setTextColor(GREY);
            codeNote.setText("Valid for " + ((shownUntil - now) / 1000) + " s. It works once.");
        } else {
            code.setText("");
            codeNote.setTextColor(GREY);
            codeNote.setText("Tap Pair a phone to show a code.");
        }

        phones.removeAllViews();
        Map<String, Store.Device> devices = store.loadDevices();
        if (devices.isEmpty()) phones.addView(text("None yet.", 22, GREY, false));
        DateFormat df = DateFormat.getDateInstance(DateFormat.MEDIUM);
        for (final Store.Device d : devices.values()) {
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(0, 12, 0, 12);
            TextView name = text(d.name + "\npaired " + df.format(new Date(d.pairedAt)), 22, TEXT, false);
            row.addView(name, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
            Button remove = button("Remove");
            remove.setOnClickListener(new View.OnClickListener() {
                public void onClick(View v) {
                    try {
                        store.revoke(d.id);
                        v.setEnabled(false);
                        ((Button) v).setText("Removing…");
                    } catch (IOException e) {
                        ((Button) v).setText("Failed");
                    }
                }
            });
            row.addView(remove);
            phones.addView(row);
        }
    }

    /** the car's Wi-Fi address (wlan0 or the access point's interface), or the stock one */
    static String hotspotAddress() {
        try {
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                String n = ni.getName();
                if (!n.startsWith("wlan") && !n.startsWith("ap")) continue;
                for (InetAddress a : Collections.list(ni.getInetAddresses())) {
                    if (a instanceof Inet4Address && !a.isLoopbackAddress()) return a.getHostAddress();
                }
            }
        } catch (Exception e) {
            // fall through
        }
        return "192.168.0.1";
    }

    LinearLayout column() {
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.VERTICAL);
        l.setPadding(0, 0, 32, 0);
        return l;
    }

    TextView text(String s, int sp, int color, boolean bold) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color);
        if (bold) t.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        t.setPadding(0, 6, 0, 6);
        return t;
    }

    Button button(String s) {
        Button b = new Button(this);
        b.setText(s);
        b.setTextSize(24);
        b.setPadding(40, 20, 40, 20);
        return b;
    }
}
