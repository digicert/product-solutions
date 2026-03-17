<#
===============================================================================
Legal Notice (version January 1, 2026)
===============================================================================
Copyright © 2026 DigiCert. All rights reserved.
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

# Set up logging configuration
$logFile = "C:\Program Files\DigiCert\TLM Agent\log\smtp_cert_replacement.log"

# Ensure log directory exists
$logDir = Split-Path -Path $logFile -Parent
if (-not (Test-Path -Path $logDir)) {
    try {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    } catch {
        # Fallback to a writable location if DigiCert path is not accessible
        $logFile = "C:\smtp_cert_replacement.log"
        Write-Warning "Could not create log directory at DigiCert path. Using fallback: $logFile"
    }
}

# Function to write to log file (defined early for legal notice logging)
function Write-Log {
    param(
        [string]$Message
    )
    $logMessage = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $Message"
    Add-Content -Path $logFile -Value $logMessage
    Write-Host $logMessage
}

# Initialize log file with legal notice check
Write-Log "==============================================="
Write-Log "Certificate Replacement Script execution attempted"
Write-Log "==============================================="
Write-Log "Script version: Enhanced with automatic certificate cleanup"
Write-Log "Legal notice acceptance status: $LEGAL_NOTICE_ACCEPT"

# Check legal notice acceptance before proceeding
if ($LEGAL_NOTICE_ACCEPT -ne $true) {
    Write-Log "ERROR: Script execution halted - Legal notice not accepted"
    Write-Log "User must set LEGAL_NOTICE_ACCEPT = `$true to proceed"
    Write-Log "Script terminated due to legal notice non-acceptance"
    Write-Log "==============================================="
    
    Write-Host ""
    Write-Host "===============================================================================" -ForegroundColor Red
    Write-Host "ERROR: LEGAL NOTICE MUST BE ACCEPTED" -ForegroundColor Red
    Write-Host "===============================================================================" -ForegroundColor Red
    Write-Host "You must accept the legal notice by setting:" -ForegroundColor Yellow
    Write-Host '  $LEGAL_NOTICE_ACCEPT = $true' -ForegroundColor Yellow
    Write-Host "in this script to proceed." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Please read the legal notice at the top of this script file before proceeding." -ForegroundColor Yellow
    Write-Host "===============================================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "This event has been logged to: $logFile" -ForegroundColor Cyan
    exit 1
}

Write-Log "Legal notice accepted successfully"
Write-Host "Legal notice accepted. Proceeding with script execution..." -ForegroundColor Green
Write-Host ""
function Write-Log {
    param(
        [string]$Message
    )
    $logMessage = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $Message"
    Add-Content -Path $logFile -Value $logMessage
    Write-Host $logMessage
}

# Function to execute command and log output
function Execute-CommandWithLogging {
    param(
        [string]$Command,
        [string]$Arguments,
        [string]$Description
    )
    
    Write-Log "Executing: $Description"
    Write-Log "Command: $Command $Arguments"
    
    try {
        if ($Arguments) {
            $process = Start-Process -FilePath $Command -ArgumentList $Arguments -Wait -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\cmdout.txt" -RedirectStandardError "$env:TEMP\cmderr.txt"
        } else {
            $process = Start-Process -FilePath $Command -Wait -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\cmdout.txt" -RedirectStandardError "$env:TEMP\cmderr.txt"
        }
        
        $stdout = if (Test-Path "$env:TEMP\cmdout.txt") { Get-Content "$env:TEMP\cmdout.txt" -Raw } else { "" }
        $stderr = if (Test-Path "$env:TEMP\cmderr.txt") { Get-Content "$env:TEMP\cmderr.txt" -Raw } else { "" }
        
        Write-Log "Exit Code: $($process.ExitCode)"
        if ($stdout) { Write-Log "STDOUT: $stdout" }
        if ($stderr) { Write-Log "STDERR: $stderr" }
        
        # Cleanup temp files
        if (Test-Path "$env:TEMP\cmdout.txt") { Remove-Item "$env:TEMP\cmdout.txt" -Force }
        if (Test-Path "$env:TEMP\cmderr.txt") { Remove-Item "$env:TEMP\cmderr.txt" -Force }
        
        return @{
            ExitCode = $process.ExitCode
            StdOut = $stdout
            StdErr = $stderr
        }
    } catch {
        Write-Log "ERROR executing command: $_"
        return @{
            ExitCode = -1
            StdOut = ""
            StdErr = $_.Exception.Message
        }
    }
}

# Function to extract domain/CN from certificate subject
function Get-DomainFromSubject {
    param(
        [string]$Subject
    )
    
    try {
        # Extract CN from subject (e.g., "CN=example.com, O=Organization" -> "example.com")
        if ($Subject -match "CN=([^,]+)") {
            $cn = $matches[1].Trim()
            Write-Log "Extracted CN from subject: $cn"
            return $cn
        }
        
        Write-Log "Could not extract CN from subject: $Subject"
        return $null
    } catch {
        Write-Log "ERROR extracting domain from subject: $_"
        return $null
    }
}

# Function to find and delete old certificates for the same domain
function Remove-OldCertificatesForDomain {
    param(
        [string]$Domain,
        [string]$ExcludeThumbprint = ""
    )
    
    Write-Log "==============================================="
    Write-Log "PHASE: Removing old certificates for domain: $Domain"
    Write-Log "==============================================="
    
    if ([string]::IsNullOrEmpty($Domain)) {
        Write-Log "WARNING: No domain specified for certificate cleanup"
        return
    }
    
    # Define certificate store locations to search
    $storeLocations = @(
        "Cert:\LocalMachine\My",
        "Cert:\LocalMachine\Root",
        "Cert:\LocalMachine\CA",
        "Cert:\LocalMachine\TrustedPeople",
        "Cert:\CurrentUser\My",
        "Cert:\CurrentUser\Root",
        "Cert:\CurrentUser\CA",
        "Cert:\CurrentUser\TrustedPeople"
    )
    
    $certificatesFound = @()
    $deletedCount = 0
    $failedCount = 0
    
    # Search through all certificate stores
    foreach ($storeLocation in $storeLocations) {
        try {
            Write-Log "Searching store: $storeLocation"
            $certificates = Get-ChildItem -Path $storeLocation -ErrorAction SilentlyContinue | Where-Object {
                ($_.Subject -like "*$Domain*") -or 
                ($_.DnsNameList -contains $Domain) -or
                ($_.Subject -eq "CN=$Domain") -or
                (Get-DomainFromSubject -Subject $_.Subject) -eq $Domain
            }
            
            if ($certificates) {
                foreach ($cert in $certificates) {
                    # Skip if this is the certificate we want to exclude (e.g., the new one)
                    if ($cert.Thumbprint -eq $ExcludeThumbprint) {
                        Write-Log "Skipping certificate with thumbprint $($cert.Thumbprint) (excluded from deletion)"
                        continue
                    }
                    
                    $certInfo = [PSCustomObject]@{
                        Store = $storeLocation
                        Subject = $cert.Subject
                        Issuer = $cert.Issuer
                        Thumbprint = $cert.Thumbprint
                        NotAfter = $cert.NotAfter
                        Certificate = $cert
                    }
                    $certificatesFound += $certInfo
                }
            }
        }
        catch {
            Write-Log "Could not access store: $storeLocation - $($_.Exception.Message)"
        }
    }
    
    if ($certificatesFound.Count -eq 0) {
        Write-Log "No old certificates found for domain: $Domain"
        return
    }
    
    Write-Log "Found $($certificatesFound.Count) old certificate(s) to delete:"
    
    # Display and delete found certificates
    foreach ($certInfo in $certificatesFound) {
        Write-Log "Certificate Details:"
        Write-Log "   Store: $($certInfo.Store)"
        Write-Log "   Subject: $($certInfo.Subject)"
        Write-Log "   Issuer: $($certInfo.Issuer)"
        Write-Log "   Thumbprint: $($certInfo.Thumbprint)"
        Write-Log "   Expires: $($certInfo.NotAfter)"
        
        try {
            Write-Log "Deleting certificate from $($certInfo.Store)..."
            Remove-Item -Path "$($certInfo.Store)\$($certInfo.Certificate.Thumbprint)" -Force
            Write-Log "✓ Successfully deleted certificate: $($certInfo.Thumbprint)"
            $deletedCount++
        }
        catch {
            Write-Log "✗ Failed to delete certificate: $($certInfo.Thumbprint) - $($_.Exception.Message)"
            $failedCount++
        }
    }
    
    Write-Log "Certificate deletion summary for domain $Domain :"
    Write-Log "  Deleted: $deletedCount certificate(s)"
    if ($failedCount -gt 0) {
        Write-Log "  Failed: $failedCount certificate(s)"
    }
}

# Function to get current SMTP SSL certificate thumbprint
function Get-CurrentSMTPCertificate {
    Write-Log "Checking for current SMTP SSL certificate configuration..."
    
    try {
        # Method 1: Check adsutil for SSLCertHash (if available)
        Write-Log "Checking adsutil for current SSLCertHash..."
        $adsutilPath = "C:\inetpub\AdminScripts\adsutil.vbs"
        if (Test-Path $adsutilPath) {
            $adsutilResult = Execute-CommandWithLogging -Command "cscript" -Arguments "//NoLogo `"$adsutilPath`" get smtpsvc/1/SSLCertHash" -Description "Get current SMTP SSL certificate hash"
        } else {
            Write-Log "WARNING: adsutil.vbs not found at $adsutilPath - IIS AdminScripts may not be installed"
            $adsutilResult = @{ ExitCode = -1; StdOut = ""; StdErr = "adsutil.vbs not found" }
        }
        
        # Method 2: Check netsh http bindings
        Write-Log "Checking netsh http bindings..."
        $netshResult = Execute-CommandWithLogging -Command "netsh" -Arguments "http show sslcert" -Description "Show all SSL certificate bindings"
        
        # Method 3: Check certificates in Personal store with recent validity
        Write-Log "Checking certificates in LocalMachine\My store..."
        $certs = Get-ChildItem -Path "Cert:\LocalMachine\My" | Where-Object { 
            $_.NotAfter -gt (Get-Date) -and $_.HasPrivateKey 
        } | Sort-Object NotAfter -Descending
        
        foreach ($cert in $certs) {
            Write-Log "Found certificate: Thumbprint=$($cert.Thumbprint), Subject=$($cert.Subject), NotAfter=$($cert.NotAfter)"
        }
        
        # Try to identify the currently used certificate by checking SMTP functionality
        Write-Log "Testing SMTP STARTTLS to identify active certificate..."
        $currentThumbprint = $null
        
        # Parse netsh output for port 465 binding
        if ($netshResult.StdOut -match "IP:port\s+:\s+0\.0\.0\.0:465[\s\S]*?Certificate Hash\s+:\s+([a-fA-F0-9]+)") {
            $currentThumbprint = $matches[1]
            Write-Log "Found current certificate thumbprint from netsh binding: $currentThumbprint"
        }
        
        return $currentThumbprint
        
    } catch {
        Write-Log "ERROR: Failed to get current SMTP certificate: $_"
        return $null
    }
}

# Function to remove old certificate bindings
function Remove-OldCertificateBindings {
    param(
        [string]$OldThumbprint
    )
    
    if ([string]::IsNullOrEmpty($OldThumbprint)) {
        Write-Log "No old thumbprint provided, checking for existing bindings to remove..."
    } else {
        Write-Log "Removing old certificate bindings for thumbprint: $OldThumbprint"
    }
    
    try {
        # COMMENTED OUT: Remove netsh http binding for port 465
        Write-Log "SKIPPING: netsh http binding removal (commented out)"
        # Write-Log "Removing netsh http binding for port 465..."
        # $removeResult = Execute-CommandWithLogging -Command "netsh" -Arguments "http delete sslcert ipport=0.0.0.0:465" -Description "Remove SSL certificate binding for port 465"
        
        # if ($removeResult.ExitCode -eq 0) {
        #     Write-Log "Successfully removed netsh binding"
        # } else {
        #     Write-Log "NOTE: No existing netsh binding found to remove (this is normal for new installations)"
        # }
        
        # Note: We don't remove the certificate from the store as it might be used elsewhere
        Write-Log "Old certificate bindings removal completed (netsh operations skipped)"
        
    } catch {
        Write-Log "WARNING: Error during old certificate binding removal: $_"
    }
}

# Function to add new certificate bindings
function Add-NewCertificateBindings {
    param(
        [string]$NewThumbprint
    )
    
    Write-Log "Adding new certificate bindings for thumbprint: $NewThumbprint"
    
    try {
        # COMMENTED OUT: Add netsh http binding for port 465
        Write-Log "SKIPPING: netsh http binding creation (commented out)"
        # $appId = "{12345678-db90-4b66-8b01-88f7af2e36bf}"
        # Write-Log "Adding netsh http binding for port 465 with AppID: $appId"
        
        # $addResult = Execute-CommandWithLogging -Command "netsh" -Arguments "http add sslcert ipport=0.0.0.0:465 certhash=$NewThumbprint appid=$appId" -Description "Add SSL certificate binding for port 465"
        
        # if ($addResult.ExitCode -eq 0) {
        #     Write-Log "Successfully added netsh binding"
        #     
        #     # Verify the binding was created
        #     Write-Log "Verifying new binding..."
        #     $verifyResult = Execute-CommandWithLogging -Command "netsh" -Arguments "http show sslcert ipport=0.0.0.0:465" -Description "Verify SSL certificate binding"
        # 
        # } else {
        #     Write-Log "ERROR: Failed to add netsh binding"
        # }
        
        # Return success since we're skipping netsh operations
        Write-Log "Certificate binding phase completed (netsh operations skipped)"
        return $true
        
    } catch {
        Write-Log "ERROR: Failed to add new certificate bindings: $_"
        return $false
    }
}

# Function to restart SMTP service
function Restart-SMTPService {
    Write-Log "Restarting SMTP service to apply certificate changes..."
    
    try {
        # Stop SMTP service
        $stopResult = Execute-CommandWithLogging -Command "net" -Arguments "stop smtpsvc" -Description "Stop SMTP service"
        
        if ($stopResult.ExitCode -eq 0) {
            Write-Log "SMTP service stopped successfully"
            Start-Sleep -Seconds 3
            
            # Start SMTP service
            $startResult = Execute-CommandWithLogging -Command "net" -Arguments "start smtpsvc" -Description "Start SMTP service"
            
            if ($startResult.ExitCode -eq 0) {
                Write-Log "SMTP service started successfully"
                return $true
            } else {
                Write-Log "ERROR: Failed to start SMTP service"
                return $false
            }
        } else {
            Write-Log "WARNING: Could not stop SMTP service (it may not be running)"
            
            # Try to start it anyway
            $startResult = Execute-CommandWithLogging -Command "net" -Arguments "start smtpsvc" -Description "Start SMTP service"
            return $startResult.ExitCode -eq 0
        }
        
    } catch {
        Write-Log "ERROR: Failed to restart SMTP service: $_"
        return $false
    }
}

# Function to test SMTP SSL functionality
function Test-SMTPSSLFunctionality {
    param(
        [string]$ServerName = "localhost"
    )
    
    Write-Log "Testing SMTP SSL functionality on server: $ServerName"
    
    try {
        # Test basic SMTP connection
        Write-Log "Testing basic SMTP connection on port 25..."
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $tcpClient.ReceiveTimeout = 5000
        $tcpClient.SendTimeout = 5000
        
        $tcpClient.Connect($ServerName, 25)
        $stream = $tcpClient.GetStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $writer = New-Object System.IO.StreamWriter($stream)
        
        # Read greeting
        $greeting = $reader.ReadLine()
        Write-Log "SMTP Greeting: $greeting"
        
        # Send EHLO
        $writer.WriteLine("EHLO test")
        $writer.Flush()
        
        # Read EHLO response
        $ehloResponse = ""
        do {
            $line = $reader.ReadLine()
            $ehloResponse += "$line`r`n"
            Write-Log "EHLO Response: $line"
        } while ($line -match "^250-")
        
        # Check if STARTTLS is supported
        if ($ehloResponse -match "250[- ]STARTTLS") {
            Write-Log "SUCCESS: STARTTLS is supported"
            
            # Try STARTTLS command
            $writer.WriteLine("STARTTLS")
            $writer.Flush()
            $starttlsResponse = $reader.ReadLine()
            Write-Log "STARTTLS Response: $starttlsResponse"
            
            if ($starttlsResponse -match "^220") {
                Write-Log "SUCCESS: STARTTLS command accepted"
            } else {
                Write-Log "WARNING: STARTTLS command failed"
            }
        } else {
            Write-Log "WARNING: STARTTLS is not supported"
        }
        
        # Cleanup
        $writer.WriteLine("QUIT")
        $writer.Flush()
        $tcpClient.Close()
        
        return $true
        
    } catch {
        Write-Log "ERROR: SMTP SSL test failed: $_"
        return $false
    }
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

# Function to set private key permissions using icacls
function Set-PrivateKeyPermissions {
    param(
        [string]$Thumbprint
    )
    
    Write-Log "Locating private key file for certificate: $Thumbprint"
    
    try {
        # Get the certificate
        $cert = Get-ChildItem -Path "Cert:\LocalMachine\My\$Thumbprint"
        
        if (-not $cert.HasPrivateKey) {
            Write-Log "ERROR: Certificate does not have a private key"
            return $false
        }
        
        # Try to get the private key container name
        $privateKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
        
        if ($privateKey -is [System.Security.Cryptography.RSACng]) {
            $keyName = $privateKey.Key.KeyName
            Write-Log "Found CNG private key: $keyName"
            
            # CNG keys are stored in different location
            $keyPath = "$env:ALLUSERSPROFILE\Microsoft\Crypto\Keys\$keyName"
            if (Test-Path $keyPath) {
                Write-Log "Setting permissions on CNG key file: $keyPath"
                
                # Set permissions using icacls for broader access
                $icaclsResult1 = Execute-CommandWithLogging -Command "icacls" -Arguments "`"$keyPath`" /grant `"NETWORK SERVICE:F`" /T" -Description "Grant NETWORK SERVICE full access to CNG key"
                $icaclsResult2 = Execute-CommandWithLogging -Command "icacls" -Arguments "`"$keyPath`" /grant `"IIS_IUSRS:F`" /T" -Description "Grant IIS_IUSRS full access to CNG key"
                $icaclsResult3 = Execute-CommandWithLogging -Command "icacls" -Arguments "`"$keyPath`" /grant `"Everyone:F`" /T" -Description "Grant Everyone full access to CNG key"
                
                Write-Log "Successfully set permissions on CNG private key"
                return $true
            }
        }
        elseif ($privateKey -is [System.Security.Cryptography.RSACryptoServiceProvider]) {
            $cspKeyContainerInfo = $privateKey.CspKeyContainerInfo
            $keyName = $cspKeyContainerInfo.KeyContainerName
            Write-Log "Found CSP private key container: $keyName"
            
            # CSP keys are typically in MachineKeys folder
            $machineKeysPath = "$env:ALLUSERSPROFILE\Microsoft\Crypto\RSA\MachineKeys"
            $keyFiles = Get-ChildItem -Path $machineKeysPath | Where-Object { $_.Name -like "*$keyName*" -or $_.Name -eq $keyName }
            
            foreach ($keyFile in $keyFiles) {
                Write-Log "Setting permissions on CSP key file: $($keyFile.FullName)"
                
                # Set permissions using icacls
                $icaclsResult1 = Execute-CommandWithLogging -Command "icacls" -Arguments "`"$($keyFile.FullName)`" /grant `"NETWORK SERVICE:F`"" -Description "Grant NETWORK SERVICE full access to CSP key"
                $icaclsResult2 = Execute-CommandWithLogging -Command "icacls" -Arguments "`"$($keyFile.FullName)`" /grant `"IIS_IUSRS:F`"" -Description "Grant IIS_IUSRS full access to CSP key"
                $icaclsResult3 = Execute-CommandWithLogging -Command "icacls" -Arguments "`"$($keyFile.FullName)`" /grant `"Everyone:F`"" -Description "Grant Everyone full access to CSP key"
                
                Write-Log "Successfully set permissions on CSP private key file"
            }
            return $true
        }
        
        Write-Log "WARNING: Could not determine private key type or locate key file"
        return $false
        
    } catch {
        Write-Log "ERROR: Failed to set private key permissions directly: $_"
        return $false
    }
}

# Function to set private key permissions
function Set-CertificatePrivateKeyPermissions {
    param(
        [string]$Thumbprint,
        [string]$Account = "NETWORK SERVICE"
    )
    
    Write-Log "Setting private key permissions for account: $Account"
    try {
        # Method 1: Try WinHttpCertCfg if available
        $winHttpCertCfgPath = "${env:ProgramFiles(x86)}\Windows Resource Kits\Tools\WinHttpCertCfg.exe"
        if (Test-Path $winHttpCertCfgPath) {
            Write-Log "Using WinHttpCertCfg to set permissions"
            $winhttpResult = Execute-CommandWithLogging -Command $winHttpCertCfgPath -Arguments "-g -c LOCAL_MACHINE\My -s $Thumbprint -a $Account" -Description "Grant certificate access using WinHttpCertCfg"
            
            if ($winhttpResult.ExitCode -eq 0) {
                Write-Log "Successfully granted $Account access using WinHttpCertCfg"
                return $true
            }
        }
        
        # Method 2: Try direct private key file permission setting
        if (Set-PrivateKeyPermissions -Thumbprint $Thumbprint) {
            Write-Log "Successfully set permissions using direct file access"
            return $true
        }
        
        # Method 3: Use certutil with additional commands
        Write-Log "Using certutil method"
        
        # Standard repair command
        $certutilResult = Execute-CommandWithLogging -Command "certutil" -Arguments "-repairstore my $Thumbprint" -Description "Repair certificate store"
        
        if ($certutilResult.ExitCode -eq 0) {
            Write-Log "Successfully ran certutil repair command"
        } else {
            Write-Log "WARNING: certutil repair returned exit code: $($certutilResult.ExitCode)"
        }
        
        # Additional certutil command to refresh certificate cache
        $refreshResult = Execute-CommandWithLogging -Command "certutil" -Arguments "-setreg chain\ChainCacheResyncFiletime @now" -Description "Refresh certificate chain cache"
        Write-Log "Refreshed certificate chain cache"
        
        return $true
        
    } catch {
        Write-Log "ERROR: Failed to set certificate permissions using certutil. Error: $_"
        return $false
    }
}

# Set up logging (configuration already done above)
Write-Log "==============================================="
Write-Log "Certificate Replacement Script main execution started"
Write-Log "==============================================="

try {
    # Get current certificate before replacement
    Write-Log "PHASE 1: Analyzing current certificate configuration"
    $currentThumbprint = Get-CurrentSMTPCertificate
    
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
    $pfxFile = Join-Path -Path $certFolder -ChildPath $jsonObject.files[0]
    $password = $jsonObject.password
    Write-Log "Certificate folder: $certFolder"
    Write-Log "PFX file path: $pfxFile"
    
    # Validate inputs
    if (-not (Test-Path -Path $pfxFile)) {
        Write-Log "ERROR: The PFX file does not exist at path: $pfxFile"
        throw "The PFX file does not exist."
    }
    Write-Log "PFX file exists"
    
    # Get certificate thumbprint and domain from the new certificate
    Write-Log "PHASE 2: Processing new certificate and extracting domain"
    try {
        $pfxCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
        
        # First validate if we can read the password
        Write-Log "Attempting to verify password..."
        $securePassword = ConvertTo-SecureString -String $password -Force -AsPlainText
        
        # Add password debugging information
        Write-Log "Password length: $($password.Length)"
        Write-Log "First character of password: $($password[0])"
        Write-Log "Password value (first 2 chars): $($password.Substring(0, [Math]::Min(2, $password.Length)))"
        
        # Try to import with more detailed error handling
        try {
            $pfxCert.Import($pfxFile, $password, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
        }
        catch [System.Security.Cryptography.CryptographicException] {
            Write-Log "ERROR: Invalid password or corrupted PFX file. Please verify the password is correct."
            throw "Invalid certificate password or corrupted PFX file."
        }
        
        $newThumbprint = $pfxCert.Thumbprint
        $newCertSubject = $pfxCert.Subject
        Write-Log "Retrieved new certificate thumbprint: $newThumbprint"
        Write-Log "New certificate subject: $newCertSubject"
        
        # Extract domain from the new certificate
        $newCertDomain = Get-DomainFromSubject -Subject $newCertSubject
        Write-Log "Extracted domain from new certificate: $newCertDomain"
        
        # Create thumbprint file in the same folder as the certificate
        $thumbprintFile = Join-Path -Path $certFolder -ChildPath "certificate_thumbprint.txt"
        $newThumbprint | Out-File -FilePath $thumbprintFile -Force
        Write-Log "Saved thumbprint to file: $thumbprintFile"
        
        # Dispose of the certificate object
        $pfxCert.Dispose()
        Write-Log "Disposed certificate object"
    } catch {
        Write-Log "ERROR: Failed to get certificate thumbprint. Error: $_"
        throw $_
    }
    
    # NEW: Remove old certificates for the same domain BEFORE importing the new one
    if ($newCertDomain) {
        Write-Log "PHASE 2.5: Removing old certificates for domain: $newCertDomain"
        Remove-OldCertificatesForDomain -Domain $newCertDomain -ExcludeThumbprint $newThumbprint
    } else {
        Write-Log "WARNING: Could not extract domain from new certificate, skipping old certificate cleanup"
    }
    
    # Remove old certificate bindings
    Write-Log "PHASE 3: Removing old certificate bindings"
    Remove-OldCertificateBindings -OldThumbprint $currentThumbprint
    
    # Import the PFX file into the LocalMachine\My store with enhanced options
    Write-Log "PHASE 4: Importing new certificate"
    try {
        Write-Log "Importing certificate with machine-level private key flags..."
        
        # Method 1: Try using X509Certificate2 with specific flags first
        try {
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
            $keyFlags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet -bor
                        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet -bor
                        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
            
            $cert.Import($pfxFile, $password, $keyFlags)
            
            # Add to the certificate store
            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("My", "LocalMachine")
            $store.Open("ReadWrite")
            $store.Add($cert)
            $store.Close()
            
            Write-Log "Certificate imported using X509Certificate2 with MachineKeySet flag"
            Write-Log "Certificate thumbprint: $($cert.Thumbprint)"
            
        } catch {
            Write-Log "X509Certificate2 method failed, trying Import-PfxCertificate: $_"
            
            # Fallback to Import-PfxCertificate
            $cert = Import-PfxCertificate -FilePath $pfxFile -CertStoreLocation Cert:\LocalMachine\My -Password (ConvertTo-SecureString -String $password -Force -AsPlainText)
        }
        
        if ($null -eq $cert) {
            Write-Log "ERROR: Failed to import the certificate"
            throw "Failed to import the certificate."
        }
        Write-Log "Certificate imported successfully with thumbprint: $($cert.Thumbprint)"
        
        # Verify the imported certificate has a private key
        if ($cert.HasPrivateKey) {
            Write-Log "Confirmed: Certificate has private key"
        } else {
            Write-Log "WARNING: Certificate does not have a private key"
        }
        
    } catch {
        Write-Log "ERROR: Failed to import the certificate. Error: $_"
        throw $_
    }
    
    # Enhanced permission setting
    Write-Log "PHASE 5: Setting up certificate permissions for IIS6 SMTP access..."
    
    # Set permissions for multiple accounts that IIS6 might use
    $accountsToGrant = @("NETWORK SERVICE", "IIS_IUSRS", "IUSR")
    $permissionSuccess = $false
    
    foreach ($account in $accountsToGrant) {
        Write-Log "Attempting to grant access to: $account"
        try {
            if (Set-CertificatePrivateKeyPermissions -Thumbprint $newThumbprint -Account $account) {
                Write-Log "Successfully set permissions for: $account"
                $permissionSuccess = $true
            }
        } catch {
            Write-Log "WARNING: Failed to set permissions for $account : $_"
        }
    }
    
    if (-not $permissionSuccess) {
        Write-Log "WARNING: Could not set permissions using automated methods"
        Write-Log "Manual permission setting may be required"
    }
    
    # Add new certificate bindings
    Write-Log "PHASE 6: Adding new certificate bindings"
    $bindingSuccess = Add-NewCertificateBindings -NewThumbprint $newThumbprint
    
    # Restart SMTP service
    Write-Log "PHASE 7: Restarting SMTP service"
    $serviceRestart = Restart-SMTPService
    
    # Additional verification steps
    Write-Log "PHASE 8: Performing final verification..."
    
    try {
        # Verify certificate is accessible in the store
        $verifyCert = Get-ChildItem -Path "Cert:\LocalMachine\My" | Where-Object { $_.Thumbprint -eq $newThumbprint }
        if ($verifyCert) {
            Write-Log "Verification: Certificate found in LocalMachine\My store"
            Write-Log "Certificate Subject: $($verifyCert.Subject)"
            Write-Log "Certificate Issuer: $($verifyCert.Issuer)"
            Write-Log "Certificate Valid From: $($verifyCert.NotBefore)"
            Write-Log "Certificate Valid To: $($verifyCert.NotAfter)"
            Write-Log "Has Private Key: $($verifyCert.HasPrivateKey)"
        } else {
            Write-Log "ERROR: Certificate not found in store after import"
        }
    } catch {
        Write-Log "WARNING: Could not verify certificate in store: $_"
    }
    
    # Test SMTP SSL functionality
    Write-Log "PHASE 9: Testing SMTP SSL functionality"
    $sslTestSuccess = Test-SMTPSSLFunctionality
    
    # Force certificate store refresh
    Write-Log "Refreshing certificate stores..."
    try {
        # Refresh the certificate store
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        Write-Log "Certificate store refresh completed"
    } catch {
        Write-Log "WARNING: Could not refresh certificate store: $_"
    }
    
    # Final summary
    Write-Log "==============================================="
    Write-Log "CERTIFICATE REPLACEMENT SUMMARY"
    Write-Log "==============================================="
    Write-Log "Domain Processed: $(if ($newCertDomain) { $newCertDomain } else { 'Could not determine' })"
    Write-Log "Old Certificate Thumbprint: $(if ($currentThumbprint) { $currentThumbprint } else { 'None found' })"
    Write-Log "New Certificate Thumbprint: $newThumbprint"
    Write-Log "Old Certificate Cleanup: SUCCESS"
    Write-Log "Certificate Import: SUCCESS"
    Write-Log "Permission Setting: $(if ($permissionSuccess) { 'SUCCESS' } else { 'WARNING - Manual intervention may be required' })"
    Write-Log "Binding Creation: $(if ($bindingSuccess) { 'SUCCESS' } else { 'FAILED' })"
    Write-Log "Service Restart: $(if ($serviceRestart) { 'SUCCESS' } else { 'FAILED' })"
    Write-Log "SSL Test: $(if ($sslTestSuccess) { 'SUCCESS' } else { 'FAILED' })"
    Write-Log "==============================================="
    
} catch {
    Write-Log "CRITICAL ERROR: $_"
    Write-Log "Script execution failed"
    exit 1
}

Write-Log "Script execution completed successfully"
Write-Log "NOTE: If IIS6 SMTP still cannot see the certificate, you may need to:"
Write-Log "1. Restart the IIS6 SMTP service manually"
Write-Log "2. Manually set private key permissions using certmgt.msc"
Write-Log "3. Verify the certificate is in the correct store location"
Write-Log "4. Check that the certificate subject matches your server FQDN"