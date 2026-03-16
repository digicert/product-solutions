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

# Posh-ACME Certificate Management Script with Tomcat Integration
# This script installs prerequisites, manages certificates, and configures Tomcat

# Check legal notice acceptance
if ($LEGAL_NOTICE_ACCEPT -ne $true) {
    Write-Host "ERROR: Script execution halted - Legal notice not accepted" -ForegroundColor Red
    Write-Host "User must set `$LEGAL_NOTICE_ACCEPT = `$true to proceed" -ForegroundColor Yellow
    Write-Host "Script terminated due to legal notice non-acceptance" -ForegroundColor Red
    exit 1
}

Write-Host "Legal notice accepted - proceeding with script execution" -ForegroundColor Green

# Check if running as Administrator
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "This script requires Administrator privileges for software installation and PATH updates." -ForegroundColor Red
    Write-Host "Please run PowerShell as Administrator and try again." -ForegroundColor Yellow
    exit 1
}

# Configuration Variables
$domain = "tomcat-05.tlsguru.io"
$keystorePassword = "changeit"  # Change this to a secure password
$tomcatHome = "C:\tomcat"  # Update this path to your Tomcat installation
$keystorePath = "$tomcatHome\conf\$domain.keystore"
$serverXmlPath = "$tomcatHome\conf\server.xml"
$serverXmlBackup = "$tomcatHome\conf\server.xml.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

Write-Host "=== Posh-ACME Certificate Management Script ===" -ForegroundColor Cyan
Write-Host "Domain: $domain" -ForegroundColor Gray
Write-Host "Tomcat Home: $tomcatHome" -ForegroundColor Gray
Write-Host ""

# Step 1: Check and Install Prerequisites
Write-Host "Step 1: Checking and Installing Prerequisites..." -ForegroundColor Yellow

# Check for OpenSSL
Write-Host "`nChecking for OpenSSL..." -ForegroundColor Gray
$opensslPath = "openssl"
$opensslInstalled = $false

try {
    $opensslVersion = & $opensslPath version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $opensslInstalled = $true
        Write-Host "OpenSSL found: $opensslVersion" -ForegroundColor Green
    }
} catch {
    # Try common OpenSSL installation paths
    $possiblePaths = @(
        "C:\Program Files\OpenSSL-Win64\bin\openssl.exe",
        "C:\OpenSSL-Win64\bin\openssl.exe",
        "C:\OpenSSL\bin\openssl.exe",
        "C:\Tools\OpenSSL\bin\openssl.exe"
    )
    $opensslPath = $possiblePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($opensslPath) {
        $opensslInstalled = $true
        $opensslVersion = & $opensslPath version 2>&1
        Write-Host "OpenSSL found at: $opensslPath" -ForegroundColor Green
        Write-Host "Version: $opensslVersion" -ForegroundColor Gray
    }
}

if (-not $opensslInstalled) {
    Write-Host "OpenSSL not found. Installing..." -ForegroundColor Yellow
    
    # Method 1: Try Chocolatey first
    $chocoInstalled = $false
    try {
        $chocoVersion = choco --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            $chocoInstalled = $true
        }
    } catch {
        $chocoInstalled = $false
    }
    
    if ($chocoInstalled) {
        Write-Host "Installing OpenSSL via Chocolatey..." -ForegroundColor Gray
        choco install openssl -y --force
        
        # Refresh environment variables
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        
        # Check if installation succeeded
        try {
            & openssl version 2>&1 | Out-Null
            $opensslPath = "openssl"
            $opensslInstalled = $true
            Write-Host "OpenSSL installed successfully via Chocolatey" -ForegroundColor Green
        } catch {
            Write-Host "Chocolatey installation didn't add OpenSSL to PATH, will try direct download..." -ForegroundColor Yellow
        }
    }
    
    # Method 2: Direct download if Chocolatey failed or not available
    if (-not $opensslInstalled) {
        Write-Host "Downloading OpenSSL directly..." -ForegroundColor Gray
        
        $opensslUrl = "https://slproweb.com/download/Win64OpenSSL_Light-3_3_2.exe"
        $installerPath = "$env:TEMP\OpenSSL-installer.exe"
        $opensslInstallPath = "C:\Tools\OpenSSL"
        
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $opensslUrl -OutFile $installerPath -UseBasicParsing
            
            Write-Host "Installing OpenSSL to $opensslInstallPath..." -ForegroundColor Gray
            
            # Silent installation
            Start-Process -FilePath $installerPath -ArgumentList "/silent", "/sp-", "/suppressmsgboxes", "/DIR=`"$opensslInstallPath`"" -Wait
            
            # Set OpenSSL path
            $opensslPath = "$opensslInstallPath\bin\openssl.exe"
            
            if (Test-Path $opensslPath) {
                $opensslInstalled = $true
                
                # Add to PATH for current session
                $env:Path += ";$opensslInstallPath\bin"
                
                # Add to system PATH permanently
                $currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
                if ($currentPath -notlike "*$opensslInstallPath\bin*") {
                    [Environment]::SetEnvironmentVariable("Path", "$currentPath;$opensslInstallPath\bin", "Machine")
                    Write-Host "Added OpenSSL to system PATH" -ForegroundColor Green
                }
                
                Write-Host "OpenSSL installed successfully" -ForegroundColor Green
            } else {
                throw "OpenSSL installation failed"
            }
            
            # Clean up installer
            Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
            
        } catch {
            Write-Host "Failed to download or install OpenSSL: $_" -ForegroundColor Red
            Write-Host "Please install OpenSSL manually from https://slproweb.com/products/Win32OpenSSL.html" -ForegroundColor Yellow
            exit 1
        }
    }
}

# Configure OpenSSL environment
$opensslCfgPath = if ($opensslPath -eq "openssl") {
    $cfgPaths = @(
        "$env:ProgramFiles\OpenSSL-Win64\bin\openssl.cfg",
        "$env:ProgramFiles\OpenSSL-Win64\ssl\openssl.cnf",
        "C:\Tools\OpenSSL\bin\openssl.cfg",
        "C:\Tools\OpenSSL\ssl\openssl.cnf"
    )
    $cfgPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
} else {
    $opensslDir = Split-Path (Split-Path $opensslPath -Parent) -Parent
    $cfgPaths = @(
        "$opensslDir\bin\openssl.cfg",
        "$opensslDir\ssl\openssl.cnf"
    )
    $cfgPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if ($opensslCfgPath) {
    $env:OPENSSL_CONF = $opensslCfgPath
    Write-Host "OpenSSL config: $opensslCfgPath" -ForegroundColor Gray
}

# Check for Java/keytool
Write-Host "`nChecking for Java/keytool..." -ForegroundColor Gray
$keytoolPath = "keytool"
$javaInstalled = $false

try {
    & $keytoolPath -help 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $javaInstalled = $true
        Write-Host "Java keytool found in PATH" -ForegroundColor Green
    }
} catch {
    # Try to find Java installation
    $javaHome = $env:JAVA_HOME
    if ($javaHome -and (Test-Path "$javaHome\bin\keytool.exe")) {
        $keytoolPath = "$javaHome\bin\keytool.exe"
        $javaInstalled = $true
        Write-Host "Java keytool found at: $keytoolPath" -ForegroundColor Green
    } else {
        # Common Java installation paths
        $possiblePaths = @(
            "C:\Program Files\Java\jdk*\bin\keytool.exe",
            "C:\Program Files (x86)\Java\jdk*\bin\keytool.exe",
            "C:\Program Files\Eclipse Adoptium\jdk*\bin\keytool.exe",
            "C:\Program Files\OpenJDK\jdk*\bin\keytool.exe"
        )
        $keytoolPath = Get-ChildItem -Path $possiblePaths -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        if ($keytoolPath) {
            $javaInstalled = $true
            Write-Host "Java keytool found at: $keytoolPath" -ForegroundColor Green
        }
    }
}

if (-not $javaInstalled) {
    Write-Host "Java keytool not found. Please ensure Java JDK is installed." -ForegroundColor Red
    Write-Host "You can download it from: https://adoptium.net/" -ForegroundColor Yellow
    Write-Host "After installation, set JAVA_HOME environment variable to the Java installation directory." -ForegroundColor Yellow
    exit 1
}

# Check for Posh-ACME module
Write-Host "`nChecking for Posh-ACME module..." -ForegroundColor Gray
if (-not (Get-Module -ListAvailable -Name Posh-ACME)) {
    Write-Host "Posh-ACME module not found. Installing..." -ForegroundColor Yellow
    try {
        Install-Module -Name Posh-ACME -Scope CurrentUser -Force -AllowClobber
        Write-Host "Posh-ACME module installed successfully" -ForegroundColor Green
    } catch {
        Write-Host "Failed to install Posh-ACME module: $_" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "Posh-ACME module found" -ForegroundColor Green
}

# Import Posh-ACME module
Import-Module Posh-ACME -Force

Write-Host "`nAll prerequisites satisfied!" -ForegroundColor Green
Write-Host ""

# Step 2: Remove existing PA Account(s)
Write-Host "Step 2: Removing existing PA Account(s)..." -ForegroundColor Yellow
try {
    $existingAccounts = Get-PAAccount -ErrorAction SilentlyContinue
    if ($existingAccounts) {
        Remove-PAAccount -ID ((Get-PAAccount).ID | Out-String).Trim() -Force
        Write-Host "Existing account(s) removed successfully." -ForegroundColor Green
    } else {
        Write-Host "No existing accounts found to remove." -ForegroundColor Gray
    }
} catch {
    Write-Host "Error removing account: $_" -ForegroundColor Red
}

# Step 3: Set PA Server
Write-Host "`nStep 3: Setting PA Server..." -ForegroundColor Yellow
try {
    Set-PAServer -DirectoryUrl https://demo.one.digicert.com/mpki/api/v1/acme/v2/directory
    Write-Host "PA Server set to DigiCert demo directory." -ForegroundColor Green
} catch {
    Write-Host "Error setting PA Server: $_" -ForegroundColor Red
    exit 1
}

# Step 4: Create new PA Account with EAB credentials
Write-Host "`nStep 4: Creating new PA Account..." -ForegroundColor Yellow
try {
    $eabKID = '<ACME KID>'
    $eabHMAC = '<ACME HMAC>'
    
    New-PAAccount -ExtAcctKID $eabKID -ExtAcctHMACKey $eabHMAC -Contact 'michael.rudloff@digicert.com' -AcceptTOS
    Write-Host "New PA Account created successfully." -ForegroundColor Green
} catch {
    Write-Host "Error creating PA Account: $_" -ForegroundColor Red
    exit 1
}

# Step 5: Configure Route53 plugin arguments
Write-Host "`nStep 5: Configuring Route53 plugin..." -ForegroundColor Yellow
$pArgs = @{
    R53AccessKey = '< AWS Access Key ID>'
    R53SecretKey = '< AWS Secret Access Key>' | ConvertTo-SecureString -AsPlainText -Force
}
Write-Host "Route53 plugin configured." -ForegroundColor Green

# Step 6: Request new certificate
Write-Host "`nStep 6: Requesting new certificate for $domain..." -ForegroundColor Yellow
try {
    $cert = New-PACertificate $domain -Plugin Route53 -PluginArgs $pArgs
    
    if ($cert) {
        Write-Host "Certificate requested successfully!" -ForegroundColor Green
        Write-Host "`nCertificate Details:" -ForegroundColor Cyan
        Write-Host "Subject: $($cert.Subject)"
        Write-Host "Thumbprint: $($cert.Thumbprint)"
        Write-Host "NotBefore: $($cert.NotBefore)"
        Write-Host "NotAfter: $($cert.NotAfter)"
        Write-Host "Certificate Path: $($cert.CertFile)"
        Write-Host "Key Path: $($cert.KeyFile)"
        
        # Store paths for later use
        $certPath = $cert.CertFile
        $keyPath = $cert.KeyFile
        $chainPath = $cert.ChainFile
    }
} catch {
    Write-Host "Error requesting certificate: $_" -ForegroundColor Red
    exit 1
}

# Step 7: Create Java Keystore
Write-Host "`nStep 7: Creating Java Keystore for Tomcat..." -ForegroundColor Yellow
try {
    # Convert certificate and key to PKCS12 format
    $pkcs12Path = "$env:TEMP\$domain.p12"
    
    Write-Host "Converting certificate to PKCS12 format..." -ForegroundColor Gray
    $opensslArgs = @(
        "pkcs12",
        "-export",
        "-in", $certPath,
        "-inkey", $keyPath,
        "-out", $pkcs12Path,
        "-name", $domain,
        "-password", "pass:$keystorePassword"
    )
    
    # Add chain file if it exists
    if ($chainPath -and (Test-Path $chainPath)) {
        $opensslArgs += @("-certfile", $chainPath)
    }
    
    & $opensslPath $opensslArgs
    
    if ($LASTEXITCODE -ne 0) {
        throw "OpenSSL conversion failed"
    }
    
    # Import PKCS12 into Java keystore
    Write-Host "Importing into Java keystore..." -ForegroundColor Gray
    
    # Remove existing keystore if it exists
    if (Test-Path $keystorePath) {
        Remove-Item $keystorePath -Force
    }
    
    # Import PKCS12 into Java keystore
    $keytoolArgs = @(
        "-importkeystore",
        "-deststorepass", $keystorePassword,
        "-destkeystore", $keystorePath,
        "-srckeystore", $pkcs12Path,
        "-srcstoretype", "PKCS12",
        "-srcstorepass", $keystorePassword,
        "-alias", $domain,
        "-noprompt"
    )
    
    # Redirect stderr to stdout to capture all output
    $keytoolOutput = & $keytoolPath $keytoolArgs 2>&1
    
    # Check if keystore was actually created
    if (-not (Test-Path $keystorePath)) {
        throw "Keytool import failed: Keystore file not created"
    }
    
    # Verify the keystore contains our certificate
    Write-Host "Verifying keystore..." -ForegroundColor Gray
    $verifyArgs = @(
        "-list",
        "-keystore", $keystorePath,
        "-storepass", $keystorePassword,
        "-alias", $domain
    )
    
    $verifyOutput = & $keytoolPath $verifyArgs 2>&1
    $aliasFound = $false
    
    foreach ($line in $verifyOutput) {
        if ($line -like "*$domain*" -and $line -like "*PrivateKeyEntry*") {
            $aliasFound = $true
            break
        }
    }
    
    if (-not $aliasFound) {
        throw "Certificate alias '$domain' not found in keystore"
    }
    
    # Clean up temporary PKCS12 file
    Remove-Item $pkcs12Path -Force
    
    Write-Host "Java keystore created successfully at: $keystorePath" -ForegroundColor Green
    
} catch {
    Write-Host "Error creating keystore: $_" -ForegroundColor Red
    exit 1
}

# Step 8: Update Tomcat server.xml
Write-Host "`nStep 8: Updating Tomcat server.xml..." -ForegroundColor Yellow
try {
    # Check if server.xml exists
    if (-not (Test-Path $serverXmlPath)) {
        throw "server.xml not found at: $serverXmlPath"
    }
    
    # Create backup
    Write-Host "Creating backup: $serverXmlBackup" -ForegroundColor Gray
    Copy-Item $serverXmlPath $serverXmlBackup -Force
    
    # Read server.xml
    $xmlContent = Get-Content $serverXmlPath -Raw
    
    # Create the new Certificate element
    $newCertificate = @"
           <Certificate certificateKeystoreFile="conf/$domain.keystore"
                        certificateKeystorePassword="$keystorePassword"
                        certificateKeyAlias="$domain"
                        type="RSA" />
"@
    
    # Replace the Certificate element within SSLHostConfig
    $pattern = '(\s*)<Certificate[^>]*(?:/>|>[^<]*</Certificate>)'
    
    if ($xmlContent -match $pattern) {
        $indentation = $matches[1]
        $xmlContent = $xmlContent -replace $pattern, $newCertificate
        Write-Host "Certificate configuration updated in server.xml" -ForegroundColor Green
    } else {
        Write-Host "Warning: Could not find Certificate element in server.xml" -ForegroundColor Yellow
        Write-Host "You may need to manually update the SSL configuration" -ForegroundColor Yellow
    }
    
    # Save the updated server.xml
    $xmlContent | Set-Content $serverXmlPath -Force
    
    Write-Host "`nTomcat configuration updated successfully!" -ForegroundColor Green
    Write-Host "Keystore location: $keystorePath" -ForegroundColor Cyan
    Write-Host "Keystore password: $keystorePassword" -ForegroundColor Cyan
    Write-Host "Certificate alias: $domain" -ForegroundColor Cyan
    Write-Host "`nPlease restart Tomcat for the changes to take effect." -ForegroundColor Yellow
    
} catch {
    Write-Host "Error updating server.xml: $_" -ForegroundColor Red
    Write-Host "A backup has been created at: $serverXmlBackup" -ForegroundColor Yellow
    exit 1
}

# Step 9: Restart Tomcat Service
Write-Host "`nStep 9: Restarting Tomcat service..." -ForegroundColor Yellow
try {
    # Check if Tomcat service exists
    $tomcatService = Get-Service -Name "Tomcat10" -ErrorAction SilentlyContinue
    
    if ($tomcatService) {
        Write-Host "Found Tomcat10 service. Current status: $($tomcatService.Status)" -ForegroundColor Gray
        
        # Stop the service if it's running
        if ($tomcatService.Status -eq 'Running') {
            Write-Host "Stopping Tomcat10 service..." -ForegroundColor Gray
            Stop-Service -Name "Tomcat10" -Force
            
            # Wait for service to stop
            $timeout = 30
            $timer = 0
            while ((Get-Service -Name "Tomcat10").Status -ne 'Stopped' -and $timer -lt $timeout) {
                Start-Sleep -Seconds 1
                $timer++
            }
            
            if ($timer -eq $timeout) {
                throw "Timeout waiting for Tomcat service to stop"
            }
        }
        
        # Start the service
        Write-Host "Starting Tomcat10 service..." -ForegroundColor Gray
        Start-Service -Name "Tomcat10"
        
        # Wait for service to start
        $timer = 0
        while ((Get-Service -Name "Tomcat10").Status -ne 'Running' -and $timer -lt $timeout) {
            Start-Sleep -Seconds 1
            $timer++
        }
        
        if ((Get-Service -Name "Tomcat10").Status -eq 'Running') {
            Write-Host "Tomcat10 service restarted successfully!" -ForegroundColor Green
            
            # Give Tomcat a few seconds to fully initialize
            Write-Host "Waiting for Tomcat to initialize..." -ForegroundColor Gray
            Start-Sleep -Seconds 5
        } else {
            throw "Failed to start Tomcat service"
        }
    } else {
        Write-Host "Tomcat10 service not found. Trying other common service names..." -ForegroundColor Yellow
        
        # Try other common Tomcat service names
        $possibleServiceNames = @("Tomcat9", "Tomcat8", "Tomcat", "Apache Tomcat")
        $foundService = $null
        
        foreach ($serviceName in $possibleServiceNames) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service) {
                $foundService = $serviceName
                Write-Host "Found service: $serviceName" -ForegroundColor Green
                Restart-Service -Name $serviceName -Force
                Write-Host "$serviceName service restarted successfully!" -ForegroundColor Green
                break
            }
        }
        
        if (-not $foundService) {
            Write-Host "No Tomcat service found. You may need to restart Tomcat manually." -ForegroundColor Yellow
            Write-Host "If Tomcat is running as a standalone process, restart it using:" -ForegroundColor Gray
            Write-Host "  $tomcatHome\bin\shutdown.bat" -ForegroundColor Gray
            Write-Host "  $tomcatHome\bin\startup.bat" -ForegroundColor Gray
        }
    }
} catch {
    Write-Host "Error restarting Tomcat: $_" -ForegroundColor Red
    Write-Host "Please restart Tomcat manually to apply the SSL certificate changes." -ForegroundColor Yellow
}

Write-Host "`n=== Script completed successfully! ===" -ForegroundColor Green
Write-Host "`nYour certificate has been installed and configured." -ForegroundColor Cyan
Write-Host "Test your HTTPS connection at: https://$domain`:8443" -ForegroundColor Green
Write-Host ""
Write-Host "To verify the certificate in your browser:" -ForegroundColor Cyan
Write-Host "1. Navigate to https://$domain`:8443" -ForegroundColor Gray
Write-Host "2. Click the padlock icon in the address bar" -ForegroundColor Gray
Write-Host "3. View certificate details to confirm it's your new certificate" -ForegroundColor Gray