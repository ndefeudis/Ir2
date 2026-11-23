package dev.ir2.companion;

import java.io.UnsupportedEncodingException;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** The protocol's crypto (docs/PROTOCOL.md), the same as tools/fakecar/ir2proto.py and Ir2Kit. Java 7, Android 4.4. */
public final class Proto {
    public static final int PORT = 47115;
    public static final String CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    private static final byte[] SALT = utf8("ir2-companion/v1");
    private static final SecureRandom RANDOM = new SecureRandom();

    private Proto() {}

    /** 16 Crockford base32 characters: 80 random bits */
    public static String newCode() {
        byte[] b = new byte[10];
        RANDOM.nextBytes(b);
        StringBuilder sb = new StringBuilder(16);
        int acc = 0, bits = 0;
        for (byte x : b) {
            acc = (acc << 8) | (x & 255);
            bits += 8;
            while (bits >= 5) {
                bits -= 5;
                sb.append(CROCKFORD.charAt((acc >> bits) & 31));
            }
        }
        return sb.toString();
    }

    public static String showCode(String code) {
        return code.substring(0, 4) + "-" + code.substring(4, 8) + "-" + code.substring(8, 12) + "-" + code.substring(12, 16);
    }

    public static String normalizeCode(String text) {
        String s = text.toUpperCase(java.util.Locale.US).replace("-", "").replace(" ", "");
        return s.replace('O', '0').replace('I', '1').replace('L', '1');
    }

    public static byte[] hkdf(byte[] ikm, byte[] salt, byte[] info, int length) {
        byte[] prk = hmac(salt, ikm);
        byte[] out = new byte[length];
        byte[] block = new byte[0];
        int done = 0;
        for (int i = 1; done < length; i++) {
            byte[] in = new byte[block.length + info.length + 1];
            System.arraycopy(block, 0, in, 0, block.length);
            System.arraycopy(info, 0, in, block.length, info.length);
            in[in.length - 1] = (byte) i;
            block = hmac(prk, in);
            int n = Math.min(block.length, length - done);
            System.arraycopy(block, 0, out, done, n);
            done += n;
        }
        return out;
    }

    public static byte[] deviceKey(String code, String deviceId) {
        return hkdf(utf8(normalizeCode(code)), SALT, utf8("device-key:" + deviceId), 32);
    }

    public static String signRequest(byte[] key, String method, String path, String deviceId, long counter, byte[] body) {
        String canonical = method.toUpperCase(java.util.Locale.US) + "\n" + path + "\n" + deviceId + "\n" + counter + "\n" + hex(sha256(body));
        return hex(hmac(key, utf8(canonical)));
    }

    public static String signResponse(byte[] key, long counter, int status, byte[] body) {
        return hex(hmac(key, utf8("response\n" + counter + "\n" + status + "\n" + hex(sha256(body)))));
    }

    /** constant-time compare of two hex strings */
    public static boolean same(String a, String b) {
        if (a == null || b == null) return false;
        byte[] x = utf8(a), y = utf8(b);
        return MessageDigest.isEqual(x, y);
    }

    public static byte[] hmac(byte[] key, byte[] data) {
        try {
            Mac m = Mac.getInstance("HmacSHA256");
            m.init(new SecretKeySpec(key, "HmacSHA256"));  // keys here are never empty
            return m.doFinal(data);
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    public static byte[] sha256(byte[] data) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(data);
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    public static String hex(byte[] b) {
        char[] out = new char[b.length * 2];
        String d = "0123456789abcdef";
        for (int i = 0; i < b.length; i++) {
            out[2 * i] = d.charAt((b[i] >> 4) & 15);
            out[2 * i + 1] = d.charAt(b[i] & 15);
        }
        return new String(out);
    }

    public static byte[] unhex(String s) {
        byte[] out = new byte[s.length() / 2];
        for (int i = 0; i < out.length; i++) out[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16);
        return out;
    }

    public static byte[] utf8(String s) {
        try {
            return s.getBytes("UTF-8");
        } catch (UnsupportedEncodingException e) {
            throw new IllegalStateException(e);
        }
    }
}
