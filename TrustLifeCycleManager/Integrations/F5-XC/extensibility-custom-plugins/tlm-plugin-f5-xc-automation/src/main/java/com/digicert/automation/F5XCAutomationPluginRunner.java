/**
 * Entry point for the DigiCert TLM F5 Distributed Cloud (F5-XC) Automation Plugin.
 * <p>
 * <b>Purpose:</b> Contains the main method to launch the automation plugin using the DigiCert TLM SDK.<br>
 * <b>How it works:</b>
 * <ol>
 *   <li>Initializes the plugin runtime environment.</li>
 *   <li>Creates a context for passing data to the plugin.</li>
 *   <li>Executes the plugin by name with the provided context.</li>
 * </ol>
 * <b>Usage Example:</b>
 * <pre>
 *   java com.digicert.automation.F5XCAutomationPluginRunner
 * </pre>
 */

package com.digicert.automation;

import java.io.IOException;

import com.digicert.tlm.SdkContext;
import com.digicert.tlm.SdkRuntime;

/**
 * @author michael.rudloff
 */
public class F5XCAutomationPluginRunner {

    /**
     * Main method to start the F5-XC Automation Plugin.
     *
     * @param args Command-line arguments (not used)
     * @throws IOException if an I/O error occurs during plugin execution
     */
    public static void main(String[] args) throws IOException {
        // 1. Initialize the SDK runtime with the package name (in lowercase).
        SdkRuntime runtime = new SdkRuntime(F5XCAutomationPluginRunner.class.getPackageName().toLowerCase());

        // 2. Create a new context object for the plugin execution.
        SdkContext context = new SdkContext();

        // 3. Execute the plugin named "F5XCAutomationPlugin".
        runtime.execute("F5XCAutomationPlugin", context);
    }
}
