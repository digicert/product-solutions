/**
 * Entry point for the DigiCert TLM Automation Plugin (Azure Key Vault, subscription scope).
 * <p>
 * Launches the automation plugin using the DigiCert TLM SDK: initialises the plugin runtime, creates
 * an execution context and executes the plugin by name.
 */

package com.example.automation;

import java.io.IOException;

import com.digicert.tlm.SdkContext;
import com.digicert.tlm.SdkRuntime;

public class AzureKeyvaultSubscriptionAutomationPluginRunner {

    public static void main(String[] args) throws IOException {
        // 1. Initialize the SDK runtime with the package name (in lowercase).
        SdkRuntime runtime = new SdkRuntime(
                AzureKeyvaultSubscriptionAutomationPluginRunner.class.getPackageName().toLowerCase());

        // 2. Create a new context object for the plugin execution.
        SdkContext context = new SdkContext();

        // 3. Execute the plugin by its @WorkflowEntryPoint name.
        runtime.execute("AzureKeyvaultSubscriptionAutomationPlugin", context);
    }
}
