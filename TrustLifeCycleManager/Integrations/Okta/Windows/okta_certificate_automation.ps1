<#
.SYNOPSIS
    DigiCert TLM AWR - Okta Custom Domain Certificate Updater

.DESCRIPTION
    Post-delivery automation script for DigiCert Trust Lifecycle Manager (TLM).
    Reads a PFX file delivered by TLM, extracts the leaf certificate, certificate
    chain, and private key in PEM format, then locates the matching Okta custom
    domain and upserts the certificate via the Okta Management API.

.NOTES
    Legal Notice (version January 1, 2026)
    Copyright (c) 2026 DigiCert. All rights reserved.
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
    subparagraphs (c)(1) and (2) of the Commercial Computer Software-Restricted Rights at 48 CFR 52.227-19,
    as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
    The contractor/manufacturer is DIGICERT, INC.
#>

# =====================================================================
# GLOBALS
# =====================================================================

$LEGAL_NOTICE_ACCEPT    = "false"   # Set to "true" to accept the legal notice above
$LOG_PATH               = "C:\Program Files\DigiCert\TLM Agent\log\okta_certificate_automation.log"
$SCRIPT_VERSION         = "1.0.0"
$SKIP_CERTIFICATE_CHECK = $false    # NOT an argument - set to $true only for lab/test environments

$API_TIMEOUT_SECONDS    = 60
$MAX_RETRY_ATTEMPTS     = 3
$RETRY_DELAY_SECONDS    = 5

# =====================================================================
# LOGGING
# =====================================================================

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DEBUG")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    if ($Level -ne "DEBUG") { Write-Host $line }
    try {
        $logDir = Split-Path -Parent $LOG_PATH
        if (-not (Test-Path -Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path $LOG_PATH -Value $line -ErrorAction Stop
    } catch { }
}

# =====================================================================
# SCRIPT CONTROL
# =====================================================================

function Stop-Script {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Log -Message $Message -Level "ERROR"
    throw $Message
}

# =====================================================================
# UTILITY HELPERS
# =====================================================================

function ConvertTo-JsonString {
    param([Parameter(Mandatory = $true)]$Value)
    return ($Value | ConvertTo-Json -Depth 50 -Compress)
}

function Get-CertificateCommonName {
    param([Parameter(Mandatory = $true)][string]$SubjectDN)

    # Match CN= followed by value up to the next comma or end of string.
    # Handles quoted values (CN="foo, bar") and unquoted values.
    if ($SubjectDN -match '(?:^|,)\s*CN\s*=\s*"([^"]+)"') {
        return $Matches[1].Trim()
    }
    if ($SubjectDN -match '(?:^|,)\s*CN\s*=\s*([^,]+)') {
        return $Matches[1].Trim()
    }
    return $null
}

function ConvertTo-DerLength {
    param([int]$Length)
    if ($Length -lt 0x80) {
        return [byte[]]@($Length)
    } elseif ($Length -le 0xFF) {
        return [byte[]]@(0x81, $Length)
    } else {
        return [byte[]]@(0x82, (($Length -shr 8) -band 0xFF), ($Length -band 0xFF))
    }
}

function ConvertTo-DerInteger {
    param([byte[]]$Value)
    $trimmed = $Value
    while ($trimmed.Length -gt 1 -and $trimmed[0] -eq 0x00 -and (($trimmed[1] -band 0x80) -eq 0)) {
        $trimmed = $trimmed[1..($trimmed.Length - 1)]
    }
    if ($trimmed[0] -band 0x80) {
        $trimmed = [byte[]](@([byte]0x00) + $trimmed)
    }
    $lenBytes = ConvertTo-DerLength -Length $trimmed.Length
    return [byte[]](@([byte]0x02) + $lenBytes + $trimmed)
}

function ConvertTo-Pkcs1RsaPrivateKeyDer {
    param([System.Security.Cryptography.RSAParameters]$RsaParams)

    $version = [byte[]]@(0x02, 0x01, 0x00)   # INTEGER 0
    $n    = ConvertTo-DerInteger -Value $RsaParams.Modulus
    $e    = ConvertTo-DerInteger -Value $RsaParams.Exponent
    $d    = ConvertTo-DerInteger -Value $RsaParams.D
    $p    = ConvertTo-DerInteger -Value $RsaParams.P
    $q    = ConvertTo-DerInteger -Value $RsaParams.Q
    $dp   = ConvertTo-DerInteger -Value $RsaParams.DP
    $dq   = ConvertTo-DerInteger -Value $RsaParams.DQ
    $qinv = ConvertTo-DerInteger -Value $RsaParams.InverseQ

    $content  = $version + $n + $e + $d + $p + $q + $dp + $dq + $qinv
    $lenBytes = ConvertTo-DerLength -Length $content.Length
    return [byte[]](@([byte]0x30) + $lenBytes + $content)
}

function Format-Pem {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [byte[]]$Bytes,
        [string]$Base64Content
    )
    if ($Bytes) {
        $Base64Content = [Convert]::ToBase64String($Bytes)
    }
    # Split base64 into 64-char lines
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("-----BEGIN $Label-----")
    for ($i = 0; $i -lt $Base64Content.Length; $i += 64) {
        $end = [Math]::Min(64, $Base64Content.Length - $i)
        $lines.Add($Base64Content.Substring($i, $end))
    }
    $lines.Add("-----END $Label-----")
    return ($lines -join "`n")
}

function Get-RsaPrivateKeyFromCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    try {
        $rsaKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
        if ($null -ne $rsaKey) {
            return $rsaKey
        }
    } catch { }

    return ($Certificate.PrivateKey -as [System.Security.Cryptography.RSA])
}

# =====================================================================
# POST-SCRIPT DATA PARSING
# =====================================================================

function Get-PostScriptDataObject {
    $rawData = [System.Environment]::GetEnvironmentVariable("DC1_POST_SCRIPT_DATA")
    if ([string]::IsNullOrWhiteSpace($rawData)) {
        Stop-Script -Message "DC1_POST_SCRIPT_DATA environment variable is missing or empty."
    }
    try {
        $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($rawData))
        return $decoded | ConvertFrom-Json
    } catch {
        Stop-Script -Message "Failed to decode DC1_POST_SCRIPT_DATA: $($_.Exception.Message)"
    }
}

function Get-ArgumentAtIndex {
    param(
        [Parameter(Mandatory = $true)]$JsonObject,
        [Parameter(Mandatory = $true)][int]$Index
    )
    $argsArray = @($JsonObject.args)
    if ($Index -ge 0 -and $Index -lt $argsArray.Count) {
        return [string]$argsArray[$Index]
    }
    return ""
}

function Get-FileByExtensions {
    param(
        [Parameter(Mandatory = $true)]$JsonObject,
        [Parameter(Mandatory = $true)][string[]]$Extensions,
        [Parameter(Mandatory = $true)][string]$CertFolder
    )
    foreach ($file in @($JsonObject.files)) {
        $ext = [System.IO.Path]::GetExtension($file).ToLower()
        foreach ($target in $Extensions) {
            if ($ext -eq $target.ToLower()) {
                return [System.IO.Path]::Combine($CertFolder, $file)
            }
        }
    }
    return ""
}

# =====================================================================
# CERTIFICATE EXTRACTION
# =====================================================================

function Get-PemComponentsFromPfx {
    param(
        [Parameter(Mandatory = $true)][string]$PfxPath,
        [Parameter(Mandatory = $true)][string]$PfxPassword
    )

    Write-Log -Message "Loading PFX file: $PfxPath" -Level "INFO"

    $storageFlags = `
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor `
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet

    # Load the full certificate collection from PFX
    $collection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    try {
        $collection.Import($PfxPath, $PfxPassword, $storageFlags)
    } catch {
        Stop-Script -Message "Failed to load PFX file '$PfxPath': $($_.Exception.Message)"
    }

    Write-Log -Message "PFX loaded successfully. Certificate count in collection: $($collection.Count)" -Level "INFO"

    # Identify leaf cert (has private key) vs intermediates
    $leafCert = $null
    $caCerts = New-Object 'System.Collections.Generic.List[object]'

    foreach ($cert in $collection) {
        if ($cert.HasPrivateKey) {
            $leafCert = $cert
        } else {
            $caCerts.Add($cert) | Out-Null
        }
    }

    if ($null -eq $leafCert) {
        Stop-Script -Message "No certificate with a private key found in the PFX file."
    }

    Write-Log -Message "Leaf certificate subject: $($leafCert.Subject)" -Level "INFO"
    Write-Log -Message "Leaf certificate thumbprint: $($leafCert.Thumbprint)" -Level "INFO"
    Write-Log -Message "Leaf certificate not after: $($leafCert.NotAfter)" -Level "INFO"
    Write-Log -Message "CA certificates found: $($caCerts.Count)" -Level "INFO"

    # --- Extract leaf cert PEM ---
    $leafDer    = $leafCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $leafCertPem = Format-Pem -Label "CERTIFICATE" -Bytes $leafDer

    # --- Extract chain PEM (concatenated intermediates) ---
    $chainPemParts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($caCert in $caCerts) {
        $caCertDer = $caCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
        $chainPemParts.Add((Format-Pem -Label "CERTIFICATE" -Bytes $caCertDer)) | Out-Null
    }
    $chainPemParts.Reverse()
    $chainPem = $chainPemParts -join "`n"

    # --- Extract private key PEM ---
    $privateKeyPem = ""
    $psVersion = $PSVersionTable.PSVersion.Major
    $keyType = "Unknown"

    # Attempt to detect key type
    if ($leafCert | Get-Member -Name "PublicKey" -ErrorAction SilentlyContinue) {
        $pubKeyOid = $leafCert.PublicKey.Oid.FriendlyName
        if ($pubKeyOid -match "RSA") {
            $keyType = "RSA"
        } elseif ($pubKeyOid -match "ECC|ECDSA") {
            $keyType = "ECC"
        }
    }

    Write-Log -Message "Detected certificate key type: $keyType" -Level "INFO"

    if ($psVersion -ge 7) {
        # PS7+ / .NET 5+: use built-in ExportPkcs8PrivateKey() for both RSA and ECC
        Write-Log -Message "Using PS7+ path for private key export (supports RSA and ECC)." -Level "DEBUG"
        $ps7Success = $false
        
        try {
            # Try RSA first
            try {
                $rsaKey = Get-RsaPrivateKeyFromCertificate -Certificate $leafCert
                if ($null -ne $rsaKey) {
                    Write-Log -Message "Exporting RSA private key using PKCS#8 format." -Level "DEBUG"
                    $pkcs8Bytes    = $rsaKey.ExportPkcs8PrivateKey()
                    $privateKeyPem = Format-Pem -Label "PRIVATE KEY" -Bytes $pkcs8Bytes
                    $ps7Success    = $true
                }
            } catch {
                Write-Log -Message "RSA key export failed: $($_.Exception.Message)" -Level "DEBUG"
            }

            # If RSA failed, try ECDSA/ECC
            if (-not $ps7Success -and ($leafCert | Get-Member -Name "GetECDsaPrivateKey" -ErrorAction SilentlyContinue)) {
                try {
                    $ecKey = $leafCert.GetECDsaPrivateKey()
                    if ($null -ne $ecKey) {
                        Write-Log -Message "Exporting ECC/ECDSA private key using PKCS#8 format." -Level "DEBUG"
                        $pkcs8Bytes    = $ecKey.ExportPkcs8PrivateKey()
                        $privateKeyPem = Format-Pem -Label "PRIVATE KEY" -Bytes $pkcs8Bytes
                        $ps7Success    = $true
                    }
                } catch {
                    Write-Log -Message "ECC key export failed: $($_.Exception.Message)" -Level "DEBUG"
                }
            }
        } catch {
            Write-Log -Message "PS7+ method-based export encountered an error: $($_.Exception.Message)" -Level "WARN"
        }

        # If PS7+ modern approach failed, fall back to PS5.1-style RSA-only approach
        if (-not $ps7Success) {
            if ($keyType -eq "ECC") {
                Stop-Script -Message "ECC certificate detected, but PS7+ ECDSA export methods failed. ECC certificates require PS7+ with working cryptography APIs. Try updating PowerShell or reinstalling .NET."
            }
            
            Write-Log -Message "Falling back to legacy RSA private key export method." -Level "WARN"
            try {
                $rsaKey = Get-RsaPrivateKeyFromCertificate -Certificate $leafCert
                if ($null -eq $rsaKey) {
                    Stop-Script -Message "Private key is not an RSA key. Cannot export on this system."
                }
                Write-Log -Message "Exporting RSA private key using legacy PKCS#1 format." -Level "DEBUG"
                $rsaParams     = $rsaKey.ExportParameters($true)
                $pkcs1Der      = ConvertTo-Pkcs1RsaPrivateKeyDer -RsaParams $rsaParams
                $privateKeyPem = Format-Pem -Label "RSA PRIVATE KEY" -Bytes $pkcs1Der
            } catch {
                Stop-Script -Message "Failed to export RSA private key (fallback path): $($_.Exception.Message)"
            }
        }
    } else {
        # PS5.1 / .NET Framework: only RSA is supported
        Write-Log -Message "Using PS5.1 path for private key export (RSA only, PKCS#1 DER format)." -Level "DEBUG"
        
        if ($keyType -eq "ECC") {
            Stop-Script -Message "ECC/ECDSA certificate detected. ECC certificates are not supported on PowerShell 5.1 - they require PowerShell 7+ with .NET 5+. Please upgrade PowerShell."
        }
        
        try {
            $rsaKey = Get-RsaPrivateKeyFromCertificate -Certificate $leafCert
            if ($null -eq $rsaKey) {
                Stop-Script -Message "Private key is not an RSA key. Cannot export on PS5.1."
            }
            Write-Log -Message "Exporting RSA private key using PKCS#1 format." -Level "DEBUG"
            $rsaParams     = $rsaKey.ExportParameters($true)
            $pkcs1Der      = ConvertTo-Pkcs1RsaPrivateKeyDer -RsaParams $rsaParams
            $privateKeyPem = Format-Pem -Label "RSA PRIVATE KEY" -Bytes $pkcs1Der
        } catch {
            Stop-Script -Message "Failed to export RSA private key (PS5.1 path): $($_.Exception.Message)"
        }
    }

    Write-Log -Message "Private key exported successfully. [Content REDACTED]" -Level "INFO"

    return [pscustomobject]@{
        LeafCertPem      = $leafCertPem
        ChainPem         = $chainPem
        PrivateKeyPem    = $privateKeyPem
        LeafCertSubject  = $leafCert.Subject        # e.g. "CN=login.example.com, O=Acme, C=US"
    }
}

# =====================================================================
# OKTA-SPECIFIC API
# =====================================================================

function Invoke-OktaApi {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$AuthorizationHeader,
        [string]$Body = $null
    )

    $iwrCommand                 = Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue
    $supportsSkipHttpErrorCheck = $iwrCommand -and $iwrCommand.Parameters.ContainsKey("SkipHttpErrorCheck")
    $supportsSkipCertCheck      = $iwrCommand -and $iwrCommand.Parameters.ContainsKey("SkipCertificateCheck")
    $supportsUseBasicParsing    = $iwrCommand -and $iwrCommand.Parameters.ContainsKey("UseBasicParsing")

    $headers = @{
        "Authorization" = $AuthorizationHeader
        "Accept"        = "application/json"
        "Content-Type"  = "application/json"
    }

    $params = @{
        Method  = $Method
        Uri     = $Uri
        Headers = $headers
        TimeoutSec = $API_TIMEOUT_SECONDS
        ErrorAction = "Stop"
    }

    if ($supportsUseBasicParsing) { $params.UseBasicParsing = $true }
    if ($supportsSkipCertCheck -and $SKIP_CERTIFICATE_CHECK) { $params.SkipCertificateCheck = $true }
    if ($supportsSkipHttpErrorCheck) { $params.SkipHttpErrorCheck = $true }

    if (-not [string]::IsNullOrWhiteSpace($Body)) {
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
    }

    try {
        if ($supportsSkipHttpErrorCheck) {
            # PS7+: errors are returned as normal responses
            $response = Invoke-WebRequest @params
            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                Body       = $response.Content
            }
        } else {
            # PS5.1: Invoke-WebRequest throws on 4xx/5xx
            try {
                $response = Invoke-WebRequest @params
                return [pscustomobject]@{
                    StatusCode = [int]$response.StatusCode
                    Body       = $response.Content
                }
            } catch [System.Net.WebException] {
                $webEx = $_.Exception
                if ($null -ne $webEx.Response) {
                    $stream = $webEx.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $errBody = $reader.ReadToEnd()
                    $reader.Close()
                    $stream.Close()
                    return [pscustomobject]@{
                        StatusCode = [int]$webEx.Response.StatusCode
                        Body       = $errBody
                    }
                }
                # No response (DNS failure, connection refused, timeout, etc.)
                Write-Log -Message "Connection-level error calling $Uri : $($webEx.Message)" -Level "ERROR"
                return [pscustomobject]@{ StatusCode = $null; Body = $webEx.Message }
            }
        }
    } catch {
        Write-Log -Message "Unexpected error calling $Uri : $($_.Exception.Message)" -Level "ERROR"
        return [pscustomobject]@{ StatusCode = $null; Body = $_.Exception.Message }
    }
}

function Write-OktaApiErrorDetails {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [int]$StatusCode,
        [string]$ResponseBody
    )
    switch ($StatusCode) {
        $null { Write-Log -Message "$Operation failed: No response received (network/DNS/timeout issue). Response: $ResponseBody" -Level "ERROR" }
        400   { Write-Log -Message "$Operation failed (400 Bad Request): Check certificate format and required fields. Response: $ResponseBody" -Level "ERROR" }
        401   { Write-Log -Message "$Operation failed (401 Unauthorized): SSWS API token is invalid or expired." -Level "ERROR" }
        403   { Write-Log -Message "$Operation failed (403 Forbidden): Response: $ResponseBody" -Level "ERROR" }
        404   { Write-Log -Message "$Operation failed (404 Not Found): Domain ID not found or domain does not exist." -Level "ERROR" }
        429   { Write-Log -Message "$Operation failed (429 Too Many Requests): Okta API rate limit hit. Consider increasing retry delay." -Level "WARN" }
        500   { Write-Log -Message "$Operation failed (500 Internal Server Error): Okta-side error. Retry may succeed." -Level "ERROR" }
        default { Write-Log -Message "$Operation failed (HTTP $StatusCode). Response: $ResponseBody" -Level "ERROR" }
    }
}

function Get-OktaDomainId {
    param(
        [Parameter(Mandatory = $true)][string]$OktaBaseUrl,
        [Parameter(Mandatory = $true)][string]$AuthorizationHeader,
        [Parameter(Mandatory = $true)][string]$TargetDomain
    )

    $uri = "$OktaBaseUrl/api/v1/domains"
    Write-Log -Message "Listing Okta custom domains: GET $uri" -Level "INFO"

    $result = Invoke-OktaApi -Method "GET" -Uri $uri -AuthorizationHeader $AuthorizationHeader

    if ($result.StatusCode -ne 200) {
        Write-OktaApiErrorDetails -Operation "List custom domains" `
            -StatusCode $result.StatusCode -ResponseBody $result.Body
        Stop-Script -Message "Failed to retrieve Okta custom domains (HTTP $($result.StatusCode))."
    }

    $domains = $null
    try {
        $parsed  = $result.Body | ConvertFrom-Json
        $domains = @($parsed.domains)
    } catch {
        Stop-Script -Message "Failed to parse domain list response: $($_.Exception.Message)"
    }

    Write-Log -Message "Total custom domains returned: $($domains.Count)" -Level "INFO"

    foreach ($domain in $domains) {
        Write-Log -Message "  Found domain: '$($domain.domain)' (id=$($domain.id), validationStatus=$($domain.validationStatus))" -Level "INFO"
        if ($domain.domain -ieq $TargetDomain) {
            Write-Log -Message "Target domain matched: '$TargetDomain' -> id=$($domain.id)" -Level "SUCCESS"
            return $domain.id
        }
    }

    Write-Log -Message "Target domain '$TargetDomain' not found in the $($domains.Count) domain(s) returned." -Level "WARN"
    return $null
}

function Update-OktaCertificate {
    param(
        [Parameter(Mandatory = $true)][string]$OktaBaseUrl,
        [Parameter(Mandatory = $true)][string]$AuthorizationHeader,
        [Parameter(Mandatory = $true)][string]$DomainId,
        [Parameter(Mandatory = $true)][string]$CertificatePem,
        [Parameter(Mandatory = $true)][string]$CertificateChainPem,
        [Parameter(Mandatory = $true)][string]$PrivateKeyPem
    )

    $uri = "$OktaBaseUrl/api/v1/domains/$DomainId/certificate"
    Write-Log -Message "Upserting certificate for domain ID '$DomainId': PUT $uri" -Level "INFO"

    $payload = [ordered]@{
        certificate      = $CertificatePem
        certificateChain = $CertificateChainPem
        privateKey       = $PrivateKeyPem
        type             = "PEM"
    }
    $bodyJson = ConvertTo-JsonString -Value $payload

    Write-Log -Message "Sending certificate payload to Okta API. [Content REDACTED]" -Level "INFO"

    $attempt = 0
    while ($attempt -lt $MAX_RETRY_ATTEMPTS) {
        $attempt++
        Write-Log -Message "API call attempt $attempt of $MAX_RETRY_ATTEMPTS..." -Level "INFO"

        $result = Invoke-OktaApi -Method "PUT" -Uri $uri -AuthorizationHeader $AuthorizationHeader -Body $bodyJson

        if ($result.StatusCode -eq 204) {
            Write-Log -Message "Certificate upserted successfully (HTTP 204 No Content)." -Level "SUCCESS"
            return $true
        }

        if ($result.StatusCode -eq 429 -and $attempt -lt $MAX_RETRY_ATTEMPTS) {
            Write-Log -Message "Rate limited (429). Waiting $RETRY_DELAY_SECONDS seconds before retry..." -Level "WARN"
            Start-Sleep -Seconds $RETRY_DELAY_SECONDS
            continue
        }

        Write-OktaApiErrorDetails -Operation "Upsert certificate" `
            -StatusCode $result.StatusCode -ResponseBody $result.Body
        return $false
    }

    return $false
}

# =====================================================================
# MAIN ENTRY POINT
# =====================================================================

function Main {

    try {
        # -----------------------------------------------------------------
        # Startup banner
        # -----------------------------------------------------------------
        Write-Log -Message "============================================================" -Level "INFO"
        Write-Log -Message "Starting Okta Certificate Automation v$SCRIPT_VERSION"        -Level "INFO"
        Write-Log -Message "============================================================" -Level "INFO"
        Write-Log -Message "PowerShell Version : $($PSVersionTable.PSVersion)"            -Level "INFO"
        Write-Log -Message "Script Start Time  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level "INFO"

        # -----------------------------------------------------------------
        # Legal notice gate
        # -----------------------------------------------------------------
        if ($LEGAL_NOTICE_ACCEPT -ne "true") {
            Stop-Script -Message 'Legal notice not accepted. Set $LEGAL_NOTICE_ACCEPT = "true" to proceed.'
        }

        # -----------------------------------------------------------------
        # TLS 1.2
        # -----------------------------------------------------------------
        [System.Net.ServicePointManager]::SecurityProtocol = `
            [System.Net.ServicePointManager]::SecurityProtocol -bor `
            [System.Net.SecurityProtocolType]::Tls12

        # -----------------------------------------------------------------
        # Step 1 - Decode DC1_POST_SCRIPT_DATA
        # -----------------------------------------------------------------
        Write-Log -Message "Step 1: Decoding DC1_POST_SCRIPT_DATA..." -Level "INFO"
        $jsonObject = Get-PostScriptDataObject

        # -----------------------------------------------------------------
        # Step 2 - Extract arguments
        # -----------------------------------------------------------------
        Write-Log -Message "Step 2: Extracting arguments..." -Level "INFO"

        $oktaBaseUrl  = Get-ArgumentAtIndex -JsonObject $jsonObject -Index 0
        $pfxPassword  = [string]$jsonObject.password
        $certFolder   = [string]$jsonObject.certfolder
        $sswsToken    = Get-ArgumentAtIndex -JsonObject $jsonObject -Index 1
        $targetDomain = Get-ArgumentAtIndex -JsonObject $jsonObject -Index 2

        # -----------------------------------------------------------------
        # Step 3 - TLS bypass (lab/test environments only)
        # -----------------------------------------------------------------
        if ($SKIP_CERTIFICATE_CHECK) {
            Write-Log -Message "WARNING: TLS certificate validation is DISABLED (\$SKIP_CERTIFICATE_CHECK = \$true)." -Level "WARN"
            if ($PSVersionTable.PSVersion.Major -le 5) {
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            }
        }

        # -----------------------------------------------------------------
        # Step 4 - Locate PFX file
        # -----------------------------------------------------------------
        Write-Log -Message "Step 4: Locating PFX file in cert folder: $certFolder" -Level "INFO"
        $pfxFile = Get-FileByExtensions -JsonObject $jsonObject -CertFolder $certFolder `
                       -Extensions @(".pfx", ".p12")

        # -----------------------------------------------------------------
        # Step 5 - Log extraction summary (redact secrets)
        # -----------------------------------------------------------------
        $pfxPwdDesc = if ([string]::IsNullOrWhiteSpace($pfxPassword)) {
            "empty (password-less PFX)"
        } else {
            "$($pfxPassword.Length) chars"
        }

        Write-Log -Message "Extraction summary:"                                           -Level "INFO"
        Write-Log -Message "  Okta Base URL  : $oktaBaseUrl"                              -Level "INFO"
        Write-Log -Message "  Target Domain  : $targetDomain"                             -Level "INFO"
        Write-Log -Message "  Cert Folder    : $certFolder"                               -Level "INFO"
        Write-Log -Message "  PFX File       : $pfxFile"                                  -Level "INFO"
        Write-Log -Message "  PFX Password   : [REDACTED - $pfxPwdDesc]"                 -Level "INFO"
        Write-Log -Message "  SSWS Token     : [REDACTED]"                            -Level "INFO"

        # -----------------------------------------------------------------
        # Step 6 - Validate required arguments
        # -----------------------------------------------------------------
        Write-Log -Message "Step 6: Validating required arguments..." -Level "INFO"

        if ([string]::IsNullOrWhiteSpace($oktaBaseUrl)) {
            Stop-Script -Message "ARGUMENT_1 (Okta base URL) is missing or empty."
        }
        if ([string]::IsNullOrWhiteSpace($sswsToken)) {
            Stop-Script -Message "ARGUMENT_2 (Okta SSWS token) is missing or empty."
        }
        # ARGUMENT_3 (target domain) is optional - CN fallback applied after PFX load
        if ([string]::IsNullOrWhiteSpace($pfxFile)) {
            Stop-Script -Message "No .pfx or .p12 file found in the delivered files. Check AWR delivery configuration."
        }
        if (-not (Test-Path -Path $pfxFile)) {
            Stop-Script -Message "PFX file does not exist on disk: $pfxFile"
        }

        # Normalise base URL - strip trailing slash
        $oktaBaseUrl = $oktaBaseUrl.TrimEnd("/")

        Write-Log -Message "All required arguments validated." -Level "INFO"

        # -----------------------------------------------------------------
        # Step 7 - Build Authorization header
        # -----------------------------------------------------------------
        Write-Log -Message "Step 7: Building authorization header..." -Level "INFO"

        $authHeader = "SSWS $sswsToken"
        Write-Log -Message "Using SSWS token authentication." -Level "INFO"

        # -----------------------------------------------------------------
        # Step 8 - Extract PEM components from PFX
        # -----------------------------------------------------------------
        Write-Log -Message "Step 8: Extracting PEM components from PFX..." -Level "INFO"
        $pemComponents = Get-PemComponentsFromPfx -PfxPath $pfxFile -PfxPassword $pfxPassword

        if ([string]::IsNullOrWhiteSpace($pemComponents.LeafCertPem)) {
            Stop-Script -Message "Leaf certificate PEM is empty after extraction."
        }
        if ([string]::IsNullOrWhiteSpace($pemComponents.PrivateKeyPem)) {
            Stop-Script -Message "Private key PEM is empty after extraction."
        }
        if ([string]::IsNullOrWhiteSpace($pemComponents.ChainPem)) {
            Write-Log -Message "No intermediate certificates found in PFX. The certificateChain field will be empty." -Level "WARN"
        }

        Write-Log -Message "PEM extraction complete. [Content REDACTED]" -Level "INFO"

        # -----------------------------------------------------------------
        # Step 9 - Resolve target domain (argument or cert CN fallback)
        # -----------------------------------------------------------------
        if ([string]::IsNullOrWhiteSpace($targetDomain)) {
            Write-Log -Message "Step 9: Target domain not provided - extracting CN from certificate subject..." -Level "INFO"
            $certSubject = $pemComponents.LeafCertSubject
            $cnValue     = Get-CertificateCommonName -SubjectDN $certSubject
            if ([string]::IsNullOrWhiteSpace($cnValue)) {
                Stop-Script -Message "Target domain not specified and no CN found in certificate subject '$certSubject'."
            }
            $targetDomain = $cnValue
            Write-Log -Message "Target domain resolved from certificate CN: '$targetDomain'" -Level "INFO"
        } else {
            Write-Log -Message "Step 9: Target domain provided via argument: '$targetDomain'" -Level "INFO"
        }

        # -----------------------------------------------------------------
        # Step 10 - List Okta domains and find target domain ID
        # -----------------------------------------------------------------
        Write-Log -Message "Step 10: Searching for domain '$targetDomain' in Okta..." -Level "INFO"
        $domainId = Get-OktaDomainId `
            -OktaBaseUrl         $oktaBaseUrl `
            -AuthorizationHeader $authHeader `
            -TargetDomain        $targetDomain

        if ([string]::IsNullOrWhiteSpace($domainId)) {
            Stop-Script -Message "Domain '$targetDomain' not found in this Okta org. Verify the domain exists and the credential has 'okta.domains.read' access."
        }

        # -----------------------------------------------------------------
        # Step 11 - Upsert the certificate
        # -----------------------------------------------------------------
        Write-Log -Message "Step 11: Upserting certificate for domain ID '$domainId'..." -Level "INFO"
        $success = Update-OktaCertificate `
            -OktaBaseUrl         $oktaBaseUrl `
            -AuthorizationHeader $authHeader `
            -DomainId            $domainId `
            -CertificatePem      $pemComponents.LeafCertPem `
            -CertificateChainPem $pemComponents.ChainPem `
            -PrivateKeyPem       $pemComponents.PrivateKeyPem

        if (-not $success) {
            Stop-Script -Message "Certificate upsert failed for domain '$targetDomain' (ID: $domainId). See above errors for details."
        }

        # -----------------------------------------------------------------
        # Success
        # -----------------------------------------------------------------
        Write-Log -Message "============================================================" -Level "SUCCESS"
        Write-Log -Message "Certificate successfully updated for Okta custom domain:"    -Level "SUCCESS"
        Write-Log -Message "  Domain  : $targetDomain"                                  -Level "SUCCESS"
        Write-Log -Message "  ID      : $domainId"                                      -Level "SUCCESS"
        Write-Log -Message "  Org URL : $oktaBaseUrl"                                   -Level "SUCCESS"
        Write-Log -Message "============================================================" -Level "SUCCESS"
        exit 0

    } catch {
        Write-Log -Message "Script execution failed. Error: $($_.Exception.Message)" -Level "ERROR"
        Write-Log -Message "Stack trace: $($_.ScriptStackTrace)"                     -Level "ERROR"
        exit 1

    } finally {
        # Restore TLS validation callback if it was overridden on PS5.1
        if ($SKIP_CERTIFICATE_CHECK -and $PSVersionTable.PSVersion.Major -le 5) {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
        }
        Write-Log -Message "Script cleanup complete." -Level "INFO"
    }
}

# =====================================================================
# SCRIPT ENTRY POINT
# =====================================================================
Main
