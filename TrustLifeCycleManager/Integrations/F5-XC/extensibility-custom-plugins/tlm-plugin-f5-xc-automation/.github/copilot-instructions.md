---
applyTo: '**'
---

# TLM Plugin Automation Setup Instructions

## Step 1: Ask for Vendor Name

Before proceeding, prompt for the `vendorname` value. This value will be used throughout the project for naming conventions, package paths, and class names.

---

## Step 2: Copy Template Project

Copy `tlm-plugin-example-automation` to a new project directory named `tlm-plugin-<vendorname>-automation` in the same parent directory as `tlm-plugin-example-automation`:

```bash
parent_dir="$(dirname "$(realpath tlm-plugin-example-automation)")"
cp -R "$parent_dir/tlm-plugin-example-automation" "$parent_dir/tlm-plugin-<vendorname>-automation"
```

---

## Step 3: Change Directory

Move into the new project directory before running the remaining steps:

```bash
cd tlm-plugin-<vendorname>-automation
```

---

## Step 4: Update `pom.xml`

In `pom.xml`, update the following fields:

| Field       | Value                                    |
|-------------|------------------------------------------|
| `groupId`   | `com.digicert.plugin.automation`         |
| `artifactId`| `tlm-plugin-<vendorname>-automation`     |

Use the values under the root `<project>` coordinates (not `<parent>`):

```xml
<project>
  <groupId>com.digicert.plugin.automation</groupId>
  <artifactId>tlm-plugin-<vendorname>-automation</artifactId>
</project>
```

If a `<version>` is present, keep it unchanged unless explicitly required.

---

## Step 5: Fix `build.sh` Error

Execute this step only when the OS is macOS (`uname` returns `Darwin`).

Open `build.sh` and resolve any errors present before proceeding to the build step.

---

## Step 6: Remove `.git` Folder

Remove the `.git` folder from the newly copied project to detach it from the template's git history:

```bash
rm -rf tlm-plugin-<vendorname>-automation/.git
```

Remove all files and subfolders inside `plugin-dist`:

```bash
find tlm-plugin-<vendorname>-automation/plugin-dist -mindepth 1 -delete
```

---

## Step 7: Rename Classes and Files

Perform the following class and file renames, and update **all references** consistently:

| Old Name                     | New Name                                      |
|------------------------------|-----------------------------------------------|
| `MyAutomationPlugin`         | `<Vendorname>AutomationPlugin`                |
| `MyAutomationPluginRunner`   | `<Vendorname>AutomationPluginRunner`          |

- Rename each `.java` file to match its new class name (e.g., `VendornameAutomationPlugin.java`).
- Update all import statements, annotations, and references across the project.
- Also remove the `My` prefix from any other class names and file names across the project, then update all references accordingly.

---

## Step 8: Create Service Package and Classes
## Step 7.5: Rename PluginConfiguration Class

Rename the `PluginConfiguration` class to `<Vendorname>PluginConfiguration`:

| Old Name               | New Name                          |
|------------------------|-----------------------------------|
| `PluginConfiguration`  | `<Vendorname>PluginConfiguration` |

- Rename the `.java` file to match the new class name (e.g., `VendornamePluginConfiguration.java`).
- Update all import statements and references across the project.

---

## Step 8: Create Service Package and Classes

Create the following package:

```
com.digicert.automation.<vendorname>.service
```

Inside this package, create the following service classes (one per action). Use the naming format `<ActionName>Service`:

| Action                 | Class Name                    |
|------------------------|-------------------------------|
| `testconnection`       | `TestConnectionService`       |
| `generatecsr`          | `GenerateCsrService`          |
| `installcertificate`   | `InstallCertificateService`   |
| `validatecertificate`  | `ValidateCertificateService`  |
| `refreshconfiguration` | `RefreshConfigurationService` |

**For each service class, implement the following:**

- Move the sample implementation code from each action into its respective service class method (ignore if already moved)
- Add the `@Slf4j` annotation from Lombok to enable logging
- Implement a **thread-safe singleton pattern** using a private constructor and static `getInstance()` method
- Create a public method matching the action name (e.g., `testConnection()`, `generateCsr()`, etc.) that accepts a request and returns `Response<JsonNode>`

**Example structure for each service class:**

```java
package com.digicert.automation.<vendorname>.service;

import lombok.extern.slf4j.Slf4j;
import com.digicert.automation.response.Response;
import com.fasterxml.jackson.databind.JsonNode;

@Slf4j
public class <ActionName>Service {

  private static <ActionName>Service instance;

  private <ActionName>Service() {
  }

  public static synchronized <ActionName>Service getInstance() {
    if (instance == null) {
      instance = new <ActionName>Service();
    }
    return instance;
  }

  public Response<JsonNode> <actionName>(Request request) {
    // Implementation here
    return new Response<>();
  }
}
```

**Call service methods from `<Vendorname>AutomationPlugin` class in the following pattern:**

```java
log.info("<actionName> action started");
Response<JsonNode> response = <ServiceClassName>.getInstance().<actionName>(request);
log.info("<actionName> action completed");
return response;
```

---

## Step 8.5: Create API Adapter Class

Create the package:

```
com.digicert.automation.<vendorname>.service.api
```

Create the class `DigiCertApiAdapter` under this package with the following implementation:

```java
package com.digicert.automation.<vendorname>.service.api;

import lombok.extern.slf4j.Slf4j;

import java.io.IOException;
import java.io.InputStream;
import java.net.URL;

@Slf4j
public class DigiCertApiAdapter {
  private DigiCertApiAdapter() {
  }

  private static final class SingletonHolder {
    private static final DigiCertApiAdapter INSTANCE = new DigiCertApiAdapter();
  }

  public static DigiCertApiAdapter getInstance() {
    return DigiCertApiAdapter.SingletonHolder.INSTANCE;
  }

  public String downloadCertificate(String fileUrl) throws IOException {
    log.info("Certificate download started from link: {}", fileUrl);
    URL url = new URL(fileUrl);
    try (InputStream in = url.openStream()) {
      String certificateContent = new String(in.readAllBytes());
      log.info("Certificate download completed from link: {}", fileUrl);
      return certificateContent;
    }
  }
}
```


## Step 9: Create `plugin-info.json`
## Step 9.5: Rename Package and Clean Up

Rename the `com.example.automation` package to `com.digicert.automation`:

```bash
# Move the digicert package folder if needed and update all imports
find . -type f -name "*.java" -exec sed -i '' 's/com\.example\.automation/com.digicert.automation/g' {} \;
```

Delete the old `com.example` package folder:

```bash
rm -rf src/main/java/com/example
```

Verify that all Java files now reference `com.digicert.automation` and no references to `com.example` remain.

---

## Step 10: Create `plugin-info.json`

Create the file `plugin-info.json` at the root of the project `tlm-plugin-<vendorname>-automation` with the following content:

```json
{
  "executions": [
    {
      "stage": "config",
      "args": {
      }
    },
    {
      "stage": "run",
      "args": {
        "action": "testConnection",
        "parameters": {
        }
      }
    }
  ]
}
```


## Step 10: Build the Project
## Step 11: Build the Project

Run the Maven build and confirm it succeeds:

```bash
sh build.sh
```

Verify the build output and confirm whether it was **successful** or **failed**.
