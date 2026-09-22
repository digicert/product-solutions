package com.digicert.automation.f5xc.service.api;

import lombok.extern.slf4j.Slf4j;

import java.io.IOException;
import java.io.InputStream;
import java.net.URL;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;

/**
 * Downloads the issued certificate artifact from the DigiCert One portal.
 *
 * @author michael.rudloff
 */
@Slf4j
public class DigiCertApiAdapter {

    /** File name used for the downloaded artifact. The content may be a ZIP or PKCS#12. */
    public static final String ARTIFACT_FILE_NAME = "certificate-artifact";

    private DigiCertApiAdapter() {
    }

    private static final class SingletonHolder {
        private static final DigiCertApiAdapter INSTANCE = new DigiCertApiAdapter();
    }

    public static DigiCertApiAdapter getInstance() {
        return SingletonHolder.INSTANCE;
    }

    /**
     * Downloads the artifact at {@code fileUrl} into {@code directory}.
     *
     * @param fileUrl   the DigiCert One artifact link (from the install request)
     * @param directory destination directory
     * @return the path to the downloaded file
     */
    public String downloadArtifact(String fileUrl, String directory) {
        log.info("Artifact download started from link: {}", fileUrl);
        try {
            URL url = new URL(fileUrl);
            Path targetPath = Path.of(directory, ARTIFACT_FILE_NAME);
            try (InputStream in = url.openStream()) {
                Files.copy(in, targetPath, StandardCopyOption.REPLACE_EXISTING);
                log.info("Artifact download completed from link: {}", fileUrl);
                return targetPath.toString();
            }
        } catch (IOException e) {
            throw new IllegalStateException("Unable to download certificate from DigiCert One portal. Error: " + e.getMessage(), e);
        }
    }
}
