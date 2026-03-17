<#
.SYNOPSIS
    DigiCert TLM Agent Certificate Processing Script (CRT/KEY Format) - PowerShell Version
.DESCRIPTION
    PowerShell conversion of the original Bash script for processing separate certificate and key files from DigiCert TLM Agent
.NOTES
    Legal Notice (version January 1, 2026)
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
#>
<#

.SYNOPSIS
    Upload a certificate (and key) to Sophos Firewall via its API.

.DESCRIPTION
    This script constructs the multipart form request with XML + files,
    securely retrieves credentials from Windows Credential Store,
    and logs results and errors.

.ADMIN WEB REQUEST INCOMING ARGUMENTS
    The following arguments must be sent with the Admin Web Request:

    $ARGUMENT_1 = Username
    Sophos Firewall admin username

    $ARGUMENT_2 = VaultName
    The secrets vault name created (see pre-requisites below)

    $ARGUMENT_3 = FirewallHost
    FQDN or IP of the Sophos Firewall

    $ARGUMENT_4 = FirewallPort
    HTTP port
	
	$ARGUMENT_5 = DEBUG
    Output DEBUG logging

.PRE-REQUISITES
    On the DigiCert Agent endpoint machine run the following within a PowerShell 5.x terminal:
    
    $> psexec -i -s powershell.exe

    The above will open a new PowerShell window.

    Check that you are "nt authority\system" by running:

    $> whoami

    Install PowerShell built-in secrets manager:

    $> Install-Module Microsoft.PowerShell.SecretManagement -Scope AllUsers -Force
    $> Install-Module Microsoft.PowerShell.SecretStore -Scope AllUsers -Force
    $> Import-Module Microsoft.PowerShell.SecretManagement
    $> Import-Module Microsoft.PowerShell.SecretStore

    Disable authentication to access secrets store:
	
	$> Set-SecretStoreConfiguration -Authentication None -Interaction None -Confirm:$false
	
	Register a local vault:

    $> Register-SecretVault -Name SophosVault -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault

    Define a secret name:

        - The solution concatinate the following incoming arguments to create a unique secret name:
            -- Username: Sophos login username
            -- Hostname: Sophos firewall hostname
            -- Port: Sophos firewall admin port

            -- Example: "admin:localhost:4443"

            -- The solution will pull these values from $ARGUMENT_1, $ARGUMENT_3, $ARGUMENT_4

    Set a secret:

    $> Set-Secret -Name <secret name as above> -Secret (Read-Host "Enter Sophos User Password" -AsSecureString) -Vault SophosVault

        - Example: Set-Secret -Name "admin:localhost:4443" -Secret (Read-Host "Enter Sophos User Password" -AsSecureString) -Vault SophosVault
#>

Try {

    # Configuration
    $LEGAL_NOTICE_ACCEPT = "false"
    $LogFolder = "C:\Program Files\DigiCert\TLM Agent\log\"
    $Host.UI.RawUI.WindowTitle = " "
    $VerbosePreference = 'SilentlyContinue'
    $InformationPreference = 'SilentlyContinue'
    $WarningPreference = 'SilentlyContinue'

    # ----------------------------
    # Logging Setup
    # ----------------------------
    $script:LogPath = Join-Path $LogFolder ("DigiCert-AWR-SophosCertUpload_{0}.log" -f (Get-Date -Format yyyyMMddHHmmss))

    function Write-LogMessage {
        param(
            [string]$Message,
            [ValidateSet("INFO", "ERROR", "DEBUG")]
            [string]$Level = "INFO"
        )

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $entry = "[$timestamp] [$Level] $Message"

        $entry | Out-File -FilePath $script:LogPath -Append -Encoding UTF8
    }

    # Start logging
    Write-LogMessage "=========================================="
    Write-LogMessage "Starting DC1_POST_SCRIPT_DATA extraction script"
    Write-LogMessage "=========================================="

    try {
        Start-Transcript -Path ($script:LogPath + ".transcript.txt") -Append -ErrorAction Stop | Out-Null
    }
    catch {
        Write-LogMessage "Transcript could not be started: $($_.Exception.Message)" "ERROR"
    }

    # Check legal notice acceptance
    Write-LogMessage "Checking legal notice acceptance..."
    if ($LEGAL_NOTICE_ACCEPT -ne "true") {
        Write-LogMessage "ERROR: Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT=`"true`" to proceed."
        Write-LogMessage "Script execution terminated due to legal notice non-acceptance."
        Write-LogMessage "=========================================="
        exit 1
    }
    else {
        Write-LogMessage "Legal notice accepted, proceeding with script execution."
    }

    # Log initial configuration
    Write-LogMessage "Configuration:"
    Write-LogMessage "  LEGAL_NOTICE_ACCEPT: $LEGAL_NOTICE_ACCEPT"
    Write-LogMessage "  LOGFILE: $script:LogPath"

    # Log environment variable check
    Write-LogMessage "Checking DC1_POST_SCRIPT_DATA environment variable..."
    $CERT_INFO = $env:DC1_POST_SCRIPT_DATA

    if ([string]::IsNullOrEmpty($CERT_INFO)) {
        Write-LogMessage "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set"
        exit 1
    }
    else {
        Write-LogMessage "DC1_POST_SCRIPT_DATA is set (length: $($CERT_INFO.Length) characters)"
    }

    Write-LogMessage "CERT_INFO length: $($CERT_INFO.Length) characters"

    # Decode JSON string from Base64
    try {
        $JSON_BYTES = [System.Convert]::FromBase64String($CERT_INFO)
        $JSON_STRING = [System.Text.Encoding]::UTF8.GetString($JSON_BYTES)
        Write-LogMessage "JSON_STRING decoded successfully"
    }
    catch {
        Write-LogMessage "ERROR: Failed to decode Base64: $_"
        exit 1
    }

    # Log the raw JSON for debugging
    Write-LogMessage "=========================================="
    Write-LogMessage "Raw JSON content:"
    Write-LogMessage $JSON_STRING
    Write-LogMessage "=========================================="

    # Parse JSON
    try {
        $JSON_OBJECT = $JSON_STRING | ConvertFrom-Json
        Write-LogMessage "JSON parsed successfully"
    }
    catch {
        Write-LogMessage "ERROR: Failed to parse JSON: $_"
        exit 1
    }

    # Extract arguments from JSON
    Write-LogMessage "Extracting arguments from JSON..."

    # Initialize argument variables
    $ARGUMENT_1 = ""
    $ARGUMENT_2 = ""
    $ARGUMENT_3 = ""
    $ARGUMENT_4 = ""
    $ARGUMENT_5 = ""

    # Extract arguments if they exist
    if ($JSON_OBJECT.args) {
        $ARGS_ARRAY = $JSON_OBJECT.args
        Write-LogMessage "Raw args array: $($ARGS_ARRAY -join ',')"
    
        if ($ARGS_ARRAY.Count -ge 1) { 
            $ARGUMENT_1 = ($ARGS_ARRAY[0] -replace '\s', '').Trim()
            Write-LogMessage "ARGUMENT_1 extracted: '$ARGUMENT_1'"
            Write-LogMessage "ARGUMENT_1 length: $($ARGUMENT_1.Length)"
        }
        if ($ARGS_ARRAY.Count -ge 2) { 
            $ARGUMENT_2 = ($ARGS_ARRAY[1] -replace '\s', '').Trim()
            Write-LogMessage "ARGUMENT_2 extracted: '$ARGUMENT_2'"
            Write-LogMessage "ARGUMENT_2 length: $($ARGUMENT_2.Length)"
        }
        if ($ARGS_ARRAY.Count -ge 3) { 
            $ARGUMENT_3 = ($ARGS_ARRAY[2] -replace '\s', '').Trim()
            Write-LogMessage "ARGUMENT_3 extracted: '$ARGUMENT_3'"
            Write-LogMessage "ARGUMENT_3 length: $($ARGUMENT_3.Length)"
        }
        if ($ARGS_ARRAY.Count -ge 4) { 
            $ARGUMENT_4 = ($ARGS_ARRAY[3] -replace '\s', '').Trim()
            Write-LogMessage "ARGUMENT_4 extracted: '$ARGUMENT_4'"
            Write-LogMessage "ARGUMENT_4 length: $($ARGUMENT_4.Length)"
        }
        if ($ARGS_ARRAY.Count -ge 5) { 
            $ARGUMENT_5 = ($ARGS_ARRAY[4] -replace '\s', '').Trim()
            Write-LogMessage "ARGUMENT_5 extracted: '$ARGUMENT_5'"
            Write-LogMessage "ARGUMENT_5 length: $($ARGUMENT_5.Length)"
        }
    }

    # Extract cert folder
    $CERT_FOLDER = $JSON_OBJECT.certfolder
    Write-LogMessage "Extracted CERT_FOLDER: $CERT_FOLDER"

    # Extract the .crt file name
    $CRT_FILE = ""
    if ($JSON_OBJECT.files) {
        $CRT_FILE = $JSON_OBJECT.files | Where-Object { $_ -match '\.crt$' } | Select-Object -First 1
    }
    Write-LogMessage "Extracted CRT_FILE: $CRT_FILE"

    # Extract the .key file name
    $KEY_FILE = ""
    if ($JSON_OBJECT.files) {
        $KEY_FILE = $JSON_OBJECT.files | Where-Object { $_ -match '\.key$' } | Select-Object -First 1
    }
    Write-LogMessage "Extracted KEY_FILE: $KEY_FILE"

    # Construct file paths
    $CRT_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $CRT_FILE
    $KEY_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $KEY_FILE

    # Extract all files from the files array
    $FILES_ARRAY = $JSON_OBJECT.files -join ','
    Write-LogMessage "Files array content: $FILES_ARRAY"

    # Log summary
    Write-LogMessage "=========================================="
    Write-LogMessage "EXTRACTION SUMMARY:"
    Write-LogMessage "=========================================="
    Write-LogMessage "Arguments extracted:"
    Write-LogMessage "  Argument 1: $ARGUMENT_1"
    Write-LogMessage "  Argument 2: $ARGUMENT_2"
    Write-LogMessage "  Argument 3: $ARGUMENT_3"
    Write-LogMessage "  Argument 4: $ARGUMENT_4"
    Write-LogMessage "  Argument 5: $ARGUMENT_5"
    Write-LogMessage ""
    Write-LogMessage "Certificate information:"
    Write-LogMessage "  Certificate folder: $CERT_FOLDER"
    Write-LogMessage "  Certificate file: $CRT_FILE"
    Write-LogMessage "  Private key file: $KEY_FILE"
    Write-LogMessage "  Certificate path: $CRT_FILE_PATH"
    Write-LogMessage "  Private key path: $KEY_FILE_PATH"
    Write-LogMessage ""
    Write-LogMessage "All files in array: $FILES_ARRAY"
    Write-LogMessage "=========================================="

    # Check if files exist and analyze them
    $CERT_COUNT = 0
    $KEY_TYPE = "Unknown"
    $KEY_FILE_CONTENT = ""

    if (Test-Path $CRT_FILE_PATH) {
        $crtFileInfo = Get-Item $CRT_FILE_PATH
        Write-LogMessage "Certificate file exists: $CRT_FILE_PATH"
        Write-LogMessage "Certificate file size: $($crtFileInfo.Length) bytes"
    
        # Count certificates in the file
        $crtContent = Get-Content $CRT_FILE_PATH -Raw
        $CERT_COUNT = ([regex]::Matches($crtContent, "BEGIN CERTIFICATE")).Count
        Write-LogMessage "Total certificates in file: $CERT_COUNT"
    
        # Try to parse certificate using .NET
        try {
            # Extract just the first certificate if there are multiple
            if ($crtContent -match '-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----') {
                $certBase64 = $matches[1] -replace '\s', ''
                $certBytes = [Convert]::FromBase64String($certBase64)
                $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certBytes)
            
                Write-LogMessage "Certificate details:"
                Write-LogMessage "  Subject: $($cert.Subject)"
                Write-LogMessage "  Issuer: $($cert.Issuer)"
                Write-LogMessage "  Serial Number: $($cert.SerialNumber)"
                Write-LogMessage "  Valid From: $($cert.NotBefore)"
                Write-LogMessage "  Valid To: $($cert.NotAfter)"
                Write-LogMessage "  Thumbprint: $($cert.Thumbprint)"
                Write-LogMessage "  Signature Algorithm: $($cert.SignatureAlgorithm.FriendlyName)"
            
                $cert.Dispose()
            }
        }
        catch {
            Write-LogMessage "Could not parse certificate details: $_"
        }
    }
    else {
        Write-LogMessage "WARNING: Certificate file not found: $CRT_FILE_PATH"
    }

    if (Test-Path $KEY_FILE_PATH) {
        $keyFileInfo = Get-Item $KEY_FILE_PATH
        Write-LogMessage "Private key file exists: $KEY_FILE_PATH"
        Write-LogMessage "Private key file size: $($keyFileInfo.Length) bytes"
    
        # Read key file content and determine type
        $KEY_FILE_CONTENT = Get-Content $KEY_FILE_PATH -Raw
    
        if ($KEY_FILE_CONTENT -match "BEGIN RSA PRIVATE KEY") {
            $KEY_TYPE = "RSA"
            Write-LogMessage "Key type: RSA (BEGIN RSA PRIVATE KEY found)"
        }
        elseif ($KEY_FILE_CONTENT -match "BEGIN EC PRIVATE KEY") {
            $KEY_TYPE = "ECC"
            Write-LogMessage "Key type: ECC (BEGIN EC PRIVATE KEY found)"
        }
        elseif ($KEY_FILE_CONTENT -match "BEGIN PRIVATE KEY") {
            $KEY_TYPE = "PKCS#8 format (generic)"
            Write-LogMessage "Key type: PKCS#8 format (BEGIN PRIVATE KEY found)"
        }
        elseif ($KEY_FILE_CONTENT -match "BEGIN ENCRYPTED PRIVATE KEY") {
            $KEY_TYPE = "Encrypted PKCS#8"
            Write-LogMessage "Key type: Encrypted PKCS#8 format (BEGIN ENCRYPTED PRIVATE KEY found)"
        }
        else {
            $KEY_TYPE = "Unknown"
            Write-LogMessage "Key type: Unknown"
        }
    }
    else {
        Write-LogMessage "WARNING: Private key file not found: $KEY_FILE_PATH"
    }

    Write-LogMessage "=========================================="
    Write-LogMessage "Starting custom script section..."
    Write-LogMessage "=========================================="

    # ----------------------------
    # Module Validation
    # ----------------------------
    try {
        Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop
        Import-Module Microsoft.PowerShell.SecretStore -ErrorAction Stop
    }
    catch {
        Write-LogMessage "Module load failed: $($_.Exception.Message)" "ERROR"
        Stop-Transcript | Out-Null
        exit 1
    }

    Write-LogMessage "SecretManagement modules loaded"

    # ----------------------------
    # Align incoming arguments to parameters
    # ----------------------------
    
    [string]$userName = $ARGUMENT_1
    [string]$vaultName = $ARGUMENT_2
    [string]$firewallHost = $ARGUMENT_3
    [int]$firewallPort = $ARGUMENT_4
    $DebugLog = $false
	
    if ($ARGUMENT_5 -ieq "DEBUG") {
        $DebugLog = $true
        Write-LogMessage "Debug logging enabled..."
    }
	

    # ----------------------------
    # Validate Firewall Parameters
    # ----------------------------
    try {
        if ([string]::IsNullOrWhiteSpace($firewallHost)) {
            throw "Firewall host cannot be empty"
        }

        if ($firewallPort -le 0 -or $firewallPort -gt 65535) {
            throw "Firewall port must be between 1 and 65535"
        }
    }
    catch {
        Write-LogMessage $_.Exception.Message "ERROR"
        Stop-Transcript | Out-Null
        exit 1
    }

    # ----------------------------
    # Validate Vault + Secret
    # ----------------------------
    try {
        $vaultExists = Get-SecretVault | Where-Object Name -eq $vaultName
        if (-not $vaultExists) {
            throw "Vault '$vaultName' not found"
        }

        $password = Get-Secret -Name "$userName`:$firewallHost`:$firewallPort" -Vault $vaultName -AsPlainText -ErrorAction Stop
        if (-not $password) {
            throw "Secret 'SophosFWUserPassword' not found in vault '$vaultName'"
        }

        Write-LogMessage "Secret retrieved successfully"
    }
    catch {
        Write-LogMessage $_.Exception.Message "ERROR"
        Stop-Transcript | Out-Null
        exit 1
    }

    # ----------------------------
    # Build XML
    # ----------------------------
    $txnId = [Guid]::NewGuid().Guid
    $certName = [IO.Path]::GetFileNameWithoutExtension($CRT_FILE_PATH)
    $certExt = [IO.Path]::GetExtension($CRT_FILE_PATH)

    if ($KEY_FILE_PATH) {
        $privateKeyFile = [IO.Path]::GetFileName($KEY_FILE_PATH)
    }
    else {
        $privateKeyFile = ""
    }

    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<Request>
  <Login>
    <Username>$userName</Username>
    <Password>$password</Password>
  </Login>
  <Set>
    <Certificate transactionid="$txnId">
      <Name>$certName</Name>
      <Action>UploadCertificate</Action>
      <CertificateFormat>pem</CertificateFormat>
      <CertificateFile>$($certName + $certExt)</CertificateFile>
      <PrivateKeyFile>$privateKeyFile</PrivateKeyFile>
    </Certificate>
  </Set>
</Request>
"@

    Write-LogMessage "XML payload constructed"
    if ($DebugLog) {
        $safeXml = $xml -replace '<Password>.*?</Password>', '<Password>****</Password>'
        Write-LogMessage $safeXml "DEBUG"
    }

    # ----------------------------
    # Build Multipart Request
    # ----------------------------

    Add-Type -AssemblyName System.Net.Http

    $multipart = New-Object System.Net.Http.MultipartFormDataContent

    # XML part
    $xmlContent = New-Object System.Net.Http.StringContent($xml, [Text.Encoding]::UTF8, "application/xml")
    $multipart.Add($xmlContent, "reqxml")

    # Certificate part
    $certBytes = [IO.File]::ReadAllBytes($CRT_FILE_PATH)
    $certContent = New-Object System.Net.Http.ByteArrayContent -ArgumentList (, $certBytes)
    $certContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/octet-stream")
    $multipart.Add($certContent, $certName, ($certName + $certExt))

    # Key part
    if ($KEY_FILE_PATH) {
        $keyFileBytes = [IO.File]::ReadAllBytes($KEY_FILE_PATH)
        $keyFileName = [IO.Path]::GetFileName($KEY_FILE_PATH)

        $keyContent = New-Object System.Net.Http.ByteArrayContent -ArgumentList (, $keyFileBytes)
        $keyContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/octet-stream")
        $multipart.Add($keyContent, $keyFileName, $keyFileName)
    }

    if ($DebugLog) {
        $partCount = ($multipart | Measure-Object).Count
        Write-LogMessage "Multipart contains $partCount parts" "DEBUG"

        foreach ($part in $multipart) {
            $cd = $part.Headers.ContentDisposition
            $ct = $part.Headers.ContentType
            Write-LogMessage "Part Name: $($cd.Name) | FileName: $($cd.FileName) | ContentType: $ct" "DEBUG"
        }
    }

    Write-LogMessage "Multipart request constructed"

    # ----------------------------
    # Send Request
    # ----------------------------
    $url = "https://$firewallHost`:$firewallPort/webconsole/APIController"
    Write-LogMessage "Sending request to $url"

    try {

        # Enforce TLS 1.2
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}

        $response = Invoke-WebRequest `
            -Uri $url `
            -Method Post `
            -Body $multipart `
            -ErrorAction Stop

        Write-LogMessage "HTTP Status Code: $($response.StatusCode)"

        if ($response.StatusCode -ne 200) {
            Write-LogMessage "Unexpected HTTP status code: $($response.StatusCode)" "ERROR"
            exit 1
        }

        # Parse XML response
        try {
            [xml]$xmlResponse = $response.Content
            Write-LogMessage "XML response parsed successfully"
        }
        catch {
            Write-LogMessage "Failed to parse XML response" "ERROR"
            Write-LogMessage $response.Content "ERROR"
            exit 1
        }

        # Validate login status
        $loginStatus = $xmlResponse.Response.Login.status
        if ($loginStatus -ne "Authentication Successful") {
            Write-LogMessage "Authentication failed: $loginStatus" "ERROR"
            exit 1
        }

        # Validate certificate status
        $certStatusNode = $xmlResponse.Response.Certificate.Status
        $certStatusCode = $certStatusNode.code
        $certStatusText = $certStatusNode.'#text'

        Write-LogMessage "API Status Code: $certStatusCode"
        Write-LogMessage "API Status Message: $certStatusText"

        if ($certStatusCode -ne "200") {
            Write-LogMessage "Sophos API reported failure" "ERROR"
            exit 1
        }

        Write-LogMessage "Certificate successfully uploaded to Sophos"

    }
    catch {

        Write-LogMessage "HTTP request failed: $($_.Exception.Message)" "ERROR"

        if ($_.Exception.Response) {
            try {
                $reader = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
                $errorBody = $reader.ReadToEnd()
                Write-LogMessage "Raw error response: $errorBody" "ERROR"

                # Try parse XML even on failure
                try {
                    [xml]$errorXml = $errorBody
                    $errorStatus = $errorXml.Response.Certificate.Status.'#text'
                    Write-LogMessage "Parsed API Error: $errorStatus" "ERROR"
                }
                catch {}
            }
            catch {}
        }

        exit 1
    }
}
catch {
    Write-LogMessage "Fatal error: $($_.Exception.Message)" "ERROR"
    exit 1
}
finally {
    if ($multipart) {
        $multipart.Dispose()
    }
    try { Stop-Transcript | Out-Null } catch {}
}