/**
 * Entry point for the DigiCert TLM Automation Plugin (Azure Key Vault).
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
 *   java com.example.automation.AzureKeyvaultAutomationPluginRunner
 * </pre>
 */

package com.example.automation;

import java.io.IOException;

import com.digicert.tlm.SdkContext;
import com.digicert.tlm.SdkRuntime;

public class AzureKeyvaultAutomationPluginRunner {

    /**
     * Main method to start the Automation Plugin.
     *
     * @param args Command-line arguments (not used)
     * @throws IOException if an I/O error occurs during plugin execution
     */
    public static void main(String[] args) throws IOException {
        // 1. Initialize the SDK runtime with the package name (in lowercase).
        SdkRuntime runtime =
                new SdkRuntime(AzureKeyvaultAutomationPluginRunner.class.getPackageName().toLowerCase());

        // 2. Create a new context object for the plugin execution.
        SdkContext context = new SdkContext();

        // 3. Execute the plugin named "AzureKeyvaultAutomationPlugin".
        runtime.execute("AzureKeyvaultAutomationPlugin", context);
    }
}
