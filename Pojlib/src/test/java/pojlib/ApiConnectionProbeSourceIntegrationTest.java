package pojlib;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertTrue;

public class ApiConnectionProbeSourceIntegrationTest {
    @Test
    public void metadataProbeIsBoundedAndFallsBackOffline() throws Exception {
        String api = new String(
                Files.readAllBytes(Path.of("src/main/java/pojlib/API.java")),
                StandardCharsets.UTF_8);

        int probe = api.indexOf(
                "public static synchronized boolean hasConnection(Context activity)");
        int cacheLookup = api.indexOf("probeAgeNanos < METADATA_PROBE_CACHE_NANOS", probe);
        int request = api.indexOf("conn.setRequestMethod(\"GET\")", probe);
        int connectTimeout = api.indexOf("conn.setConnectTimeout(", request);
        int readTimeout = api.indexOf("conn.setReadTimeout(", connectTimeout);
        int response = api.indexOf("conn.getResponseCode()", readTimeout);
        int disconnect = api.indexOf("conn.disconnect()", response);
        int offlineResult = api.indexOf("hasWifi = false;", disconnect);

        assertTrue(probe >= 0);
        assertTrue(cacheLookup > probe);
        assertTrue(request > cacheLookup);
        assertTrue(connectTimeout > request);
        assertTrue(readTimeout > connectTimeout);
        assertTrue(response > readTimeout);
        assertTrue(disconnect > response);
        assertTrue(offlineResult > disconnect);
        assertTrue(api.contains("responseCode >= HttpURLConnection.HTTP_OK"));
        assertTrue(api.contains("METADATA_PROBE_CACHE_NANOS = 15_000_000_000L"));
        assertTrue(api.contains("return cacheMetadataProbeResult(false)"));
        assertTrue(api.contains("Mojang version metadata endpoint"));
        assertTrue(!api.contains("Unable to reach Microsoft servers"));
    }
}
