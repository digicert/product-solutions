<#
===============================================================================
LEGAL NOTICE (version October 29, 2024)
===============================================================================
Copyright © 2024 DigiCert. All rights reserved.
DigiCert and its logo are registered trademarks of DigiCert, Inc.
Other names may be trademarks of their respective owners.

For the purposes of this Legal Notice, "DigiCert" refers to:
- DigiCert, Inc., if you are located in the United States;
- DigiCert Ireland Limited, if you are located outside of the United States or Japan;
- DigiCert Japan G.K., if you are located in Japan.

The software described in this notice is provided by DigiCert and distributed under licenses
restricting its use, copying, distribution, and decompilation or reverse engineering.
No part of the software may be reproduced in any form by any means without prior written authorization
of DigiCert and its licensors, if any.

Use of the software is subject to the terms and conditions of your agreement with DigiCert, including
any dispute resolution and applicable law provisions. The terms set out herein are supplemental to
your agreement and, in the event of conflict, these terms control.

THE SOFTWARE IS PROVIDED "AS IS" AND ALL EXPRESS OR IMPLIED CONDITIONS, REPRESENTATIONS AND WARRANTIES,
INCLUDING ANY IMPLIED WARRANTY OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE OR NON-INFRINGEMENT,
ARE DISCLAIMED, EXCEPT TO THE EXTENT THAT SUCH DISCLAIMERS ARE HELD TO BE LEGALLY INVALID.

Export Regulation: The software and related technical data and services (collectively "Controlled Technology")
are subject to the import and export laws of the United States, specifically the U.S. Export Administration
Regulations (EAR), and the laws of any country where Controlled Technology is imported or re-exported.

US Government Restricted Rights: The software is provided with "Restricted Rights," Use, duplication, or
disclosure by the U.S. Government is subject to restrictions as set forth in subparagraph (c)(1)(ii) of the
Rights in Technical Data and Computer Software clause at DFARS 252.227-7013,
subparagraphs (c)(1) and (2) of the Commercial Computer Software—Restricted Rights at 48 CFR 52.227-19,
as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
The contractor/manufacturer is DIGICERT, INC.
===============================================================================
#>

# Legal notice acceptance variable (user must set to $true to accept and allow script execution)
$LEGAL_NOTICE_ACCEPT = $false  # Change this to $true to accept the legal notice and run the script

# Configuration
$logFile = "C:\CertificateImport.log"

# Function to write to log file
function Write-Log {
    param(
        [string]$Message
    )
    $logMessage = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $Message"
    Add-Content -Path $logFile -Value $logMessage
    Write-Host $Message
}

# Function to decode base64 encoded string
function Decode-Base64 {
    param (
        [string]$base64String
    )
    $bytes = [System.Convert]::FromBase64String($base64String)
    $decodedString = [System.Text.Encoding]::UTF8.GetString($bytes)
    return $decodedString
}

# Function to update Tomcat server.xml
function Update-TomcatServerXml {
    param (
        [string]$ServerXmlPath,
        [string]$KeystoreFile,
        [string]$KeystorePassword,
        [string]$KeyAlias
    )
    
    try {
        Write-Log "Starting Tomcat server.xml update"
        Write-Log "Server.xml path: $ServerXmlPath"
        Write-Log "Keystore file: $KeystoreFile"
        Write-Log "Key alias: $KeyAlias"
        
        # Check if server.xml exists
        if (-not (Test-Path -Path $ServerXmlPath)) {
            throw "Server.xml file not found at: $ServerXmlPath"
        }
        
        # Create backup of server.xml
        $backupPath = "$ServerXmlPath.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item -Path $ServerXmlPath -Destination $backupPath -Force
        Write-Log "Created backup: $backupPath"
        
        # Read the server.xml content
        $xmlContent = Get-Content -Path $ServerXmlPath -Raw
        
        # Convert keystore path to use forward slashes for Tomcat
        $keystoreFileUnix = $KeystoreFile -replace '\\', '/'
        
        # Create the new Certificate element
        $newCertificate = @"
            <Certificate certificateKeystoreFile="$keystoreFileUnix"
                         certificateKeystorePassword="$KeystorePassword"
                         certificateKeyAlias="$KeyAlias"
                         type="RSA" />
"@
        
        # Use regex to find and replace the Certificate element
        $pattern = '<Certificate\s+certificateKeystoreFile="[^"]*"\s*certificateKeystorePassword="[^"]*"\s*certificateKeyAlias="[^"]*"\s*type="[^"]*"\s*/>'
        
        if ($xmlContent -match $pattern) {
            $xmlContent = $xmlContent -replace $pattern, $newCertificate.Trim()
            Write-Log "Successfully updated Certificate element in server.xml"
        } else {
            # If exact pattern doesn't match, try a more flexible pattern
            $pattern2 = '<Certificate[^>]*>'
            if ($xmlContent -match $pattern2) {
                $xmlContent = $xmlContent -replace $pattern2, $newCertificate.Trim()
                Write-Log "Successfully updated Certificate element using flexible pattern"
            } else {
                throw "Could not find Certificate element in server.xml"
            }
        }
        
        # Write the updated content back to server.xml
        Set-Content -Path $ServerXmlPath -Value $xmlContent -Encoding UTF8
        Write-Log "Successfully wrote updated server.xml"
        
        return $true
    }
    catch {
        Write-Log "ERROR updating server.xml: $_"
        return $false
    }
}

Write-Log "Script execution started"

# Check legal notice acceptance
if ($LEGAL_NOTICE_ACCEPT -ne $true) {
    Write-Log "ERROR: Script execution halted - Legal notice not accepted"
    Write-Log "User must set `$LEGAL_NOTICE_ACCEPT = `$true to proceed"
    Write-Log "Script terminated due to legal notice non-acceptance"
    exit 1
}

Write-Log "Legal notice accepted - proceeding with script execution"

try {
    # Base64 encoded JSON input
    $base64Json = [System.Environment]::GetEnvironmentVariable("DC1_POST_SCRIPT_DATA")
    Write-Log "Retrieved environment variable DC1_POST_SCRIPT_DATA"
    
    # Decode the base64 encoded JSON
    $jsonString = Decode-Base64 -base64String $base64Json
    Write-Log "Decoded base64 string successfully"
    
    # Convert JSON string to PowerShell object
    $jsonObject = $jsonString | ConvertFrom-Json
    Write-Log "Converted JSON string to object"
    Write-Log "Arguments: $($jsonObject.args)"
    
    # Extract values from JSON object
    $certFolder = $jsonObject.certfolder
    $jksFile = Join-Path -Path $certFolder -ChildPath $jsonObject.files[0]
    $password = $jsonObject.password
    $keystorePassword = $jsonObject.keystorepassword
    $truststorePassword = $jsonObject.truststorepassword
    
    Write-Log "Certificate folder: $certFolder"
    Write-Log "jks file path: $jksFile"
    
    # Log passwords in plaintext (FOR TESTING ONLY - SECURITY RISK)
    Write-Log "WARNING: Logging passwords in plaintext - FOR TESTING ONLY"
    Write-Log "Password: $password"
    Write-Log "Keystore Password: $keystorePassword"
    Write-Log "Truststore Password: $truststorePassword"
    
    # Validate inputs
    if (-not (Test-Path -Path $jksFile)) {
        Write-Log "ERROR: The JKS file does not exist at path: $jksFile"
        throw "The JKS file does not exist."
    }
    
    # Extract the key alias from the JKS filename
    $jksFileName = [System.IO.Path]::GetFileNameWithoutExtension($jksFile)
    Write-Log "Extracted key alias: $jksFileName"
    
    # Define Tomcat server.xml path (adjust this path as needed)
    $tomcatHome = $env:CATALINA_HOME
    if (-not $tomcatHome) {
        # Default Tomcat installation paths
        $possiblePaths = @(
            "C:\Program Files\Apache Software Foundation\Tomcat 10.0",
            "C:\Program Files\Apache Software Foundation\Tomcat 10.1",
            "C:\Program Files\Apache Software Foundation\Tomcat 9.0",
            "C:\tomcat",
            "C:\apache-tomcat"
        )
        
        foreach ($path in $possiblePaths) {
            if (Test-Path -Path $path) {
                $tomcatHome = $path
                break
            }
        }
    }
    
    if (-not $tomcatHome) {
        throw "Could not determine Tomcat installation directory. Please set CATALINA_HOME environment variable."
    }
    
    $serverXmlPath = Join-Path -Path $tomcatHome -ChildPath "conf\server.xml"
    Write-Log "Tomcat home: $tomcatHome"
    Write-Log "Server.xml path: $serverXmlPath"
    
    # Update Tomcat server.xml
    $updateResult = Update-TomcatServerXml -ServerXmlPath $serverXmlPath `
                                          -KeystoreFile $jksFile `
                                          -KeystorePassword $keystorePassword `
                                          -KeyAlias $jksFileName
    
    if ($updateResult) {
        Write-Log "Successfully updated Tomcat server.xml"
        
        # Restart Tomcat service - try both Tomcat9 and Tomcat10
        $serviceNames = @("Tomcat10", "Tomcat9")
        $serviceRestarted = $false
        
        Write-Log "Attempting to restart Tomcat service..."
        
        foreach ($serviceName in $serviceNames) {
            try {
                Write-Log "Checking for service: $serviceName"
                $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                
                if ($service) {
                    Write-Log "Found Tomcat service: $serviceName (Status: $($service.Status))"
                    
                    # Stop the service
                    Write-Log "Stopping Tomcat service: $serviceName"
                    Stop-Service -Name $serviceName -Force -ErrorAction Stop
                    
                    # Wait for service to stop
                    $timeout = 30
                    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    while ($service.Status -ne 'Stopped' -and $stopwatch.Elapsed.TotalSeconds -lt $timeout) {
                        Start-Sleep -Seconds 1
                        $service.Refresh()
                        Write-Log "Waiting for service to stop... (Status: $($service.Status))"
                    }
                    
                    if ($service.Status -eq 'Stopped') {
                        Write-Log "Service $serviceName stopped successfully"
                    } else {
                        Write-Log "WARNING: Service $serviceName did not stop within $timeout seconds"
                    }
                    
                    # Start the service
                    Write-Log "Starting Tomcat service: $serviceName"
                    Start-Service -Name $serviceName -ErrorAction Stop
                    
                    # Wait for service to start
                    $stopwatch.Restart()
                    while ($service.Status -ne 'Running' -and $stopwatch.Elapsed.TotalSeconds -lt $timeout) {
                        Start-Sleep -Seconds 1
                        $service.Refresh()
                        Write-Log "Waiting for service to start... (Status: $($service.Status))"
                    }
                    
                    if ($service.Status -eq 'Running') {
                        Write-Log "Tomcat service $serviceName restarted successfully"
                        $serviceRestarted = $true
                        break
                    } else {
                        Write-Log "WARNING: Service $serviceName did not start within $timeout seconds"
                    }
                } else {
                    Write-Log "Service $serviceName not found on this system"
                }
            }
            catch {
                Write-Log "ERROR: Could not restart service $serviceName : $_"
            }
        }
        
        if (-not $serviceRestarted) {
            Write-Log "WARNING: No Tomcat service could be restarted. Please restart Tomcat manually for changes to take effect."
            Write-Log "Checked for services: $($serviceNames -join ', ')"
        }
    } else {
        throw "Failed to update Tomcat server.xml"
    }
    
    Write-Log "Script execution completed successfully"
}
catch {
    $errorMessage = "ERROR: $($_.Exception.Message)"
    Write-Log $errorMessage
    Write-Log "Stack Trace: $($_.ScriptStackTrace)"
    
    # Re-throw the error if needed, or handle it appropriately
    throw
}
finally {
    Write-Log "Script execution finished"
}