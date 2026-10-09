/**
 * Entry point for the DigiCert TLM Automation Plugin (Fortinet FortiGate).
 * <p>
 * <b>Purpose:</b> Launches the automation plugin using the DigiCert TLM SDK.<br>
 * <b>How it works:</b>
 * <ol>
 *   <li>Initializes the plugin runtime environment.</li>
 *   <li>Creates a context for passing data to the plugin.</li>
 *   <li>Executes the plugin by name with the provided context.</li>
 * </ol>
 * <b>Usage Example:</b>
 * <pre>
 *   java com.example.automation.FortiGateAutomationPluginRunner
 * </pre>
 */

package com.example.automation;

import java.io.IOException;

import com.digicert.tlm.SdkContext;
import com.digicert.tlm.SdkRuntime;

public class FortiGateAutomationPluginRunner {

    /**
     * Main method to start the Automation Plugin.
     *
     * @param args Command-line arguments (not used)
     * @throws IOException if an I/O error occurs during plugin execution
     */
    public static void main(String[] args) throws IOException {
        // 0. FortiGates present a self-signed (or factory) management certificate and are usually
        //    addressed by IP, so the JDK HttpClient must not verify the TLS hostname. The property is
        //    read once when the HTTP client classes load, so set it before anything else runs.
        System.setProperty("jdk.internal.httpclient.disableHostnameVerification", "true");

        // 1. Initialize the SDK runtime with the package name (in lowercase).
        SdkRuntime runtime =
                new SdkRuntime(FortiGateAutomationPluginRunner.class.getPackageName().toLowerCase());

        // 2. Create a new context object for the plugin execution.
        SdkContext context = new SdkContext();

        // 3. Execute the plugin named "FortiGateAutomationPlugin".
        runtime.execute("FortiGateAutomationPlugin", context);
    }
}
