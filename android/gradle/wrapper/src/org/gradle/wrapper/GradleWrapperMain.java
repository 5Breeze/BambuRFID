package org.gradle.wrapper;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.net.URLConnection;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Properties;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/**
 * Small self-contained Gradle bootstrap used by this source bundle.
 * It reads gradle-wrapper.properties, downloads/verifies the configured
 * distribution, extracts it under GRADLE_USER_HOME, and forwards all CLI args.
 */
public final class GradleWrapperMain {
    private static final int BUFFER_SIZE = 64 * 1024;

    public static void main(String[] args) {
        try {
            int exit = run(args);
            System.exit(exit);
        } catch (Throwable t) {
            System.err.println("Gradle wrapper bootstrap failed: " + t.getMessage());
            if (Boolean.getBoolean("bamburfid.wrapper.debug")) {
                t.printStackTrace(System.err);
            }
            System.exit(1);
        }
    }

    private static int run(String[] args) throws Exception {
        Path jarPath = Path.of(
            GradleWrapperMain.class.getProtectionDomain().getCodeSource().getLocation().toURI()
        ).toAbsolutePath();
        Path wrapperDir = jarPath.getParent();
        if (wrapperDir == null) {
            throw new IllegalStateException("Cannot locate wrapper directory");
        }

        Path propertiesPath = wrapperDir.resolve("gradle-wrapper.properties");
        Properties properties = new Properties();
        try (InputStream in = Files.newInputStream(propertiesPath)) {
            properties.load(in);
        }

        String distributionUrl = require(properties, "distributionUrl");
        String expectedSha256 = properties.getProperty("distributionSha256Sum", "").trim().toLowerCase();
        int networkTimeout = parseInt(properties.getProperty("networkTimeout"), 10000);

        Path gradleUserHome = gradleUserHome();
        Path distsDir = gradleUserHome.resolve("wrapper").resolve("dists").resolve("bamburfid");
        Files.createDirectories(distsDir);

        String zipName = fileNameFromUrl(distributionUrl);
        String distKey = shortHash(distributionUrl);
        Path installRoot = distsDir.resolve(zipName.replaceFirst("\\.zip$", "") + "-" + distKey);
        Path marker = installRoot.resolve(".ready");

        if (!Files.isRegularFile(marker)) {
            installDistribution(distributionUrl, expectedSha256, networkTimeout, installRoot);
        }

        Path gradleHome = findGradleHome(installRoot);
        boolean windows = System.getProperty("os.name", "").toLowerCase().contains("win");
        Path executable = gradleHome.resolve("bin").resolve(windows ? "gradle.bat" : "gradle");
        if (!Files.isRegularFile(executable)) {
            throw new IOException("Gradle executable not found: " + executable);
        }
        if (!windows) {
            executable.toFile().setExecutable(true, false);
        }

        List<String> command = new ArrayList<>();
        if (windows) {
            command.add("cmd.exe");
            command.add("/d");
            command.add("/c");
            command.add(executable.toString());
        } else {
            command.add(executable.toString());
        }
        for (String arg : args) command.add(arg);

        ProcessBuilder pb = new ProcessBuilder(command);
        pb.inheritIO();
        Process process = pb.start();
        return process.waitFor();
    }

    private static void installDistribution(
        String distributionUrl,
        String expectedSha256,
        int networkTimeout,
        Path installRoot
    ) throws Exception {
        Path parent = installRoot.getParent();
        Files.createDirectories(parent);
        String token = Long.toUnsignedString(System.nanoTime(), 36);
        Path zip = parent.resolve(".download-" + token + ".zip");
        Path temp = parent.resolve(".extract-" + token);

        try {
            System.out.println("Downloading " + distributionUrl);
            download(distributionUrl, zip, networkTimeout);
            if (!expectedSha256.isEmpty()) {
                String actual = sha256(zip);
                if (!actual.equalsIgnoreCase(expectedSha256)) {
                    throw new SecurityException(
                        "Gradle distribution checksum mismatch. Expected " + expectedSha256 + ", got " + actual
                    );
                }
            }

            Files.createDirectories(temp);
            unzip(zip, temp);

            deleteRecursively(installRoot);
            try {
                Files.move(temp, installRoot, StandardCopyOption.ATOMIC_MOVE);
            } catch (Exception ignored) {
                Files.move(temp, installRoot, StandardCopyOption.REPLACE_EXISTING);
            }
            Files.writeString(installRoot.resolve(".ready"), "ok\n");
        } finally {
            Files.deleteIfExists(zip);
            if (Files.exists(temp)) deleteRecursively(temp);
        }
    }

    private static void download(String urlString, Path target, int timeoutMs) throws Exception {
        URI uri = URI.create(urlString);
        if ("file".equalsIgnoreCase(uri.getScheme())) {
            Files.copy(Path.of(uri), target, StandardCopyOption.REPLACE_EXISTING);
            return;
        }

        URL current = uri.toURL();
        for (int redirect = 0; redirect < 10; redirect++) {
            URLConnection raw = current.openConnection();
            raw.setConnectTimeout(timeoutMs);
            raw.setReadTimeout(Math.max(timeoutMs, 30000));
            raw.setRequestProperty("User-Agent", "BambuRFID-Gradle-Wrapper/1");

            if (raw instanceof HttpURLConnection http) {
                http.setInstanceFollowRedirects(false);
                int code = http.getResponseCode();
                if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
                    String location = http.getHeaderField("Location");
                    http.disconnect();
                    if (location == null || location.isBlank()) {
                        throw new IOException("Redirect without Location header");
                    }
                    current = new URL(current, location);
                    continue;
                }
                if (code < 200 || code >= 300) {
                    throw new IOException("HTTP " + code + " while downloading " + current);
                }
            }

            try (
                InputStream in = new BufferedInputStream(raw.getInputStream(), BUFFER_SIZE);
                OutputStream out = new BufferedOutputStream(Files.newOutputStream(target), BUFFER_SIZE)
            ) {
                byte[] buffer = new byte[BUFFER_SIZE];
                int read;
                while ((read = in.read(buffer)) >= 0) {
                    if (read > 0) out.write(buffer, 0, read);
                }
            }
            return;
        }
        throw new IOException("Too many redirects while downloading Gradle");
    }

    private static void unzip(Path zip, Path destination) throws IOException {
        Path normalizedDestination = destination.toAbsolutePath().normalize();
        try (ZipInputStream zin = new ZipInputStream(new BufferedInputStream(Files.newInputStream(zip), BUFFER_SIZE))) {
            ZipEntry entry;
            byte[] buffer = new byte[BUFFER_SIZE];
            while ((entry = zin.getNextEntry()) != null) {
                Path out = normalizedDestination.resolve(entry.getName()).normalize();
                if (!out.startsWith(normalizedDestination)) {
                    throw new IOException("Unsafe ZIP entry: " + entry.getName());
                }
                if (entry.isDirectory()) {
                    Files.createDirectories(out);
                } else {
                    Files.createDirectories(out.getParent());
                    try (OutputStream fileOut = new BufferedOutputStream(Files.newOutputStream(out), BUFFER_SIZE)) {
                        int read;
                        while ((read = zin.read(buffer)) >= 0) {
                            if (read > 0) fileOut.write(buffer, 0, read);
                        }
                    }
                }
                zin.closeEntry();
            }
        }
    }

    private static Path findGradleHome(Path installRoot) throws IOException {
        try (var stream = Files.list(installRoot)) {
            List<Path> dirs = stream.filter(Files::isDirectory).toList();
            if (dirs.size() == 1 && Files.isDirectory(dirs.get(0).resolve("bin"))) {
                return dirs.get(0);
            }
        }
        if (Files.isDirectory(installRoot.resolve("bin"))) return installRoot;
        throw new IOException("Could not locate extracted Gradle home under " + installRoot);
    }

    private static Path gradleUserHome() {
        String env = System.getenv("GRADLE_USER_HOME");
        if (env != null && !env.isBlank()) return Path.of(env).toAbsolutePath();
        return Path.of(System.getProperty("user.home"), ".gradle").toAbsolutePath();
    }

    private static String require(Properties properties, String key) {
        String value = properties.getProperty(key);
        if (value == null || value.isBlank()) throw new IllegalStateException("Missing " + key);
        return value.trim();
    }

    private static int parseInt(String value, int fallback) {
        if (value == null || value.isBlank()) return fallback;
        try { return Integer.parseInt(value.trim()); } catch (NumberFormatException ignored) { return fallback; }
    }

    private static String fileNameFromUrl(String url) {
        String path = URI.create(url).getPath();
        if (path == null || path.isBlank()) return "gradle.zip";
        int slash = path.lastIndexOf('/');
        return slash >= 0 ? path.substring(slash + 1) : path;
    }

    private static String shortHash(String value) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        return HexFormat.of().formatHex(digest.digest(value.getBytes(java.nio.charset.StandardCharsets.UTF_8))).substring(0, 16);
    }

    private static String sha256(Path file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream in = new BufferedInputStream(Files.newInputStream(file), BUFFER_SIZE)) {
            byte[] buffer = new byte[BUFFER_SIZE];
            int read;
            while ((read = in.read(buffer)) >= 0) {
                if (read > 0) digest.update(buffer, 0, read);
            }
        }
        return HexFormat.of().formatHex(digest.digest());
    }

    private static void deleteRecursively(Path path) throws IOException {
        if (!Files.exists(path)) return;
        try (var walk = Files.walk(path)) {
            List<Path> paths = walk.sorted((a, b) -> b.getNameCount() - a.getNameCount()).toList();
            for (Path p : paths) Files.deleteIfExists(p);
        }
    }
}
