<#
.SYNOPSIS
    FortiGate certificate import and reassignment automation for DigiCert TLM AWR delivery.
.DESCRIPTION
    This script reads DC1_POST_SCRIPT_DATA, imports a certificate and key into FortiGate,
    optionally reassigns matching references to the new certificate, and optionally deletes
    previously matched certificates.
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
$LEGAL_NOTICE_ACCEPT = "false"
$LOG_PATH = "C:\Program Files\DigiCert\TLM Agent\log\fortigate-awr.log"
$SCRIPT_VERSION = "1.0.0"
$SKIP_CERTIFICATE_CHECK = $false

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DEBUG")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"

    if ($Level -ne "DEBUG") {
        Write-Host $line
    }

    try {
        $logDir = Split-Path -Parent $LOG_PATH
        if (-not (Test-Path -Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path $LOG_PATH -Value $line -ErrorAction Stop
    } catch {
        # Logging should not block execution.
    }
}

function Stop-Script {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Log -Message $Message -Level "ERROR"
    throw $Message
}

function Get-PostScriptDataObject {
    $encoded = $env:DC1_POST_SCRIPT_DATA
    if ([string]::IsNullOrWhiteSpace($encoded)) {
        throw "DC1_POST_SCRIPT_DATA environment variable is not set"
    }

    try {
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
        return ($json | ConvertFrom-Json)
    } catch {
        throw "Unable to decode or parse DC1_POST_SCRIPT_DATA: $($_.Exception.Message)"
    }
}

function Get-ArgumentAtIndex {
    param(
        [Parameter(Mandatory = $true)]$JsonObject,
        [Parameter(Mandatory = $true)][int]$Index
    )

    if (-not $JsonObject.args) {
        return ""
    }

    if ($Index -lt 0 -or $Index -ge $JsonObject.args.Count) {
        return ""
    }

    return ([string]$JsonObject.args[$Index]).Trim()
}

function Get-FileByExtension {
    param(
        [Parameter(Mandatory = $true)]$JsonObject,
        [Parameter(Mandatory = $true)][string]$Extension
    )

    foreach ($file in $JsonObject.files) {
        if (($file -as [string]).ToLowerInvariant().EndsWith($Extension.ToLowerInvariant())) {
            return [string]$file
        }
    }

    return ""
}

function Get-FileSize {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        return (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
    } catch {
        return "unknown"
    }
}

function Get-FortiGateBaseUrl {
    param([Parameter(Mandatory = $true)][string]$FortiGateUrl)

    $trimmed = $FortiGateUrl.Trim().TrimEnd("/")
    if ($trimmed -match '^https?://') {
        return $trimmed
    }

    return "https://$trimmed"
}

function ConvertTo-JsonString {
    param([Parameter(Mandatory = $true)]$Value)
    return ($Value | ConvertTo-Json -Depth 50 -Compress)
}

function Invoke-FortiGateApi {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("GET", "POST", "PUT", "DELETE")][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$BearerToken,
        [string]$Body,
        [bool]$SkipCertificateCheck = $SKIP_CERTIFICATE_CHECK
    )

    $headers = @{
        Authorization = "Bearer $BearerToken"
        "Content-Type" = "application/json"
    }

    $command = Get-Command Invoke-WebRequest
    $supportsSkipHttpErrorCheck = $command.Parameters.ContainsKey("SkipHttpErrorCheck")
    $supportsSkipCertificateCheck = $command.Parameters.ContainsKey("SkipCertificateCheck")

    $params = @{
        Method = $Method
        Uri = $Uri
        Headers = $headers
        ErrorAction = "Stop"
    }

    if ($command.Parameters.ContainsKey("UseBasicParsing")) {
        $params.UseBasicParsing = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($Body)) {
        $params.Body = $Body
    }

    if ($supportsSkipCertificateCheck -and $SkipCertificateCheck) {
        $params.SkipCertificateCheck = $true
    }

    if ($supportsSkipHttpErrorCheck) {
        $params.SkipHttpErrorCheck = $true
        try {
            $response = Invoke-WebRequest @params
            $statusCode = [int]$response.StatusCode
            $content = [string]$response.Content
            return [pscustomobject]@{
                StatusCode = $statusCode
                Body = $content
            }
        } catch {
            return [pscustomobject]@{
                StatusCode = $null
                Body = $_.Exception.Message
            }
        }
    }

    try {
        $response = Invoke-WebRequest @params
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Body = [string]$response.Content
        }
    } catch {
        $statusCode = $null
        $body = $_.Exception.Message

        $errorResponse = $_.Exception.Response
        if ($errorResponse -and $errorResponse.StatusCode) {
            try {
                $statusCode = [int]$errorResponse.StatusCode.value__
            } catch {
                try {
                    $statusCode = [int]$errorResponse.StatusCode
                } catch {
                    $statusCode = $null
                }
            }

            try {
                if ($errorResponse -and $errorResponse.GetResponseStream) {
                    $stream = $errorResponse.GetResponseStream()
                    if ($stream) {
                        $reader = New-Object System.IO.StreamReader($stream)
                        $body = $reader.ReadToEnd()
                        $reader.Dispose()
                        $stream.Dispose()
                    }
                }
            } catch {
                # Keep existing fallback body text.
            }
        }

        return [pscustomobject]@{
            StatusCode = $statusCode
            Body = $body
        }
    }
}

function Write-ImportErrorDetails {
    param(
        [string]$Status,
        [string]$Body,
        [string]$RawResponse
    )

    switch ($Status) {
        "401" {
            Write-Log -Message "Authentication failed (401 Unauthorized). Verify Bearer token." -Level "ERROR"
        }
        "403" {
            Write-Log -Message "Access forbidden (403 Forbidden). Token may lack permissions." -Level "ERROR"
        }
        "404" {
            Write-Log -Message "API endpoint not found (404). Verify FortiGate URL/path." -Level "ERROR"
        }
        "500" {
            Write-Log -Message "Internal server error (500) from FortiGate." -Level "ERROR"
        }
        "" {
            Write-Log -Message "Failed to connect to FortiGate. Verify URL and connectivity." -Level "ERROR"
        }
        default {
            Write-Log -Message "Unexpected HTTP status code: $Status" -Level "WARN"
        }
    }
    Write-Log -Message "Response: $Body" -Level "ERROR"
}

function Get-MatchingSingletonFieldValue {
    param(
        [Parameter(Mandatory = $true)]$BodyObject,
        [Parameter(Mandatory = $true)][string]$Field,
        [Parameter(Mandatory = $true)][string]$BaseName
    )

    $result = $BodyObject.results
    if (-not $result) {
        $result = $BodyObject
    }

    $value = $result.$Field
    if ($value -isnot [string]) {
        return ""
    }

    if ($value -eq $BaseName -or $value.StartsWith("$BaseName")) {
        return $value
    }

    return ""
}

function Get-UnwrappedStringValues {
    param([Parameter(Mandatory = $true)]$Value)

    $values = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $Value) {
        return $values
    }

    if ($Value -is [string]) {
        $values.Add($Value)
        return $values
    }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in @("name", "q_origin_key", "mkey", "value")) {
            if ($Value.Contains($k) -and $Value[$k] -is [string]) {
                $values.Add([string]$Value[$k])
            }
        }
        return $values
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) {
            $nested = Get-UnwrappedStringValues -Value $item
            foreach ($v in $nested) {
                $values.Add($v)
            }
        }
    }

    return $values
}

function Get-MatchingTableObjects {
    param(
        [Parameter(Mandatory = $true)]$BodyObject,
        [Parameter(Mandatory = $true)][string]$Field,
        [Parameter(Mandatory = $true)][string]$BaseName
    )

    $tableRows = @()
    $results = $BodyObject.results
    if ($results -is [System.Collections.IDictionary]) {
        $results = @($results)
    }

    foreach ($item in $results) {
        $fieldValue = $item.$Field
        $candidates = Get-UnwrappedStringValues -Value $fieldValue
        $matchedValue = ""

        foreach ($candidate in $candidates) {
            if ($candidate -eq $BaseName -or $candidate.StartsWith("$BaseName-")) {
                $matchedValue = $candidate
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($matchedValue)) {
            continue
        }

        $mkey = $item.name
        if ([string]::IsNullOrWhiteSpace([string]$mkey)) {
            $mkey = $item.q_origin_key
        }
        if ([string]::IsNullOrWhiteSpace([string]$mkey)) {
            $mkey = $item.mkey
        }
        if ([string]::IsNullOrWhiteSpace([string]$mkey)) {
            $mkey = $item.id
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$mkey)) {
            $tableRows += [pscustomobject]@{
                Mkey = [string]$mkey
                MatchedValue = $matchedValue
            }
        }
    }

    return $tableRows
}

function New-ImportPayload {
    param(
        [Parameter(Mandatory = $true)][string]$CertificatePath,
        [Parameter(Mandatory = $true)][string]$PrivateKeyPath,
        [Parameter(Mandatory = $true)][string]$CertificateName
    )

    $certBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($CertificatePath))
    $keyBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($PrivateKeyPath))

    $payload = @{
        type = "regular"
        scope = "global"
        certname = $CertificateName
        file_content = $certBase64
        key_file_content = $keyBase64
    }

    return (ConvertTo-JsonString -Value $payload)
}

function New-SingleFieldPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Field,
        [Parameter(Mandatory = $true)][string]$Value
    )

    return (ConvertTo-JsonString -Value @{ $Field = $Value })
}

function Add-OldCertificateMatch {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$CertificateName
    )

    if (-not [string]::IsNullOrWhiteSpace($CertificateName)) {
        [void]$State.MatchedOldCerts.Add($CertificateName)
    }
}

function Invoke-ReassignSingleton {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [Parameter(Mandatory = $true)][string]$Field
    )

    $url = "$($State.FortiGateBaseUrl)/api/v2/cmdb/$Endpoint"
    Write-Log -Message "Checking $Label field $Field" -Level "INFO"

    $response = Invoke-FortiGateApi -Method "GET" -Uri $url -BearerToken $State.BearerToken
    Write-Log -Message "$Label GET HTTP: $($response.StatusCode)" -Level "INFO"

    if ($response.StatusCode -ne 200) {
        Write-Log -Message "Could not read $Label" -Level "WARN"
        return
    }

    try {
        # Write-Log -Message "Entire response: $response.Body" -Level "INFO"
        $bodyObject = $response.Body | ConvertFrom-Json
    } catch {
        Write-Log -Message "Could not parse $Label response JSON" -Level "WARN"
        return
    }

    $rawValue = "<missing>"
    if ($bodyObject.results) {
        $rawValue = [string]$bodyObject.results.$Field
    } elseif ($bodyObject.$Field) {
        $rawValue = [string]$bodyObject.$Field
    }
    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        $rawValue = "<missing>"
    }
    Write-Log -Message "$Label raw $Field value: $rawValue" -Level "INFO"

    $matchedValue = Get-MatchingSingletonFieldValue -BodyObject $bodyObject -Field $Field -BaseName $State.CertBaseName
    if ([string]::IsNullOrWhiteSpace($matchedValue)) {
        Write-Log -Message "No matching reference found in $Label field $Field" -Level "INFO"
        return
    }

    Write-Log -Message "Reference found: $Label uses '$matchedValue'" -Level "INFO"
    Add-OldCertificateMatch -State $State -CertificateName $matchedValue

    $payload = New-SingleFieldPayload -Field $Field -Value $State.NewCertName
    Write-Log -Message "PUT $url" -Level "INFO"

    $updateResponse = Invoke-FortiGateApi -Method "PUT" -Uri $url -BearerToken $State.BearerToken -Body $payload
    Write-Log -Message "$Label update HTTP: $($updateResponse.StatusCode)" -Level "INFO"
    Write-Log -Message "$Label update Body: $($updateResponse.Body)" -Level "INFO"

    if ($updateResponse.StatusCode -eq 200) {
        $State.ReferenceCount += 1
        Write-Log -Message "Reassigned $Label from '$matchedValue' to '$($State.NewCertName)'" -Level "SUCCESS"
    } else {
        $State.FailedReassignCount += 1
        Write-Log -Message "Failed to reassign $Label" -Level "ERROR"
    }
}

function Invoke-ReassignTable {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [Parameter(Mandatory = $true)][string]$Field
    )

    $listUrl = "$($State.FortiGateBaseUrl)/api/v2/cmdb/$Endpoint"
    Write-Log -Message "Checking table $Label field $Field" -Level "INFO"

    $response = Invoke-FortiGateApi -Method "GET" -Uri $listUrl -BearerToken $State.BearerToken
    Write-Log -Message "$Label GET HTTP: $($response.StatusCode)" -Level "INFO"

    if ($response.StatusCode -ne 200) {
        Write-Log -Message "Could not list $Label" -Level "WARN"
        return
    }

    try {
        $bodyObject = $response.Body | ConvertFrom-Json
    } catch {
        Write-Log -Message "Could not parse $Label response JSON" -Level "WARN"
        return
    }

    $tableRows = Get-MatchingTableObjects -BodyObject $bodyObject -Field $Field -BaseName $State.CertBaseName
    if (-not $tableRows -or $tableRows.Count -eq 0) {
        Write-Log -Message "No matching references found in $Label" -Level "INFO"
        return
    }

    foreach ($match in $tableRows) {
        if ([string]::IsNullOrWhiteSpace($match.Mkey)) {
            continue
        }

        Add-OldCertificateMatch -State $State -CertificateName $match.MatchedValue

        $encodedMkey = [uri]::EscapeDataString([string]$match.Mkey)
        $updateUrl = "$($State.FortiGateBaseUrl)/api/v2/cmdb/$Endpoint/$encodedMkey"
        $payload = New-SingleFieldPayload -Field $Field -Value $State.NewCertName

        Write-Log -Message "PUT $updateUrl" -Level "INFO"

        $updateResponse = Invoke-FortiGateApi -Method "PUT" -Uri $updateUrl -BearerToken $State.BearerToken -Body $payload
        Write-Log -Message "$Label '$($match.Mkey)' update HTTP: $($updateResponse.StatusCode)" -Level "INFO"
        Write-Log -Message "$Label '$($match.Mkey)' update Body: $($updateResponse.Body)" -Level "INFO"

        if ($updateResponse.StatusCode -eq 200) {
            $State.ReferenceCount += 1
            Write-Log -Message "Reassigned $Label '$($match.Mkey)' from '$($match.MatchedValue)' to '$($State.NewCertName)'" -Level "SUCCESS"
        } else {
            $State.FailedReassignCount += 1
            Write-Log -Message "Failed to reassign $Label '$($match.Mkey)'" -Level "ERROR"
        }
    }
}

function Write-CertificateFileDetails {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -Path $Path)) {
        Write-Log -Message "Certificate file not found: $Path" -Level "WARN"
        return
    }

    Write-Log -Message "Certificate file exists: $Path" -Level "INFO"
    Write-Log -Message "Certificate file size: $(Get-FileSize -Path $Path) bytes" -Level "INFO"

    $content = Get-Content -Path $Path -Raw
    $certCount = ([regex]::Matches($content, "BEGIN CERTIFICATE")).Count
    Write-Log -Message "Total certificates in file: $certCount" -Level "INFO"
}

function Write-PrivateKeyFileDetails {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -Path $Path)) {
        Write-Log -Message "Private key file not found: $Path" -Level "WARN"
        return
    }

    Write-Log -Message "Private key file exists: $Path" -Level "INFO"
    Write-Log -Message "Private key file size: $(Get-FileSize -Path $Path) bytes" -Level "INFO"

    $content = Get-Content -Path $Path -Raw
    if ($content -match "BEGIN RSA PRIVATE KEY") {
        Write-Log -Message "Key type: RSA (BEGIN RSA PRIVATE KEY found)" -Level "INFO"
    } elseif ($content -match "BEGIN EC PRIVATE KEY") {
        Write-Log -Message "Key type: ECC (BEGIN EC PRIVATE KEY found)" -Level "INFO"
    } elseif ($content -match "BEGIN PRIVATE KEY") {
        Write-Log -Message "Key type: PKCS#8 format (BEGIN PRIVATE KEY found)" -Level "INFO"
    } else {
        Write-Log -Message "Key type: Unknown" -Level "WARN"
    }
}

function Invoke-FortiGateCertificateImport {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$CrtPath,
        [Parameter(Mandatory = $true)][string]$KeyPath
    )

    Write-Log -Message "Starting FortiGate certificate import..." -Level "INFO"

    $importUrl = "$($State.FortiGateBaseUrl)/api/v2/monitor/vpn-certificate/local/import"
    $importPayload = New-ImportPayload -CertificatePath $CrtPath -PrivateKeyPath $KeyPath -CertificateName $State.NewCertName

    Write-Log -Message "POST $importUrl" -Level "INFO"
    $importResponse = Invoke-FortiGateApi -Method "POST" -Uri $importUrl -BearerToken $State.BearerToken -Body $importPayload

    Write-Log -Message "Import HTTP Status: $($importResponse.StatusCode)" -Level "INFO"
    # Write-Log -Message "Import Body: $($importResponse.Body)" -Level "INFO"

    return $importResponse
}

function Get-AssignModeConfig {
    param([string]$AssignMode)

    $config = @{
        ImportOnly = $false
        ReassignSslVpn = $false
        ReassignAdminHttps = $false
        ReassignAdminHttpsFallback = $false
        ReassignIpsecPhase1Interface = $false
        ReassignIpsecPhase1 = $false
        UnknownOptions = @()
    }

    if ([string]::IsNullOrWhiteSpace($AssignMode)) {
        $AssignMode = "assign_refs"
    }

    $options = @($AssignMode.Split(",") | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($options.Count -eq 0) {
        $options = @("assign_refs")
    }

    if ($options -contains "import_only") {
        $config.ImportOnly = $true
        return $config
    }

    if ($options -contains "assign_refs") {
        $config.ReassignSslVpn = $true
        $config.ReassignAdminHttps = $true
        $config.ReassignAdminHttpsFallback = $true
        $config.ReassignIpsecPhase1Interface = $true
        $config.ReassignIpsecPhase1 = $true
        return $config
    }

    foreach ($option in $options) {
        switch ($option) {
            { $_ -in @("ssl_vpn") } {
                $config.ReassignSslVpn = $true
            }
            { $_ -in @("admin_https") } {
                $config.ReassignAdminHttps = $true
            }
            { $_ -in @("admin_https_fallback") } {
                $config.ReassignAdminHttpsFallback = $true
            }
            { $_ -in @("ipsec_phase1_interface") } {
                $config.ReassignIpsecPhase1Interface = $true
            }
            { $_ -in @("ipsec_phase1") } {
                $config.ReassignIpsecPhase1 = $true
            }
            default {
                $config.UnknownOptions += $option
            }
        }
    }

    return $config
}

function Main {
    try {
        Write-Log -Message "==========================================" -Level "INFO"
        Write-Log -Message "Starting FortiGate Certificate Import Script v$SCRIPT_VERSION" -Level "INFO"
        Write-Log -Message "==========================================" -Level "INFO"

        if ($LEGAL_NOTICE_ACCEPT -ne "true") {
            Stop-Script -Message 'Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT="true" to proceed.'
        }

        $jsonObject = Get-PostScriptDataObject

        $fortiGateUrl = Get-ArgumentAtIndex -JsonObject $jsonObject -Index 0
        $certBaseName = Get-ArgumentAtIndex -JsonObject $jsonObject -Index 1
        $bearerToken = Get-ArgumentAtIndex -JsonObject $jsonObject -Index 2
        $deleteMode = Get-ArgumentAtIndex -JsonObject $jsonObject -Index 3
        $assignMode = Get-ArgumentAtIndex -JsonObject $jsonObject -Index 4

        if ([string]::IsNullOrWhiteSpace($deleteMode)) { $deleteMode = "keep_old" }
        if ([string]::IsNullOrWhiteSpace($assignMode)) { $assignMode = "assign_refs" }
        $assignConfig = Get-AssignModeConfig -AssignMode $assignMode

        $certFolder = [string]$jsonObject.certfolder
        $crtFile = Get-FileByExtension -JsonObject $jsonObject -Extension ".crt"
        $keyFile = Get-FileByExtension -JsonObject $jsonObject -Extension ".key"

        $crtPath = Join-Path -Path $certFolder -ChildPath $crtFile
        $keyPath = Join-Path -Path $certFolder -ChildPath $keyFile

        $dateSuffix = Get-Date -Format "yyyyMMdd-HHmmss"
        $newCertName = "$certBaseName-$dateSuffix"
        $fortiGateBaseUrl = Get-FortiGateBaseUrl -FortiGateUrl $fortiGateUrl
        $state = @{
            BearerToken = $bearerToken
            CertBaseName = $certBaseName
            NewCertName = $newCertName
            FortiGateBaseUrl = $fortiGateBaseUrl
            MatchedOldCerts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            ReferenceCount = 0
            FailedReassignCount = 0
        }

        $sanitizedArgs = @()
        for ($i = 0; $i -lt 5; $i++) {
            $argValue = Get-ArgumentAtIndex -JsonObject $jsonObject -Index $i
            if ($i -eq 2 -and -not [string]::IsNullOrWhiteSpace($argValue)) {
                $sanitizedArgs += "[REDACTED]"
            } else {
                $sanitizedArgs += $argValue
            }
        }

        Write-Log -Message "Extraction summary:" -Level "INFO"
        Write-Log -Message "  FortiGate URL: $fortiGateUrl" -Level "INFO"
        Write-Log -Message "  Base URL: $($state.FortiGateBaseUrl)" -Level "INFO"
        Write-Log -Message "  Certificate Base Name: $($state.CertBaseName)" -Level "INFO"
        Write-Log -Message "  New Certificate Name: $($state.NewCertName)" -Level "INFO"
        Write-Log -Message "  Bearer Token: [REDACTED - $($state.BearerToken.Length) characters]" -Level "INFO"
        Write-Log -Message "  Delete Mode: $deleteMode" -Level "INFO"
        Write-Log -Message "  Assign Mode: $assignMode" -Level "INFO"
        Write-Log -Message "  Certificate folder: $certFolder" -Level "INFO"
        Write-Log -Message "  Certificate file: $crtFile" -Level "INFO"
        Write-Log -Message "  Private key file: $keyFile" -Level "INFO"
        Write-Log -Message "  Certificate path: $crtPath" -Level "INFO"
        Write-Log -Message "  Private key path: $keyPath" -Level "INFO"
        Write-Log -Message "  Args array (redacted): $(ConvertTo-JsonString -Value $sanitizedArgs)" -Level "INFO"

        if ($jsonObject.files) {
            Write-Log -Message "  Files array: $(ConvertTo-JsonString -Value $jsonObject.files)" -Level "INFO"
        }

        if ([string]::IsNullOrWhiteSpace($fortiGateUrl)) { Stop-Script -Message "Argument 1 FortiGate URL is empty" }
        if ([string]::IsNullOrWhiteSpace($state.CertBaseName)) { Stop-Script -Message "Argument 2 certificate base name is empty" }
        if ([string]::IsNullOrWhiteSpace($state.BearerToken)) { Stop-Script -Message "Argument 3 bearer token is empty" }
        if (-not (Test-Path -Path $crtPath)) { Stop-Script -Message "Certificate file does not exist: $crtPath" }
        if (-not (Test-Path -Path $keyPath)) { Stop-Script -Message "Private key file does not exist: $keyPath" }

        Write-CertificateFileDetails -Path $crtPath
        Write-PrivateKeyFileDetails -Path $keyPath

        $importResponse = Invoke-FortiGateCertificateImport -State $state -CrtPath $crtPath -KeyPath $keyPath

        if ($importResponse.StatusCode -ne 200) {
            Write-ImportErrorDetails -Status ([string]$importResponse.StatusCode) -Body $importResponse.Body -RawResponse $importResponse.Body
            exit 1
        }

        Write-Log -Message "Imported new certificate '$($state.NewCertName)'" -Level "SUCCESS"

        if ($assignConfig.UnknownOptions.Count -gt 0) {
            Write-Log -Message "Unknown ASSIGN_MODE option(s) ignored: $($assignConfig.UnknownOptions -join ',')" -Level "WARN"
        }

        if ($assignConfig.ImportOnly) {
            Write-Log -Message "ASSIGN_MODE=import_only, skipping reference reassignment" -Level "INFO"
            Write-Log -Message "Script execution completed" -Level "SUCCESS"
            exit 0
        }

        if ($assignConfig.ReassignSslVpn) {
            Invoke-ReassignSingleton -State $state -Label "SSL-VPN settings" -Endpoint "vpn.ssl/settings" -Field "servercert"
        }
        if ($assignConfig.ReassignAdminHttps) {
            Invoke-ReassignSingleton -State $state -Label "Admin HTTPS certificate" -Endpoint "system/global" -Field "admin-server-cert"
        }
        if ($assignConfig.ReassignAdminHttpsFallback) {
            Invoke-ReassignSingleton -State $state -Label "Admin HTTPS certificate fallback" -Endpoint "system/global" -Field "admin-server-certname"
        }
        if ($assignConfig.ReassignIpsecPhase1Interface) {
            Invoke-ReassignTable -State $state -Label "IPsec phase1-interface" -Endpoint "vpn.ipsec/phase1-interface" -Field "certificate"
        }
        if ($assignConfig.ReassignIpsecPhase1) {
            Invoke-ReassignTable -State $state -Label "IPsec phase1" -Endpoint "vpn.ipsec/phase1" -Field "certificate"
        }

        Write-Log -Message "References reassigned: $($state.ReferenceCount)" -Level "INFO"
        Write-Log -Message "Failed reassignments: $($state.FailedReassignCount)" -Level "INFO"

        if ($state.FailedReassignCount -gt 0) {
            Stop-Script -Message "One or more references failed to reassign"
        }

        if ($deleteMode -eq "delete_old") {
            foreach ($oldCert in ($state.MatchedOldCerts | Sort-Object)) {
                if ([string]::IsNullOrWhiteSpace($oldCert)) { continue }
                if ($oldCert -eq $state.NewCertName) { continue }

                $encoded = [uri]::EscapeDataString($oldCert)
                $deleteUrl = "$($state.FortiGateBaseUrl)/api/v2/cmdb/vpn.certificate/local/$encoded"

                Write-Log -Message "DELETE $deleteUrl" -Level "INFO"
                $deleteResponse = Invoke-FortiGateApi -Method "DELETE" -Uri $deleteUrl -BearerToken $state.BearerToken

                Write-Log -Message "Delete '$oldCert' HTTP Status: $($deleteResponse.StatusCode)" -Level "INFO"
                Write-Log -Message "Delete '$oldCert' Body: $($deleteResponse.Body)" -Level "INFO"
            }
        } else {
            Write-Log -Message "DELETE_MODE=$deleteMode, leaving old certificates in place" -Level "INFO"
        }

        Write-Log -Message "FortiGate certificate import section completed" -Level "SUCCESS"
        Write-Log -Message "Script execution completed" -Level "SUCCESS"
        Write-Log -Message "New Certificate Name: $($state.NewCertName)" -Level "INFO"
        exit 0
    } catch {
        Write-Log -Message "Script execution failed. Error: $($_.Exception.Message)" -Level "ERROR"
        Write-Log -Message "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"
        exit 1
    }
}

Main
