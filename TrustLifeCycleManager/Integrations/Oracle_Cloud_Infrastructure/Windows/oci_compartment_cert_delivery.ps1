<#
.SYNOPSIS
	Oracle Cloud Infrastructure (OCI) certificate import automation via REST API.
.DESCRIPTION
	This script automates the import of SSL/TLS certificates into Oracle Cloud Infrastructure (OCI) Certificates service using OCI REST APIs.
	It is designed to be used in a local machine standalone execution mode or in a LocalMachineValidateOnly mode where certificate files are provided via a specified folder.
	The script handles parsing of certificate and key files, constructing the required API request payload, signing the request with the provided RSA key, and invoking the OCI API to import the certificate.
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

# =====================================================================
# GLOBALS
# =====================================================================
$LEGAL_NOTICE_ACCEPT = "false"
$LOG_PATH = "C:\Program Files\DigiCert\TLM Agent\log\oci-compartment-cert-delivery.log"
$API_CALLS_LOG_PATH = "C:\Program Files\DigiCert\TLM Agent\log\oci-compartment-cert-delivery-api-calls.log"
$SCRIPT_VERSION = "1.0.0"

# =====================================================================
# Common inputs
# =====================================================================
$Region = "eu-frankfurt-1"

# =====================================================================
# CONFIGURATION for Local machine standalone script execution only or LocalMachineValidateOnly mode
# =====================================================================
# ARGUMENTS
$Arguments = @(
	# "ARGUMENT_1: Tenancy OCID"
	'',
	# "ARGUMENT_2: User OCID"
	'',
	# "ARGUMENT_3: Key fingerprint"
	'',
	# "ARGUMENT_4: Signing key file content (PEM format, unencrypted)"
	'',
	# "ARGUMENT_5: Compartment OCID"
	'',
	# "ARGUMENT_6: Certificate description (optional)"
	'',
	# "ARGUMENT_7: Input source (optional, defaults to 'AWRProduction')
	'AWRProduction'
)
$AdditionalInputs = @{
	# "CERT_FOLDER: Path to folder containing certificate files (.crt/.cer and .key) for LocalMachineValidateOnly mode"
	CertFolder = ""
}

function Write-Log {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Message,

		[ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DEBUG")]
		[string]$Level = "INFO"
	)

	if ($Level -eq "DEBUG") {
		if ($API_CALLS_LOG_PATH) {
			try {
				$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
				$line = "[$timestamp] [$Level] $Message"
				Add-Content -Path $API_CALLS_LOG_PATH -Value $line -ErrorAction Stop
			} catch {
				# Logging must never block certificate operations.
			}
		}
		return
	}
	$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
	$line = "[$timestamp] [$Level] $Message"
	Write-Host $line

	if ($LOG_PATH) {
		try {
			Add-Content -Path $LOG_PATH -Value $line -ErrorAction Stop
		} catch {
			# Logging must never block certificate operations.
		}
	}
}

function Test-RequiredPath {
	param(
		[Parameter(Mandatory = $false)]
		[string] $Path,
		[Parameter(Mandatory = $true)]
		[string] $Label
	)
	if ([string]::IsNullOrWhiteSpace($Path)) {
		Write-Log -Message "$Label path is not provided." -Level "ERROR"
		throw "$Label path is not provided."
	}
	if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -Path $Path)) {
		Write-Log -Message "$Label path not found: $Path" -Level "ERROR"
		throw "$Label path not found: $Path"
	}
	Write-Log -Message "$Label path validated: $Path" -Level "DEBUG"
}

function Initialize-PostScriptDataForLocalMachineValidateOnly {
	$env:DC1_POST_SCRIPT_DATA = $null
	Write-Log -Message "Preparing DC1_POST_SCRIPT_DATA environment variable for LocalMachineValidateOnly mode..." -Level "INFO"

	Test-RequiredPath -Path $AdditionalInputs.CertFolder -Label "Certificate folder"

	Write-Log -Message "Building certificate data structure with $($(Get-ChildItem -Path $AdditionalInputs.CertFolder -File).Count) files from $($AdditionalInputs.CertFolder)" -Level "DEBUG"
	$Data = @{
		args = $Arguments
		certfolder = $AdditionalInputs.CertFolder
		files      = @(Get-ChildItem -Path $AdditionalInputs.CertFolder -File | Select-Object -ExpandProperty Name)
		password   = ""
	}

	$CrtJson = $Data | ConvertTo-Json -Depth 2 -Compress
	Write-Log -Message "JSON data prepared (length: $($CrtJson.Length) bytes)" -Level "DEBUG"
	$JsonBytes = [System.Text.Encoding]::UTF8.GetBytes($CrtJson)
	$env:DC1_POST_SCRIPT_DATA = [Convert]::ToBase64String($JsonBytes)
	Write-Log -Message "DC1_POST_SCRIPT_DATA environment variable set successfully" -Level "SUCCESS"
}

function Get-PostScriptDataObject {
	try {
		Write-Log -Message "Retrieving DC1_POST_SCRIPT_DATA from environment..." -Level "DEBUG"
		$certInfo = $env:DC1_POST_SCRIPT_DATA
		if ([string]::IsNullOrEmpty($certInfo)) {
			Write-Log -Message "DC1_POST_SCRIPT_DATA environment variable is not set" -Level "ERROR"
			throw "DC1_POST_SCRIPT_DATA environment variable is not set"
		}
	
		Write-Log -Message "Decoding Base64 DC1_POST_SCRIPT_DATA (length: $($certInfo.Length) bytes)" -Level "DEBUG"
		$jsonBytes = [System.Convert]::FromBase64String($certInfo)
		$jsonString = [System.Text.Encoding]::UTF8.GetString($jsonBytes)
		Write-Log -Message "DC1_POST_SCRIPT_DATA decoded successfully (JSON length: $($jsonString.Length) bytes)" -Level "DEBUG"
		return ($jsonString | ConvertFrom-Json)
	}
	catch {
		throw "Failed to retrieve or parse DC1_POST_SCRIPT_DATA: $($_.Exception.Message)"
	}
}

function Print-AllArgs {
	param(
		[Parameter(Mandatory = $true)]
		[pscustomobject] $JsonObject
	)

	Write-Log -Message "Printing all arguments from DC1_POST_SCRIPT_DATA:" -Level "INFO"
	for ($i = 0; $i -lt [Math]::Min($JsonObject.args.Count, 7); $i++) {
		$last4Chars = if ($JsonObject.args[$i].Length -gt 4) { $JsonObject.args[$i].Substring($JsonObject.args[$i].Length - 4) } else { "---REDACTED---" }
		Write-Log -Message ("ARGUMENT_{0}: ...{1}" -f ($i + 1), $last4Chars) -Level "INFO"
	}
}

function Resolve-ArgumentsFromJson {
	param(
		[Parameter(Mandatory = $true)]
		[pscustomobject] $JsonObject
	)

	$ociArgs = @('', '', '', '', '', '', '')
	if ($JsonObject.args) {
		for ($i = 0; $i -lt [Math]::Min($JsonObject.args.Count, 7); $i++) {
			$ociArgs[$i] = [string]$JsonObject.args[$i]
		}
	}

	Print-AllArgs -JsonObject $JsonObject

	return @{
		TenancyOcid    = $ociArgs[0]
		UserOcid       = $ociArgs[1]
		KeyFingerprint = $ociArgs[2]
		SignKeyContent = $ociArgs[3]		
		CompartmentId  = $ociArgs[4]
		Description    = $ociArgs[5]
		InputSource    = if ($ociArgs[6]) { $ociArgs[6] } else { "AWRProduction" }
	}
}

function Resolve-OciCertificateFilePaths {
	param(
		[Parameter(Mandatory = $true)]
		[pscustomobject] $JsonObject
	)

	Write-Log -Message "Resolving certificate file paths from JsonObject..." -Level "DEBUG"
	$crtFile = ""
	$keyFile = ""
	if ($JsonObject.files) {
		Write-Log -Message "Found $($JsonObject.files.Count) files in JsonObject" -Level "DEBUG"
		$crtFile = $JsonObject.files | Where-Object { $_ -match '\.crt$|\.cer$' } | Select-Object -First 1
		$keyFile = $JsonObject.files | Where-Object { $_ -match '\.key$' } | Select-Object -First 1
		Write-Log -Message "Identified certificate file: '$crtFile', Key file: '$keyFile'" -Level "DEBUG"
	}

	$certFolder = [string]$JsonObject.certfolder
	if ([string]::IsNullOrWhiteSpace($certFolder)) {
		Write-Log -Message "certfolder is missing in DC1_POST_SCRIPT_DATA" -Level "ERROR"
		throw "certfolder is missing in DC1_POST_SCRIPT_DATA"
	}
	if ([string]::IsNullOrWhiteSpace($crtFile)) {
		Write-Log -Message "No .crt or .cer file found in certfolder: $certFolder" -Level "ERROR"
		throw "No .crt or .cer file found in certfolder of DC1_POST_SCRIPT_DATA"
	}
	if ([string]::IsNullOrWhiteSpace($keyFile)) {
		Write-Log -Message "No .key file found in certfolder: $certFolder" -Level "ERROR"
		throw "No .key file found in certfolder of DC1_POST_SCRIPT_DATA"
	}

	return @{
		CertFolder  = $certFolder
		CertPemPath = Join-Path -Path $certFolder -ChildPath $crtFile
		KeyPemPath  = Join-Path -Path $certFolder -ChildPath $keyFile
	}
}

function Remove-EmptyLines {
	param([string]$Text)
	$lines = $Text -split "\r?\n"
	$nonEmpty = $lines | Where-Object { $_.Trim() -ne "" }
	return ($nonEmpty -join "`n")
}

function Split-PemChain {
	param([string]$PemPath)
	Write-Log -Message "Processing PEM certificate chain from: $PemPath" -Level "DEBUG"
	if (-not (Test-Path $PemPath)) {
		Write-Log -Message "PEM file not found: $PemPath" -Level "ERROR"
		throw "PEM file not found: $PemPath"
	}

	Write-Log -Message "Reading PEM file content..." -Level "DEBUG"
	$PemContent = Get-Content -Raw -Path $PemPath
	Write-Log -Message "PEM file loaded (length: $($PemContent.Length) bytes)" -Level "DEBUG"
	
	$Pattern = "-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----"
	$Match = [regex]::Matches($PemContent, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

	if ($Match.Count -eq 0) {
		Write-Log -Message "No certificates found in input file: $PemPath" -Level "ERROR"
		throw "No certificates found in input file."
	}
	Write-Log -Message "Found $($Match.Count) certificate(s) in PEM chain" -Level "INFO"

	$LeafCert = Remove-EmptyLines -Text $Match[0].Value
	Write-Log -Message "Extracted leaf certificate (length: $($LeafCert.Length) bytes)" -Level "DEBUG"
	
	$ChainCerts = ""
	if ($Match.Count -gt 1) {
		Write-Log -Message "Extracting $($Match.Count - 1) intermediate certificate(s)..." -Level "DEBUG"
		for ($i = 1; $i -lt $Match.Count; $i++) {
			$ChainCerts += Remove-EmptyLines -Text $Match[$i].Value
			$ChainCerts += "`n"
		}
		Write-Log -Message "Certificate chain extracted (length: $($ChainCerts.Length) bytes)" -Level "DEBUG"
	} else {
		Write-Log -Message "No intermediate certificates found in chain" -Level "INFO"
	}

	return @{
		Leaf  = $LeafCert
		Chain = $ChainCerts
	}
}

function Get-OciRsaKey {
    param([Parameter(Mandatory)][string] $SignKeyContent)

    Write-Log -Message "Parsing RSA private key from PEM content..." -Level "DEBUG"

    if ([string]::IsNullOrWhiteSpace($SignKeyContent)) {
        Write-Log -Message "Signing key content is empty." -Level "ERROR"
        throw "Signing key content is empty."
    }

    $SignKeyContent = $SignKeyContent -replace '\\n', "`n"

    function Read-Asn1Tlv {
        param(
            [byte[]] $Data,
            [ref] $Offset
        )

        $tag = $Data[$Offset.Value]
        $Offset.Value++

        $lenByte = $Data[$Offset.Value]
        $Offset.Value++

        if (($lenByte -band 0x80) -eq 0) {
            $length = $lenByte
        }
        else {
            $count = $lenByte -band 0x7F
            $length = 0

            for ($i = 0; $i -lt $count; $i++) {
                $length = ($length -shl 8) -bor $Data[$Offset.Value]
                $Offset.Value++
            }
        }

        $value = New-Object byte[] $length
        [Array]::Copy($Data, $Offset.Value, $value, 0, $length)
        $Offset.Value += $length

        return @{
            Tag = $tag
            Length = $length
            Value = $value
        }
    }

    function Read-Asn1Integer {
        param(
            [byte[]] $Data,
            [ref] $Offset
        )

        $tlv = Read-Asn1Tlv -Data $Data -Offset $Offset

        if ($tlv.Tag -ne 0x02) {
            throw "Invalid RSA key format. Expected ASN.1 INTEGER."
        }

        [byte[]] $value = $tlv.Value

        while ($value.Length -gt 1 -and $value[0] -eq 0x00) {
            [byte[]] $value = $value[1..($value.Length - 1)]
        }

        return $value
    }

    function ConvertFrom-Pkcs1PrivateKey {
        param([byte[]] $DerBytes)

        $offset = 0
        $seq = Read-Asn1Tlv -Data $DerBytes -Offset ([ref]$offset)

        if ($seq.Tag -ne 0x30) {
            throw "Invalid RSA private key. Expected ASN.1 SEQUENCE."
        }

        $inner = $seq.Value
        $innerOffset = 0

        # version
        [void](Read-Asn1Integer -Data $inner -Offset ([ref]$innerOffset))

        $params = New-Object System.Security.Cryptography.RSAParameters
        $params.Modulus  = Read-Asn1Integer -Data $inner -Offset ([ref]$innerOffset)
        $params.Exponent = Read-Asn1Integer -Data $inner -Offset ([ref]$innerOffset)
        $params.D        = Read-Asn1Integer -Data $inner -Offset ([ref]$innerOffset)
        $params.P        = Read-Asn1Integer -Data $inner -Offset ([ref]$innerOffset)
        $params.Q        = Read-Asn1Integer -Data $inner -Offset ([ref]$innerOffset)
        $params.DP       = Read-Asn1Integer -Data $inner -Offset ([ref]$innerOffset)
        $params.DQ       = Read-Asn1Integer -Data $inner -Offset ([ref]$innerOffset)
        $params.InverseQ = Read-Asn1Integer -Data $inner -Offset ([ref]$innerOffset)

        return $params
    }

    function ConvertFrom-Pkcs8PrivateKey {
        param([byte[]] $DerBytes)

        $offset = 0
        $seq = Read-Asn1Tlv -Data $DerBytes -Offset ([ref]$offset)

        if ($seq.Tag -ne 0x30) {
            throw "Invalid PKCS#8 key. Expected ASN.1 SEQUENCE."
        }

        $inner = $seq.Value
        $innerOffset = 0

        # version
        [void](Read-Asn1Tlv -Data $inner -Offset ([ref]$innerOffset))

        # algorithm identifier
        [void](Read-Asn1Tlv -Data $inner -Offset ([ref]$innerOffset))

        # privateKey OCTET STRING
        $privateKey = Read-Asn1Tlv -Data $inner -Offset ([ref]$innerOffset)

        if ($privateKey.Tag -ne 0x04) {
            throw "Invalid PKCS#8 key. Expected OCTET STRING."
        }

        return ConvertFrom-Pkcs1PrivateKey -DerBytes $privateKey.Value
    }

    if ($SignKeyContent -match "-----BEGIN RSA PRIVATE KEY-----") {
        $base64 = $SignKeyContent `
            -replace "-----BEGIN RSA PRIVATE KEY-----", "" `
            -replace "-----END RSA PRIVATE KEY-----", "" `
            -replace "\s", ""

        $der = [Convert]::FromBase64String($base64)
        $rsaParams = ConvertFrom-Pkcs1PrivateKey -DerBytes $der
    }
    elseif ($SignKeyContent -match "-----BEGIN PRIVATE KEY-----") {
        $base64 = $SignKeyContent `
            -replace "-----BEGIN PRIVATE KEY-----", "" `
            -replace "-----END PRIVATE KEY-----", "" `
            -replace "\s", ""

        $der = [Convert]::FromBase64String($base64)
        $rsaParams = ConvertFrom-Pkcs8PrivateKey -DerBytes $der
    }
    else {
        throw "Unsupported PEM format. Expected BEGIN RSA PRIVATE KEY or BEGIN PRIVATE KEY."
    }

    $cspParams = New-Object System.Security.Cryptography.CspParameters
    $cspParams.ProviderType = 24
    $cspParams.ProviderName = "Microsoft Enhanced RSA and AES Cryptographic Provider"

    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider($cspParams)
    $rsa.PersistKeyInCsp = $false
    $rsa.ImportParameters($rsaParams)

    Write-Log -Message "RSA key imported successfully using PowerShell 5-compatible parser" -Level "SUCCESS"

    return $rsa
}

function Invoke-DryRunOciRequest {
	param(
		[Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'DELETE', 'HEAD')][string] $Method,
		[Parameter(Mandatory)][string] $Uri,
		[object] $Body
	)

	Write-Log -Message "Dry run: would invoke OCI request: $Method $Uri" -Level "INFO"
	return @{
		status = "DryRun"
		method = $Method
		uri    = $Uri
		body   = $Body
	}
}

function Invoke-OciRequest {
	param(
		[Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'DELETE', 'HEAD')][string] $Method,
		[Parameter(Mandatory)][string] $Uri,
		[object] $Body,
		[Parameter(Mandatory)][hashtable] $Config
	)
	
	Write-Log -Message "Preparing OCI $Method request to: $Uri" -Level "DEBUG"
	if ($InputSource -eq "AWRDryRun") {
		Write-Log -Message "Operating in AWRDryRun mode - will not execute actual API calls" -Level "WARN"
		return Invoke-DryRunOciRequest -Method $Method -Uri $Uri -Body $Body
	}

	Write-Log -Message ("OCI request invocation started: $Method $Uri") -Level "INFO"

	Write-Log -Message "Parsing URI and preparing request headers..." -Level "DEBUG"
	$u = [Uri]$Uri
	$path = $u.PathAndQuery
	Write-Log -Message "URI path: $path" -Level "DEBUG"
	$date = (Get-Date).ToUniversalTime().ToString("ddd, dd MMM yyyy HH:mm:ss 'GMT'", [System.Globalization.CultureInfo]::InvariantCulture)
	Write-Log -Message "Request date: $date" -Level "DEBUG"

	$keyId = "{0}/{1}/{2}" -f $Config.TenancyOcid, $Config.UserOcid, $Config.KeyFingerprint
	Write-Log -Message "Key ID: $keyId" -Level "DEBUG"

	$headers = [ordered]@{
		'date' = $date
		'host' = $u.Host
	}
	Write-Log -Message "Base headers: date, host=$($u.Host)" -Level "DEBUG"

	$bodyBytes = $null
	$hasBody = $Method -in @('POST', 'PUT') -and $null -ne $Body
	if ($hasBody) {
		Write-Log -Message "Request has body - computing SHA256 digest..." -Level "DEBUG"
		$json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
		$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
		Write-Log -Message "Request body size: $($bodyBytes.Length) bytes" -Level "DEBUG"
		$sha256 = [System.Security.Cryptography.SHA256]::Create()
		$digest = [Convert]::ToBase64String($sha256.ComputeHash($bodyBytes))
		Write-Log -Message "Content SHA256 digest: $digest" -Level "DEBUG"
		$headers['x-content-sha256'] = $digest
		$headers['content-type'] = 'application/json'
		$headers['content-length'] = "$($bodyBytes.Length)"
		Write-Log -Message "Added headers: x-content-sha256, content-type, content-length" -Level "DEBUG"
	} else {
		Write-Log -Message "Request has no body" -Level "DEBUG"
	}

	Write-Log -Message "Building signing string for RFC 3230 signature..." -Level "DEBUG"
	$signingHeaders = @('(request-target)') + $headers.Keys
	Write-Log -Message "Signing headers: $($signingHeaders -join ', ')" -Level "DEBUG"
	$lines = @("(request-target): {0} {1}" -f $Method.ToLower(), $path)
	foreach ($k in $headers.Keys) { $lines += ("{0}: {1}" -f $k, $headers[$k]) }
	$signingString = $lines -join "`n"
	Write-Log -Message "Signing string prepared ($($lines.Count) lines)" -Level "DEBUG"

	Write-Log -Message "Loading RSA key for signing..." -Level "DEBUG"
	$rsa = Get-OciRsaKey -SignKeyContent $Config.SignKeyContent
	try {
		Write-Log -Message "Signing request with RSA-SHA256..." -Level "DEBUG"
		$sigBytes = $rsa.SignData(
			[System.Text.Encoding]::ASCII.GetBytes($signingString),
			[System.Security.Cryptography.HashAlgorithmName]::SHA256,
			[System.Security.Cryptography.RSASignaturePadding]::Pkcs1
		)
		Write-Log -Message "Request signed successfully (signature length: $($sigBytes.Length) bytes)" -Level "DEBUG"
	} finally {
		$rsa.Dispose()
	}

	$signatureB64 = [Convert]::ToBase64String($sigBytes)
	Write-Log -Message "Signature Base64 encoded (length: $($signatureB64.Length) bytes)" -Level "DEBUG"
	$authHeader = 'Signature version="1",keyId="{0}",algorithm="rsa-sha256",headers="{1}",signature="{2}"' -f $keyId, ($signingHeaders -join ' '), $signatureB64
	Write-Log -Message "Authorization header prepared (length: $($authHeader.Length) bytes)" -Level "DEBUG"

	$reqHeaders = @{
		Date          = $date
		Authorization = $authHeader
	}
	foreach ($k in $headers.Keys) {
		if ($k -in @('host', 'content-type', 'content-length')) { continue }
		$reqHeaders[$k] = $headers[$k]
	}

	Write-Log -Message "Using PSCore Invoke-RestMethod for HTTP request..." -Level "DEBUG"
	$params = @{
		Method               = $Method
		Uri                  = $Uri
		Headers              = $reqHeaders
		ErrorAction          = 'Stop'
	}
	if ($hasBody) {
		$params.Body = $bodyBytes
		$params.ContentType = 'application/json'
	}
	Write-Log -Message "Invoking HTTP $Method request..." -Level "INFO"
	try {
		$response = Invoke-RestMethod @params
		Write-Log -Message ("OCI request completed successfully: $Method $Uri. Status code: $($response.StatusCode)") -Level "SUCCESS"
		return $response
	}
	catch {
		Write-Log -Message "HTTP request failed: $($_.Exception.Message)" -Level "ERROR"
		if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
			Write-Log -Message "Error response body: $($_.ErrorDetails.Message)" -Level "ERROR"
		}
		throw
	}
}

function Import-OciCertificate {
    <#
    Creates a new IMPORTED certificate in OCI Certificates service.
  
    .PARAMETER Name           friendly name for the cert resource
    .PARAMETER CompartmentId  target compartment OCID
    .PARAMETER CertPem        leaf cert content (PEM)
    .PARAMETER KeyPem         private key content (PEM, unencrypted)
    .PARAMETER ChainPem       issuer chain content (PEM); optional but recommended
    .PARAMETER Description    optional description
    #>
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $CompartmentId,
        [Parameter(Mandatory)][string] $CertPem,
        [Parameter(Mandatory)][string] $KeyPem,
        [string]      $ChainPem,
        [string]      $Description,
        [hashtable]   $Config = $Script:OciConfig
    )
    Write-Log -Message "Importing certificate '$Name' into compartment $CompartmentId ..." -Level "INFO"
  
    # version name as timestamp to ensure uniqueness; Certificates service requires it for imported certs but ignores it for generated certs
    $versionName = "v{0:yyyy-MM-dd-HH-mm-ss}" -f (Get-Date)

    $certificateConfig = [ordered]@{
        configType        = 'IMPORTED'
        certificatePem    = $CertPem
        privateKeyPem     = $KeyPem
        versionName       = $versionName
    }
    if ($ChainPem) {
        Write-Log -Message "Including certificate chain in import." -Level "INFO"
        $certificateConfig.certChainPem = $ChainPem
    }
  
    $body = [ordered]@{
        name              = $Name
        compartmentId     = $CompartmentId
        certificateConfig = $certificateConfig
    }
    if ($Description) { $body.description = $Description }
  
    $uri = "https://certificatesmanagement.$($Config.Region).oci.oraclecloud.com/20210224/certificates"
    $result = Invoke-OciRequest -Method POST -Uri $uri -Body $body -Config $Config
    Write-Log -Message ("Importing Certificate completed. OK -- certificate id: {0}  state: {1}" -f $result.id, $result.lifecycleState) -Level "SUCCESS"
    return $result
}

function Get-CertificateCommonName {
	param([string]$CertPemPath)
	try {
		$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertPemPath)
		# get common name (CN) from subject
		$cn = ($cert.Subject -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -like 'CN=*' } | ForEach-Object { $_.Substring(3) } | Select-Object -First 1
		return $cn
	} catch {
		throw "Failed to parse certificate PEM content: $($_.Exception.Message)"
	}
}

function Create-CertificateName {
	param([string]$CommonName)
	if ($CommonName.StartsWith("*.")) {
		return "star." + $CommonName.Substring(2)
	}
	return $CommonName
}

function Update-OciCertificate {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $CompartmentId,
        [Parameter(Mandatory)][string] $CertPem,
        [Parameter(Mandatory)][string] $KeyPem,
        [string]      $ChainPem,
        [string]      $Description,
		[string]      $CertificateId,
        [hashtable]   $Config = $Script:OciConfig
    )
    Write-Log -Message "Updating renewed certificate '$Name' in compartment '$CompartmentId' ..." -Level "INFO"
  
    # version name as timestamp to ensure uniqueness; Certificates service requires it for imported certs but ignores it for generated certs
    $versionName = "v{0:yyyy-MM-dd-HH-mm-ss}" -f (Get-Date)

    $certificateConfig = [ordered]@{
        configType        = 'IMPORTED'
        certificatePem    = $CertPem
        privateKeyPem     = $KeyPem
        versionName       = $versionName
    }
    if ($ChainPem) {
        Write-Log -Message "Including certificate chain in import." -Level "INFO"
        $certificateConfig.certChainPem = $ChainPem
    }
  
    $body = [ordered]@{
        name              = $Name
        compartmentId     = $CompartmentId
        certificateConfig = $certificateConfig
    }
    if ($Description) { $body.description = $Description }
  
    $uri = "https://certificatesmanagement.$($Config.Region).oci.oraclecloud.com/20210224/certificates/$CertificateId"
    $result = Invoke-OciRequest -Method PUT -Uri $uri -Body $body -Config $Config
    Write-Log -Message ("Updating renewed certificate completed. OK -- certificate id: {0}  new description: {1}" -f $result.id, $result.description) -Level "SUCCESS"
    return $result
}

function Get-CertificatesInCompartment {
	param(
		[Parameter(Mandatory)][string] $CompartmentId,
		[hashtable] $Config = $Script:OciConfig
	)

	$uri = "https://certificatesmanagement.$($Config.Region).oci.oraclecloud.com/20210224/certificates?compartmentId=$CompartmentId&limit=20"
	Write-Log -Message "Listing certificates in compartment: $CompartmentId" -Level "INFO"
	$response = Invoke-OciRequest -Method GET -Uri $uri -Body $null -Config $Config
	Write-Log -Message ("Found {0} certificate(s) in compartment {1}" -f ($response.items | Measure-Object).Count, $CompartmentId) -Level "INFO"
	return $response
}

function Test-CertificatePrerequisites {
	param(
		[Parameter(Mandatory = $true)]
		[hashtable] $certPaths,
		[Parameter(Mandatory = $true)]
		[string] $compartmentId
	)

	$certPemPath = $certPaths.CertPemPath
	$keyPemPath = $certPaths.KeyPemPath
	Write-Log -Message "Certificate path: $certPemPath" -Level "DEBUG"
	Write-Log -Message "Key path: $keyPemPath" -Level "DEBUG"
	if (-not $certPemPath -or -not (Test-Path $certPemPath)) {
		Write-Log -Message "Certificate file not found: $certPemPath" -Level "ERROR"
		throw "Certificate file not found: $certPemPath"
	}
	Write-Log -Message "Certificate file validated" -Level "DEBUG"
	
	if (-not $keyPemPath -or -not (Test-Path $keyPemPath)) {
		Write-Log -Message "Private key file not found: $keyPemPath" -Level "ERROR"
		throw "Private key file not found: $keyPemPath"
	}
	Write-Log -Message "Private key file validated" -Level "DEBUG"
	
	if (-not $compartmentId) {
		Write-Log -Message "Compartment OCID not provided - required for certificate import" -Level "ERROR"
		throw "Provide compartment OCID in ARGUMENT_6"
	}
	Write-Log -Message "All prerequisite validations passed" -Level "DEBUG"
}

function Find-ExistingCertificate {
	param(
		[Parameter(Mandatory = $false)]
		[object[]] $Certificates,
		[Parameter(Mandatory = $true)]
		[string] $CommonName
	)

	$commonNamePossibilities = New-Object System.Collections.Generic.List[string]
	$commonNamePossibilities.Add($CommonName)
	if ($CommonName.StartsWith("*.")) {
		$commonNamePossibilities.Add("star." + $CommonName.Substring(2))
		$commonNamePossibilities.Add("wildcard." + $CommonName.Substring(2))
	}
	Write-Log -Message "Matching certificate with common name matching possibilities: $($commonNamePossibilities -join ', ')" -Level "INFO"
	Write-Log -Message "Size of certificates list to evaluate: $($Certificates.Count)" -Level "INFO"
	$existingCertificate = $null
	foreach ($cert in $Certificates) {
		Write-Log -Message "Evaluating certificate: ID=$($cert.id), Name=$($cert.name), State=$($cert.lifecycleState), CommonName=$($cert.subject.commonName)" -Level "DEBUG"
		foreach ($commonName in $commonNamePossibilities) {
			if ($cert.subject -and $cert.subject.commonName -eq "$commonName") {
				$existingCertificate = $cert
				Write-Log -Message "Matching certificate found: ID=$($cert.id), Name=$($cert.name), State=$($cert.lifecycleState)" -Level "INFO"
				break
			}
		}
		if ($existingCertificate) { break }
	}
	return $existingCertificate
}

function Main {
	try {
		Write-Log -Message "================================================================" -Level "INFO"
		Write-Log -Message "OCI Certificate Import Script started. Version: $SCRIPT_VERSION" -Level "INFO"
		Write-Log -Message "================================================================" -Level "INFO"
		
		if ($Arguments.Contains("LocalMachineValidateOnly")) {
			Initialize-PostScriptDataForLocalMachineValidateOnly
		}
		if ($LEGAL_NOTICE_ACCEPT -ne "true") {
			Write-Log -Message "ERROR: Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT=\"true\" to proceed." -Level "ERROR"
			exit 1
		}

		$jsonObject = Get-PostScriptDataObject
		Write-Log -Message "Extracting OCI arguments from JSON object..." -Level "DEBUG"
		$arguments = Resolve-ArgumentsFromJson -JsonObject $jsonObject
		Write-Log -Message "OCI arguments resolved: Region=$($Region), InputSource=$($arguments.InputSource)" -Level "DEBUG"

		Write-Log -Message "Resolving certificate file paths..." -Level "DEBUG"
		$certPaths = Resolve-OciCertificateFilePaths -JsonObject $jsonObject
		Test-CertificatePrerequisites -certPaths $certPaths -compartmentId $arguments.CompartmentId

		$certCommonName = Get-CertificateCommonName -CertPemPath $certPaths.CertPemPath
		Write-Log -Message "Certificate common name: $certCommonName" -Level "SUCCESS"

		Write-Log -Message "Parsing certificate chain..." -Level "DEBUG"
		$pemContents = Split-PemChain -PemPath $certPaths.CertPemPath
		
		Write-Log -Message "Reading private key file..." -Level "DEBUG"
		$pemContents.Key = Get-Content -Raw -Path $certPaths.KeyPemPath
		Write-Log -Message "Private key loaded (length: $($pemContents.Key.Length) bytes)" -Level "DEBUG"

		$ociConfig = @{
			TenancyOcid    = $arguments.TenancyOcid
			UserOcid       = $arguments.UserOcid
			KeyFingerprint = $arguments.KeyFingerprint
			SignKeyContent = $arguments.SignKeyContent
			Region         = $Region
			InputSource    = $arguments.InputSource
		}

		$certificates = Get-CertificatesInCompartment -CompartmentId $arguments.CompartmentId -Config $ociConfig
		$existingCertificate = Find-ExistingCertificate -Certificates $certificates.items -CommonName $certCommonName

		if ($existingCertificate) {
			Write-Log -Message "Existing certificate with matching common name found with name $($existingCertificate.name). Proceeding to update." -Level "INFO"
			$updateParams = @{
				Name          = $certCommonName
				CompartmentId = $arguments.CompartmentId
				CertPem       = $pemContents.Leaf
				KeyPem        = $pemContents.Key
				ChainPem      = $pemContents.Chain
				Description   = $arguments.Description
				Config        = $ociConfig
				CertificateId  = $existingCertificate.id
			}
			$response = Update-OciCertificate @updateParams
			Write-Log -Message ("Certificate updated successfully: ID={0}, New State={1}" -f $response.id, $response.lifecycleState) -Level "SUCCESS"
		} else {
			$CertificateName = Create-CertificateName -CommonName $certCommonName
			Write-Log -Message "No existing certificate with matching common name found. Proceeding to import new certificate with name $CertificateName" -Level "INFO"
			$importParams = @{
				Name          = $CertificateName
				CompartmentId = $arguments.CompartmentId
				CertPem       = $pemContents.Leaf
				KeyPem        = $pemContents.Key
				ChainPem      = $pemContents.Chain
				Description   = $arguments.Description
				Config        = $ociConfig
			}
			$response = Import-OciCertificate @importParams
			Write-Log -Message ("Certificate imported successfully: ID={0}, State={1}" -f $response.id, $response.lifecycleState) -Level "SUCCESS"
		}

		Write-Log -Message "================================================================" -Level "INFO"
		Write-Log -Message "OCI Certificate Import Script completed. Version: $SCRIPT_VERSION" -Level "INFO"
		Write-Log -Message "================================================================" -Level "INFO"
	}
	catch {
		Write-Log -Message "Script execution failed. Error: $($_.Exception)" -Level "ERROR"
		Write-Log -Message "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"
		exit 1
	}
}

Main