<#
.SYNOPSIS
    Generate a CSR on PAN-OS, obtain a DigiCert certificate, and import it.
.DESCRIPTION
    Interactive standalone PowerShell 5.1-compatible workflow. API keys are requested
    as secure input and are not displayed or saved. PAN-OS CSR retrieval and DigiCert
    API response bodies are saved in the selected output directory, but not displayed.
#>

$DigiCertOneHost = 'one.digicert.com'
$TrustAllCertificates = $false

function Write-SectionSeparator {
    Write-Host ('-' * 64)
}

function Read-RequiredValue {
    param([string]$Prompt, [string]$Default)
    while ($true) {
        $promptText = if ([string]::IsNullOrWhiteSpace($Default)) { $Prompt } else { "$Prompt [$Default]" }
        $value = Read-Host $promptText
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
        Write-Host 'A value is required.'
    }
}

function Read-OptionalValue {
    param([string]$Prompt)
    return ([string](Read-Host "$Prompt (optional)")).Trim()
}

function Read-SecretValue {
    param([string]$Prompt)
    while ($true) {
        $secureValue = Read-Host $Prompt -AsSecureString
        if ($secureValue.Length -gt 0) { return $secureValue }
        Write-Host 'A value is required.'
    }
}

function ConvertTo-PlainText {
    param([Security.SecureString]$Value)
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
}

function ConvertTo-FormBody {
    param([System.Collections.IDictionary]$Values)
    $items = foreach ($key in $Values.Keys) {
        '{0}={1}' -f [Uri]::EscapeDataString([string]$key), [Uri]::EscapeDataString([string]$Values[$key])
    }
    return ($items -join '&')
}

function Get-HttpFailureMessage {
    param([Exception]$Exception, [string]$RequestUri)

    $targetUri = $null
    $target = 'the configured endpoint'
    if ([Uri]::TryCreate($RequestUri, [UriKind]::Absolute, [ref]$targetUri)) {
        $target = "$($targetUri.DnsSafeHost):$($targetUri.Port)"
    }

    $reason = 'Request setup, transport, or response processing failed.'
    $exceptionTypes = @()
    for ($current = $Exception; $null -ne $current; $current = $current.InnerException) {
        $exceptionTypes += $current.GetType().FullName
        if ($current -is [Net.WebException]) {
            switch ($current.Status.ToString()) {
                'NameResolutionFailure' { $reason = 'DNS lookup failed. Check the hostname and DNS settings.' }
                'ProxyNameResolutionFailure' { $reason = 'Proxy DNS lookup failed. Check proxy settings.' }
                'ConnectFailure' { $reason = 'Connection failed. Check the HTTPS port, routing, firewall, and proxy.' }
                'Timeout' { $reason = 'Request timed out after 60 seconds. Check reachability and server responsiveness.' }
                'TrustFailure' { $reason = 'TLS certificate validation failed. Check certificate trust, expiry, and hostname.' }
                'SecureChannelFailure' { $reason = 'TLS handshake failed. Check certificate trust and supported TLS versions.' }
            }
        }
        if ($current -is [Net.Sockets.SocketException]) {
            switch ($current.SocketErrorCode.ToString()) {
                'HostNotFound' { $reason = 'DNS lookup failed. Check the hostname and DNS settings.' }
                'NoData' { $reason = 'DNS lookup returned no address. Check the hostname and DNS settings.' }
                'TryAgain' { $reason = 'DNS lookup temporarily failed. Check DNS availability.' }
                'ConnectionRefused' { $reason = 'Connection refused. Check that HTTPS is listening on the configured port.' }
                'NetworkUnreachable' { $reason = 'Network unreachable. Check routing and VPN connectivity.' }
                'HostUnreachable' { $reason = 'Host unreachable. Check routing, firewall, and VPN connectivity.' }
                'TimedOut' { $reason = 'Connection timed out. Check routing, firewall, and server availability.' }
            }
        }
        if ($current -is [System.Security.Authentication.AuthenticationException]) {
            $reason = 'TLS handshake failed. Check certificate trust, expiry, hostname, and supported TLS versions.'
        }
        if ($current -is [OperationCanceledException]) {
            $reason = 'Request timed out or was cancelled. The configured timeout is 60 seconds.'
        }
    }

    $trustMode = if ($TrustAllCertificates) { 'bypassed' } else { 'enabled' }
    return "HTTPS request to $target failed. $reason Certificate validation: $trustMode. Exception types: $($exceptionTypes -join ' -> ')."
}

function Invoke-HttpRequest {
    param(
        [string]$Uri,
        [byte[]]$Body,
        [string]$ContentType,
        [System.Collections.IDictionary]$Headers = $null,
        [string]$ResponseFilePath
    )

    $restCommand = Get-Command Invoke-RestMethod -CommandType Cmdlet
    $requestParameters = @{
        Uri = $Uri
        Method = 'Post'
        ContentType = $ContentType
        TimeoutSec = 60
        MaximumRedirection = 0
        UseBasicParsing = $true
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) { $requestParameters.Body = $Body }
    if ($Headers) { $requestParameters.Headers = $Headers }
    if (-not [string]::IsNullOrWhiteSpace($ResponseFilePath)) {
        $requestParameters.OutFile = $ResponseFilePath
        if ($restCommand.Parameters.ContainsKey('SkipHttpErrorCheck')) {
            $requestParameters.SkipHttpErrorCheck = $true
        }
    }

    $statusCode = 200
    if ($restCommand.Parameters.ContainsKey('StatusCodeVariable')) {
        $requestParameters.StatusCodeVariable = 'statusCode'
    }
    $originalCertificateValidationCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
    $certificateValidationOverridden = $false
    try {
        if ($TrustAllCertificates) {
            if ($restCommand.Parameters.ContainsKey('SkipCertificateCheck')) {
                $requestParameters.SkipCertificateCheck = $true
            }
            else {
                if (-not ('PanosCertificateAutomation.RestCertificateTrust' -as [type])) {
                    Add-Type -TypeDefinition @'
namespace PanosCertificateAutomation
{
    public static class RestCertificateTrust
    {
        public static readonly System.Net.Security.RemoteCertificateValidationCallback AcceptAll =
            (sender, certificate, chain, errors) => true;
    }
}
'@
                }
                [Net.ServicePointManager]::ServerCertificateValidationCallback = [PanosCertificateAutomation.RestCertificateTrust]::AcceptAll
                $certificateValidationOverridden = $true
            }
        }

        $result = Invoke-RestMethod @requestParameters
        $content = if (-not [string]::IsNullOrWhiteSpace($ResponseFilePath)) {
            [IO.File]::ReadAllText($ResponseFilePath)
        }
        elseif ($result -is [System.Xml.XmlNode]) {
            $result.OuterXml
        }
        elseif ($result -is [string]) {
            $result
        }
        elseif ($null -eq $result) {
            ''
        }
        else {
            ConvertTo-Json -InputObject $result -Depth 100 -Compress
        }
        return [pscustomobject]@{ StatusCode = [int]$statusCode; Content = $content }
    }
    catch {
        $errorResponse = if ($_.Exception.PSObject.Properties.Name -contains 'Response') { $_.Exception.Response } else { $null }
        if ($null -ne $errorResponse) {
            try {
                $errorStatusCode = [int]$errorResponse.StatusCode
                if ($errorStatusCode -lt 200 -or $errorStatusCode -ge 300) {
                    $errorContent = ''
                    if (-not [string]::IsNullOrWhiteSpace($ResponseFilePath)) {
                        if ($errorResponse.PSObject.Properties.Name -contains 'Content') {
                            $errorBytes = $errorResponse.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                        }
                        else {
                            $errorStream = $errorResponse.GetResponseStream()
                            $memory = New-Object IO.MemoryStream
                            try {
                                $errorStream.CopyTo($memory)
                                $errorBytes = $memory.ToArray()
                            }
                            finally {
                                $memory.Dispose()
                                if ($null -ne $errorStream) { $errorStream.Dispose() }
                            }
                        }
                        [IO.File]::WriteAllBytes($ResponseFilePath, $errorBytes)
                        $errorContent = [IO.File]::ReadAllText($ResponseFilePath)
                    }
                    return [pscustomobject]@{ StatusCode = $errorStatusCode; Content = $errorContent }
                }
            }
            finally {
                if ($errorResponse -is [IDisposable]) { $errorResponse.Dispose() }
            }
        }
        throw (Get-HttpFailureMessage -Exception $_.Exception -RequestUri $Uri)
    }
    finally {
        if ($certificateValidationOverridden) {
            [Net.ServicePointManager]::ServerCertificateValidationCallback = $originalCertificateValidationCallback
        }
    }
}

function Invoke-PanosFormRequest {
    param([string]$FirewallUri, [System.Collections.IDictionary]$Values, [string]$ResponseFilePath)
    $body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-FormBody $Values))
    return Invoke-HttpRequest -Uri "$FirewallUri/api/" -Body $body -ContentType 'application/x-www-form-urlencoded' -ResponseFilePath $ResponseFilePath
}

function Test-PanosSuccess {
    param([string]$XmlText)
    try {
        $document = New-Object System.Xml.XmlDocument
        $document.XmlResolver = $null
        $document.LoadXml($XmlText)
        return ($document.DocumentElement.LocalName -eq 'response' -and $document.DocumentElement.GetAttribute('status') -eq 'success')
    }
    catch { return $false }
}

function New-MultipartBody {
    param(
        [System.Collections.IDictionary]$Fields,
        [string]$FilePath
    )
    $boundary = '---------------------------' + [Guid]::NewGuid().ToString('N')
    $memory = New-Object System.IO.MemoryStream
    $encoding = [Text.Encoding]::UTF8
    foreach ($key in $Fields.Keys) {
        $part = "--$boundary`r`nContent-Disposition: form-data; name=`"$key`"`r`n`r`n$($Fields[$key])`r`n"
        $bytes = $encoding.GetBytes($part)
        $memory.Write($bytes, 0, $bytes.Length)
    }
    $header = "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"certificate.crt`"`r`nContent-Type: application/x-pem-file`r`n`r`n"
    $headerBytes = $encoding.GetBytes($header)
    $memory.Write($headerBytes, 0, $headerBytes.Length)
    $fileBytes = [IO.File]::ReadAllBytes($FilePath)
    $memory.Write($fileBytes, 0, $fileBytes.Length)
    $trailer = $encoding.GetBytes("`r`n--$boundary--`r`n")
    $memory.Write($trailer, 0, $trailer.Length)
    $result = $memory.ToArray()
    $memory.Dispose()
    return [pscustomobject]@{ Boundary = $boundary; Bytes = $result }
}

function ConvertTo-XmlText {
    param([string]$Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

function Show-LegalNotice {
    Write-Host 'Welcome to the PAN-OS Certificate Automation Tool!'
    Write-Host ''
    Write-Host ('=' * 76)
    Write-Host 'LEGAL NOTICE'
    Write-Host ('=' * 76)
    Write-Host @'
Legal Notice (version January 1, 2026)
Copyright (C) 2026 DigiCert. All rights reserved.
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
'@
    Write-Host ('=' * 76)
    Write-Host ''
}

function Get-Configuration {
    Write-SectionSeparator
    Show-LegalNotice
    $accepted = Read-Host 'Do you accept the above legal notice and terms? [n]'
    if ($accepted -notmatch '^(?i:y|yes)$') { throw 'Legal notice must be accepted to proceed.' }

    Write-SectionSeparator
    Write-Host '=== PAN-OS Certificate Automation - Configuration ==='
    Write-Host '[OK] Legal notice accepted'
    Write-Host 'Press Enter to use default values shown in brackets'
    Write-Host ''
    Write-Host '--- PAN-OS Firewall Configuration ---'
    $firewall = Read-RequiredValue 'Firewall IP/Hostname' ''
    if ($firewall -notmatch '^https://') { $firewall = 'https://' + $firewall }
    $firewallUri = $null
    if (-not [Uri]::TryCreate($firewall, [UriKind]::Absolute, [ref]$firewallUri) -or $firewallUri.Scheme -ne 'https' -or $firewallUri.AbsolutePath -ne '/' -or $firewallUri.UserInfo -or $firewallUri.Query -or $firewallUri.Fragment) {
        throw 'Enter a valid HTTPS firewall hostname or base URL.'
    }
    $firewall = $firewall.TrimEnd('/')

    $panosKeySecure = Read-SecretValue 'API Key'
    $digicertKeySecure = $null
    try {
        Write-SectionSeparator
        Write-Host '--- Advanced Options ---'
        $autoCommitAnswer = Read-Host 'Automatically commit configuration changes to PAN-OS? [n]'
        $autoCommit = $autoCommitAnswer -match '^(?i:y|yes)$'

        Write-SectionSeparator
        Write-Host '--- Certificate Configuration ---'
        $certificateName = Read-RequiredValue 'Certificate Name' ''
        if ($certificateName.IndexOfAny([char[]]'*?[]') -ge 0) {
            throw 'Certificate Name cannot contain wildcard characters (*, ?, [ or ]) because it is used in filenames. Use a name such as wildcard-example-com; wildcard Common Names (CN) are allowed.'
        }
        if ($certificateName -notmatch '^[A-Za-z0-9._-]+$') { throw 'Certificate name may contain only letters, numbers, periods, underscores, and hyphens.' }
        $commonName = Read-RequiredValue 'Common Name (CN)' ''
        $organization = Read-OptionalValue 'Organization (O)'
        $locality = Read-OptionalValue 'Locality/City (L)'
        $state = Read-OptionalValue 'State/Province (ST)'
        $country = Read-OptionalValue 'Country Code (C)'
        if ($country -and $country -notmatch '^[A-Za-z]{2}$') { throw 'Country code must contain exactly two letters when provided.' }
        Write-SectionSeparator
        Write-Host '--- DigiCert API Configuration ---'
        $digicertKeySecure = Read-SecretValue 'DigiCert API Key'
        $profileId = Read-RequiredValue 'DigiCert Profile ID' ''
        $seatId = Read-RequiredValue 'DigiCert Seat ID' ''
        Write-SectionSeparator
        Write-Host '--- File Configuration ---'
        $outputDirectory = Read-RequiredValue 'Output Directory' '.\certs'

        Write-SectionSeparator
        Write-Host '=== Configuration Summary ==='
        Write-Host "DigiCert ONE host: $DigiCertOneHost"
        Write-Host "Firewall: $firewall"
        Write-Host "Certificate: $certificateName ($commonName)"
        $subjectDetails = [ordered]@{
            'Organization' = $organization
            'Locality/City' = $locality
            'State/Province' = $state
            'Country' = $country
        }
        foreach ($detail in $subjectDetails.GetEnumerator()) {
            if (-not [string]::IsNullOrWhiteSpace([string]$detail.Value)) {
                Write-Host "$($detail.Key): $($detail.Value)"
            }
        }
        Write-Host "Output Directory: $outputDirectory"
        if ($autoCommit) {
            Write-Host 'Auto-commit: Yes [OK]'
        }
        else {
            Write-Host 'Auto-commit: No [WARN] (manual commit required)'
        }
        Write-SectionSeparator
        $proceed = Read-Host 'Proceed with certificate automation? [y]'
        if ($proceed -match '^(?i:n|no)$') {
            Write-Host 'Operation cancelled.'
            $panosKeySecure.Dispose()
            $digicertKeySecure.Dispose()
            return $null
        }

        return [pscustomobject]@{
            FirewallUri = $firewall
            PanosApiKey = $panosKeySecure
            DigiCertApiKey = $digicertKeySecure
            CertificateName = $certificateName
            CommonName = $commonName
            Organization = $organization
            Locality = $locality
            State = $state
            Country = $country
            ProfileId = $profileId
            SeatId = $seatId
            OutputDirectory = $outputDirectory
            AutoCommit = $autoCommit
        }
    }
    catch {
        if ($null -ne $panosKeySecure) { $panosKeySecure.Dispose() }
        if ($null -ne $digicertKeySecure) { $digicertKeySecure.Dispose() }
        throw
    }
}

function New-PanosCsr {
    param([psobject]$Configuration, [string]$PanosApiKey)

    $rawResponsePath = Join-Path $Configuration.OutputDirectory ($Configuration.CertificateName + '_raw_response.xml')
    $cleanCsrPath = Join-Path $Configuration.OutputDirectory ($Configuration.CertificateName + '_clean.csr')
    $singleLineCsrPath = Join-Path $Configuration.OutputDirectory ($Configuration.CertificateName + '_single_line.txt')
    Write-SectionSeparator
    Write-Host 'Step 1: Generating CSR in PAN-OS...'
    $subjectFields = [ordered]@{
        CN = $Configuration.CommonName
        O = $Configuration.Organization
        L = $Configuration.Locality
        ST = $Configuration.State
        C = $Configuration.Country
    }
    $subject = @(
        foreach ($field in $subjectFields.GetEnumerator()) {
            if (-not [string]::IsNullOrWhiteSpace([string]$field.Value)) {
                '{0}={1}' -f $field.Key, $field.Value
            }
        }
    ) -join ','
    $command = '<request><certificate><generate><certificate-name>{0}</certificate-name><name>{1}</name><algorithm><RSA><rsa-nbits>2048</rsa-nbits></RSA></algorithm><signed-by>external</signed-by></generate></certificate></request>' -f (ConvertTo-XmlText $Configuration.CertificateName), (ConvertTo-XmlText $subject)
    $response = Invoke-PanosFormRequest -FirewallUri $Configuration.FirewallUri -Values @{ type = 'op'; key = $PanosApiKey; cmd = $command }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300 -or -not (Test-PanosSuccess $response.Content)) {
        throw '[ERROR] Failed to generate CSR in PAN-OS. The response was not displayed to protect returned data.'
    }
    Write-Host '[OK] CSR generated successfully in PAN-OS'

    Write-SectionSeparator
    Write-Host 'Step 2: Extracting CSR from PAN-OS...'
    $xpath = "/config/shared/certificate/entry[@name='$($Configuration.CertificateName)']"
    $response = Invoke-PanosFormRequest -FirewallUri $Configuration.FirewallUri -Values @{ type = 'config'; action = 'get'; key = $PanosApiKey; xpath = $xpath } -ResponseFilePath $rawResponsePath
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) { throw '[ERROR] Failed to extract CSR.' }
    $document = New-Object System.Xml.XmlDocument
    $document.XmlResolver = $null
    try { $document.LoadXml($response.Content) }
    catch { throw 'PAN-OS returned malformed XML; response content was not displayed.' }
    $csrNode = $document.SelectSingleNode("//*[local-name()='csr']")
    if ($null -eq $csrNode -or [string]::IsNullOrWhiteSpace($csrNode.InnerText)) { throw 'PAN-OS response did not contain a CSR.' }
    $csrPem = $csrNode.InnerText.Trim()
    if ($csrPem -notmatch '-----BEGIN CERTIFICATE REQUEST-----') {
        $csrPem = "-----BEGIN CERTIFICATE REQUEST-----`r`n$csrPem`r`n-----END CERTIFICATE REQUEST-----"
    }
    Set-Content -Path $cleanCsrPath -Value $csrPem -Encoding ASCII
    Write-Host "[OK] CSR extracted to $cleanCsrPath"
    $csrBase64 = ($csrPem -replace '-----BEGIN CERTIFICATE REQUEST-----|-----END CERTIFICATE REQUEST-----|\s', '')
    if ($csrBase64 -notmatch '^[A-Za-z0-9+/=]+$') { throw 'The CSR format returned by PAN-OS was invalid.' }
    Set-Content -Path $singleLineCsrPath -Value $csrBase64 -NoNewline -Encoding ASCII
    Write-Host "[OK] Single-line CSR saved to $singleLineCsrPath"
    Remove-Variable response, document, csrPem -ErrorAction SilentlyContinue
    return $csrBase64
}

function Request-DigiCertCertificate {
    param([psobject]$Configuration, [string]$DigiCertApiKey, [string]$CsrBase64)

    $digicertResponsePath = Join-Path $Configuration.OutputDirectory ($Configuration.CertificateName + '_digicert_response.json')
    $signedCertificatePath = Join-Path $Configuration.OutputDirectory ($Configuration.CertificateName + '_signed_certificate.crt')
    Write-SectionSeparator
    Write-Host 'Step 3: Submitting CSR to DigiCert...'
    $payload = @{
        profile = @{ id = $Configuration.ProfileId }
        seat = @{ seat_id = $Configuration.SeatId }
        csr = $CsrBase64
        attributes = @{ subject = @{ common_name = $Configuration.CommonName } }
    } | ConvertTo-Json -Depth 8 -Compress
    $payloadBytes = [Text.Encoding]::UTF8.GetBytes($payload)
    try {
        $response = Invoke-HttpRequest -Uri "https://$DigiCertOneHost/mpki/api/v1/certificate" -Body $payloadBytes -ContentType 'application/json' -Headers @{ 'x-api-key' = $DigiCertApiKey } -ResponseFilePath $digicertResponsePath
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) { throw "[ERROR] Failed to get certificate from DigiCert. Review $digicertResponsePath; response content was not displayed." }
        try { $digicertResult = ConvertFrom-Json -InputObject $response.Content }
        catch { throw "DigiCert returned malformed JSON. Review $digicertResponsePath; response content was not displayed." }
        if ([string]::IsNullOrWhiteSpace([string]$digicertResult.certificate)) { throw 'DigiCert response did not contain a certificate.' }
        $certificatePem = [string]$digicertResult.certificate
        if ($certificatePem -notmatch '-----BEGIN CERTIFICATE-----') { throw 'DigiCert returned a certificate in an unsupported format.' }
        Write-Host '[OK] Certificate issued by DigiCert'

        Write-SectionSeparator
        Write-Host 'Step 4: Extracting certificate from DigiCert response...'
        Set-Content -Path $signedCertificatePath -Value $certificatePem.Trim() -Encoding ASCII
        Write-Host "[OK] Certificate extracted to $signedCertificatePath"
        $pemMatch = [regex]::Match($certificatePem, '-----BEGIN CERTIFICATE-----\s*(?<data>[A-Za-z0-9+/=\s]+)\s*-----END CERTIFICATE-----')
        if (-not $pemMatch.Success) { throw 'The returned certificate could not be parsed.' }
        try {
            $certificateBytes = [Convert]::FromBase64String(($pemMatch.Groups['data'].Value -replace '\s', ''))
            $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,$certificateBytes)
        }
        catch { throw 'DigiCert certificate could not be decoded; response details were not displayed.' }
        try {
            if ($x509.NotAfter -le (Get-Date)) { throw 'The returned certificate is expired.' }
            Write-Host '[OK] Certificate is valid'
            Write-Host "Certificate Serial: $($x509.SerialNumber)"
            Write-Host "Certificate expires: $($x509.NotAfter.ToUniversalTime().ToString('u'))"
            return [pscustomobject]@{ SerialNumber = $x509.SerialNumber }
        }
        finally { $x509.Dispose() }
    }
    finally {
        Remove-Variable payload, payloadBytes, response, digicertResult, certificatePem, certificateBytes -ErrorAction SilentlyContinue
    }
}

function Import-PanosCertificate {
    param([psobject]$Configuration, [string]$PanosApiKey)

    $signedCertificatePath = Join-Path $Configuration.OutputDirectory ($Configuration.CertificateName + '_signed_certificate.crt')
    Write-SectionSeparator
    Write-Host 'Step 5: Importing signed certificate to PAN-OS...'
    $multipart = New-MultipartBody -Fields ([ordered]@{
        key = $PanosApiKey
        type = 'import'
        category = 'certificate'
        'certificate-name' = $Configuration.CertificateName
        format = 'pem'
    }) -FilePath $signedCertificatePath
    try {
        $response = Invoke-HttpRequest -Uri "$($Configuration.FirewallUri)/api/" -Body $multipart.Bytes -ContentType ('multipart/form-data; boundary=' + $multipart.Boundary)
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300 -or -not (Test-PanosSuccess $response.Content)) {
            throw '[ERROR] Failed to import certificate to PAN-OS. The response was not displayed to protect returned data.'
        }
        Write-Host '[OK] Certificate imported to PAN-OS successfully'
    }
    finally { Remove-Variable multipart, response -ErrorAction SilentlyContinue }
}

function Commit-PanosConfiguration {
    param([psobject]$Configuration, [string]$PanosApiKey)

    Write-SectionSeparator
    if (-not $Configuration.AutoCommit) {
        Write-Host 'Step 6: Skipping configuration commit (AUTO_COMMIT is set to false)'
        Write-Host '[WARN] Remember to commit the configuration manually in PAN-OS to activate the certificate'
        return
    }
    Write-Host 'Step 6: Committing PAN-OS configuration...'
    $response = Invoke-PanosFormRequest -FirewallUri $Configuration.FirewallUri -Values @{ type = 'commit'; key = $PanosApiKey; cmd = '<commit></commit>' }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300 -or -not (Test-PanosSuccess $response.Content)) {
        Write-Warning '[ERROR] Failed to commit configuration. Review pending changes in PAN-OS; response content was not displayed.'
    }
    else {
        Write-Host '[OK] Configuration committed successfully'
    }
    Remove-Variable response -ErrorAction SilentlyContinue
}

function Test-PanosInstallation {
    param([psobject]$Configuration, [string]$PanosApiKey)

    Write-SectionSeparator
    Write-Host 'Step 7: Verifying certificate installation...'
    $xpath = "/config/shared/certificate/entry[@name='$($Configuration.CertificateName)']"
    $response = Invoke-PanosFormRequest -FirewallUri $Configuration.FirewallUri -Values @{ type = 'config'; action = 'get'; key = $PanosApiKey; xpath = $xpath }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) { throw 'PAN-OS certificate verification request failed.' }
    $document = New-Object System.Xml.XmlDocument
    $document.XmlResolver = $null
    try { $document.LoadXml($response.Content) }
    catch { throw 'PAN-OS returned malformed XML; response content was not displayed.' }
    $privateKeyNode = $document.SelectSingleNode("//*[local-name()='private-key']")
    $commonNameNode = $document.SelectSingleNode("//*[local-name()='common-name']")
    if ($null -ne $privateKeyNode -and $null -ne $commonNameNode) { Write-Host '[OK] Certificate with private key verified in PAN-OS' }
    else { Write-Warning '[WARN] Certificate verification incomplete. Response content was not displayed.' }
    Remove-Variable response, document, privateKeyNode, commonNameNode -ErrorAction SilentlyContinue
}

function Main {
    $ErrorActionPreference = 'Stop'
    $originalSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $configuration = $null
    $panosKey = $null
    $digicertKey = $null
    try {
        $configuration = Get-Configuration
        if ($null -eq $configuration) { return }

        $panosKey = ConvertTo-PlainText $configuration.PanosApiKey
        $digicertKey = ConvertTo-PlainText $configuration.DigiCertApiKey
        $configuration.PanosApiKey.Dispose()
        $configuration.PanosApiKey = $null
        $configuration.DigiCertApiKey.Dispose()
        $configuration.DigiCertApiKey = $null

        $null = New-Item -ItemType Directory -Path $configuration.OutputDirectory -Force
        Write-SectionSeparator
        Write-Host '=== PAN-OS Certificate Automation Script ==='
        Write-Host "Certificate Name: $($configuration.CertificateName)"
        Write-Host "Common Name: $($configuration.CommonName)"
        Write-Host "Auto-commit: $($configuration.AutoCommit.ToString().ToLowerInvariant())"
        $csrBase64 = New-PanosCsr -Configuration $configuration -PanosApiKey $panosKey
        $certificateDetails = Request-DigiCertCertificate -Configuration $configuration -DigiCertApiKey $digicertKey -CsrBase64 $csrBase64
        Remove-Variable csrBase64 -ErrorAction SilentlyContinue
        Import-PanosCertificate -Configuration $configuration -PanosApiKey $panosKey
        Commit-PanosConfiguration -Configuration $configuration -PanosApiKey $panosKey
        Test-PanosInstallation -Configuration $configuration -PanosApiKey $panosKey

        Write-SectionSeparator
        Write-Host '=== Certificate Installation Complete ==='
        Write-Host "Certificate Name: $($configuration.CertificateName)"
        Write-Host "Common Name: $($configuration.CommonName)"
        Write-Host "Serial Number: $($certificateDetails.SerialNumber)"
        Write-Host "Output Directory: $($configuration.OutputDirectory)"
        Write-Host "Auto-commit: $($configuration.AutoCommit.ToString().ToLowerInvariant())"
        if (-not $configuration.AutoCommit) {
            Write-Host '[WARN] IMPORTANT: Configuration was NOT committed automatically.'
            Write-Host '   You must manually commit the configuration in PAN-OS to activate the certificate.'
        }
        Write-Host ''
        Write-Host 'Files created:'
        Write-Host "- $(Join-Path $configuration.OutputDirectory ($configuration.CertificateName + '_clean.csr')) (original CSR)"
        Write-Host "- $(Join-Path $configuration.OutputDirectory ($configuration.CertificateName + '_single_line.txt')) (single-line CSR for APIs)"
        Write-Host "- $(Join-Path $configuration.OutputDirectory ($configuration.CertificateName + '_digicert_response.json')) (DigiCert API response)"
        Write-Host "- $(Join-Path $configuration.OutputDirectory ($configuration.CertificateName + '_signed_certificate.crt')) (final signed certificate)"
        Write-Host "- $(Join-Path $configuration.OutputDirectory ($configuration.CertificateName + '_raw_response.xml')) (PAN-OS API response)"
        Write-Host ''
        Write-Host 'The certificate is now ready for use in SSL/TLS configurations!'
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $originalSecurityProtocol
        Remove-Variable panosKey, digicertKey, csrBase64 -ErrorAction SilentlyContinue
        if ($null -ne $configuration) {
            if ($null -ne $configuration.PanosApiKey) { $configuration.PanosApiKey.Dispose() }
            if ($null -ne $configuration.DigiCertApiKey) { $configuration.DigiCertApiKey.Dispose() }
        }
    }
}

Main