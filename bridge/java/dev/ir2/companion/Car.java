package dev.ir2.companion;

import java.io.IOException;

import org.json.JSONObject;

/** What the bridge needs from HMG-API. On the car: {@link HmgapidCar}; off the car: {@link DevMain}'s fake. */
public interface Car {
    /**
     * HMG-API's ambient_light command ("color", "ff3300" / "brightness", "6" / "release").
     * Returns HMG-API's "ok ..." or "refused: ..." line; throws when hmgapid doesn't answer.
     */
    String ambient(String... args) throws IOException;

    /** gear.park: TRUE, FALSE, or null when the car doesn't answer */
    Boolean parked();

    /** the mod's settings: settings.json defaults with the owner's values over them */
    JSONObject loadSettings() throws IOException;

    /** saves all of the mod's values (this replaces them) */
    void saveSettings(JSONObject values) throws IOException;
}
