package dev.ir2.companion;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.Semaphore;

/**
 * A small HTTP/1.1 server: one request per connection, Content-Length bodies only, at most
 * 4 connections at once, 10 s to send a request. Only peers on the car's hotspot
 * (192.168.0.0/24, IPv6 link-local) and loopback get an answer.
 */
public final class HttpServer {
    static final int MAX_HEAD = 8 * 1024;
    static final int TIMEOUT_MS = 10000;

    final Bridge bridge;
    final ServerSocket socket;
    final Semaphore slots = new Semaphore(4);
    final boolean anyPeer;

    public HttpServer(Bridge bridge, String host, int port, boolean anyPeer) throws IOException {
        this.bridge = bridge;
        this.anyPeer = anyPeer;
        socket = new ServerSocket();
        socket.setReuseAddress(true);
        socket.bind(new InetSocketAddress(InetAddress.getByName(host), port), 8);
    }

    public int port() {
        return socket.getLocalPort();
    }

    /** accepts until the socket is closed */
    public void serve() {
        while (!socket.isClosed()) {
            final Socket s;
            try {
                s = socket.accept();
            } catch (IOException e) {
                if (socket.isClosed()) return;
                Bridge.log("accept: " + e.getMessage());
                continue;
            }
            if (!allowed(s.getInetAddress()) || !slots.tryAcquire()) {
                Store.close(s);
                continue;
            }
            Thread t = new Thread(new Runnable() {
                public void run() {
                    try {
                        serve(s);
                    } finally {
                        Store.close(s);
                        slots.release();
                    }
                }
            }, "ir2-http");
            t.setDaemon(true);
            t.start();
        }
    }

    public void close() {
        Store.close(socket);
    }

    boolean allowed(InetAddress a) {
        if (anyPeer || a.isLoopbackAddress()) return true;
        if (a instanceof Inet4Address) {
            byte[] b = a.getAddress();
            return (b[0] & 255) == 192 && (b[1] & 255) == 168 && b[2] == 0;
        }
        return a instanceof Inet6Address && a.isLinkLocalAddress();
    }

    void serve(Socket s) {
        try {
            s.setSoTimeout(TIMEOUT_MS);
            InputStream in = s.getInputStream();
            String head = readHead(in);
            if (head == null) {
                write(s.getOutputStream(), 400, Bridge.error("bad_request", "malformed request"), null, 0);
                return;
            }
            String[] lines = head.split("\r\n");
            String[] first = lines[0].split(" ");
            if (first.length != 3 || !first[2].startsWith("HTTP/1.")) {
                write(s.getOutputStream(), 400, Bridge.error("bad_request", "malformed request line"), null, 0);
                return;
            }
            Map<String, String> headers = new HashMap<String, String>();
            for (int i = 1; i < lines.length; i++) {
                int c = lines[i].indexOf(':');
                if (c > 0) headers.put(lines[i].substring(0, c).trim().toLowerCase(Locale.US), lines[i].substring(c + 1).trim());
            }
            if (headers.containsKey("transfer-encoding")) {
                write(s.getOutputStream(), 400, Bridge.error("bad_request", "no chunked bodies"), null, 0);
                return;
            }
            int length;
            try {
                length = headers.containsKey("content-length") ? Integer.parseInt(headers.get("content-length")) : 0;
            } catch (NumberFormatException e) {
                length = -1;
            }
            if (length < 0 || length > Bridge.MAX_BODY) {
                write(s.getOutputStream(), 413, Bridge.error("too_large", "body over 16 KiB"), null, 0);
                return;
            }
            byte[] body = new byte[length];
            int off = 0;
            while (off < length) {
                int n = in.read(body, off, length - off);
                if (n < 0) return;
                off += n;
            }
            Bridge.Response r = bridge.handle(first[0].toUpperCase(Locale.US), first[1], headers, body);
            write(s.getOutputStream(), r.status, r.body, r.key, r.counter);
        } catch (IOException e) {
            // the phone went away
        }
    }

    /** the request line and headers, up to the empty line; null if too long or cut short */
    static String readHead(InputStream in) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        int state = 0;
        while (b.size() < MAX_HEAD) {
            int c = in.read();
            if (c < 0) return null;
            b.write(c);
            if (c == '\r' && (state == 0 || state == 2)) state++;
            else if (c == '\n' && (state == 1 || state == 3)) state++;
            else state = 0;
            if (state == 4) {
                String h = b.toString("ISO-8859-1");
                return h.substring(0, h.length() - 4);
            }
        }
        return null;
    }

    static void write(OutputStream out, int status, org.json.JSONObject body, byte[] key, long counter) throws IOException {
        byte[] data = Proto.utf8(body.toString());
        StringBuilder h = new StringBuilder();
        h.append("HTTP/1.1 ").append(status).append(' ').append(reason(status)).append("\r\n");
        h.append("Content-Type: application/json\r\n");
        h.append("Content-Length: ").append(data.length).append("\r\n");
        h.append("Connection: close\r\n");
        if (key != null) h.append("X-Ir2-Signature: ").append(Proto.signResponse(key, counter, status, data)).append("\r\n");
        h.append("\r\n");
        out.write(Proto.utf8(h.toString()));
        out.write(data);
        out.flush();
    }

    static String reason(int status) {
        switch (status) {
            case 200: return "OK";
            case 400: return "Bad Request";
            case 401: return "Unauthorized";
            case 403: return "Forbidden";
            case 404: return "Not Found";
            case 409: return "Conflict";
            case 413: return "Payload Too Large";
            case 429: return "Too Many Requests";
            case 503: return "Service Unavailable";
            default: return "Error";
        }
    }
}
