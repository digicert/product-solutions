<#
.SYNOPSIS
	Oracle Cloud Infrastructure (OCI) Load Balancer certificate delivery automation via REST API.
.DESCRIPTION
	This script automates the delivery of SSL/TLS certificates to Oracle Cloud Infrastructure (OCI) Load Balancer using OCI REST APIs.
	The script handles parsing of certificate and key files, uploading the certificate to the OCI Load Balancer Certificates store, and binding it to the specified listener.
	Certificate naming convention: <CommonName>_<YYYYMMDD>.
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
$LOG_PATH = "C:\Program Files\DigiCert\TLM Agent\log\oci-lb-cert-delivery.log"
$API_CALLS_LOG_PATH = "C:\Program Files\DigiCert\TLM Agent\log\oci-lb-cert-delivery-api-calls.log"
$SCRIPT_VERSION = "1.0.0"

# =====================================================================
# Common inputs
# =====================================================================
$Region = "eu-frankfurt-1"

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
		$argValue = if ($null -ne $JsonObject.args[$i]) { [string]$JsonObject.args[$i] } else { "" }
		# Fully redact sensitive arguments: TenancyOcid, UserOcid, KeyFingerprint, SignKeyContent
		if ($i -le 3) {
			$display = "---REDACTED---"
		} elseif ($argValue.Length -le 4) {
			$display = $argValue
		} else {
			$display = "..." + $argValue.Substring($argValue.Length - 4)
		}
		Write-Log -Message ("ARGUMENT_{0}: {1}" -f ($i + 1), $display) -Level "INFO"
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
		TenancyOcid      = $ociArgs[0]
		UserOcid         = $ociArgs[1]
		KeyFingerprint   = $ociArgs[2]
		SignKeyContent   = $ociArgs[3]
		LoadBalancerId   = $ociArgs[4]
		ListenerName     = $ociArgs[5]
		InputSource      = if ($ociArgs[6]) { $ociArgs[6] } else { "AWRProduction" }
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
	if ($Config.InputSource -eq "AWRDryRun") {
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
		Write-Log -Message ("OCI request completed successfully: $Method $Uri") -Level "SUCCESS"
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

function Get-CertificateCommonName {
	param([string]$CertPemPath)
	if ([string]::IsNullOrWhiteSpace($CertPemPath) -or -not (Test-Path $CertPemPath)) {
		Write-Log -Message "Certificate file path is invalid: $CertPemPath" -Level "ERROR"
		throw "Certificate file path is invalid: $CertPemPath"
	}

	$cert = $null
	try {
		# PowerShell 5.1/.NET Framework compatible X509 load path.
		$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
		$certBytes = [System.IO.File]::ReadAllBytes($CertPemPath)
		$cert.Import($certBytes)

		$cn = $cert.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
		if ([string]::IsNullOrWhiteSpace($cn)) {
			$subject = $cert.Subject
			if ($subject -match '(^|,\s*)CN=([^,]+)') {
				$cn = $matches[2]
			}
		}

		if (-not [string]::IsNullOrWhiteSpace($cn)) {
			Write-Log -Message "Extracted certificate CN from certificate subject: $cn" -Level "DEBUG"
			return $cn.Trim()
		}

		Write-Log -Message "Certificate subject did not contain a CN value. Falling back to file name." -Level "WARN"
	}
	catch {
		Write-Log -Message "Failed to extract CN from certificate content. Falling back to file name. Details: $($_.Exception.Message)" -Level "WARN"
	}
	finally {
		if ($null -ne $cert) {
			$cert.Reset()
		}
	}

	$fileNameFallback = [System.IO.Path]::GetFileNameWithoutExtension($CertPemPath)
	if (-not [string]::IsNullOrWhiteSpace($fileNameFallback)) {
		Write-Log -Message "Using file name as CN fallback: $fileNameFallback" -Level "WARN"
		return $fileNameFallback.Trim()
	}

	Write-Log -Message "Unable to extract common name from certificate content or file name: $CertPemPath" -Level "ERROR"
	throw "Unable to extract common name from certificate content or file name: $CertPemPath"
}

function Create-CertificateName {
	param([string]$CommonName)
	$dateSuffix = (Get-Date).ToString("yyyyMMdd")
	$baseName = if ($CommonName.StartsWith("*.")) {
		"star." + $CommonName.Substring(2)
	} else {
		$CommonName
	}
	return "{0}_{1}" -f $baseName, $dateSuffix
}

function Test-CertificatePrerequisites {
	param(
		[Parameter(Mandatory = $true)]
		[hashtable] $certPaths
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
	Write-Log -Message "All prerequisite validations passed" -Level "DEBUG"
}

function Upload-LbCertificate {
    <#
    .SYNOPSIS
        Uploads a certificate to the OCI Load Balancer Certificates store.
    .DESCRIPTION
        Calls POST /loadBalancers/{loadBalancerId}/certificates (API 20170115).
        The certificate name is <CommonName>_<YYYYMMDD> (already formatted by Create-CertificateName).
    .PARAMETER LoadBalancerId   OCID of the target load balancer.
    .PARAMETER CertificateName  Friendly name for the LB certificate entry.
    .PARAMETER CertPem          Leaf certificate content (PEM).
    .PARAMETER KeyPem           Private key content (PEM, unencrypted).
    .PARAMETER ChainPem         Issuer chain content (PEM); optional.
    .PARAMETER Config           OCI auth/config hashtable.
    #>
    param(
        [Parameter(Mandatory)][string] $LoadBalancerId,
        [Parameter(Mandatory)][string] $CertificateName,
        [Parameter(Mandatory)][string] $CertPem,
        [Parameter(Mandatory)][string] $KeyPem,
        [string]    $ChainPem,
        [hashtable] $Config = $Script:OciConfig
    )

    Write-Log -Message "Uploading certificate '$CertificateName' to load balancer '$LoadBalancerId' ..." -Level "INFO"

    $body = [ordered]@{
        certificateName   = $CertificateName
        publicCertificate = $CertPem
        privateKey        = $KeyPem
    }
    if ($ChainPem) {
        Write-Log -Message "Including CA certificate chain in LB certificate upload." -Level "INFO"
        $body.caCertificate = $ChainPem
    }

    $uri = "https://iaas.$($Config.Region).oraclecloud.com/20170115/loadBalancers/$LoadBalancerId/certificates"
    Write-Log -Message "LB CreateCertificate URI: $uri" -Level "DEBUG"

    $result = Invoke-OciRequest -Method POST -Uri $uri -Body $body -Config $Config
    Write-Log -Message ("LB certificate upload completed. OK -- certificate name: {0}" -f $CertificateName) -Level "SUCCESS"
    return $result
}

function Get-LbListener {
    <#
    .SYNOPSIS
        Retrieves the current configuration of a Load Balancer listener.
	.DESCRIPTION
		Retrieves listener details from GET /loadBalancers/{loadBalancerId} response (listeners map).
		Used to read the existing listener properties before issuing an UpdateListener so that
		unchanged fields are preserved in the PUT body.
    .PARAMETER LoadBalancerId  OCID of the target load balancer.
    .PARAMETER ListenerName    Name of the listener to retrieve.
    .PARAMETER Config          OCI auth/config hashtable.
    #>
    param(
        [Parameter(Mandatory)][string] $LoadBalancerId,
        [Parameter(Mandatory)][string] $ListenerName,
        [hashtable] $Config = $Script:OciConfig
    )

    Write-Log -Message "Retrieving listener '$ListenerName' from load balancer '$LoadBalancerId' ..." -Level "INFO"

    try {
        $lb = Get-LoadBalancer -LoadBalancerId $LoadBalancerId -Config $Config

        if (-not $lb.listeners) {
            throw "No listeners were returned for load balancer '$LoadBalancerId'."
        }

        $listener = $lb.listeners.$ListenerName
        if (-not $listener) {
            $available = @($lb.listeners.PSObject.Properties.Name)
            throw "Listener '$ListenerName' was not found on load balancer. Available listeners: $($available -join ', ')"
        }

        Write-Log -Message ("LB listener retrieved. Name: {0}, Protocol: {1}, Port: {2}" -f $ListenerName, $listener.protocol, $listener.port) -Level "INFO"
        return $listener
    }
    catch {
        Write-Log -Message "Get-LbListener failed for listener '$ListenerName'. Error: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Set-LbListenerCertificate {
    <#
    .SYNOPSIS
        Binds a certificate to an OCI Load Balancer listener via UpdateListener.
    .DESCRIPTION
        Calls PUT /loadBalancers/{loadBalancerId}/listeners/{listenerName} (API 20170115).
        All required listener fields are preserved from the existing listener config;
        only sslConfiguration.certificateName is updated to the newly uploaded certificate.
    .PARAMETER LoadBalancerId   OCID of the target load balancer.
    .PARAMETER ListenerName     Name of the listener to update.
    .PARAMETER CertificateName  Name of the LB certificate to bind (must already exist in the LB).
    .PARAMETER Config           OCI auth/config hashtable.
    #>
    param(
        [Parameter(Mandatory)][string] $LoadBalancerId,
        [Parameter(Mandatory)][string] $ListenerName,
        [Parameter(Mandatory)][string] $CertificateName,
        [hashtable] $Config = $Script:OciConfig
    )

    Write-Log -Message "Binding certificate '$CertificateName' to listener '$ListenerName' on load balancer '$LoadBalancerId' ..." -Level "INFO"

    # Fetch current listener to preserve all required fields (protocol, port, defaultBackendSetName, etc.)
    $current = Get-LbListener -LoadBalancerId $LoadBalancerId -ListenerName $ListenerName -Config $Config

    # Build sslConfiguration: carry forward all existing SSL settings and replace only certificateName
    $sslConfig = [ordered]@{
        certificateName = $CertificateName
    }
    if ($current.sslConfiguration) {
        Write-Log -Message "Existing SSL configuration found on listener preserving non-certificate fields." -Level "DEBUG"
        foreach ($prop in $current.sslConfiguration.PSObject.Properties) {
            if ($prop.Name -ne 'certificateName') {
                $sslConfig[$prop.Name] = $prop.Value
            }
        }
    } else {
        Write-Log -Message "Listener has no prior SSL configuration creating a minimal sslConfiguration." -Level "WARN"
    }

    # UpdateListener requires: defaultBackendSetName, port, protocol; forward everything present
    $body = [ordered]@{
        defaultBackendSetName = $current.defaultBackendSetName
        port                  = $current.port
        protocol              = $current.protocol
        sslConfiguration      = $sslConfig
    }

    # Preserve optional fields if the listener currently has them
    $optionalFields = @(
        'connectionConfiguration', 'hostnameNames', 'pathRouteSetName',
        'routingPolicyName', 'ruleSetNames'
    )
    foreach ($field in $optionalFields) {
        if ($null -ne $current.$field) {
            Write-Log -Message "Preserving optional listener field: $field" -Level "DEBUG"
            $body[$field] = $current.$field
        }
    }

	# $bodyJson = $body | ConvertTo-Json -Depth 20 -Compress
	# Write-Log -Message ("UpdateListener request body: $bodyJson") -Level "INFO"

	$encodedListenerName = [System.Uri]::EscapeDataString($ListenerName)
	$uri = "https://iaas.$($Config.Region).oraclecloud.com/20170115/loadBalancers/$LoadBalancerId/listeners/$encodedListenerName"
    Write-Log -Message "LB UpdateListener URI: $uri" -Level "DEBUG"

    $result = Invoke-OciRequest -Method PUT -Uri $uri -Body $body -Config $Config
    Write-Log -Message ("LB listener '$ListenerName' updated successfully. Certificate '$CertificateName' is now bound.") -Level "SUCCESS"
    return $result
}

function Get-LoadBalancer {
    <#
    .SYNOPSIS
        Retrieves the details of an OCI Load Balancer.
    .DESCRIPTION
        Calls GET /loadBalancers/{loadBalancerId} (API 20170115).
        Returns comprehensive load balancer configuration including listeners, backend sets, and certificates.
    .PARAMETER LoadBalancerId  OCID of the target load balancer.
    .PARAMETER Config          OCI auth/config hashtable.
    #>
    param(
        [Parameter(Mandatory)][string] $LoadBalancerId,
        [hashtable] $Config = $Script:OciConfig
    )

    Write-Log -Message "Retrieving load balancer details for OCID: $LoadBalancerId" -Level "INFO"

    $uri = "https://iaas.$($Config.Region).oraclecloud.com/20170115/loadBalancers/$LoadBalancerId"
    Write-Log -Message "Get LoadBalancer URI: $uri" -Level "DEBUG"

    try {
        $result = Invoke-OciRequest -Method GET -Uri $uri -Body $null -Config $Config
        Write-Log -Message ("Load balancer retrieved. Name: {0}, Status: {1}, IP: {2}" -f $result.displayName, $result.lifecycleState, $result.ipAddress) -Level "SUCCESS"
        return $result
    }
    catch {
        Write-Log -Message "Failed to retrieve load balancer: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Main {
	try {
		Write-Log -Message "================================================================" -Level "INFO"
		Write-Log -Message "OCI LB Certificate Delivery Script started. Version: $SCRIPT_VERSION" -Level "INFO"
		Write-Log -Message "================================================================" -Level "INFO"

		if ($LEGAL_NOTICE_ACCEPT -ne "true") {
			Write-Log -Message "ERROR: Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT=\"true\" to proceed." -Level "ERROR"
			exit 1
		}

		$jsonObject = Get-PostScriptDataObject
		Write-Log -Message "Extracting OCI arguments from JSON object..." -Level "DEBUG"
		$arguments = Resolve-ArgumentsFromJson -JsonObject $jsonObject
		Write-Log -Message "OCI arguments resolved: Region=$($Region), InputSource=$($arguments.InputSource)" -Level "DEBUG"

		# Validate Load Balancer required arguments
		if ([string]::IsNullOrWhiteSpace($arguments.LoadBalancerId)) {
			Write-Log -Message "Load Balancer OCID not provided - required for LB certificate delivery (ARGUMENT_5)" -Level "ERROR"
			throw "Provide Load Balancer OCID in ARGUMENT_5"
		}
		Write-Log -Message "Load Balancer OCID validated." -Level "DEBUG"

		Write-Log -Message "Resolving certificate file paths..." -Level "DEBUG"
		$certPaths = Resolve-OciCertificateFilePaths -JsonObject $jsonObject
		Test-CertificatePrerequisites -certPaths $certPaths

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

		# ------------------------------------------------------------------
		# STEP 1: Upload certificate to OCI Load Balancer Certificates store
		# Certificate name = <CommonName>_<YYYYMMDD>
		# ------------------------------------------------------------------
		$lbCertName = Create-CertificateName -CommonName $certCommonName
		Write-Log -Message "Load Balancer certificate name: $lbCertName" -Level "INFO"

		$uploadParams = @{
			LoadBalancerId  = $arguments.LoadBalancerId
			CertificateName = $lbCertName
			CertPem         = $pemContents.Leaf
			KeyPem          = $pemContents.Key
			ChainPem        = $pemContents.Chain
			Config          = $ociConfig
		}
		Upload-LbCertificate @uploadParams | Out-Null

		if ([string]::IsNullOrWhiteSpace($arguments.ListenerName)) {
			Write-Log -Message "Listener name not provided (ARGUMENT_6). Skipping listener binding and completing after certificate upload." -Level "INFO"
			Write-Log -Message "================================================================" -Level "INFO"
			Write-Log -Message "OCI LB Certificate Delivery Script completed. Version: $SCRIPT_VERSION" -Level "INFO"
			Write-Log -Message "================================================================" -Level "INFO"
			exit 0
		}

		# add a delay to ensure the certificate is fully available before attempting to bind to listener
		Write-Log -Message "Waiting for 30 seconds to ensure certificate is available in LB certificate store before binding to listener..." -Level "INFO"
		Start-Sleep -Seconds 30

		# ------------------------------------------------------------------
		# STEP 2: Bind the uploaded certificate to the target listener
		# ------------------------------------------------------------------
		$bindParams = @{
			LoadBalancerId  = $arguments.LoadBalancerId
			ListenerName    = $arguments.ListenerName
			CertificateName = $lbCertName
			Config          = $ociConfig
		}
		Set-LbListenerCertificate @bindParams | Out-Null

		Write-Log -Message "================================================================" -Level "INFO"
		Write-Log -Message "OCI LB Certificate Delivery Script completed. Version: $SCRIPT_VERSION" -Level "INFO"
		Write-Log -Message "================================================================" -Level "INFO"
        exit 0
	}
	catch {
		Write-Log -Message "Script execution failed. Error: $($_.Exception)" -Level "ERROR"
		Write-Log -Message "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"
		exit 1
	}
}

Main