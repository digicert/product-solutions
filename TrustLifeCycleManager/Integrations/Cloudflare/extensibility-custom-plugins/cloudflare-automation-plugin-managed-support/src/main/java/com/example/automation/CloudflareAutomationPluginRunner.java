/**
 * Entry point for the DigiCert TLM Automation Plugin (Cloudflare custom certificates).
 * <p>
 * <b>How it works:</b>
 * <ol>
 *   <li>Initializes the plugin runtime environment.</li>
 *   <li>Creates a context for passing data to the plugin.</li>
 *   <li>Executes the plugin by name with the provided context.</li>
 * </ol>
 */

package com.example.automation;

import java.io.IOException;

import com.digicert.tlm.SdkContext;
import com.digicert.tlm.SdkRuntime;

public class CloudflareAutomationPluginRunner {

    /**
     * Main method to start the Automation Plugin.
     *
     * @param args Command-line arguments (not used)
     * @throws IOException if an I/O error occurs during plugin execution
     */
    public static void main(String[] args) throws IOException {
        // The Cloudflare API presents a publicly trusted certificate, so TLS verification stays on.

        // 1. Initialize the SDK runtime with the package name (in lowercase).
        SdkRuntime runtime =
                new SdkRuntime(CloudflareAutomationPluginRunner.class.getPackageName().toLowerCase());

        // 2. Create a new context object for the plugin execution.
        SdkContext context = new SdkContext();

        // 3. Execute the plugin named "CloudflareAutomationPlugin".
        runtime.execute("CloudflareAutomationPlugin", context);
    }
}
