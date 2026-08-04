<#
.SYNOPSIS
	Barracuda WAF certificate upload and service bind automation script
.DESCRIPTION
	Uploads a signed PKCS12/PFX certificate to Barracuda WAF using REST API and binds it to a target virtual service.
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
	subparagraphs (c)(1) and (2) of the Commercial Computer Software-Restricted Rights at 48 CFR 52.227-19,
	as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
	The contractor/manufacturer is DIGICERT, INC.
#>

# =====================================================================
# GLOBALS
# =====================================================================
$LEGAL_NOTICE_ACCEPT = "false"
$LOG_PATH = "C:\\Program Files\\DigiCert\\TLM Agent\\log\\barracuda_waf_service_delivery.log"
$API_CALLS_LOG_PATH = "C:\\Program Files\\DigiCert\\TLM Agent\\log\\barracuda_waf_service_delivery_api.log"
$SCRIPT_VERSION = "1.0.0"

# =====================================================================
# Common inputs
# =====================================================================
# ARGUMENT_1: Base URL (include protocol and port)
#             Example: https:/<host>:8443 or http://<host>:8000
# ARGUMENT_2: API username
# ARGUMENT_3: API password
# ARGUMENT_4: Service name
# ARGUMENT_5: Certificate name (optional)
# ARGUMENT_6: Input source (AWRProduction/AWRDryRun)

function Write-Log {
	param(
		[Parameter(Mandatory = $true)][string]$Message,
		[ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DEBUG")][string]$Level = "INFO"
	)

	# Sanitize sensitive values before writing logs.
	$sanitizedMessage = $Message
	$sanitizedMessage = $sanitizedMessage -replace '(?i)((?:"|''|\b)(?:password|token|secret|api[_-]?key|authorization)(?:"|'')?\s*[:=]\s*"?)[^",\s}]+', '$1****'
	$sanitizedMessage = $sanitizedMessage -replace '(?i)([?&](?:password|token|secret|api[_-]?key)=)[^&\s]+', '$1****'
	$sanitizedMessage = $sanitizedMessage -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s,;]+', '$1****'

	$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
	$line = "[$timestamp] [$Level] $sanitizedMessage"

	if ($Level -ne "DEBUG") {
		Write-Host $line
	}

	$target = if ($Level -eq "DEBUG") { $API_CALLS_LOG_PATH } else { $LOG_PATH }
	if (-not [string]::IsNullOrWhiteSpace($target)) {
		try {
			Add-Content -Path $target -Value $line -ErrorAction Stop
		} catch {
			# Logging should never block certificate delivery.
		}
	}
}

function Write-ExceptionDetails {
	param(
		[Parameter(Mandatory = $true)]$ErrorRecord,
		[string]$Context = "Unhandled exception",
		[ValidateSet("ERROR", "WARN", "INFO", "DEBUG")][string]$Level = "ERROR"
	)

	if (-not $ErrorRecord) {
		Write-Log -Message "$($Context): no error record available" -Level $Level
		return
	}

	# PowerShell 5.1: Check if Exception property exists and is not null
	$exception = $null
	$exceptionProp = $ErrorRecord.PSObject.Properties.Name | Where-Object { $_ -eq 'Exception' }
	if ($exceptionProp) {
		$exception = $ErrorRecord.Exception
	}

	# Build primary error message
	$message = ""
	if ($exception -and $exception.Message) {
		$message = $exception.Message
	} elseif ($ErrorRecord) {
		$message = [string]$ErrorRecord
	} else {
		$message = "Unknown error"
	}
	Write-Log -Message "$($Context): $message" -Level $Level

	# Log error details if available
	$errorDetailsProp = $ErrorRecord.PSObject.Properties.Name | Where-Object { $_ -eq 'ErrorDetails' }
	if ($errorDetailsProp -and $ErrorRecord.ErrorDetails) {
		$detailMsgProp = $ErrorRecord.ErrorDetails.PSObject.Properties.Name | Where-Object { $_ -eq 'Message' }
		if ($detailMsgProp -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
			Write-Log -Message "Error details: $($ErrorRecord.ErrorDetails.Message)" -Level $Level
		}
	}

	# Log HTTP response body if available (PowerShell 5+)
	if ($exception) {
		$responseProp = $exception.PSObject.Properties.Name | Where-Object { $_ -eq 'Response' }
		if ($responseProp -and $exception.Response) {
			try {
				$responseBody = $exception.Response.GetResponseStream()
				if ($responseBody) {
					$reader = New-Object System.IO.StreamReader($responseBody)
					$errorContent = $reader.ReadToEnd()
					if (-not [string]::IsNullOrWhiteSpace($errorContent)) {
						Write-Log -Message "HTTP response body: $errorContent" -Level $Level
					}
					$reader.Dispose()
					$responseBody.Dispose()
				}
			} catch {
				# Response body extraction should not block exception logging
			}
		}
	}

	# Log script stack trace if available
	$stackTraceProp = $ErrorRecord.PSObject.Properties.Name | Where-Object { $_ -eq 'ScriptStackTrace' }
	if ($stackTraceProp -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.ScriptStackTrace)) {
		Write-Log -Message "Script stack trace: $($ErrorRecord.ScriptStackTrace)" -Level $Level
	}

	# Log invocation position if available
	$invocationProp = $ErrorRecord.PSObject.Properties.Name | Where-Object { $_ -eq 'InvocationInfo' }
	if ($invocationProp -and $ErrorRecord.InvocationInfo) {
		$positionProp = $ErrorRecord.InvocationInfo.PSObject.Properties.Name | Where-Object { $_ -eq 'PositionMessage' }
		if ($positionProp -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.InvocationInfo.PositionMessage)) {
			Write-Log -Message "Invocation position: $($ErrorRecord.InvocationInfo.PositionMessage)" -Level $Level
		}
	}

	# Log inner exceptions if available
	$inner = $null
	if ($exception) {
		$innerExceptionProp = $exception.PSObject.Properties.Name | Where-Object { $_ -eq 'InnerException' }
		if ($innerExceptionProp) {
			$inner = $exception.InnerException
		}
	}
	$innerDepth = 0
	while ($inner -and $innerDepth -lt 10) {
		$innerDepth++
		$innerMsg = ""
		$innerMsgProp = $inner.PSObject.Properties.Name | Where-Object { $_ -eq 'Message' }
		if ($innerMsgProp) {
			$innerMsg = $inner.Message
		} else {
			$innerMsg = [string]$inner
		}
		Write-Log -Message "Inner exception [$innerDepth]: $innerMsg" -Level $Level
		$innerStackProp = $inner.PSObject.Properties.Name | Where-Object { $_ -eq 'StackTrace' }
		if ($innerStackProp -and -not [string]::IsNullOrWhiteSpace($inner.StackTrace)) {
			Write-Log -Message "Inner stack [$innerDepth]: $($inner.StackTrace)" -Level $Level
		}
		$innerExceptionNextProp = $inner.PSObject.Properties.Name | Where-Object { $_ -eq 'InnerException' }
		if ($innerExceptionNextProp) {
			$inner = $inner.InnerException
		} else {
			$inner = $null
		}
	}

	# Log main exception stack trace if available
	$exceptionStackProp = $null
	if ($exception) {
		$exceptionStackProp = $exception.PSObject.Properties.Name | Where-Object { $_ -eq 'StackTrace' }
	}
	if ($exceptionStackProp -and -not [string]::IsNullOrWhiteSpace($exception.StackTrace)) {
		Write-Log -Message "Exception stack trace: $($exception.StackTrace)" -Level $Level
	}
}

function Get-PostScriptDataObject {
	$encoded = $env:DC1_POST_SCRIPT_DATA
	if ([string]::IsNullOrWhiteSpace($encoded)) {
		throw "DC1_POST_SCRIPT_DATA environment variable is not set"
	}

	$json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
	return ($json | ConvertFrom-Json)
}

function Resolve-ArgumentsFromJson {
	param([Parameter(Mandatory = $true)][pscustomobject]$JsonObject)

	$apiArgs = @('', '', '', '', '', '')
	if ($JsonObject.args) {
		for ($i = 0; $i -lt [Math]::Min($JsonObject.args.Count, 6); $i++) {
			$apiArgs[$i] = [string]$JsonObject.args[$i]
		}
	}

	return @{
		BaseUrl = $apiArgs[0]
		Username = $apiArgs[1]
		Password = $apiArgs[2]
		VirtualServiceName = $apiArgs[3]
		CertificateName = if ([string]::IsNullOrWhiteSpace($apiArgs[4])) { "" } else { $apiArgs[4] }
		InputSource = if ([string]::IsNullOrWhiteSpace($apiArgs[5])) { "AWRProduction" } else { $apiArgs[5] }
	}
}

function Resolve-BarracudaPkcs12Inputs {
	param([Parameter(Mandatory = $true)][pscustomobject]$JsonObject)

	$certFolder = [string]$JsonObject.certfolder
	if ([string]::IsNullOrWhiteSpace($certFolder)) {
		throw "certfolder is missing"
	}

	$files = @()
	if ($JsonObject.files) {
		$files = @($JsonObject.files | ForEach-Object { [string]$_ })
	}

	if ($files.Count -eq 0) {
		$files = @(Get-ChildItem -Path $certFolder -File | Select-Object -ExpandProperty Name)
	}

	if ($files.Count -eq 0) {
		throw "No files found in certfolder"
	}

	$pkcs12 = $files | Where-Object { $_ -match '(?i)\.(pfx|p12)$' } | Select-Object -First 1
	if ([string]::IsNullOrWhiteSpace($pkcs12)) {
		throw "PFX/PKCS12 certificate file (.pfx or .p12) is required in certfolder"
	}

	return @{
		Type = "pkcs12"
		SignedCertificatePath = Join-Path -Path $certFolder -ChildPath $pkcs12
		Password = if ($JsonObject.password) { [string]$JsonObject.password } else { "" }
	}
}

function New-X509Certificate2Compat {
	param(
		[Parameter(Mandatory = $true)][string]$CertificatePath,
		[Parameter(Mandatory = $true)][string]$CertificatePassword,
		[Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]$Flags
	)

	# PowerShell 5.1 can run on older .NET Framework builds where ::new may fail.
	# Try constructor syntax first, then fall back to New-Object.
	try {
		return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CertificatePath, $CertificatePassword, $Flags)
	} catch {
		return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertificatePath, $CertificatePassword, $Flags)
	}
}

function Get-CertificateKeyType {
	param(
		[Parameter(Mandatory = $true)][string]$CertificatePath,
		[Parameter(Mandatory = $true)][string]$CertificatePassword
	)

	if (-not (Test-Path -LiteralPath $CertificatePath)) {
		throw "Certificate file not found: $CertificatePath"
	}

	if ([string]::IsNullOrWhiteSpace($CertificatePassword)) {
		throw "Certificate password is required to determine key type"
	}

	$cert = $null
	$rsa = $null
	$ecdsa = $null

	try {
		$loadErrors = @()
		$exportableFlag = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
		$flagCandidates = @()
		# EphemeralKeySet requires .NET Framework 4.7.2+; reference it defensively so older
		# hosts fall back to the Exportable-only flag instead of failing here.
		try {
			$ephemeralFlag = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
			$flagCandidates += ($exportableFlag -bor $ephemeralFlag)
		} catch {
			# EphemeralKeySet not available on this .NET Framework version.
		}
		$flagCandidates += $exportableFlag

		foreach ($flags in $flagCandidates) {
			try {
				$cert = New-X509Certificate2Compat -CertificatePath $CertificatePath -CertificatePassword $CertificatePassword -Flags $flags
				break
			} catch {
				$loadErrors += $_.Exception.Message
			}
		}

		if (-not $cert) {
			throw "Unable to load certificate with supported key storage flags. $($loadErrors -join ' | ')"
		}

		$rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
		if ($rsa) {
			Write-Log -Message "Detected certificate key type: rsa" -Level "INFO"
			return "rsa"
		}

		$ecdsa = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($cert)
		if ($ecdsa) {
			Write-Log -Message "Detected certificate key type: ecdsa" -Level "INFO"
			return "ecdsa"
		}

		# Backward-compatible fallback for environments where extension methods are limited.
		if ($cert.PrivateKey) {
			$privateKeyTypeName = [string]$cert.PrivateKey.GetType().FullName
			if ($privateKeyTypeName -match 'RSA') {
				Write-Log -Message "Detected certificate key type via fallback private key type: rsa" -Level "INFO"
				return "rsa"
			}
			if ($privateKeyTypeName -match 'ECDsa|ECDiffieHellman') {
				Write-Log -Message "Detected certificate key type via fallback private key type: ecdsa" -Level "INFO"
				return "ecdsa"
			}
		}

		throw "Unsupported certificate private key algorithm. Only RSA and ECDSA are supported."
	} catch {
			throw
	} finally {
		if ($rsa) {
			$rsa.Dispose()
		}
		if ($ecdsa) {
			$ecdsa.Dispose()
		}
		if ($cert) {
			$cert.Dispose()
		}
	}
}

function New-BarracudaCertificateName {
	param(
		[Parameter(Mandatory = $true)][hashtable]$CertPaths,
		[string]$RequestedName
	)

	if (-not [string]::IsNullOrWhiteSpace($RequestedName)) {
		return $RequestedName.Trim()
	}

	$baseName = [System.IO.Path]::GetFileNameWithoutExtension($CertPaths.SignedCertificatePath)
	$uniqueName = $baseName + "_" + (Get-Date -Format "yyyyMMddHHmmss")

	return $uniqueName
}

function Get-BarracudaApiBaseUrl {
	param([Parameter(Mandatory = $true)][string]$BaseUrl)

	$trimmed = $BaseUrl.Trim()
	if (-not ($trimmed -match '^https?://')) {
		throw "Base URL must include protocol and port. Example: http://<host>:8000 or https://<host>:8443"
	}

	return $trimmed.TrimEnd('/')
}

function Get-BasicAuthorizationHeader {
	param([Parameter(Mandatory = $true)][string]$Token)

	$raw = "${Token}:"
	$encoded = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($raw))
	return "Basic $encoded"
}

function Invoke-DryRunApiRequest {
	param(
		[Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string]$Method,
		[Parameter(Mandatory)][string]$Uri,
		[object]$Body
	)

	Write-Log -Message "Dry run: $Method $Uri" -Level "INFO"
	return @{ status = "DryRun"; method = $Method; uri = $Uri; body = $Body }
}

function Invoke-ApiRequest {
	param(
		[Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string]$Method,
		[Parameter(Mandatory)][string]$Uri,
		[object]$Body,
		[Parameter(Mandatory)][hashtable]$Config,
		[switch]$SkipAuth,
		[switch]$AsJson
	)

	if ($Config.InputSource -eq "AWRDryRun") {
		return Invoke-DryRunApiRequest -Method $Method -Uri $Uri -Body $Body
	}

	$headers = @{}
	if (-not $SkipAuth) {
		if ([string]::IsNullOrWhiteSpace($Config.SessionToken)) {
			throw "Session token is empty for authenticated request"
		}
		$headers["Authorization"] = Get-BasicAuthorizationHeader -Token $Config.SessionToken
	}

	$invokeParams = @{
		Method = $Method
		Uri = $Uri
		Headers = $headers
		ErrorAction = "Stop"
	}

	if ($AsJson) {
		$invokeParams["ContentType"] = "application/json"
		if ($null -ne $Body) {
			$invokeParams["Body"] = ($Body | ConvertTo-Json -Depth 6 -Compress)
		}
	}

	Write-Log -Message "API call: $Method $Uri" -Level "INFO"
	try {
        $response = Invoke-RestMethod @invokeParams
        # Write-Log -Message "API response: $(if ($response) { $response | ConvertTo-Json -Depth 6 -Compress } else { 'null' })" -Level "INFO"
        if ($response -and $response.PSObject.Properties.Name -contains "token") {
            $Config.SessionToken = [string]$response.token
        }
        return $response
    }
    catch {
		Write-Log -Message "API request failed ($Method $Uri)" -Level "ERROR"
		throw
    }
}

function New-BarracudaSignedCertificateMultipartBody {
	param(
		[Parameter(Mandatory = $true)][string]$CertificateName,
		[Parameter(Mandatory = $true)][string]$KeyType,
		[Parameter(Mandatory = $true)][hashtable]$CertPaths
	)

	$boundary = "---------------------------" + [Guid]::NewGuid().ToString("N")
	$crlf = "`r`n"
	$fileName = [System.IO.Path]::GetFileName($CertPaths.SignedCertificatePath)
	$fileBytes = [System.IO.File]::ReadAllBytes($CertPaths.SignedCertificatePath)
	$utf8 = [System.Text.Encoding]::UTF8

	$ms = New-Object System.IO.MemoryStream
	try {
		$writeString = {
			param([string]$text)
			$bytes = $utf8.GetBytes($text)
			$ms.Write($bytes, 0, $bytes.Length)
		}

		& $writeString "--$boundary$crlf"
		& $writeString "Content-Disposition: form-data; name=`"name`"$crlf$crlf"
		& $writeString "$CertificateName$crlf"

		& $writeString "--$boundary$crlf"
		& $writeString "Content-Disposition: form-data; name=`"type`"$crlf$crlf"
		& $writeString "$($CertPaths.Type)$crlf"

		& $writeString "--$boundary$crlf"
		& $writeString "Content-Disposition: form-data; name=`"key_type`"$crlf$crlf"
		& $writeString "$KeyType$crlf"

		& $writeString "--$boundary$crlf"
		& $writeString "Content-Disposition: form-data; name=`"password`"$crlf$crlf"
		& $writeString "$($CertPaths.Password)$crlf"

		& $writeString "--$boundary$crlf"
		& $writeString "Content-Disposition: form-data; name=`"allow_private_key_export`"$crlf$crlf"
		& $writeString "no$crlf"

		& $writeString "--$boundary$crlf"
		& $writeString "Content-Disposition: form-data; name=`"signed_certificate`"; filename=`"$fileName`"$crlf"
		& $writeString "Content-Type: application/x-pkcs12$crlf$crlf"
		$ms.Write($fileBytes, 0, $fileBytes.Length)
		& $writeString $crlf

		& $writeString "--$boundary--$crlf"

		return @{
			Body = $ms.ToArray()
			ContentType = "multipart/form-data; boundary=$boundary"
		}
	} finally {
		if ($ms) {
			$ms.Dispose()
		}
	}
}

function Import-CertificateToBarracuda {
	param(
		[Parameter(Mandatory = $true)][string]$CertificateName,
		[Parameter(Mandatory = $true)][hashtable]$CertPaths,
		[Parameter(Mandatory = $true)][hashtable]$Config,
		[Parameter(Mandatory = $true)][string]$KeyType
	)

	$uploadUri = "$($Config.BaseUrl)/restapi/v1/certificates?upload=signed"
	if ($Config.InputSource -eq "AWRDryRun") {
		return Invoke-DryRunApiRequest -Method "POST" -Uri $uploadUri -Body @{ name = $CertificateName; type = $CertPaths.Type; key_type = $KeyType; signed_certificate = $CertPaths.SignedCertificatePath }
	}

	$payload = New-BarracudaSignedCertificateMultipartBody -CertificateName $CertificateName -KeyType $KeyType -CertPaths $CertPaths
	$headers = @{ Authorization = (Get-BasicAuthorizationHeader -Token $Config.SessionToken) }
	Write-Log -Message "Uploading certificate with name '$CertificateName'" -Level "INFO"
	try {
		$response = Invoke-RestMethod -Method "POST" -Uri $uploadUri -Headers $headers -ContentType $payload.ContentType -Body $payload.Body -ErrorAction Stop
		# Write-Log -Message "Certificate upload response body: $(if ($response) { $response | ConvertTo-Json -Depth 8 -Compress } else { 'null' })" -Level "INFO"
        Write-Log -Message "Certificate upload completed" -Level "INFO"
		if ($response -and $response.PSObject.Properties.Name -contains "token") {
			$Config.SessionToken = [string]$response.token
		}

		return $response
	} catch {
		Write-Log -Message "Certificate upload failed ($uploadUri)" -Level "ERROR"
		throw
	}
}

function Test-BarracudaWafPrerequisites {
	param(
		[Parameter(Mandatory = $true)][hashtable]$CertPaths,
		[Parameter(Mandatory = $true)][hashtable]$InputArgs
	)

	if ([string]::IsNullOrWhiteSpace($InputArgs.BaseUrl)) {
		throw "Base URL is required"
	}
	if ([string]::IsNullOrWhiteSpace($InputArgs.Username)) {
		throw "API username is required"
	}
	if ([string]::IsNullOrWhiteSpace($InputArgs.Password)) {
		throw "API password is required"
	}
	if ([string]::IsNullOrWhiteSpace($InputArgs.VirtualServiceName)) {
		throw "Virtual service name is required"
	}
	if (-not (Test-Path -Path $CertPaths.SignedCertificatePath)) {
		throw "Signed certificate file not found: $($CertPaths.SignedCertificatePath)"
	}
	if ([string]::IsNullOrWhiteSpace($CertPaths.Password)) {
		throw "PFX/PKCS12 password is required"
	}
}

function Print-ParsedArguments {
    param([Parameter(Mandatory = $true)][hashtable]$ParsedArgs)
    Write-Log -Message "Parsed input arguments:" -Level "INFO"
    foreach ($key in $ParsedArgs.Keys) {
        $value = $ParsedArgs[$key]
        if ($key -match 'password|secret|token|key' -and -not [string]::IsNullOrWhiteSpace($value)) {
            $displayValue = if ($value.Length -gt 4) { "****" + $value.Substring($value.Length - 4) } else { "****" }
            Write-Log -Message "  $($key): $($displayValue)" -Level "INFO"
        } else {
            Write-Log -Message "  $($key): $($value)" -Level "INFO"
        }
    }
}

function Connect-BarracudaWaf {
	param(
		[Parameter(Mandatory = $true)][hashtable]$Config,
		[Parameter(Mandatory = $true)][string]$Username,
		[Parameter(Mandatory = $true)][string]$Password
	)

	$loginUri = "$($Config.BaseUrl)/restapi/v3.2/login"
	if ($Config.InputSource -eq "AWRDryRun") {
		Write-Log -Message "Dry run: would authenticate to Barracuda WAF via POST $loginUri" -Level "INFO"
		$Config.SessionToken = "DRYRUN"
		return
	}
	$loginBody = @{
		username = $Username
		password = $Password
	}

	$loginResponse = Invoke-ApiRequest -Method "POST" -Uri $loginUri -Body $loginBody -Config $Config -SkipAuth -AsJson
	if (-not $loginResponse -or [string]::IsNullOrWhiteSpace([string]$loginResponse.token)) {
		throw "Login succeeded without token in response"
	}

	$Config.SessionToken = [string]$loginResponse.token
	Write-Log -Message "Authenticated with Barracuda WAF" -Level "SUCCESS"
}

function Bind-CertificateToService {
	param(
		[Parameter(Mandatory = $true)][string]$VirtualServiceName,
		[Parameter(Mandatory = $true)][string]$CertificateName,
		[Parameter(Mandatory = $true)][hashtable]$Config,
		[Parameter(Mandatory = $true)][string]$KeyType
	)

	$escapedServiceName = [System.Uri]::EscapeDataString($VirtualServiceName)
	$bindUri = "$($Config.BaseUrl)/restapi/v3.2/services/$escapedServiceName/ssl-security"
	if ($KeyType -eq "rsa") {
		$bindBody = @{
			certificate = $CertificateName
		}
	} elseif ($KeyType -eq "ecdsa") {
		$bindBody = @{
			"ecdsa-certificate" = $CertificateName
		}
	} else {
		throw "Unsupported key type for binding: $KeyType"
	}
	
	$bindResponse = Invoke-ApiRequest -Method "PUT" -Uri $bindUri -Body $bindBody -Config $Config -AsJson

	if ($bindResponse -and $bindResponse.PSObject.Properties.Name -contains "token") {
		$Config.SessionToken = [string]$bindResponse.token
	}

	Write-Log -Message "Certificate bound to virtual service '$VirtualServiceName'" -Level "SUCCESS"
}

function Disconnect-BarracudaWaf {
	param([Parameter(Mandatory = $true)][hashtable]$Config)

	if (-not $Config -or [string]::IsNullOrWhiteSpace($Config.SessionToken)) {
		return
	}

	$logoutUri = "$($Config.BaseUrl)/restapi/v3.2/logout"
	Invoke-ApiRequest -Method "DELETE" -Uri $logoutUri -Config $Config | Out-Null
	Write-Log -Message "Logged out from Barracuda WAF" -Level "INFO"
}

function Main {
	$config = $null
	$didLogin = $false

	try {
		Write-Log -Message "Barracuda WAF certificate upload and service bind automation script started. Version: $SCRIPT_VERSION" -Level "INFO"

		if ($LEGAL_NOTICE_ACCEPT -ne "true") {
			throw "Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT='true'."
		}

		$jsonObject = Get-PostScriptDataObject
		$parsedArgs = Resolve-ArgumentsFromJson -JsonObject $jsonObject
        Print-ParsedArguments -ParsedArgs $parsedArgs
		$certPaths = Resolve-BarracudaPkcs12Inputs -JsonObject $jsonObject
		Test-BarracudaWafPrerequisites -CertPaths $certPaths -InputArgs $parsedArgs

		$baseUrl = Get-BarracudaApiBaseUrl -BaseUrl $parsedArgs.BaseUrl

		$certName = New-BarracudaCertificateName -CertPaths $certPaths -RequestedName $parsedArgs.CertificateName
		Write-Log -Message "Resolved certificate name: $certName" -Level "INFO"

		$config = @{
			BaseUrl = $baseUrl
			SessionToken = ""
			InputSource = $parsedArgs.InputSource
		}

		Connect-BarracudaWaf -Config $config -Username $parsedArgs.Username -Password $parsedArgs.Password
		$didLogin = $true

		$keyType = Get-CertificateKeyType -CertificatePath $CertPaths.SignedCertificatePath -CertificatePassword $CertPaths.Password

        $uploadResponse = Import-CertificateToBarracuda -CertificateName $certName -CertPaths $certPaths -Config $config -KeyType $keyType

        if ($uploadResponse -and $uploadResponse.PSObject.Properties.Name -contains "token") {
            $config.SessionToken = [string]$uploadResponse.token
        }

		Bind-CertificateToService -VirtualServiceName $parsedArgs.VirtualServiceName -CertificateName $certName -Config $config -KeyType $keyType

		Write-Log -Message " Barracuda WAF certificate upload and service bind automation script completed. Version: $SCRIPT_VERSION" -Level "SUCCESS"
	} catch {
		Write-ExceptionDetails -ErrorRecord $_ -Context "Script execution failed" -Level "ERROR"
		throw
	} finally {
		try {
			if ($didLogin) {
				Disconnect-BarracudaWaf -Config $config
				Write-Log -Message "Barracuda WAF certificate upload and service bind automation script completed. Version: $SCRIPT_VERSION" -Level "INFO"
			}
		} catch {
			Write-ExceptionDetails -ErrorRecord $_ -Context "Logout failed" -Level "WARN"
		}
	}
}

try {
	Main
	exit 0
} catch {
	exit 1
}
