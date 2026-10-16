<#
.SYNOPSIS
    DigiCert TLM AWR - Exchange Server Hybrid Support Script

.DESCRIPTION
    This script automates the post-delivery configuration and management of an Exchange Server hybrid environment, 
	including certificate handling and service management.

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
[CmdletBinding()]
param(
	[ValidateSet("Single", "HA")]
	[string]$NodeMode = "HA",
	[ValidateNotNullOrEmpty()]
	[string]$PrimaryServer = "LV-EXCH1",
	[string]$SecondaryServer = "BV-EXCH1",
	[ValidateSet("true", "false")]
	[string]$HybridEnabled = "true",
	[ValidateSet("true", "false", "report")]
	[string]$RemoveOldCertificate = "true",
	[string]$ExchangeServices = "POP,IMAP,IIS,SMTP",
	[ValidateSet("DEBUG", "INFO")]
	[string]$LogLevel = "DEBUG"
)
$ErrorActionPreference = "Stop"
$CommandLineParameters = @($PSBoundParameters.Keys)
$ScriptVersion = "9.13"
$LEGAL_NOTICE_ACCEPT = "false"
$LogFilePath         = "C:\Program Files\DigiCert\TLM Agent\log\ms-exchange-server-hybrid-support.log"
$LogMaxSizeMB        = 20
$LogRotatedKeepCount = 5
$LocalServerName = $env:COMPUTERNAME
$SupportedExchangeServices = @("POP", "IMAP", "IIS", "SMTP")
$ExchangeServiceAliases = @{ "POP3" = "POP"; "IMAP4" = "IMAP" }
$LocalServices  = ""
$RemoteServices = ""
$EnforceNameContinuity = $true
$HybridSendConnectorOverride = @()
$HybridReceiveConnectorOverride = @()
$UpdateHybridConfigurationObject = $true
$BackEndSiteName = "Exchange Back End"
$BackEndPort     = 444
$FrontEndPort    = 443
$IisStopTimeoutSeconds  = 120
$IisStartTimeoutSeconds = 60
$TransportStopTimeoutSeconds  = 30
$TransportStartTimeoutSeconds = 30
$OptionalServiceStopTimeoutSeconds  = 20
$OptionalServiceStartTimeoutSeconds = 20
$RestartFrontEndTransport = $true
$ChildProcessTimeoutSeconds = 600
$KbTransportStopTimeoutSeconds  = 60
$KbTransportStartTimeoutSeconds = 60
$TlmTimeLimitSeconds   = 300
$KbMinimumSeconds      = 100
$KbReserveSeconds      = 45
$FinalFullRevalidation = $false
$ImportKeyExportable = $true
$script:LogLevels        = @{ DEBUG = 10; INFO = 20; WARN = 30; ERROR = 40; CRITICAL = 50 }
$script:MinLogLevel      = $script:LogLevels[$LogLevel]
$script:LogEncoding      = New-Object System.Text.UTF8Encoding($false)
$script:InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
$script:BannerLine       = "=" * 42
$script:RunId        = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), ([Guid]::NewGuid().ToString("N").Substring(0, 6))
$script:RunStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:SectionRecords           = New-Object System.Collections.ArrayList
$script:CurrentSection           = $null
$script:FirstFailure             = $null
$script:LogWriteFailures         = 0
$script:SummaryThumbprint        = ""
$script:SummaryCertName          = ""
$script:ManagedServersForSummary = @()
$script:OldCertificateResults    = New-Object System.Collections.ArrayList
function Protect-LogText {
	param([string]$Text)
	if ([string]::IsNullOrEmpty($Text)) { return $Text }
	$t = [regex]::Replace(
		$Text,
		'(?i)("?(?:password|pfxpassword|pfxpass|pwd|secret)"?\s*[:=]\s*)("[^"]*"|''[^'']*''|[^\s,;}]+)',
		'$1***'
	)
	$t = [regex]::Replace(
		$t,
		'(?i)(DC1_POST_SCRIPT_DATA\s*[:=]\s*)[A-Za-z0-9+/]{16,}={0,2}',
		'$1***'
	)
	return $t
}
function Add-LogFileLine {
	param([string]$Path, [string]$Line)
	if ([string]::IsNullOrWhiteSpace($Path)) { return }
	for ($attempt = 1; $attempt -le 5; $attempt++) {
		try {
			[System.IO.File]::AppendAllText($Path, $Line + [Environment]::NewLine, $script:LogEncoding)
			return
		}
		catch {
			if ($attempt -eq 5) { $script:LogWriteFailures++ }
			else { Start-Sleep -Milliseconds (50 * $attempt) }
		}
	}
}
function Write-LogLine {
	param([string]$Text = "")
	$line = "[{0}] {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss", $script:InvariantCulture), (Protect-LogText $Text)
	Add-LogFileLine -Path $LogFilePath -Line $line
	Write-Host $line
}
function Write-Log {
	param(
		[ValidateSet("DEBUG", "INFO", "WARN", "ERROR", "CRITICAL")]
		[string]$Level = "INFO",
		[string]$Message = ""
	)
	$levelValue = $script:LogLevels[$Level]
	$section    = $script:CurrentSection
	if ($null -ne $section -and $section.Status -eq "RUNNING") {
		if ($Level -eq "WARN") { $section.Warnings++ }
		if ($levelValue -ge 40) { $section.Errors++ }
	}
	$prefix = ""
	if     ($Level -eq "WARN")     { $prefix = "WARNING: " }
	elseif ($Level -eq "ERROR")    { $prefix = "ERROR: " }
	elseif ($Level -eq "CRITICAL") { $prefix = "CRITICAL: " }
	$text = $prefix + ($Message -replace '\s*\r?\n\s*', ' ')
	if ($levelValue -ge 40 -and $null -eq $script:FirstFailure) {
		$sectionName = if ($null -ne $section) { $section.Name } else { "Initialization" }
		$script:FirstFailure = "[$sectionName] $(Protect-LogText $text)"
	}
	if ($levelValue -lt $script:MinLogLevel) { return }
	Write-LogLine -Text $text
}
function Log-Debug    { param([string]$Message) Write-Log -Level "DEBUG"    -Message $Message }
function Log-Info     { param([string]$Message) Write-Log -Level "INFO"     -Message $Message }
function Log-Warn     { param([string]$Message) Write-Log -Level "WARN"     -Message $Message }
function Log-Error    { param([string]$Message) Write-Log -Level "ERROR"    -Message $Message }
function Log-Critical { param([string]$Message) Write-Log -Level "CRITICAL" -Message $Message }
function Log-Success  { param([string]$Message) Write-Log -Level "INFO"     -Message "SUCCESS: $Message" }
function Write-Banner { Write-LogLine -Text $script:BannerLine }
function Write-LogBlock {
	param(
		[string]$Level = "DEBUG",
		[string]$Title,
		[string]$Text,
		[int]$MaxLines = 200
	)
	if ($script:LogLevels[$Level] -lt $script:MinLogLevel) { return }
	if ([string]::IsNullOrWhiteSpace($Text)) {
		Write-Log -Level $Level -Message "${Title}: (empty)"
		return
	}
	$lines = @($Text -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
	Write-Log -Level $Level -Message "${Title} ($($lines.Count) lines):"
	$count = 0
	foreach ($l in $lines) {
		$count++
		if ($count -gt $MaxLines) {
			Write-LogLine -Text "  ... truncated after $MaxLines lines"
			break
		}
		Write-LogLine -Text "  $($l.TrimEnd())"
	}
}
function Write-LogException {
	param(
		$ErrorRecord,
		[string]$Context = "Exception detail",
		[string]$Level = "DEBUG"
	)
	try {
		if ($null -eq $ErrorRecord) { return }
		$ex = $ErrorRecord
		if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
			$ex = $ErrorRecord.Exception
		}
		Write-Log -Level $Level -Message "$Context : [$($ex.GetType().FullName)] $($ex.Message)"
		try {
			if ($ex.HResult) { Log-Debug ("  HResult=0x{0:X8}" -f $ex.HResult) }
		} catch { }
		if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
			if ($ErrorRecord.FullyQualifiedErrorId) { Log-Debug "  FullyQualifiedErrorId=$($ErrorRecord.FullyQualifiedErrorId)" }
			if ($ErrorRecord.CategoryInfo)          { Log-Debug "  Category=$($ErrorRecord.CategoryInfo.ToString())" }
			$inv = $ErrorRecord.InvocationInfo
			if ($inv -and $inv.ScriptLineNumber -gt 0) {
				Log-Debug "  At line $($inv.ScriptLineNumber) char $($inv.OffsetInLine): $(([string]$inv.Line).Trim())"
			}
			if ($ErrorRecord.ScriptStackTrace) {
				Write-LogBlock -Level "DEBUG" -Title "  ScriptStackTrace" -Text $ErrorRecord.ScriptStackTrace -MaxLines 30
			}
		}
		if ($ex -is [System.Management.Automation.Remoting.PSRemotingTransportException]) {
			Log-Debug "  WinRM ErrorCode=$($ex.ErrorCode) TransportMessage=$($ex.TransportMessage)"
		}
		$inner = $ex.InnerException
		$depth = 1
		while ($null -ne $inner -and $depth -le 5) {
			Log-Debug "  Inner[$depth]: [$($inner.GetType().FullName)] $($inner.Message)"
			$inner = $inner.InnerException
			$depth++
		}
	}
	catch {
		Write-Host "Logging failure while recording exception detail: $($_.Exception.Message)"
	}
}
function Start-Section {
	param(
		[string]$Id,
		[string]$Name,
		[switch]$Silent
	)
	if ($null -ne $script:CurrentSection -and $script:CurrentSection.Status -eq "RUNNING") {
		Complete-Section -Status "PASS"
	}
	$record = [PSCustomObject]@{
		Id         = $Id
		Name       = $Name
		Silent     = [bool]$Silent
		Status     = "RUNNING"
		DurationMs = 0
		Warnings   = 0
		Errors     = 0
		Detail     = ""
		Stopwatch  = [System.Diagnostics.Stopwatch]::StartNew()
	}
	[void]$script:SectionRecords.Add($record)
	$script:CurrentSection = $record
	if (-not $Silent) {
		Write-Banner
		Log-Info "Starting $Name..."
		Write-Banner
	}
}
function Complete-Section {
	param(
		[ValidateSet("PASS", "FAIL", "SKIPPED")]
		[string]$Status = "PASS",
		[string]$Detail = ""
	)
	$record = $script:CurrentSection
	if ($null -eq $record -or $record.Status -ne "RUNNING") { return }
	$record.Stopwatch.Stop()
	$record.DurationMs = [int]$record.Stopwatch.ElapsedMilliseconds
	$record.Detail     = $Detail
	$final = $Status
	if ($final -eq "PASS" -and $record.Warnings -gt 0) { $final = "PASS_WITH_WARNINGS" }
	$record.Status = $final
	$detailText = if ($Detail) { " ($Detail)" } else { "" }
	switch ($final) {
		"PASS"               { if (-not $record.Silent) { Log-Info "$($record.Name) section completed" } }
		"PASS_WITH_WARNINGS" { if (-not $record.Silent) { Log-Info "$($record.Name) section completed with $($record.Warnings) warning(s)" } }
		"SKIPPED"            { if (-not $record.Silent) { Log-Info "$($record.Name) section skipped$detailText" } }
		"FAIL"               { Log-Error "$($record.Name) section FAILED$detailText" }
	}
	if (-not $record.Silent) {
		Log-Debug "$($record.Name) section duration: $($record.DurationMs) ms"
	}
}
function Write-RunSummary {
	param([int]$ExitCode)
	$script:CurrentSection = $null
	$overall = if ($ExitCode -eq 0) { "SUCCESS" } else { "FAILED" }
	Write-Banner
	Log-Info "DEPLOYMENT SUMMARY:"
	Write-Banner
	Log-Info "Result: $overall (exit code $ExitCode)"
	Log-Info "Run ID: $($script:RunId)"
	Log-Info "Script version: $ScriptVersion"
	Log-Info "Node mode: $NodeMode"
	Log-Info "Managed servers: $(if (@($script:ManagedServersForSummary).Count -gt 0) { $script:ManagedServersForSummary -join ',' } else { '(not resolved)' })"
	Log-Info "Exchange services: $ExchangeServices"
	Log-Info "Hybrid enabled: $HybridEnabled$(if ($HybridDisabledReason -and $HybridEnabled -eq 'true') { " (not applied: $HybridDisabledReason)" })"
	Log-Info "Remove old certificate: $RemoveOldCertificate"
	Log-Info "New certificate name: $(if ($script:SummaryCertName) { $script:SummaryCertName } else { '(not determined)' })"
	Log-Info "New certificate thumbprint: $(if ($script:SummaryThumbprint) { $script:SummaryThumbprint } else { '(not determined)' })"
	Log-Info ""
	Log-Info "Sections:"
	foreach ($r in $script:SectionRecords) {
		Log-Info ([string]::Format(
			$script:InvariantCulture,
			"  {0,-4} {1,-52} {2,-18} {3,9} ms  warnings={4} errors={5}",
			$r.Id, $r.Name, $r.Status, $r.DurationMs, $r.Warnings, $r.Errors
		))
	}
	if ($script:OldCertificateResults.Count -gt 0) {
		Log-Info ""
		Log-Info "Old certificate removal:"
		foreach ($o in $script:OldCertificateResults) {
			$reasonText = if ($o.Reason) { " - $($o.Reason)" } else { "" }
			Log-Info "  $($o.Server): $($o.Outcome) $($o.Thumbprint)$reasonText"
		}
	}
	Log-Info ""
	Log-Info "First failure: $(if ($script:FirstFailure) { $script:FirstFailure } else { 'none' })"
	Log-Info "Total elapsed: $([Math]::Round($script:RunStopwatch.Elapsed.TotalSeconds, 2)) seconds"
	Log-Info "LOGFILE: $LogFilePath"
	if ($script:LogWriteFailures -gt 0) {
		Write-Host "WARNING: $($script:LogWriteFailures) log line(s) could not be written to disk."
	}
	Write-Banner
	if ($ExitCode -eq 0) {
		Log-Info "Script execution completed successfully"
	}
	else {
		Log-Error "Script execution failed (exit code $ExitCode)"
	}
	Write-Banner
}
function Stop-Script {
	param(
		[int]$Code,
		[string]$Reason = ""
	)
	if ($null -ne $script:CurrentSection -and $script:CurrentSection.Status -eq "RUNNING") {
		if ($Code -eq 0) { Complete-Section -Status "PASS" }
		else             { Complete-Section -Status "FAIL" -Detail $Reason }
	}
	Write-RunSummary -ExitCode $Code
	exit $Code
}
function Initialize-Logging {
	try {
		$logDirectory = Split-Path -Path $LogFilePath -Parent
		if (-not (Test-Path -LiteralPath $logDirectory)) {
			New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
		}
		if (Test-Path -LiteralPath $LogFilePath) {
			if ((Get-Item -LiteralPath $LogFilePath).Length -ge ($LogMaxSizeMB * 1MB)) {
				$rotatedPath = "$LogFilePath.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
				Move-Item -LiteralPath $LogFilePath -Destination $rotatedPath -Force
			}
		}
		$logLeaf = Split-Path -Path $LogFilePath -Leaf
		Get-ChildItem -LiteralPath $logDirectory -Filter "$logLeaf.*.bak" -ErrorAction SilentlyContinue |
			Sort-Object LastWriteTime -Descending |
			Select-Object -Skip $LogRotatedKeepCount |
			Remove-Item -Force -ErrorAction SilentlyContinue
	}
	catch {
		Write-Host "WARNING: Logging initialization issue: $($_.Exception.Message)"
	}
}
function Invoke-NativeCapture {
	param(
		[string]$FilePath,
		[string[]]$Arguments = @()
	)
	$previousPreference = $ErrorActionPreference
	$exitCode = $null
	$lines = @()
	try {
		$ErrorActionPreference = "Continue"
		$lines = @(
			& $FilePath @Arguments 2>&1 | ForEach-Object {
				if ($_ -is [System.Management.Automation.ErrorRecord]) { "[stderr] $($_.Exception.Message)" }
				else { [string]$_ }
			}
		)
		$exitCode = $LASTEXITCODE
	}
	finally {
		$ErrorActionPreference = $previousPreference
	}
	return [PSCustomObject]@{
		ExitCode = $exitCode
		Output   = ($lines -join [Environment]::NewLine)
	}
}
function Enable-ModernTlsForProbes {
	try {
		$before = [System.Net.ServicePointManager]::SecurityProtocol
		$tls12  = [System.Net.SecurityProtocolType]::Tls12
		if ([int]$before -eq 0) {
			Log-Debug "ServicePointManager.SecurityProtocol is SystemDefault; OS-negotiated TLS retained."
		}
		elseif (($before -band $tls12) -ne $tls12) {
			[System.Net.ServicePointManager]::SecurityProtocol = $before -bor $tls12
		}
		Log-Debug "ServicePointManager.SecurityProtocol: before=[$before] after=[$([System.Net.ServicePointManager]::SecurityProtocol)]"
	}
	catch {
		Log-Warn "Could not enable TLS 1.2 for HTTPS probes. OWA/ECP checks may fail on TLS 1.2-only servers. $($_.Exception.Message)"
	}
}
function Decode-Base64 {
	param([string]$base64String)
	$bytes = [System.Convert]::FromBase64String($base64String)
	return [System.Text.Encoding]::UTF8.GetString($bytes)
}
function Open-PfxCollection {
	param([string]$Path, [string]$Password)
	$collection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
	$collection.Import(
		$Path,
		$Password,
		[System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet
	)
	return ,$collection
}
function Close-PfxCollection {
	param($Collection)
	if ($null -eq $Collection) { return }
	foreach ($c in $Collection) {
		try { $c.Reset() } catch { }
	}
}
function Test-IsCertificateAuthority {
	param($Certificate)
	$bc = $Certificate.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.19" } | Select-Object -First 1
	if (-not $bc) { return $false }
	try {
		$typed = New-Object System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension($bc, $bc.Critical)
		return [bool]$typed.CertificateAuthority
	}
	catch {
		return ($bc.Format($false) -match '(?i)(Subject Type=CA|CA:TRUE)')
	}
}
function Select-PfxLeafCertificate {
	param($Collection)
	$withKey = @($Collection | Where-Object { $_.HasPrivateKey })
	if ($withKey.Count -eq 0) { return $null }
	$endEntity = @($withKey | Where-Object { -not (Test-IsCertificateAuthority $_) })
	if ($endEntity.Count -gt 0) { return $endEntity[0] }
	return $withKey[0]
}
function Test-DnsNameCovered {
	param([string]$Name, [string[]]$CertificateNames)
	$n = $Name.ToLowerInvariant()
	foreach ($c in $CertificateNames) {
		$cn = $c.ToLowerInvariant()
		if ($cn -eq $n) { return $true }
		if ($cn.StartsWith("*.") -and -not $n.StartsWith("*.")) {
			$suffix = $cn.Substring(1)
			if ($n.EndsWith($suffix) -and ($n.Substring(0, $n.Length - $suffix.Length)) -notmatch '\.' -and $n.Length -gt $suffix.Length) {
				return $true
			}
		}
	}
	return $false
}
function Get-CertificateKeyDescription {
	param($Certificate)
	if ($null -eq $Certificate) { return "unknown" }
	$algorithm = [string]$Certificate.PublicKey.Oid.FriendlyName
	$size = $null
	try { $size = $Certificate.PublicKey.Key.KeySize } catch { }
	if (-not $size) {
		try { $size = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($Certificate).KeySize } catch { }
	}
	$sizeText = if ($size) { " $size-bit" } else { "" }
	$keyText  = if ($Certificate.HasPrivateKey) { "private key present" } else { "NO private key" }
	return "$algorithm$sizeText ($keyText)"
}
function ConvertTo-NormalizedTlsName {
	param([string]$Value)
	if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
	return (($Value -replace '\s*,\s*', ',') -replace '\s*<\s*([IS])\s*>\s*', '<$1>').Trim().ToUpperInvariant()
}
function Get-TlsNameSubjectCN {
	param([string]$Value)
	if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
	$subjectPart = $Value
	$idx = $Value.IndexOf("<S>", [System.StringComparison]::OrdinalIgnoreCase)
	if ($idx -ge 0) { $subjectPart = $Value.Substring($idx + 3) }
	$m = [regex]::Match($subjectPart, '(?i)(?:^|,\s*)CN=([^,]+)')
	if ($m.Success) { return $m.Groups[1].Value.Trim() }
	return ""
}
function Resolve-ExchangeServiceList {
	param([string]$Value)
	$result = [PSCustomObject]@{ Valid = $false; Services = @(); Text = ""; Error = $null }
	$tokens = @($Value -split '[,;+|/\s]+' | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ })
	if ($tokens.Count -eq 0) {
		$result.Error = "no services specified"
		return $result
	}
	$selected = @()
	$invalid  = @()
	foreach ($token in $tokens) {
		$name = $token
		if ($name -eq "ALL") { $selected += $SupportedExchangeServices; continue }
		if ($ExchangeServiceAliases.ContainsKey($name)) { $name = $ExchangeServiceAliases[$name] }
		if ($SupportedExchangeServices -contains $name) { $selected += $name } else { $invalid += $token }
	}
	if ($invalid.Count -gt 0) {
		$result.Error = "unsupported service(s): $($invalid -join ', '). Allowed: $($SupportedExchangeServices -join ', '), ALL"
		return $result
	}
	$ordered = @($SupportedExchangeServices | Where-Object { $selected -contains $_ })
	$result.Valid    = $true
	$result.Services = $ordered
	$result.Text     = $ordered -join ","
	return $result
}
function Select-PreviousServiceCertificate {
	param(
		$SnapshotData,
		[string]$Services,
		[string]$NewThumbprint,
		[string]$FallbackThumbprint,
		[string]$ServerName,
		[string]$Purpose = "rollback source"
	)
	$wanted     = @($Services -split "," | Where-Object { $_ })
	$candidates = @()
	foreach ($c in @($SnapshotData)) {
		$t = ([string]$c.Thumbprint).Trim().ToUpperInvariant()
		if (-not $t -or $t -eq $NewThumbprint.ToUpperInvariant()) { continue }
		$assigned   = @(([string]$c.Services) -split '[,\s]+' | Where-Object { $_ -and $_ -ne "None" } | ForEach-Object { $_.ToUpperInvariant() })
		$matchCount = @($wanted | Where-Object { $assigned -contains $_ }).Count
		if ($matchCount -eq 0) { continue }
		$ticks = 0
		try { $ticks = [long]$c.NotAfterTicks } catch { }
		$candidates += [PSCustomObject]@{
			Thumbprint    = $t
			Matches       = $matchCount
			SelfSigned    = [bool]$c.IsSelfSigned
			NotAfterTicks = $ticks
			Subject       = [string]$c.Subject
			Services      = [string]$c.Services
		}
	}
	foreach ($cand in $candidates) {
		Log-Debug "  Rollback candidate: $($cand.Thumbprint) Services=$($cand.Services) SelfSigned=$($cand.SelfSigned) Matches=$($cand.Matches) Subject=$($cand.Subject)"
	}
	$best = $candidates |
		Sort-Object @{ Expression = { $_.SelfSigned }; Descending = $false },
					@{ Expression = { $_.Matches }; Descending = $true },
					@{ Expression = { $_.NotAfterTicks }; Descending = $true } |
		Select-Object -First 1
	if ($best) {
		Log-Info "Previous certificate for services $Services on ${ServerName}: $($best.Thumbprint) (assigned: $($best.Services); self-signed: $($best.SelfSigned)) - $Purpose"
		if ($best.Matches -lt $wanted.Count) {
			Log-Warn "Rollback source $($best.Thumbprint) currently carries $($best.Matches) of $($wanted.Count) selected services; a rollback re-enables it for all of $Services."
		}
		return $best.Thumbprint
	}
	if ($FallbackThumbprint) {
		Log-Warn "No existing certificate on $ServerName carries any of $Services. Using the Front End ($FrontEndPort) certificate $FallbackThumbprint as the $Purpose."
		return $FallbackThumbprint.ToUpperInvariant()
	}
	return $null
}
function Test-CertificateNameContinuity {
	param(
		[string]$ServerName,
		$SnapshotData,
		[string]$FrontEndThumbprint,
		[string[]]$NewNames,
		[string]$NewThumbprint
	)
	$result = [PSCustomObject]@{ Server = $ServerName; Ok = $true; Skipped = $false; CurrentThumbprint = ""; Missing = @(); Reason = "" }
	$current = $null
	if ($ManagesIIS) { $current = $FrontEndThumbprint }
	else {
		$current = Select-PreviousServiceCertificate -SnapshotData $SnapshotData -Services $ExchangeServices `
			-NewThumbprint $NewThumbprint -FallbackThumbprint $FrontEndThumbprint -ServerName $ServerName -Purpose "current certificate"
	}
	if (-not $current) {
		$result.Skipped = $true
		$result.Reason  = "no current certificate identified"
		Log-Warn "Name continuity not verified on ${ServerName}: $($result.Reason)."
		return $result
	}
	$current = $current.ToUpperInvariant()
	$result.CurrentThumbprint = $current
	if ($current -eq $NewThumbprint.ToUpperInvariant()) {
		$result.Skipped = $true
		$result.Reason  = "server already uses the new certificate"
		Log-Info "Name continuity on ${ServerName}: $($result.Reason)."
		return $result
	}
	$currentCert = @($SnapshotData) | Where-Object { ([string]$_.Thumbprint).ToUpperInvariant() -eq $current } | Select-Object -First 1
	if (-not $currentCert) {
		$result.Skipped = $true
		$result.Reason  = "current certificate $current not found in the Exchange certificate list"
		Log-Warn "Name continuity not verified on ${ServerName}: $($result.Reason)."
		return $result
	}
	if ([bool]$currentCert.IsSelfSigned) {
		$result.Skipped = $true
		$result.Reason  = "current certificate is self-signed (no public names to preserve)"
		Log-Info "Name continuity on ${ServerName}: $($result.Reason)."
		return $result
	}
	$rawDomains = $currentCert.CertificateDomains
	if ($null -ne $rawDomains -and -not ($rawDomains -is [string]) -and $rawDomains.PSObject.Properties.Name -contains "value") { $rawDomains = $rawDomains.value }
	$currentNames = @(@($rawDomains) | ForEach-Object { ([string]$_) -split ',' } | ForEach-Object { $_.Trim().TrimEnd('.').ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
	$badNames = @($currentNames | Where-Object { $_ -notmatch '^(\*\.)?[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?(\.[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?)*$' })
	if ($badNames.Count -gt 0) {
		$result.Skipped = $true
		$result.Reason  = "current certificate names could not be parsed ($($badNames -join ', '))"
		Log-Warn "Name continuity not verified on ${ServerName}: $($result.Reason)."
		return $result
	}
	if ($currentNames.Count -eq 0) {
		$result.Skipped = $true
		$result.Reason  = "current certificate reports no DNS names"
		Log-Warn "Name continuity not verified on ${ServerName}: $($result.Reason)."
		return $result
	}
	Log-Info "Name continuity via: current certificate $current on $ServerName ($($currentCert.Subject))"
	Log-Info "  Current names: $($currentNames -join ', ')"
	Log-Info "  New names: $($NewNames -join ', ')"
	$result.Missing = @($currentNames | Where-Object { -not (Test-DnsNameCovered -Name $_ -CertificateNames $NewNames) })
	if ($result.Missing.Count -gt 0) {
		$result.Ok     = $false
		$result.Reason = "new certificate is missing: $($result.Missing -join ', ')"
		return $result
	}
	Log-Info "Name continuity response indicates success on ${ServerName}: every current name is on the new certificate"
	return $result
}
function Write-LogEnvironment {
	Log-Debug "64-bit OS / process: $([Environment]::Is64BitOperatingSystem) / $([Environment]::Is64BitProcess)"
	try {
		$identityName = "$([Environment]::UserDomainName)\$([Environment]::UserName)"
		Log-Info "Execution identity: $identityName"
	}
	catch {
		Log-Debug "Identity unavailable: $($_.Exception.Message)"
	}
	if (-not [Environment]::Is64BitProcess) {
		Log-Warn "32-bit PowerShell process. The Exchange child is launched through Sysnative 64-bit powershell.exe."
	}
	$culture = [System.Globalization.CultureInfo]::CurrentUICulture.Name
	if ($culture -and $culture -notlike "en*") {
		Log-Warn "UI culture is $culture. netsh output parsing expects English labels ('Certificate Hash', 'IP:port')."
	}
}
$script:ExchangeChildScript = @'
param(
	[string]$Thumbprint = "",
	[string]$Services = "",
	[string]$TargetServer = "",
	[ValidateSet("Snapshot","Topology","HybridDiscover","HybridSnapshot","HybridUpdate","HybridRestore","Enable","Validate","HealthCheck","Rollback","RemovalCheck","RemoveCertificate","TaggedConnectors","SendConnectorTls","KbRemove","NameMatch")]
	[string]$Mode,
	[string]$PreviousThumbprint = "",
	[string]$HybridSendConnector = "",
	[string]$HybridReceiveConnectors = "",
	[string]$HybridRestoreStateBase64 = "",
	[string]$ManagedServers = "",
	[int]$RetrySeconds = 60,
	[string]$UpdateHybridConfiguration = "true",
	[string]$ResultPath,
	[string]$LogFilePath,
	[ValidateSet("DEBUG","INFO")]
	[string]$LogLevel = "DEBUG"
)
$childTimer    = [System.Diagnostics.Stopwatch]::StartNew()
$childLevels   = @{ DEBUG = 10; INFO = 20; WARN = 30; ERROR = 40; CRITICAL = 50 }
$childEncoding = New-Object System.Text.UTF8Encoding($false)
$childCulture  = [System.Globalization.CultureInfo]::InvariantCulture
$srv           = if ($TargetServer -ne "") { $TargetServer } else { $env:COMPUTERNAME }
$updateHc      = ($UpdateHybridConfiguration -eq "true")
function Log-Child {
	param([string]$m, [string]$Level = "INFO")
	if ($childLevels[$Level] -lt $childLevels[$LogLevel]) { return }
	$prefix = ""
	if ($Level -eq "WARN") { $prefix = "WARNING: " } elseif ($Level -eq "ERROR") { $prefix = "ERROR: " } elseif ($Level -eq "CRITICAL") { $prefix = "CRITICAL: " }
	$line = "[" + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss", $childCulture) + "] " + $prefix + $m
	if ([string]::IsNullOrWhiteSpace($LogFilePath)) { return }
	for ($i = 1; $i -le 5; $i++) {
		try { [System.IO.File]::AppendAllText($LogFilePath, $line + [Environment]::NewLine, $childEncoding); break }
		catch { Start-Sleep -Milliseconds (50 * $i) }
	}
}
function Log-ChildException {
	param($ErrorRecord, [string]$Context)
	$ex = $ErrorRecord.Exception
	Log-Child "$Context : [$($ex.GetType().FullName)] $($ex.Message)" "ERROR"
	try { Log-Child ("  HResult=0x{0:X8}" -f $ex.HResult) "DEBUG" } catch { }
	if ($ErrorRecord.FullyQualifiedErrorId) { Log-Child "  FullyQualifiedErrorId=$($ErrorRecord.FullyQualifiedErrorId)" "DEBUG" }
	if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.ScriptLineNumber -gt 0) {
		Log-Child "  At child line $($ErrorRecord.InvocationInfo.ScriptLineNumber): $(([string]$ErrorRecord.InvocationInfo.Line).Trim())" "DEBUG"
	}
	if ($ErrorRecord.ScriptStackTrace) {
		foreach ($st in ($ErrorRecord.ScriptStackTrace -split "\r?\n")) { Log-Child "  stack> $st" "DEBUG" }
	}
	$inner = $ex.InnerException; $depth = 1
	while ($null -ne $inner -and $depth -le 5) {
		Log-Child "  Inner[$depth]: [$($inner.GetType().FullName)] $($inner.Message)" "DEBUG"
		$inner = $inner.InnerException; $depth++
	}
}
function Log-ChildCert {
	param($c, [string]$Label = "Certificate")
	if ($null -eq $c) { Log-Child "${Label}: (null)" "DEBUG"; return }
	Log-Child ("{0}: Thumbprint={1} Services={2} Status={3} SelfSigned={4} HasPrivateKey={5} NotBefore={6} NotAfter={7} Subject={8} Issuer={9} Domains={10}" -f $Label, $c.Thumbprint, $c.Services, $c.Status, $c.IsSelfSigned, $c.HasPrivateKey, $c.NotBefore, $c.NotAfter, $c.Subject, $c.Issuer, (@($c.CertificateDomains) -join ",")) "DEBUG"
}
function ConvertTo-NormalizedTlsName {
	param([string]$Value)
	if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
	return (($Value -replace '\s*,\s*', ',') -replace '\s*<\s*([IS])\s*>\s*', '<$1>').Trim().ToUpperInvariant()
}
function Find-ExchangeCertificate {
	param([string]$Thumb, [hashtable]$ServerParameters)
	$t = $Thumb.Trim().ToUpperInvariant()
	return (@(Get-ExchangeCertificate @ServerParameters -ErrorAction Stop) |
		Where-Object { $_.Thumbprint -and $_.Thumbprint.ToUpperInvariant() -eq $t } |
		Select-Object -First 1)
}
function Get-HybridConfigurationState {
	try {
		Log-Child "Get-HybridConfiguration via: Exchange Management Shell" "DEBUG"
		$hc = Get-HybridConfiguration -ErrorAction Stop
		if ($null -eq $hc) {
			Log-Child "Get-HybridConfiguration response: no Hybrid Configuration object exists" "DEBUG"
			return @{ State = "NotPresent"; TlsCertificateName = ""; ReceivingTransportServers = @(); SendingTransportServers = @(); Error = $null }
		}
		$recv = @($hc.ReceivingTransportServers | ForEach-Object { ([string]$_.Name).ToUpperInvariant() })
		$send = @($hc.SendingTransportServers | ForEach-Object { ([string]$_.Name).ToUpperInvariant() })
		Log-Child "Get-HybridConfiguration response: TlsCertificateName=$([string]$hc.TlsCertificateName) ReceivingTransportServers=$($recv -join ",") SendingTransportServers=$($send -join ",") OnPremisesSmartHost=$($hc.OnPremisesSmartHost) Domains=$(@($hc.Domains) -join ",") Features=$(@($hc.Features) -join ",")" "DEBUG"
		return @{ State = "Present"; TlsCertificateName = [string]$hc.TlsCertificateName; ReceivingTransportServers = $recv; SendingTransportServers = $send; Error = $null }
	}
	catch {
		Log-Child "Get-HybridConfiguration could not be read: $($_.Exception.Message)" "WARN"
		return @{ State = "Unreadable"; TlsCertificateName = ""; ReceivingTransportServers = @(); SendingTransportServers = @(); Error = $_.Exception.Message }
	}
}
$result = [ordered]@{ Success = $false; Mode = $Mode; TargetServer = $TargetServer; Error = $null; Data = $null }
Log-Child "Exchange $Mode child started (target: $srv, PowerShell $($PSVersionTable.PSVersion), 64-bit: $([Environment]::Is64BitProcess), user: $([Environment]::UserDomainName)\$([Environment]::UserName))" "DEBUG"
try {
	$snapTimer = [System.Diagnostics.Stopwatch]::StartNew()
	Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction Stop
	$ErrorActionPreference = "Stop"
	$snapVersion = (Get-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction SilentlyContinue).Version
	Log-Child "Exchange snap-in loaded in $($snapTimer.ElapsedMilliseconds) ms (version $snapVersion)" "DEBUG"
	$serverArgs = @{}
	if ($TargetServer -ne "") { $serverArgs["Server"] = $TargetServer }
	switch ($Mode) {
		"Snapshot" {
			Log-Child "Get-ExchangeCertificate via: Exchange Management Shell (server $srv)" "DEBUG"
			$allCerts = @(Get-ExchangeCertificate @serverArgs -ErrorAction Stop)
			Log-Child "Get-ExchangeCertificate response: $($allCerts.Count) certificate(s) on $srv" "DEBUG"
			foreach ($ec in $allCerts) { Log-ChildCert $ec "  Exchange certificate" }
			$result.Data = @($allCerts | Select-Object Thumbprint, Subject, Issuer, @{n="Services";e={$_.Services.ToString()}}, NotAfter, IsSelfSigned, @{n="NotAfterTicks";e={$_.NotAfter.ToUniversalTime().Ticks}}, @{n="CertificateDomains";e={(@($_.CertificateDomains | ForEach-Object { [string]$_ })) -join ","}})
			$result.Success = $true
		}
		"Topology" {
			Log-Child "Get-ExchangeServer via: Exchange Management Shell" "DEBUG"
			$allExchangeServers = @(Get-ExchangeServer -ErrorAction Stop)
			Log-Child "Get-ExchangeServer response: $($allExchangeServers.Count) server(s)" "DEBUG"
			foreach ($xs in $allExchangeServers) {
				Log-Child "  Exchange server: $($xs.Name) $($xs.AdminDisplayVersion) Roles=$($xs.ServerRole)" "DEBUG"
			}
			$mailboxServers = @(
				$allExchangeServers |
				Where-Object { $_.IsMailboxServer -eq $true -and $_.AdminDisplayVersion.Major -ge 15 } |
				ForEach-Object { $_.Name.ToString().ToUpperInvariant() }
			)
			$result.Data = @{ MailboxServers = $mailboxServers }
			$result.Success = $true
		}
		"HybridDiscover" {
			$managed = @($ManagedServers -split "\|" | Where-Object { $_ } | ForEach-Object { $_.Trim().ToUpperInvariant() })
			if ($managed.Count -eq 0) { throw "Managed server list was not supplied." }
			Log-Child "Get-SendConnector via: Exchange Management Shell (Hybrid Send Connector discovery)"
			$sendInfo = @()
			foreach ($sc in @(Get-SendConnector -ErrorAction Stop)) {
				$addr  = @($sc.AddressSpaces | ForEach-Object { [string]$_ })
				$hosts = @($sc.SmartHosts | ForEach-Object { [string]$_ })
				$src   = @($sc.SourceTransportServers | ForEach-Object { ([string]$_.Name).ToUpperInvariant() } | Where-Object { $_ })
				$info  = [PSCustomObject]@{
					Name     = [string]$sc.Name
					Identity = $sc.Identity.ToString()
					Enabled  = [bool]$sc.Enabled
					Cloud    = [bool]$sc.CloudServicesMailEnabled
					ToTenant = (@($addr | Where-Object { $_ -match "mail\.onmicrosoft\.com" }).Count -gt 0)
					Sources  = $src
				}
				$sendInfo += $info
				Log-Child "  Send connector: Name=$($info.Name) Enabled=$($info.Enabled) CloudServicesMailEnabled=$($info.Cloud) TenantAddressSpace=$($info.ToTenant) SourceTransportServers=$($src -join ",") AddressSpaces=$($addr -join ",") SmartHosts=$($hosts -join ",") TlsCertificateName=$($sc.TlsCertificateName)" "DEBUG"
			}
			Log-Child "Get-SendConnector response: $($sendInfo.Count) send connector(s)"
			$allNames = ($sendInfo | ForEach-Object { $_.Name }) -join "; "
			$candidates  = @()
			$overrideIds = @($HybridSendConnector -split "\|" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
			if ($overrideIds.Count -gt 0) {
				foreach ($id in $overrideIds) {
					$m = @($sendInfo | Where-Object { $_.Name -ieq $id -or $_.Identity -ieq $id })
					if ($m.Count -ne 1) { throw "Hybrid Send Connector override '$id' was not found. Send connectors: $allNames" }
					$candidates += [PSCustomObject]@{ Name = $m[0].Name; Identity = $m[0].Identity; Enabled = $m[0].Enabled; Sources = @($m[0].Sources); Method = "explicit (override)" }
				}
			}
			else {
				$cloudAll = @($sendInfo | Where-Object { $_.Cloud })
				foreach ($d in @($cloudAll | Where-Object { -not $_.Enabled })) {
					Log-Child "Send connector '$($d.Name)' is marked for Exchange Online but is disabled; ignored." "WARN"
				}
				$cloud = @($cloudAll | Where-Object { $_.Enabled })
				if ($cloud.Count -gt 0) {
					foreach ($c in $cloud) {
						$candidates += [PSCustomObject]@{ Name = $c.Name; Identity = $c.Identity; Enabled = $c.Enabled; Sources = @($c.Sources); Method = "auto (CloudServicesMailEnabled)" }
					}
				}
				else {
					$tenant = @($sendInfo | Where-Object { $_.ToTenant -and $_.Enabled })
					if ($tenant.Count -gt 0) {
						foreach ($c in $tenant) {
							$candidates += [PSCustomObject]@{ Name = $c.Name; Identity = $c.Identity; Enabled = $c.Enabled; Sources = @($c.Sources); Method = "auto (*.mail.onmicrosoft.com address space)" }
						}
						Log-Child "No enabled send connector is marked CloudServicesMailEnabled; selected by *.mail.onmicrosoft.com address space: $(($tenant | ForEach-Object { $_.Name }) -join "; ")" "WARN"
					}
					else {
						throw "No enabled Hybrid Send Connector found. Send connectors: $allNames. If not Hybrid, set ARGUMENT_4 to false."
					}
				}
			}
			foreach ($c in $candidates) {
				Log-Child "Hybrid Send Connector found: $($c.Name) [$($c.Method)] source servers: $(@($c.Sources) -join ",")"
			}
			$receive = @()
			if ($HybridReceiveConnectors -ne "") {
				foreach ($id in @($HybridReceiveConnectors -split "\|" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
					$rc = Get-ReceiveConnector -Identity $id -ErrorAction Stop
					$receive += [PSCustomObject]@{ Identity = $rc.Identity.ToString(); Server = ([string]$rc.Server).ToUpperInvariant(); Method = "explicit (override)" }
				}
			}
			else {
				foreach ($server in $managed) {
					Log-Child "Get-ReceiveConnector via: Exchange Management Shell -Server $server (Hybrid Receive Connector discovery)"
					$rcs = @(Get-ReceiveConnector -Server $server -ErrorAction Stop)
					foreach ($rc in $rcs) {
						Log-Child "  Receive connector: Identity=$($rc.Identity) Enabled=$($rc.Enabled) TransportRole=$($rc.TransportRole) TlsDomainCapabilities=$(@($rc.TlsDomainCapabilities) -join ",") Bindings=$(@($rc.Bindings) -join ",") TlsCertificateName=$($rc.TlsCertificateName)" "DEBUG"
					}
					$cloudRc = @($rcs | Where-Object { @($_.TlsDomainCapabilities | ForEach-Object { [string]$_ } | Where-Object { $_ -match "mail\.protection\.outlook\.com" }).Count -gt 0 })
					if ($cloudRc.Count -ge 1) {
						foreach ($rc in $cloudRc) {
							$receive += [PSCustomObject]@{ Identity = $rc.Identity.ToString(); Server = $server; Method = "auto (TlsDomainCapabilities mail.protection.outlook.com)" }
						}
					}
					else {
						$default = @($rcs | Where-Object { $_.Name -ieq "Default Frontend $server" })
						if ($default.Count -eq 1) {
							$receive += [PSCustomObject]@{ Identity = $default[0].Identity.ToString(); Server = $server; Method = "fallback (Default Frontend)" }
							Log-Child "No receive connector on $server has Exchange Online TlsDomainCapabilities; using '$($default[0].Identity)'." "WARN"
						}
						else {
							throw "No Hybrid receive connector found on $server."
						}
					}
				}
			}
			foreach ($r in $receive) { Log-Child "Hybrid Receive Connector found: $($r.Identity) [$($r.Method)]" }
			$edge = @()
			try {
				$hcd = Get-HybridConfiguration -ErrorAction Stop
				if ($hcd) { $edge = @($hcd.EdgeTransportServers | ForEach-Object { ([string]$_.Name).ToUpperInvariant() } | Where-Object { $_ }) }
			} catch { Log-Child "Get-HybridConfiguration could not be read during discovery: $($_.Exception.Message)" "DEBUG" }
			$result.Data = @{
				SendConnectors       = @($candidates)
				ReceiveConnectors    = @($receive)
				EdgeTransportServers = $edge
			}
			$result.Success = $true
		}
		"HybridSnapshot" {
			if ($Thumbprint -eq "") { throw "Thumbprint is required for HybridSnapshot." }
			if ($HybridReceiveConnectors -eq "") { throw "Hybrid Receive Connector identities were not supplied." }
			$cert = Get-ExchangeCertificate -Thumbprint $Thumbprint -ErrorAction Stop
			if (-not $cert) { throw "Certificate $Thumbprint was not found in Exchange." }
			Log-ChildCert $cert "  New certificate"
			$newTlsCertificateName = "<I>$($cert.Issuer)<S>$($cert.Subject)"
			Log-Child "Computed new TlsCertificateName: $newTlsCertificateName" "DEBUG"
			$sendIds = @($HybridSendConnector -split "\|" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
			$sendSnapshot = @()
			foreach ($id in $sendIds) {
				Log-Child "Get-SendConnector via: Exchange Management Shell -Identity $id" "DEBUG"
				$sc = Get-SendConnector -Identity $id -ErrorAction Stop
				Log-Child "Get-SendConnector response: Identity=$($sc.Identity) TlsCertificateName=$($sc.TlsCertificateName) RequireTLS=$($sc.RequireTLS) TlsAuthLevel=$($sc.TlsAuthLevel)" "DEBUG"
				$sendSnapshot += [PSCustomObject]@{ Identity = $sc.Identity.ToString(); TlsCertificateName = [string]$sc.TlsCertificateName }
			}
			$receiveIds = @($HybridReceiveConnectors -split "\|" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
			if ($receiveIds.Count -eq 0) { throw "No Hybrid Receive Connector identities were supplied." }
			$receiveSnapshot = @()
			foreach ($id in $receiveIds) {
				Log-Child "Get-ReceiveConnector via: Exchange Management Shell -Identity $id" "DEBUG"
				$rc = Get-ReceiveConnector -Identity $id -ErrorAction Stop
				Log-Child "Get-ReceiveConnector response: Identity=$($rc.Identity) TlsCertificateName=$($rc.TlsCertificateName)" "DEBUG"
				$receiveSnapshot += [PSCustomObject]@{ Identity = $rc.Identity.ToString(); TlsCertificateName = [string]$rc.TlsCertificateName }
			}
			$hcState = Get-HybridConfigurationState
			$result.Data = @{
				NewTlsCertificateName = $newTlsCertificateName
				SendConnectors        = @($sendSnapshot)
				ReceiveConnectors     = @($receiveSnapshot)
				HybridConfiguration   = $hcState
			}
			$result.Success = $true
			Log-Child "Hybrid TLS snapshot captured ($($sendSnapshot.Count) send, $($receiveSnapshot.Count) receive connector(s), Hybrid Configuration state $($hcState.State))" "DEBUG"
		}
		"HybridUpdate" {
			if ($HybridReceiveConnectors -eq "") { throw "Hybrid Receive Connector identities were not supplied." }
			if ($Thumbprint -eq "") { throw "Thumbprint is required for HybridUpdate." }
			$cert = Get-ExchangeCertificate -Thumbprint $Thumbprint -ErrorAction Stop
			if (-not $cert) { throw "Certificate $Thumbprint was not found in Exchange." }
			$newTlsCertificateName = "<I>$($cert.Issuer)<S>$($cert.Subject)"
			$newNorm = ConvertTo-NormalizedTlsName $newTlsCertificateName
			Log-Child "Hybrid TLS update target TlsCertificateName: $newTlsCertificateName"
			$sendIds    = @($HybridSendConnector -split "\|" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
			$receiveIds = @($HybridReceiveConnectors -split "\|" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
			if ($receiveIds.Count -eq 0) { throw "No Hybrid Receive Connector identities were supplied." }
			$changes = @()
			try {
				foreach ($id in $sendIds) {
					$sendConnector = Get-SendConnector -Identity $id -ErrorAction Stop
					$currentSendTlsName = [string]$sendConnector.TlsCertificateName
					if ((ConvertTo-NormalizedTlsName $currentSendTlsName) -ne $newNorm) {
						Log-Child "Set-SendConnector via: Exchange Management Shell -Identity $id -TlsCertificateName <new>"
						Set-SendConnector -Identity $id -TlsCertificateName $newTlsCertificateName -ErrorAction Stop
						$changes += [PSCustomObject]@{ Type = "Send"; Identity = $sendConnector.Identity.ToString(); OldValue = $currentSendTlsName; NewValue = $newTlsCertificateName }
						Log-Child "Set-SendConnector response indicates success: $($sendConnector.Identity)"
					}
					else {
						Log-Child "Send Connector $($sendConnector.Identity) already uses the new TLS certificate name. No change required."
					}
				}
				foreach ($id in $receiveIds) {
					$receiveConnector = Get-ReceiveConnector -Identity $id -ErrorAction Stop
					$currentReceiveTlsName = [string]$receiveConnector.TlsCertificateName
					if ((ConvertTo-NormalizedTlsName $currentReceiveTlsName) -ne $newNorm) {
						Log-Child "Set-ReceiveConnector via: Exchange Management Shell -Identity $id -TlsCertificateName <new>"
						Set-ReceiveConnector -Identity $id -TlsCertificateName $newTlsCertificateName -ErrorAction Stop
						$changes += [PSCustomObject]@{ Type = "Receive"; Identity = $receiveConnector.Identity.ToString(); OldValue = $currentReceiveTlsName; NewValue = $newTlsCertificateName }
						Log-Child "Set-ReceiveConnector response indicates success: $($receiveConnector.Identity)"
					}
					else {
						Log-Child "Receive Connector $($receiveConnector.Identity) already uses the new TLS certificate name. No change required."
					}
				}
				$hcAfterState = "NotManaged"
				if ($updateHc) {
					$hcState = Get-HybridConfigurationState
					if ($hcState.State -eq "Unreadable") {
						throw "Hybrid Configuration object could not be read: $($hcState.Error)"
					}
					elseif ($hcState.State -eq "NotPresent") {
						$hcAfterState = "NotPresent"
						Log-Child "No Hybrid Configuration object exists. Hybrid Configuration update not applicable." "WARN"
					}
					else {
						$currentHcTlsName = [string]$hcState.TlsCertificateName
						if ((ConvertTo-NormalizedTlsName $currentHcTlsName) -ne $newNorm) {
							Log-Child "Set-HybridConfiguration via: Exchange Management Shell -TlsCertificateName <new> (current: $currentHcTlsName)"
							Set-HybridConfiguration -TlsCertificateName $newTlsCertificateName -Confirm:$false -ErrorAction Stop
							$changes += [PSCustomObject]@{ Type = "HybridConfiguration"; Identity = "Hybrid Configuration"; OldValue = $currentHcTlsName; NewValue = $newTlsCertificateName }
							Log-Child "Set-HybridConfiguration response indicates success"
						}
						else {
							Log-Child "Hybrid Configuration already uses the new TLS certificate name. No change required."
						}
						$hcAfterState = "Present"
					}
				}
				else {
					Log-Child "Hybrid Configuration update disabled by configuration (UpdateHybridConfigurationObject=false)." "WARN"
				}
				foreach ($id in $sendIds) {
					$verifySend = Get-SendConnector -Identity $id -ErrorAction Stop
					if ((ConvertTo-NormalizedTlsName ([string]$verifySend.TlsCertificateName)) -ne $newNorm) {
						throw "Send Connector TLS verification failed for $id. Expected=$newTlsCertificateName Actual=$([string]$verifySend.TlsCertificateName)"
					}
					Log-Child "Send Connector TLS verification response indicates success: $id"
				}
				foreach ($id in $receiveIds) {
					$verifyReceive = Get-ReceiveConnector -Identity $id -ErrorAction Stop
					if ((ConvertTo-NormalizedTlsName ([string]$verifyReceive.TlsCertificateName)) -ne $newNorm) {
						throw "Receive Connector TLS verification failed for $id. Expected=$newTlsCertificateName Actual=$([string]$verifyReceive.TlsCertificateName)"
					}
					Log-Child "Receive Connector TLS verification response indicates success: $id"
				}
				if ($hcAfterState -eq "Present") {
					$verifyHc = Get-HybridConfigurationState
					if ($verifyHc.State -ne "Present" -or (ConvertTo-NormalizedTlsName $verifyHc.TlsCertificateName) -ne $newNorm) {
						throw "Hybrid Configuration TLS verification failed. Expected=$newTlsCertificateName Actual=$($verifyHc.TlsCertificateName)"
					}
					Log-Child "Hybrid Configuration TLS verification response indicates success"
				}
				$result.Data = @{
					Changed                  = ($changes.Count -gt 0)
					Changes                  = @($changes)
					ConnectorsChanged        = (@($changes | Where-Object { $_.Type -ne "HybridConfiguration" }).Count -gt 0)
					HybridConfigurationState = $hcAfterState
				}
				$result.Success = $true
				Log-Child "Hybrid TLS update and verification completed. Changes=$($changes.Count)"
			}
			catch {
				$updateError = $_.Exception.Message
				$rollbackFailures = @()
				Log-Child "Hybrid TLS update failed: $updateError" "ERROR"
				Log-Child "Rolling back $(@($changes).Count) Hybrid change(s) made during this operation." "WARN"
				foreach ($change in @($changes)) {
					try {
						$restoreValue = if ([string]::IsNullOrWhiteSpace($change.OldValue)) { $null } else { $change.OldValue }
						if ($change.Type -eq "Send") {
							Set-SendConnector -Identity $change.Identity -TlsCertificateName $restoreValue -ErrorAction Stop
						}
						elseif ($change.Type -eq "Receive") {
							Set-ReceiveConnector -Identity $change.Identity -TlsCertificateName $restoreValue -ErrorAction Stop
						}
						else {
							Set-HybridConfiguration -TlsCertificateName $restoreValue -Confirm:$false -ErrorAction Stop
						}
						Log-Child "Hybrid rollback restored $($change.Type) $($change.Identity)." "WARN"
					}
					catch {
						$rollbackFailures += "$($change.Identity): $($_.Exception.Message)"
						Log-Child "Hybrid rollback FAILED for $($change.Identity): $($_.Exception.Message)" "ERROR"
					}
				}
				if ($rollbackFailures.Count -gt 0) {
					throw "Hybrid TLS update failed and rollback was incomplete. UpdateError=$updateError RollbackErrors=$($rollbackFailures -join "; ")"
				}
				throw "Hybrid TLS update failed; Hybrid changes were rolled back. $updateError"
			}
		}
		"HybridRestore" {
			if ($HybridRestoreStateBase64 -eq "") { throw "Hybrid restore state was not supplied." }
			$restoreJson  = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($HybridRestoreStateBase64))
			$restoreState = $restoreJson | ConvertFrom-Json
			$sendRestoreState    = @($restoreState.SendConnectors | Where-Object { $_ })
			$receiveRestoreState = @($restoreState.ReceiveConnectors | Where-Object { $_ })
			if ($receiveRestoreState.Count -eq 0) { throw "Hybrid restore state does not contain Receive Connector data." }
			$restoreFailures = @()
			foreach ($saved in $sendRestoreState) {
				$sendIdentity = [string]$saved.Identity
				if ([string]::IsNullOrWhiteSpace($sendIdentity)) { $restoreFailures += "Send Connector restore state contains an invalid identity."; continue }
				Log-Child "Hybrid restore state: Send=$sendIdentity -> [$($saved.TlsCertificateName)]"
				try {
					$v = if ([string]::IsNullOrWhiteSpace([string]$saved.TlsCertificateName)) { $null } else { [string]$saved.TlsCertificateName }
					Log-Child "Set-SendConnector via: Exchange Management Shell -Identity $sendIdentity (restore)"
					Set-SendConnector -Identity $sendIdentity -TlsCertificateName $v -ErrorAction Stop
					Log-Child "Set-SendConnector response indicates success (restore): $sendIdentity"
				}
				catch {
					$restoreFailures += "Send $sendIdentity restore failed: $($_.Exception.Message)"
					Log-Child "Send $sendIdentity restore failed: $($_.Exception.Message)" "ERROR"
				}
			}
			foreach ($saved in $receiveRestoreState) {
				$receiveIdentity = [string]$saved.Identity
				if ([string]::IsNullOrWhiteSpace($receiveIdentity)) { $restoreFailures += "Receive Connector restore state contains an invalid identity."; continue }
				Log-Child "Hybrid restore state: Receive=$receiveIdentity -> [$($saved.TlsCertificateName)]"
				try {
					$v = if ([string]::IsNullOrWhiteSpace([string]$saved.TlsCertificateName)) { $null } else { [string]$saved.TlsCertificateName }
					Log-Child "Set-ReceiveConnector via: Exchange Management Shell -Identity $receiveIdentity (restore)"
					Set-ReceiveConnector -Identity $receiveIdentity -TlsCertificateName $v -ErrorAction Stop
					Log-Child "Set-ReceiveConnector response indicates success (restore): $receiveIdentity"
				}
				catch {
					$restoreFailures += "Receive $receiveIdentity restore failed: $($_.Exception.Message)"
					Log-Child "Receive $receiveIdentity restore failed: $($_.Exception.Message)" "ERROR"
				}
			}
			$hcSaved   = $restoreState.HybridConfiguration
			$restoreHc = ($updateHc -and $null -ne $hcSaved -and [string]$hcSaved.State -eq "Present")
			if ($restoreHc) {
				Log-Child "Hybrid restore state: Hybrid Configuration -> [$($hcSaved.TlsCertificateName)]"
				try {
					$hcRestoreValue = if ([string]::IsNullOrWhiteSpace([string]$hcSaved.TlsCertificateName)) { $null } else { [string]$hcSaved.TlsCertificateName }
					Log-Child "Set-HybridConfiguration via: Exchange Management Shell -TlsCertificateName <previous> (restore)"
					Set-HybridConfiguration -TlsCertificateName $hcRestoreValue -Confirm:$false -ErrorAction Stop
					Log-Child "Set-HybridConfiguration response indicates success (restore)"
				}
				catch {
					$restoreFailures += "Hybrid Configuration restore failed: $($_.Exception.Message)"
					Log-Child "Hybrid Configuration restore failed: $($_.Exception.Message)" "ERROR"
				}
			}
			else {
				Log-Child "Hybrid Configuration restore not applicable (state: $(if ($hcSaved) { $hcSaved.State } else { "not captured" }))." "DEBUG"
			}
			foreach ($saved in $sendRestoreState) {
				$sendIdentity = [string]$saved.Identity
				if ([string]::IsNullOrWhiteSpace($sendIdentity)) { continue }
				try {
					$verifySend = Get-SendConnector -Identity $sendIdentity -ErrorAction Stop
					if ((ConvertTo-NormalizedTlsName ([string]$verifySend.TlsCertificateName)) -ne (ConvertTo-NormalizedTlsName ([string]$saved.TlsCertificateName))) {
						throw "Expected=$([string]$saved.TlsCertificateName) Actual=$([string]$verifySend.TlsCertificateName)"
					}
					Log-Child "Send Connector restore verification response indicates success: $sendIdentity"
				}
				catch { $restoreFailures += "Send $sendIdentity verification failed: $($_.Exception.Message)" }
			}
			foreach ($saved in $receiveRestoreState) {
				$receiveIdentity = [string]$saved.Identity
				if ([string]::IsNullOrWhiteSpace($receiveIdentity)) { continue }
				try {
					$verifyReceive = Get-ReceiveConnector -Identity $receiveIdentity -ErrorAction Stop
					if ((ConvertTo-NormalizedTlsName ([string]$verifyReceive.TlsCertificateName)) -ne (ConvertTo-NormalizedTlsName ([string]$saved.TlsCertificateName))) {
						throw "Expected=$([string]$saved.TlsCertificateName) Actual=$([string]$verifyReceive.TlsCertificateName)"
					}
					Log-Child "Receive Connector restore verification response indicates success: $receiveIdentity"
				}
				catch { $restoreFailures += "Receive $receiveIdentity verification failed: $($_.Exception.Message)" }
			}
			if ($restoreHc) {
				$verifyHc = Get-HybridConfigurationState
				if ($verifyHc.State -ne "Present" -or (ConvertTo-NormalizedTlsName $verifyHc.TlsCertificateName) -ne (ConvertTo-NormalizedTlsName ([string]$hcSaved.TlsCertificateName))) {
					$restoreFailures += "Hybrid Configuration verification failed. Expected=$($hcSaved.TlsCertificateName) Actual=$($verifyHc.TlsCertificateName)"
				}
				else {
					Log-Child "Hybrid Configuration restore verification response indicates success"
				}
			}
			if ($restoreFailures.Count -gt 0) {
				throw "Hybrid rollback was incomplete. $($restoreFailures -join "; ")"
			}
			$result.Data = @{ SendCount = $sendRestoreState.Count; ReceiveCount = $receiveRestoreState.Count; HybridConfigurationRestored = $restoreHc }
			$result.Success = $true
			Log-Child "Hybrid TLS state restored and verified."
		}
		"Enable" {
			Log-Child "Enable-ExchangeCertificate via: Exchange Management Shell -Thumbprint $Thumbprint -Services $Services -Server $srv"
			$enableTimer = [System.Diagnostics.Stopwatch]::StartNew()
			Enable-ExchangeCertificate -Thumbprint $Thumbprint -Services $Services -Confirm:$false -Force @serverArgs
			Log-Child "Enable-ExchangeCertificate response indicates success ($($enableTimer.ElapsedMilliseconds) ms): $Thumbprint on $srv for $Services"
			try { Log-ChildCert (Get-ExchangeCertificate -Thumbprint $Thumbprint @serverArgs -ErrorAction Stop) "  After enable" } catch { Log-Child "Diagnostic read after enable failed: $($_.Exception.Message)" "WARN" }
			$result.Success = $true
		}
		"Validate" {
			$certs  = Get-ExchangeCertificate @serverArgs -ErrorAction Stop
			$target = $certs | Where-Object { $_.Thumbprint -eq $Thumbprint }
			if (-not $target) { throw "Thumbprint $Thumbprint not found on $srv." }
			$svcString = $target.Services.ToString()
			$missing = @()
			Log-ChildCert $target "  Validate target"
			foreach ($svc in ($Services -split ",")) {
				$present = ($svcString -match [regex]::Escape($svc))
				Log-Child "  Service check on ${srv}: $svc present=$present (assigned=$svcString)" "DEBUG"
				if (-not $present) { $missing += $svc }
			}
			if ($missing.Count -gt 0) { throw "Certificate is missing services: $($missing -join ", ")" }
			$result.Success = $true
			$result.Data = $svcString
			Log-Child "Service assignment validation response indicates success on ${srv}: $svcString"
		}
		"HealthCheck" {
			$serverName = $srv
			$serviceHealthOK = $false
			$unhealthy = @()
			try {
				Log-Child "Test-ServiceHealth via: Exchange Management Shell -Server $serverName"
				$healthTimer = [System.Diagnostics.Stopwatch]::StartNew()
				$health = Test-ServiceHealth -Server $serverName -ErrorAction Stop
				foreach ($h in @($health)) {
					Log-Child "  Role: $($h.Role) RequiredServicesRunning=$($h.RequiredServicesRunning) NotRunning=[$(@($h.ServicesNotRunning) -join ",")]" $(if ($h.RequiredServicesRunning) { "DEBUG" } else { "WARN" })
				}
				$unhealthy = @($health | Where-Object { $_.RequiredServicesRunning -eq $false })
				$serviceHealthOK = ($unhealthy.Count -eq 0)
				Log-Child "Test-ServiceHealth response: $(@($health).Count) role(s), $($unhealthy.Count) unhealthy ($($healthTimer.ElapsedMilliseconds) ms)"
			} catch {
				$serviceHealthOK = $false
				Log-Child "Test-ServiceHealth failed to execute on ${serverName}: $($_.Exception.Message)" "ERROR"
			}
			$mailflowOK = $false
			$mailflowResult = "Unknown"
			try {
				$allCopies = @(Get-MailboxDatabaseCopyStatus -Server $serverName -ErrorAction Stop)
				foreach ($dbc in $allCopies) {
					Log-Child "  Database copy: $($dbc.Name) Status=$($dbc.Status) ActiveCopy=$($dbc.ActiveCopy)" "DEBUG"
				}
				$activeMailboxDBs = @($allCopies | Where-Object { $_.ActiveCopy -eq $true -and $_.Status -eq "Mounted" })
				if ($activeMailboxDBs.Count -eq 0) {
					$mailflowResult = "NotApplicable"
					$mailflowOK = $true
					Log-Child "Test-Mailflow skipped: no active mounted mailbox database copies on $serverName."
				} else {
					Log-Child "Test-Mailflow via: Exchange Management Shell -TargetMailboxServer $serverName"
					$mfTimer = [System.Diagnostics.Stopwatch]::StartNew()
					$mf = Test-Mailflow -TargetMailboxServer $serverName -ErrorAction Stop
					if ($null -eq $mf) { throw "Test-Mailflow returned no result." }
					$mailflowResult = [string]$mf.TestMailflowResult
					$mailflowOK = ($mailflowResult -eq "Success")
					Log-Child "Test-Mailflow response: Result=$($mf.TestMailflowResult) Latency=$($mf.MessageLatencyTime) ($($mfTimer.ElapsedMilliseconds) ms)" $(if ($mailflowOK) { "INFO" } else { "WARN" })
				}
			} catch {
				$mailflowResult = "Failed: $($_.Exception.Message)"
				$mailflowOK = $false
				Log-Child "Mailflow check failed on ${serverName}: $($_.Exception.Message)" "ERROR"
			}
			$result.Success = $serviceHealthOK -and $mailflowOK
			$result.Data = @{
				UnhealthyRoles  = @($unhealthy | Select-Object -ExpandProperty Role)
				ServiceHealthOK = $serviceHealthOK
				MailflowResult  = $mailflowResult
			}
			Log-Child "Health check result on ${serverName}: ServiceHealthOK=$serviceHealthOK UnhealthyRoles=$($unhealthy.Count) Mailflow=$mailflowResult" $(if ($result.Success) { "INFO" } else { "ERROR" })
		}
		"Rollback" {
			if ($PreviousThumbprint -eq "") { throw "No PreviousThumbprint supplied for rollback." }
			Log-Child "Enable-ExchangeCertificate via: Exchange Management Shell -Thumbprint $PreviousThumbprint -Services $Services -Server $srv (rollback)"
			Enable-ExchangeCertificate -Thumbprint $PreviousThumbprint -Services $Services -Confirm:$false -Force @serverArgs
			Log-Child "Enable-ExchangeCertificate response indicates success (rollback): restored $PreviousThumbprint on $srv for $Services" "WARN"
			$result.Success = $true
		}
		"RemovalCheck" {
			if ($Thumbprint -eq "") { throw "Thumbprint is required for RemovalCheck." }
			$thumbList = @($Thumbprint -split "\|" | Where-Object { $_ } | ForEach-Object { $_.Trim().ToUpperInvariant() })
			$candidateThumb = $thumbList[0]
			$checkErrors = @()
			Log-Child "Get-ExchangeCertificate via: Exchange Management Shell (server $srv, removal candidate $candidateThumb)"
			$authThumbs = @(); $authOk = $true
			try {
				Log-Child "Get-AuthConfig via: Exchange Management Shell" "DEBUG"
				$ac = Get-AuthConfig -ErrorAction Stop
				foreach ($t in @($ac.CurrentCertificateThumbprint, $ac.PreviousCertificateThumbprint, $ac.NextCertificateThumbprint)) {
					if (-not [string]::IsNullOrWhiteSpace([string]$t)) { $authThumbs += ([string]$t).Trim().ToUpperInvariant() }
				}
				Log-Child "Get-AuthConfig response: OAuth certificate thumbprints=$($authThumbs -join ",")" "DEBUG"
			}
			catch {
				$authOk = $false
				$checkErrors += "Get-AuthConfig: $($_.Exception.Message)"
				Log-Child "Get-AuthConfig could not be read: $($_.Exception.Message)" "WARN"
			}
			$fedThumbs = @(); $fedOk = $true
			try {
				Log-Child "Get-FederationTrust via: Exchange Management Shell" "DEBUG"
				foreach ($ft in @(Get-FederationTrust -ErrorAction Stop)) {
					foreach ($pn in @("OrgCertificate","OrgNextCertificate","OrgPrevCertificate","OrgPrivCertificate","OrgNextPrivCertificate","OrgPrevPrivCertificate")) {
						if (-not ($ft.PSObject.Properties.Name -contains $pn)) { continue }
						$pv = $ft.$pn
						if ($null -eq $pv) { continue }
						$tv = if ($pv.PSObject.Properties.Name -contains "Thumbprint") { [string]$pv.Thumbprint } else { [string]$pv }
						if ($tv -match '^[0-9A-Fa-f]{40}$') { $fedThumbs += $tv.ToUpperInvariant() }
					}
				}
				Log-Child "Get-FederationTrust response: federation certificate thumbprints=$($fedThumbs -join ",")" "DEBUG"
			}
			catch {
				$fedOk = $false
				$checkErrors += "Get-FederationTrust: $($_.Exception.Message)"
				Log-Child "Get-FederationTrust could not be read: $($_.Exception.Message)" "WARN"
			}
			$internalTransportThumb = ""; $transportOk = $true
			try {
				Log-Child "Get-TransportService via: Exchange Management Shell -Identity $srv" "DEBUG"
				$tsv = Get-TransportService -Identity $srv -ErrorAction Stop
				$internalTransportThumb = ([string]$tsv.InternalTransportCertificateThumbprint).Trim().ToUpperInvariant()
				Log-Child "Get-TransportService response: InternalTransportCertificateThumbprint=$internalTransportThumb" "DEBUG"
			}
			catch {
				$transportOk = $false
				$checkErrors += "Get-TransportService: $($_.Exception.Message)"
				Log-Child "Get-TransportService could not be read: $($_.Exception.Message)" "WARN"
			}
			$result.Data = @{
				Thumbprint                  = $candidateThumb
				AuthCheckOk                 = $authOk
				AuthThumbprints             = $authThumbs
				FederationCheckOk           = $fedOk
				FederationThumbprints       = $fedThumbs
				TransportCheckOk            = $transportOk
				InternalTransportThumbprint = $internalTransportThumb
				CheckErrors                 = $checkErrors
				Candidates                  = @(foreach ($ct in $thumbList) { $cc = Find-ExchangeCertificate -Thumb $ct -ServerParameters $serverArgs; if ($cc) { Log-ChildCert $cc "  Removal candidate" }; [PSCustomObject]@{ Thumbprint = $ct; Exists = ($null -ne $cc); Subject = [string]$cc.Subject; Issuer = [string]$cc.Issuer; NotAfter = [string]$cc.NotAfter; IsSelfSigned = [bool]$cc.IsSelfSigned; Services = $(if ($cc) { $cc.Services.ToString() } else { "" }) } })
			}
			$result.Success = $true
		}
		"TaggedConnectors" {
			if ($Thumbprint -eq "" -or $PreviousThumbprint -eq "") { throw "Old (Thumbprint) and new (PreviousThumbprint) thumbprints are required." }
			$oldC = Find-ExchangeCertificate -Thumb $Thumbprint -ServerParameters $serverArgs
			$newC = Find-ExchangeCertificate -Thumb $PreviousThumbprint -ServerParameters $serverArgs
			if (-not $oldC) { throw "Old certificate $Thumbprint not found on $srv." }
			if (-not $newC) { throw "New certificate $PreviousThumbprint not found on $srv." }
			$oldName = "<I>$($oldC.Issuer)<S>$($oldC.Subject)"
			$newName = "<I>$($newC.Issuer)<S>$($newC.Subject)"
			$oldNorm = ConvertTo-NormalizedTlsName $oldName
			Log-Child "Get-SendConnector via: Exchange Management Shell (send connectors whose TlsCertificateName is $oldName)"
			$tagged = @(Get-SendConnector -ErrorAction Stop | Where-Object { (ConvertTo-NormalizedTlsName ([string]$_.TlsCertificateName)) -eq $oldNorm } | ForEach-Object {
				[PSCustomObject]@{ Identity = $_.Identity.ToString(); Value = [string]$_.TlsCertificateName; Sources = ((@($_.SourceTransportServers | ForEach-Object { ([string]$_.Name).ToUpperInvariant() } | Where-Object { $_ })) -join ",") } })
			foreach ($tc in $tagged) { Log-Child "  Tagged send connector: $($tc.Identity) SourceTransportServers=$($tc.Sources)" }
			$sameName = ((ConvertTo-NormalizedTlsName $newName) -eq $oldNorm)
			$newValid = ($newC.HasPrivateKey -and $newC.NotAfter -gt (Get-Date))
			Log-Child "Get-SendConnector response: $($tagged.Count) tagged connector(s); new certificate shares Issuer/Subject: $sameName; new certificate valid with key: $newValid"
			$result.Data = @{ OldTlsName = $oldName; NewTlsName = $newName; SameName = $sameName; NewValid = $newValid; Connectors = @($tagged) }
			$result.Success = $true
		}
		"NameMatch" {
			$name = ConvertTo-NormalizedTlsName ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($HybridRestoreStateBase64)))
			$out = @()
			foreach ($s in @($ManagedServers -split "\|" | Where-Object { $_ })) {
				Log-Child "Get-ExchangeCertificate via: Exchange Management Shell -Server $s (certificates matching the Hybrid TLS name)"
				$m = @(Get-ExchangeCertificate -Server $s -ErrorAction Stop | Where-Object { (ConvertTo-NormalizedTlsName "<I>$($_.Issuer)<S>$($_.Subject)") -eq $name } | ForEach-Object { $_.Thumbprint.ToUpperInvariant() })
				Log-Child "Get-ExchangeCertificate response: $($m.Count) matching certificate(s) on ${s}: $($m -join ',')"
				$out += [PSCustomObject]@{ Server = $s; Matches = ($m -join ",") }
			}
			$result.Data = @{ Servers = @($out) }
			$result.Success = $true
		}
		"KbRemove" {
			$ids = @($HybridSendConnector -split "\|" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
			if ($ids.Count -eq 0) { throw "No send connector identities supplied." }
			$newName = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($HybridRestoreStateBase64))
			$targets = @($ManagedServers -split "\|" | Where-Object { $_ } | ForEach-Object { $p = $_ -split "=", 2; [PSCustomObject]@{ Server = $p[0].Trim(); Thumb = $p[1].Trim().ToUpperInvariant(); Removed = $false; Error = "" } })
			$deadline = (Get-Date).AddSeconds($RetrySeconds)
			$restoreErrors = @()
			try {
				foreach ($id in $ids) {
					Log-Child "Set-SendConnector via: Exchange Management Shell -Identity $id -TlsCertificateName `$null"
					Set-SendConnector -Identity $id -TlsCertificateName $null -ErrorAction Stop
				}
				Log-Child "Set-SendConnector response indicates success: TlsCertificateName cleared on $($ids -join '; ')"
				$attempt = 0
				while ($true) {
					$attempt++
					foreach ($t in @($targets | Where-Object { -not $_.Removed })) {
						try {
							$sa = @{ Server = $t.Server }
							if (-not (Find-ExchangeCertificate -Thumb $t.Thumb -ServerParameters $sa)) { $t.Removed = $true; $t.Error = ""; Log-Child "$($t.Thumb) is not present on $($t.Server)."; continue }
							Log-Child "Remove-ExchangeCertificate via: Exchange Management Shell -Thumbprint $($t.Thumb) -Server $($t.Server) (attempt $attempt)"
							Remove-ExchangeCertificate -Thumbprint $t.Thumb -Server $t.Server -Confirm:$false -ErrorAction Stop
							if (Find-ExchangeCertificate -Thumb $t.Thumb -ServerParameters $sa) { throw "certificate still present after Remove-ExchangeCertificate" }
							$t.Removed = $true; $t.Error = ""
							Log-Child "Remove-ExchangeCertificate response indicates success: $($t.Thumb) on $($t.Server)"
						}
						catch {
							$t.Error = $_.Exception.Message
							Log-Child "Remove-ExchangeCertificate attempt $attempt on $($t.Server) failed: $($t.Error)" "WARN"
						}
					}
					$retry = @($targets | Where-Object { -not $_.Removed -and $_.Error -match "tagged with following Send Connectors" })
					if ($retry.Count -eq 0) { break }
					if ((Get-Date).AddSeconds(10) -gt $deadline) { Log-Child "Retry window ($RetrySeconds s) exhausted for $(($retry | ForEach-Object { $_.Server }) -join ',')." "WARN"; break }
					Log-Child "$(($retry | ForEach-Object { $_.Server }) -join ',') still sees the old send connector value (Active Directory replication/cache delay). Retrying in 10 seconds..."
					Start-Sleep -Seconds 10
				}
			}
			finally {
				foreach ($id in $ids) {
					try {
						Log-Child "Set-SendConnector via: Exchange Management Shell -Identity $id -TlsCertificateName $newName"
						Set-SendConnector -Identity $id -TlsCertificateName $newName -ErrorAction Stop
						$chk = Get-SendConnector -Identity $id -ErrorAction Stop
						if ((ConvertTo-NormalizedTlsName ([string]$chk.TlsCertificateName)) -ne (ConvertTo-NormalizedTlsName $newName)) { throw "verification failed. Actual=[$($chk.TlsCertificateName)]" }
						Log-Child "Set-SendConnector response indicates success: $id TlsCertificateName set from the new certificate"
					}
					catch {
						$restoreErrors += "${id}: $($_.Exception.Message)"
						Log-Child "Send connector $id TlsCertificateName could NOT be set: $($_.Exception.Message)" "CRITICAL"
					}
				}
			}
			$result.Data = @{ Results = @($targets | ForEach-Object { [PSCustomObject]@{ Server = $_.Server; Thumb = $_.Thumb; Removed = $_.Removed; Error = $(if ($_.Removed) { "" } else { $_.Error }) } }); RestoreOk = ($restoreErrors.Count -eq 0); RestoreErrors = ($restoreErrors -join "; ") }
			$result.Success = ($restoreErrors.Count -eq 0)
		}
		"SendConnectorTls" {
			$ids = @($HybridSendConnector -split "\|" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
			if ($ids.Count -eq 0) { throw "No send connector identities supplied." }
			$value = if ($HybridRestoreStateBase64 -eq "") { "" } else { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($HybridRestoreStateBase64)) }
			$setValue = if ($value -eq "") { $null } else { $value }
			$failures = @()
			foreach ($id in $ids) {
				try {
					Log-Child "Set-SendConnector via: Exchange Management Shell -Identity $id -TlsCertificateName $(if ($setValue) { $setValue } else { '$null' })"
					Set-SendConnector -Identity $id -TlsCertificateName $setValue -ErrorAction Stop
					$chk = Get-SendConnector -Identity $id -ErrorAction Stop
					if ((ConvertTo-NormalizedTlsName ([string]$chk.TlsCertificateName)) -ne (ConvertTo-NormalizedTlsName $value)) { throw "verification failed. Expected=[$value] Actual=[$($chk.TlsCertificateName)]" }
					Log-Child "Set-SendConnector response indicates success: $id"
				}
				catch {
					$failures += "${id}: $($_.Exception.Message)"
					Log-Child "Set-SendConnector failed for ${id}: $($_.Exception.Message)" "ERROR"
				}
			}
			if ($failures.Count -gt 0) { throw ($failures -join "; ") }
			$result.Success = $true
		}
		"RemoveCertificate" {
			if ($Thumbprint -eq "") { throw "Thumbprint is required for RemoveCertificate." }
			$removeThumb = $Thumbprint.Trim().ToUpperInvariant()
			$before = Find-ExchangeCertificate -Thumb $removeThumb -ServerParameters $serverArgs
			if (-not $before) {
				Log-Child "Certificate $removeThumb is not present on $srv. Nothing to remove."
				$result.Data = @{ Removed = $false; AlreadyAbsent = $true }
				$result.Success = $true
			}
			else {
				Log-ChildCert $before "  Certificate to remove"
				Log-Child "Remove-ExchangeCertificate via: Exchange Management Shell -Thumbprint $removeThumb -Server $srv"
				Remove-ExchangeCertificate -Thumbprint $removeThumb @serverArgs -Confirm:$false -ErrorAction Stop
				$after = Find-ExchangeCertificate -Thumb $removeThumb -ServerParameters $serverArgs
				if ($after) { throw "Certificate $removeThumb is still present on $srv after Remove-ExchangeCertificate." }
				Log-Child "Remove-ExchangeCertificate response indicates success: $removeThumb no longer returned by Get-ExchangeCertificate on $srv"
				$result.Data = @{ Removed = $true; AlreadyAbsent = $false }
				$result.Success = $true
			}
		}
	}
} catch {
	$result.Error = $_.Exception.Message
	Log-ChildException $_ "Exchange $Mode operation failed on $srv"
	if ($_.Exception.Message -like "*KeyAlgorithmUnsupported*") {
		Log-Child "Certificate uses an unsupported key algorithm for Exchange." "CRITICAL"
	}
}
Log-Child "Exchange $Mode child finished on $srv. Success=$($result.Success) DurationMs=$($childTimer.ElapsedMilliseconds)" $(if ($result.Success) { "DEBUG" } else { "ERROR" })
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
if (-not $result.Success) { exit 1 } else { exit 0 }
'@
function New-ExchangeChildScriptFile {
	param([string]$Path)
	Set-Content -LiteralPath $Path -Value $script:ExchangeChildScript -Encoding UTF8
}
function ConvertTo-SingleQuotedLiteral {
	param([string]$Value)
	if ($null -eq $Value) { return "" }
	return $Value.Replace("'", "''")
}
function Invoke-ExchangeChild {
	param(
		[string]$Mode,
		[string]$Thumbprint = "",
		[string]$Services = "",
		[string]$TargetServer = "",
		[string]$PreviousThumbprint = "",
		[string]$HybridSendConnector = "",
		[string]$HybridReceiveConnectors = "",
		[string]$HybridRestoreStateBase64 = "",
		[string]$ManagedServers = "",
		[int]$RetrySeconds = 60
	)
	$childScriptPath = $null
	$resultPath      = $null
	$stdoutPath      = $null
	$stderrPath      = $null
	$childTimer      = [System.Diagnostics.Stopwatch]::StartNew()
	$targetLabel     = if ([string]::IsNullOrEmpty($TargetServer)) { "$LocalServerName (local)" } else { $TargetServer }
	Log-Debug "Exchange $Mode via: Exchange Management Shell child process (target: $targetLabel)"
	$parsed = [PSCustomObject]@{
		Success      = $false
		Mode         = $Mode
		TargetServer = $TargetServer
		Error        = "Exchange child invocation did not complete."
		Data         = $null
	}
	try {
		if ([string]::IsNullOrWhiteSpace($env:TEMP)) { throw "TEMP environment variable is empty or unavailable." }
		$childScriptPath = Join-Path $env:TEMP ("ExCert_" + [Guid]::NewGuid().ToString() + ".ps1")
		$resultPath      = Join-Path $env:TEMP ("ExCertResult_" + [Guid]::NewGuid().ToString() + ".json")
		$stdoutPath      = Join-Path $env:TEMP ("ExCertOut_" + [Guid]::NewGuid().ToString() + ".txt")
		$stderrPath      = Join-Path $env:TEMP ("ExCertErr_" + [Guid]::NewGuid().ToString() + ".txt")
		New-ExchangeChildScriptFile -Path $childScriptPath
		$q = @{
			ChildScript   = ConvertTo-SingleQuotedLiteral $childScriptPath
			Thumbprint    = ConvertTo-SingleQuotedLiteral $Thumbprint
			Services      = ConvertTo-SingleQuotedLiteral $Services
			TargetServer  = ConvertTo-SingleQuotedLiteral $TargetServer
			Mode          = ConvertTo-SingleQuotedLiteral $Mode
			PreviousThumb = ConvertTo-SingleQuotedLiteral $PreviousThumbprint
			SendConn      = ConvertTo-SingleQuotedLiteral $HybridSendConnector
			ReceiveConns  = ConvertTo-SingleQuotedLiteral $HybridReceiveConnectors
			RestoreState  = ConvertTo-SingleQuotedLiteral $HybridRestoreStateBase64
			Managed       = ConvertTo-SingleQuotedLiteral $ManagedServers
			UpdateHc      = $(if ($UpdateHybridConfigurationObject) { "true" } else { "false" })
			ResultPath    = ConvertTo-SingleQuotedLiteral $resultPath
			LogFilePath   = ConvertTo-SingleQuotedLiteral $LogFilePath
			LogLevel      = ConvertTo-SingleQuotedLiteral $LogLevel
		}
		$cmd = "& '$($q.ChildScript)' " +
			 "-Thumbprint '$($q.Thumbprint)' -Services '$($q.Services)' -TargetServer '$($q.TargetServer)' " +
			 "-Mode '$($q.Mode)' -PreviousThumbprint '$($q.PreviousThumb)' " +
			 "-HybridSendConnector '$($q.SendConn)' -HybridReceiveConnectors '$($q.ReceiveConns)' " +
			 "-HybridRestoreStateBase64 '$($q.RestoreState)' -ManagedServers '$($q.Managed)' -RetrySeconds $RetrySeconds -UpdateHybridConfiguration '$($q.UpdateHc)' " +
			 "-ResultPath '$($q.ResultPath)' -LogFilePath '$($q.LogFilePath)' -LogLevel '$($q.LogLevel)'"
		$psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
		if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
			$psExe = Join-Path $env:SystemRoot "Sysnative\WindowsPowerShell\v1.0\powershell.exe"
		}
		if (-not (Test-Path -LiteralPath $psExe)) {
			Log-Debug "powershell.exe not found at $psExe; falling back to PATH resolution."
			$psExe = "powershell.exe"
		}
		$cmdForLog = $cmd
		if ($HybridRestoreStateBase64.Length -gt 0) {
			$cmdForLog = $cmdForLog.Replace($q.RestoreState, "<restore-state base64, $($HybridRestoreStateBase64.Length) chars>")
		}
		Log-Debug "Exchange $Mode child command: $cmdForLog"
		$proc = Start-Process $psExe `
			-ArgumentList @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", $cmd) `
			-PassThru `
			-NoNewWindow `
			-RedirectStandardOutput $stdoutPath `
			-RedirectStandardError $stderrPath `
			-ErrorAction Stop
		$null = $proc.Handle
		if (-not $proc.WaitForExit($ChildProcessTimeoutSeconds * 1000)) {
			Log-Error "Exchange $Mode child process on $targetLabel exceeded $ChildProcessTimeoutSeconds seconds. Terminating PID $($proc.Id)."
			$kill = Invoke-NativeCapture -FilePath "taskkill.exe" -Arguments @("/PID", [string]$proc.Id, "/T", "/F")
			Log-Debug "taskkill exit code: $($kill.ExitCode) output: $($kill.Output -replace '\r?\n', ' ')"
			throw "Exchange $Mode child process timed out after $ChildProcessTimeoutSeconds seconds."
		}
		$proc.WaitForExit()
		Log-Debug "Exchange $Mode exit code: $($proc.ExitCode) ($($childTimer.ElapsedMilliseconds) ms)"
		foreach ($stream in @(@{ Name = "stdout"; Path = $stdoutPath }, @{ Name = "stderr"; Path = $stderrPath })) {
			if (Test-Path -LiteralPath $stream.Path) {
				$streamText = Get-Content -LiteralPath $stream.Path -Raw -ErrorAction SilentlyContinue
				if (-not [string]::IsNullOrWhiteSpace($streamText)) {
					$streamLevel = if ($stream.Name -eq "stderr") { "WARN" } else { "DEBUG" }
					Write-LogBlock -Level $streamLevel -Title "Exchange $Mode $($stream.Name)" -Text $streamText -MaxLines 100
				}
			}
		}
		if (-not (Test-Path -LiteralPath $resultPath)) {
			throw "Exchange child process produced no result file. ExitCode=$($proc.ExitCode)"
		}
		$resultJson = Get-Content -LiteralPath $resultPath -Raw -ErrorAction Stop
		if ([string]::IsNullOrWhiteSpace($resultJson)) {
			throw "Exchange child process produced an empty result file. ExitCode=$($proc.ExitCode)"
		}
		$parsed = $resultJson | ConvertFrom-Json -ErrorAction Stop
		if ($null -eq $parsed) { throw "Exchange child result could not be parsed." }
		if ($parsed.PSObject.Properties.Name -notcontains "Success") { throw "Exchange child result does not contain the required Success property." }
		if ([bool]$parsed.Success -and $proc.ExitCode -ne 0) {
			throw "Exchange child result reported success but powershell.exe exited with code $($proc.ExitCode)."
		}
		$resultForLog = $resultJson -replace '\s+', ' '
		if ($resultForLog.Length -gt 4000) { $resultForLog = $resultForLog.Substring(0, 4000) + " ...(truncated)" }
		Log-Debug "Exchange $Mode response: $resultForLog"
		if ([bool]$parsed.Success) {
			Log-Debug "Exchange $Mode response indicates success (target: $targetLabel)"
		}
		else {
			Log-Warn "Exchange $Mode response indicates failure (target: $targetLabel, exit code $($proc.ExitCode)): $($parsed.Error)"
		}
	}
	catch {
		Write-LogException -ErrorRecord $_ -Context "Exchange $Mode child exception" -Level "DEBUG"
		$childError = $_.Exception.Message
		$parsed = [PSCustomObject]@{
			Success      = $false
			Mode         = $Mode
			TargetServer = $TargetServer
			Error        = "Exchange child invocation failed. $childError"
			Data         = $null
		}
		Log-Error "Exchange $Mode child invocation failed (target: $targetLabel): $childError"
	}
	finally {
		foreach ($tmp in @($childScriptPath, $resultPath, $stdoutPath, $stderrPath)) {
			if (-not [string]::IsNullOrWhiteSpace($tmp)) {
				Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
			}
		}
	}
	return $parsed
}
function Get-NetshSslCertOutput {
	param([string]$ComputerName, [string]$IpPort = "")
	$netshArgs = @("http", "show", "sslcert")
	if ($IpPort) { $netshArgs += "ipport=$IpPort" }
	if ($ComputerName -eq $LocalServerName -or $ComputerName -eq "localhost") {
		$netsh = Invoke-NativeCapture -FilePath "netsh.exe" -Arguments $netshArgs
		Log-Debug "netsh exit code: $($netsh.ExitCode) ($ComputerName)"
		return $netsh.Output
	}
	return (Invoke-Command -ComputerName $ComputerName -ScriptBlock {
		param($a)
		$ErrorActionPreference = "Continue"
		(& netsh.exe @a 2>&1 | ForEach-Object { [string]$_ }) | Out-String
	} -ArgumentList (,$netshArgs) -ErrorAction Stop)
}
function Get-BindingThumbprint {
	param([string]$ComputerName, [int]$Port, [string]$Label)
	try {
		Log-Info "$Label binding query via: netsh http show sslcert ipport=0.0.0.0:$Port ($ComputerName)"
		$out = Get-NetshSslCertOutput -ComputerName $ComputerName -IpPort "0.0.0.0:$Port"
		Write-LogBlock -Level "DEBUG" -Title "$Label binding query response ($ComputerName)" -Text $out -MaxLines 40
		if ($out -match "Certificate Hash\s*:\s*([0-9a-fA-F]+)") {
			$hash = $Matches[1].ToUpperInvariant()
			Log-Info "$Label binding thumbprint on ${ComputerName}: $hash"
			return $hash
		}
		Log-Warn "No 'Certificate Hash' found in netsh output for 0.0.0.0:$Port on $ComputerName."
		return $null
	}
	catch {
		Write-LogException -ErrorRecord $_ -Context "$Label binding query exception" -Level "DEBUG"
		Log-Warn "Could not read $Label binding on ${ComputerName}: $($_.Exception.Message)"
		return $null
	}
}
function Get-FrontEndCertThumbprint {
	param([string]$ComputerName)
	return (Get-BindingThumbprint -ComputerName $ComputerName -Port $FrontEndPort -Label "Front End ($FrontEndPort)")
}
function Get-BackEndCertThumbprint {
	param([string]$ComputerName)
	return (Get-BindingThumbprint -ComputerName $ComputerName -Port $BackEndPort -Label "Back End ($BackEndPort, read only)")
}
function Get-HttpSysCertificateBindings {
	param([string]$ComputerName)
	try {
		Log-Info "HTTP.sys binding inventory via: netsh http show sslcert ($ComputerName)"
		$out = Get-NetshSslCertOutput -ComputerName $ComputerName
		$bindings = @()
		$currentBinding = "(unknown)"
		foreach ($line in ($out -split "\r?\n")) {
			if ($line -match '^\s*(IP:port|Hostname:port|Central Certificate Store)\s*:\s*(.+?)\s*$') {
				$currentBinding = "$($Matches[1]) $($Matches[2])"
				continue
			}
			if ($line -match 'Certificate Hash\s*:\s*([0-9a-fA-F]+)') {
				$bindings += [PSCustomObject]@{ Binding = $currentBinding; Hash = $Matches[1].ToUpperInvariant() }
			}
		}
		Log-Info "HTTP.sys binding inventory response: $($bindings.Count) certificate binding(s) on $ComputerName"
		foreach ($b in $bindings) { Log-Debug "  $($b.Binding) -> $($b.Hash)" }
		if ($bindings.Count -eq 0) {
			Log-Warn "HTTP.sys binding inventory on $ComputerName returned no certificate bindings; treating as unreadable."
			return $null
		}
		return $bindings
	}
	catch {
		Write-LogException -ErrorRecord $_ -Context "HTTP.sys binding inventory exception" -Level "DEBUG"
		Log-Warn "Could not read HTTP.sys binding inventory on ${ComputerName}: $($_.Exception.Message)"
		return $null
	}
}
function Test-CertificateInMachineStore {
	param([string]$ComputerName, [string]$Thumbprint)
	try {
		if ($ComputerName -eq $LocalServerName) {
			return [bool](Test-Path -LiteralPath "Cert:\LocalMachine\My\$Thumbprint")
		}
		return [bool](Invoke-Command -ComputerName $ComputerName -ScriptBlock {
			param($t)
			Test-Path -LiteralPath "Cert:\LocalMachine\My\$t"
		} -ArgumentList $Thumbprint -ErrorAction Stop)
	}
	catch {
		Write-LogException -ErrorRecord $_ -Context "Certificate store check exception" -Level "DEBUG"
		return $null
	}
}
function Save-CertificatePublicCopy {
	param([string]$ComputerName, [string]$Thumbprint, [string]$DestinationPath)
	try {
		if ($ComputerName -eq $LocalServerName) {
			$raw = (Get-Item -LiteralPath "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction Stop).RawData
		}
		else {
			$raw = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
				param($t)
				,((Get-Item -LiteralPath "Cert:\LocalMachine\My\$t" -ErrorAction Stop).RawData)
			} -ArgumentList $Thumbprint -ErrorAction Stop
		}
		[System.IO.File]::WriteAllBytes($DestinationPath, [byte[]]$raw)
		return $true
	}
	catch {
		Write-LogException -ErrorRecord $_ -Context "Public certificate copy exception" -Level "DEBUG"
		return $false
	}
}
function Test-HttpsEndpoint {
	param(
		[string]$Url,
		[string]$Label,
		[string]$ExpectedThumbprint = ""
	)
	$prevCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
	$httpTimer = [System.Diagnostics.Stopwatch]::StartNew()
	$req = $null
	try {
		[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
		$req = [System.Net.HttpWebRequest]([System.Net.WebRequest]::Create($Url))
		$req.Timeout = 15000
		$req.Method = "GET"
		$req.KeepAlive = $false
		$req.AllowAutoRedirect = $false
		Log-Info "$Label probe via: $Url"
		$resp = [System.Net.HttpWebResponse]$req.GetResponse()
		try {
			$statusCode = [int]$resp.StatusCode
			Log-Info "$Label probe HTTP status: $statusCode ($($httpTimer.ElapsedMilliseconds) ms)"
			Log-Debug "$Label probe response: Server=$($resp.Headers['Server']) Location=$($resp.Headers['Location'])"
			if ($statusCode -ge 200 -and $statusCode -lt 400) {
				Log-Info "$Label probe response indicates success"
				return $true
			}
			Log-Error "$Label probe returned unexpected HTTP $statusCode."
			return $false
		}
		finally {
			$resp.Close()
		}
	}
	catch [System.Net.WebException] {
		$webResponse = $_.Exception.Response
		if ($webResponse) {
			try {
				$statusCode = [int]$webResponse.StatusCode
				Log-Info "$Label probe HTTP status: $statusCode ($($httpTimer.ElapsedMilliseconds) ms)"
				if ($statusCode -eq 401 -or $statusCode -eq 403) {
					Log-Info "$Label probe response indicates success (authentication required)"
					return $true
				}
				Log-Error "$Label probe returned HTTP $statusCode."
				return $false
			}
			finally {
				$webResponse.Close()
			}
		}
		Write-LogException -ErrorRecord $_ -Context "$Label probe exception" -Level "DEBUG"
		Log-Error "$Label probe did not return an HTTP response ($($_.Exception.Status)): $($_.Exception.Message)"
		return $false
	}
	catch {
		Write-LogException -ErrorRecord $_ -Context "$Label probe exception" -Level "DEBUG"
		Log-Error "$Label probe failed: $($_.Exception.Message)"
		return $false
	}
	finally {
		[System.Net.ServicePointManager]::ServerCertificateValidationCallback = $prevCallback
	}
}
function Test-OwaEcp {
	param([string]$ServerName, [string]$ExpectedThumbprint)
	$owaOk = Test-HttpsEndpoint -Url "https://$ServerName/owa" -Label "OWA ($ServerName)" -ExpectedThumbprint $ExpectedThumbprint
	$ecpOk = Test-HttpsEndpoint -Url "https://$ServerName/ecp" -Label "ECP ($ServerName)" -ExpectedThumbprint $ExpectedThumbprint
	return [PSCustomObject]@{ Owa = $owaOk; Ecp = $ecpOk; Success = ($owaOk -and $ecpOk) }
}
function Restart-ServiceBounded {
	param(
		[string]$ComputerName,
		[string]$ServiceName,
		[int]$StopTimeoutSeconds,
		[int]$StartTimeoutSeconds,
		[bool]$RestartOnlyIfRunning = $false
	)
	$restartScript = {
		param([string]$ServiceName, [int]$StopTimeoutSeconds, [int]$StartTimeoutSeconds, [bool]$RestartOnlyIfRunning)
		Add-Type -AssemblyName System.ServiceProcess -ErrorAction Stop
		$controller = $null
		$S = [System.ServiceProcess.ServiceControllerStatus]
		try {
			$controller = New-Object System.ServiceProcess.ServiceController -ArgumentList $ServiceName
			$controller.Refresh()
			$initialStatus = $controller.Status.ToString()
			if ($RestartOnlyIfRunning -and ($controller.Status -eq $S::Stopped -or $controller.Status -eq $S::StopPending)) {
				if ($controller.Status -eq $S::StopPending) {
					$controller.WaitForStatus($S::Stopped, [TimeSpan]::FromSeconds($StopTimeoutSeconds))
					$controller.Refresh()
				}
				return [PSCustomObject]@{ Success = $true; Skipped = $true; ServiceName = $ServiceName; InitialStatus = $initialStatus; FinalStatus = $controller.Status.ToString(); Error = $null }
			}
			if ($controller.Status -eq $S::StartPending) {
				$controller.WaitForStatus($S::Running, [TimeSpan]::FromSeconds($StartTimeoutSeconds))
				$controller.Refresh()
			}
			if ($controller.Status -ne $S::Stopped) {
				if ($controller.Status -ne $S::StopPending) { $controller.Stop() }
				$controller.WaitForStatus($S::Stopped, [TimeSpan]::FromSeconds($StopTimeoutSeconds))
				$controller.Refresh()
			}
			if ($controller.Status -ne $S::Stopped) {
				throw "$ServiceName did not reach Stopped state within $StopTimeoutSeconds seconds."
			}
			$controller.Start()
			$controller.WaitForStatus($S::Running, [TimeSpan]::FromSeconds($StartTimeoutSeconds))
			$controller.Refresh()
			if ($controller.Status -ne $S::Running) {
				throw "$ServiceName did not reach Running state within $StartTimeoutSeconds seconds."
			}
			$extra = ""
			if ($ServiceName -eq "W3SVC") {
				$was = Get-Service WAS -ErrorAction Stop
				if ($was.Status -ne "Running") { throw "IIS verification failed. W3SVC=$($controller.Status) WAS=$($was.Status)" }
				$extra = "WAS=$($was.Status)"
			}
			return [PSCustomObject]@{ Success = $true; Skipped = $false; ServiceName = $ServiceName; InitialStatus = $initialStatus; FinalStatus = $controller.Status.ToString(); Error = $null; Extra = $extra }
		}
		finally {
			if ($null -ne $controller) { $controller.Dispose() }
		}
	}
	$restartTimer = [System.Diagnostics.Stopwatch]::StartNew()
	Log-Info "$ServiceName restart via: ServiceController on $ComputerName (stop timeout ${StopTimeoutSeconds}s, start timeout ${StartTimeoutSeconds}s$(if ($RestartOnlyIfRunning) { ', only if running' }))"
	try {
		if ($ComputerName -eq $LocalServerName -or $ComputerName -eq "localhost") {
			$r = & $restartScript $ServiceName $StopTimeoutSeconds $StartTimeoutSeconds $RestartOnlyIfRunning
		}
		else {
			$r = Invoke-Command -ComputerName $ComputerName -ScriptBlock $restartScript `
				-ArgumentList $ServiceName, $StopTimeoutSeconds, $StartTimeoutSeconds, $RestartOnlyIfRunning -ErrorAction Stop
		}
		Log-Info "$ServiceName restart status: Initial=$($r.InitialStatus) Final=$($r.FinalStatus) Skipped=$($r.Skipped) $($r.Extra) ($($restartTimer.ElapsedMilliseconds) ms)"
		return $r
	}
	catch {
		Write-LogException -ErrorRecord $_ -Context "$ServiceName restart exception" -Level "DEBUG"
		Log-Info "$ServiceName restart status: FAILED on $ComputerName after $($restartTimer.ElapsedMilliseconds) ms"
		return [PSCustomObject]@{ Success = $false; Skipped = $false; ServiceName = $ServiceName; InitialStatus = $null; FinalStatus = $null; Error = $_.Exception.Message }
	}
}
function Invoke-ExchangeServiceReload {
	param(
		[string]$ServerName,
		[string]$ExpectedFrontEndThumbprint,
		[string]$Purpose
	)
	$result   = [PSCustomObject]@{ Success = $false; Error = $null }
	$expected = $ExpectedFrontEndThumbprint.ToUpperInvariant()
	if ($ManagesIIS) {
		$frontEnd = Get-FrontEndCertThumbprint -ComputerName $ServerName
		if ($frontEnd -and $frontEnd -eq $expected) {
			Log-Info "Front End ($FrontEndPort) on $ServerName already uses $expected ($Purpose). W3SVC restart not required."
		}
		else {
			if ($frontEnd) { Log-Info "Front End ($FrontEndPort) on $ServerName has not switched yet ($Purpose). Current=$frontEnd Expected=$expected. Performing bounded W3SVC restart..." }
			else           { Log-Info "Front End ($FrontEndPort) on $ServerName could not be verified before IIS reload ($Purpose). Performing bounded W3SVC restart..." }
			$w3 = Restart-ServiceBounded -ComputerName $ServerName -ServiceName "W3SVC" -StopTimeoutSeconds $IisStopTimeoutSeconds -StartTimeoutSeconds $IisStartTimeoutSeconds
			if (-not $w3.Success) {
				$result.Error = "Bounded W3SVC restart failed on $ServerName during $Purpose. $($w3.Error)"
				return $result
			}
			Log-Success "W3SVC restarted on $ServerName ($Purpose)"
		}
	}
	else {
		Log-Info "IIS not selected (EXCHANGE_SERVICES=$ExchangeServices): W3SVC not restarted on $ServerName ($Purpose)."
	}
	if ($ManagesSMTP) {
		$requiredServices = @("MSExchangeTransport")
		if ($RestartFrontEndTransport) { $requiredServices += "MSExchangeFrontEndTransport" }
		foreach ($svc in $requiredServices) {
			$r = Restart-ServiceBounded -ComputerName $ServerName -ServiceName $svc -StopTimeoutSeconds $TransportStopTimeoutSeconds -StartTimeoutSeconds $TransportStartTimeoutSeconds
			if (-not $r.Success) {
				$result.Error = "Required service $svc restart failed on $ServerName during $Purpose. $($r.Error)"
				return $result
			}
			Log-Success "$svc restarted on $ServerName ($Purpose)"
		}
	}
	else {
		Log-Info "SMTP not selected (EXCHANGE_SERVICES=$ExchangeServices): Transport services not restarted on $ServerName ($Purpose)."
	}
	foreach ($optional in @(@{ Code = "IMAP"; Service = "MSExchangeImap4" }, @{ Code = "POP"; Service = "MSExchangePop3" })) {
		$svc = $optional.Service
		if ($SelectedExchangeServices -notcontains $optional.Code) {
			Log-Debug "$($optional.Code) not selected: $svc not restarted on $ServerName ($Purpose)."
			continue
		}
		$r = Restart-ServiceBounded -ComputerName $ServerName -ServiceName $svc -StopTimeoutSeconds $OptionalServiceStopTimeoutSeconds -StartTimeoutSeconds $OptionalServiceStartTimeoutSeconds -RestartOnlyIfRunning $true
		if (-not $r.Success)  { Log-Warn "Optional service $svc could not be restarted on ${ServerName} ($Purpose): $($r.Error)" }
		elseif ($r.Skipped)   { Log-Info "Optional service $svc is not running on $ServerName. Restart skipped." }
		else                  { Log-Success "$svc restarted on $ServerName ($Purpose)" }
	}
	$result.Success = $true
	Log-Success "Exchange service reload completed on $ServerName ($Purpose)"
	return $result
}
function Import-CertificateToRemoteServer {
	param(
		[string]$ServerName,
		[string]$PfxFilePath,
		[string]$PfxFileName,
		[string]$PfxPassword,
		[string]$ExpectedThumbprint
	)
	$remotePfxDest  = "\\$ServerName\C$\Windows\Temp\$PfxFileName"
	$remoteLocalPfx = "C:\Windows\Temp\$PfxFileName"
	Log-Info "Step R1 (${ServerName}): Copying PFX to secondary staging path..."
	Log-Info "PFX copy via: SMB $remotePfxDest"
	try {
		$copyTimer = [System.Diagnostics.Stopwatch]::StartNew()
		Copy-Item -LiteralPath $PfxFilePath -Destination $remotePfxDest -Force
		$remoteSize = (Get-Item -LiteralPath $remotePfxDest -ErrorAction Stop).Length
		$localSize  = (Get-Item -LiteralPath $PfxFilePath -ErrorAction Stop).Length
		Log-Info "PFX copy status: local size $localSize bytes, remote size $remoteSize bytes ($($copyTimer.ElapsedMilliseconds) ms)"
		if ($remoteSize -ne $localSize) { throw "Remote PFX size mismatch after copy. Local=$localSize Remote=$remoteSize" }
		try {
			$icacls = Invoke-NativeCapture -FilePath "icacls.exe" -Arguments @($remotePfxDest, "/grant:r", "SYSTEM:F", "BUILTIN\Administrators:F")
			Log-Debug "icacls /grant:r exit code: $($icacls.ExitCode) output: $($icacls.Output.Trim() -replace '\r?\n', ' ')"
			if ($icacls.ExitCode -ne 0) { throw "icacls /grant:r returned exit code $($icacls.ExitCode)." }
			$icacls = Invoke-NativeCapture -FilePath "icacls.exe" -Arguments @($remotePfxDest, "/inheritance:r")
			Log-Debug "icacls /inheritance:r exit code: $($icacls.ExitCode) output: $($icacls.Output.Trim() -replace '\r?\n', ' ')"
			if ($icacls.ExitCode -ne 0) { throw "icacls /inheritance:r returned exit code $($icacls.ExitCode)." }
			Log-Info "Restricted ACL on '$remotePfxDest' to SYSTEM and Administrators"
		}
		catch {
			Write-LogException -ErrorRecord $_ -Context "Remote PFX ACL exception" -Level "DEBUG"
			Log-Warn "Could not fully verify ACL restriction on temporary PFX on ${ServerName}: $($_.Exception.Message)"
		}
		Log-Success "PFX staged on $ServerName"
	}
	catch {
		Write-LogException -ErrorRecord $_ -Context "Remote PFX copy exception" -Level "DEBUG"
		Log-Error "Failed to copy PFX to ${ServerName}: $($_.Exception.Message)"
		Remove-Item -LiteralPath $remotePfxDest -Force -ErrorAction SilentlyContinue
		return $false
	}
	Log-Info "Step R2 (${ServerName}): Importing PFX on secondary..."
	Log-Info "Import-PfxCertificate via: WinRM Invoke-Command to $ServerName (Cert:\LocalMachine\My)"
	try {
		$importTimer = [System.Diagnostics.Stopwatch]::StartNew()
		$remoteVerification = Invoke-Command -ComputerName $ServerName -ScriptBlock {
			param($pfxPath, $pfxPass, $expectedThumb, $exportable)
			$secure = ConvertTo-SecureString -String $pfxPass -Force -AsPlainText
			$p = @{ FilePath = $pfxPath; CertStoreLocation = "Cert:\LocalMachine\My"; Password = $secure; ErrorAction = "Stop" }
			if ($exportable) { $p["Exportable"] = $true }
			$importedCertificates = @(Import-PfxCertificate @p)
			if ($importedCertificates.Count -eq 0) { throw "Import-PfxCertificate returned no certificates." }
			$expectedThumb = $expectedThumb.ToUpper()
			$importedLeaf = $importedCertificates | Where-Object { $_.Thumbprint -and ($_.Thumbprint.ToUpper() -eq $expectedThumb) } | Select-Object -First 1
			if (-not $importedLeaf) { throw "Expected certificate was not returned by Import-PfxCertificate. Expected=$expectedThumb" }
			$storeCertificate = Get-Item -Path "Cert:\LocalMachine\My\$expectedThumb" -ErrorAction Stop
			if (-not $storeCertificate.HasPrivateKey) { throw "Imported certificate exists in LocalMachine\My but does not have its private key." }
			return [PSCustomObject]@{
				Thumbprint    = $storeCertificate.Thumbprint
				HasPrivateKey = $storeCertificate.HasPrivateKey
				ComputerName  = $env:COMPUTERNAME
				Imported      = @($importedCertificates | ForEach-Object { "Thumbprint=$($_.Thumbprint) HasPrivateKey=$($_.HasPrivateKey) Subject=$($_.Subject)" })
			}
		} -ArgumentList $remoteLocalPfx, $PfxPassword, $ExpectedThumbprint, $ImportKeyExportable -ErrorAction Stop
		if (-not $remoteVerification) { throw "Remote certificate verification returned no result." }
		Log-Info "Import-PfxCertificate response: $(@($remoteVerification.Imported).Count) certificate(s) on $($remoteVerification.ComputerName) ($($importTimer.ElapsedMilliseconds) ms)"
		foreach ($ri in @($remoteVerification.Imported)) { Log-Debug "  Imported: $ri" }
		if ($remoteVerification.Thumbprint.ToUpper() -ne $ExpectedThumbprint.ToUpper()) {
			throw "Remote imported thumbprint does not match expected certificate. Expected=$ExpectedThumbprint Actual=$($remoteVerification.Thumbprint)"
		}
		if (-not $remoteVerification.HasPrivateKey) { throw "Remote imported certificate does not contain its private key." }
		Log-Info "Import-PfxCertificate response indicates success"
		Log-Success "Certificate $($remoteVerification.Thumbprint) imported on $ServerName with private key"
	}
	catch {
		Write-LogException -ErrorRecord $_ -Context "Remote import exception" -Level "DEBUG"
		Log-Error "Failed to import/verify certificate on ${ServerName}: $($_.Exception.Message)"
		Invoke-Command -ComputerName $ServerName -ScriptBlock { param($p) Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } `
			-ArgumentList $remoteLocalPfx -ErrorAction SilentlyContinue
		return $false
	}
	Log-Info "Step R3 (${ServerName}): Deleting temporary PFX..."
	try {
		$tempRemoved = Invoke-Command -ComputerName $ServerName -ScriptBlock {
			param($p)
			Remove-Item -LiteralPath $p -Force -ErrorAction Stop
			return (-not (Test-Path -LiteralPath $p))
		} -ArgumentList $remoteLocalPfx -ErrorAction Stop
		if (-not $tempRemoved) { throw "Temporary PFX still exists after removal attempt." }
		Log-Info "Cleaned up temporary PFX file on $ServerName"
	}
	catch {
		Write-LogException -ErrorRecord $_ -Context "Remote PFX cleanup exception" -Level "DEBUG"
		Log-Critical "Could not remove temporary PFX from $ServerName. Aborting before Exchange activation. $($_.Exception.Message)"
		return $false
	}
	return $true
}
function Restore-PreviousCertificate {
	param(
		[string]$ServerName,
		[string]$Services,
		[string]$TargetParam,
		[string]$PreviousThumbprint,
		[AllowEmptyString()]
		[string]$ExpectedBackEndThumbprint
	)
	$rollbackTimer  = [System.Diagnostics.Stopwatch]::StartNew()
	$rollbackResult = [PSCustomObject]@{ Success = $false; ServerName = $ServerName; Error = $null }
	Log-Warn "ROLLBACK START on ${ServerName}: restore $PreviousThumbprint (Back End $BackEndPort baseline $ExpectedBackEndThumbprint, services $Services)"
	if (-not $PreviousThumbprint) {
		$rollbackResult.Error = "No previous thumbprint was captured."
		Log-Critical "No previous thumbprint was captured for $ServerName - cannot auto-rollback. Manual intervention required."
		return $rollbackResult
	}
	Log-Info "Step RB1 (${ServerName}): Verifying Back End ($BackEndPort) matches baseline before rollback..."
	if ([string]::IsNullOrWhiteSpace($ExpectedBackEndThumbprint)) {
		$rollbackResult.Error = "No Back End ($BackEndPort) baseline was supplied."
		Log-Critical "No Back End ($BackEndPort) baseline is available for $ServerName. Public certificate rollback will NOT be attempted. Manual intervention required."
		return $rollbackResult
	}
	$backEndBeforeRollback = Get-BackEndCertThumbprint -ComputerName $ServerName
	if (-not $backEndBeforeRollback) {
		$rollbackResult.Error = "Could not read Back End ($BackEndPort) before rollback."
		Log-Critical "Could not read Back End ($BackEndPort) on $ServerName before rollback. Backend state is unknown. Public certificate rollback will NOT be attempted."
		return $rollbackResult
	}
	if ($backEndBeforeRollback -ne $ExpectedBackEndThumbprint.ToUpperInvariant()) {
		$rollbackResult.Error = "Back End ($BackEndPort) is not at the expected baseline. Expected=$ExpectedBackEndThumbprint Actual=$backEndBeforeRollback"
		Log-Critical "Back End ($BackEndPort) on $ServerName differs from the protected baseline. Expected=$ExpectedBackEndThumbprint Actual=$backEndBeforeRollback. NOT modifying port 444 or the public certificate automatically."
		return $rollbackResult
	}
	Log-Success "Rollback safety verified: Back End ($BackEndPort) on $ServerName still matches baseline $backEndBeforeRollback"
	Log-Info "Step RB2 (${ServerName}): Re-enabling previous certificate..."
	$rb = Invoke-ExchangeChild -Mode "Rollback" -Services $Services -TargetServer $TargetParam -PreviousThumbprint $PreviousThumbprint
	if (-not $rb.Success) {
		$rollbackResult.Error = "Enable-ExchangeCertificate rollback failed. $($rb.Error)"
		Log-Critical "Rollback FAILED on $ServerName. $($rb.Error). Manual intervention required immediately."
		return $rollbackResult
	}
	Log-Info "Step RB3 (${ServerName}): Validating service assignment on rollback certificate..."
	$rollbackValidation = Invoke-ExchangeChild -Mode "Validate" -Thumbprint $PreviousThumbprint -Services $Services -TargetServer $TargetParam
	if (-not $rollbackValidation.Success) {
		$rollbackResult.Error = "Rollback certificate service validation failed. $($rollbackValidation.Error)"
		Log-Critical "Rollback certificate service validation failed on ${ServerName}: $($rollbackValidation.Error)"
		return $rollbackResult
	}
	Log-Info "Step RB4 (${ServerName}): Reloading Exchange services after rollback..."
	$reload = Invoke-ExchangeServiceReload -ServerName $ServerName -ExpectedFrontEndThumbprint $PreviousThumbprint -Purpose "rollback"
	if (-not $reload.Success) {
		$rollbackResult.Error = $reload.Error
		Log-Critical $reload.Error
		return $rollbackResult
	}
	Log-Info "Step RB5 (${ServerName}): Verifying Front End ($FrontEndPort) returned to previous certificate..."
	if ($ManagesIIS) {
		$frontEndAfterRollback = Get-FrontEndCertThumbprint -ComputerName $ServerName
		if (-not $frontEndAfterRollback -or $frontEndAfterRollback -ne $PreviousThumbprint.ToUpperInvariant()) {
			$rollbackResult.Error = "Front End ($FrontEndPort) rollback verification failed. Expected=$($PreviousThumbprint.ToUpperInvariant()) Actual=$frontEndAfterRollback"
			Log-Critical "Front End ($FrontEndPort) rollback verification FAILED on $ServerName. Expected=$($PreviousThumbprint.ToUpperInvariant()) Actual=$frontEndAfterRollback"
			return $rollbackResult
		}
		Log-Success "Front End ($FrontEndPort) restored on $ServerName to $frontEndAfterRollback"
	}
	else {
		Log-Info "IIS not selected: Front End ($FrontEndPort) was not changed; verification not applicable."
	}
	Log-Info "Step RB6 (${ServerName}): Verifying Back End ($BackEndPort) unchanged after rollback..."
	$backEndAfterRollback = Get-BackEndCertThumbprint -ComputerName $ServerName
	if (-not $backEndAfterRollback -or $backEndAfterRollback -ne $ExpectedBackEndThumbprint.ToUpperInvariant()) {
		$rollbackResult.Error = "Back End ($BackEndPort) changed or unreadable after rollback. Expected=$ExpectedBackEndThumbprint Actual=$backEndAfterRollback"
		Log-Critical "Back End ($BackEndPort) changed or unreadable after rollback on $ServerName. Expected=$ExpectedBackEndThumbprint Actual=$backEndAfterRollback. NOT modifying port 444 automatically."
		return $rollbackResult
	}
	Log-Success "Back End ($BackEndPort) unchanged during rollback on $ServerName ($backEndAfterRollback)"
	$rollbackResult.Success = $true
	Log-Success "ROLLBACK VERIFIED: $ServerName restored to certificate $PreviousThumbprint ($($rollbackTimer.ElapsedMilliseconds) ms)"
	return $rollbackResult
}
function Deploy-CertificateToServer {
	param(
		[string]$ServerName,
		[string]$Services,
		[bool]$IsLocal
	)
	$targetParam = if ($IsLocal) { "" } else { $ServerName }
	$newThumb    = $thumbprint.ToUpperInvariant()
	$deploymentResult = [PSCustomObject]@{
		Success            = $false
		ServerName         = $ServerName
		PreviousThumbprint = $null
		BackEndBaseline    = $null
		Error              = $null
	}
	Log-Info "Deployment target:"
	Log-Info "  Server: $ServerName$(if ($IsLocal) { ' (local)' } else { ' (remote)' })"
	Log-Info "  Services: $Services"
	Log-Info "  New certificate thumbprint: $newThumb"
	$invokeRollback = {
		param($PreviousThumbprint, $BackEndBaseline)
		$rollbackAttempt = Restore-PreviousCertificate -ServerName $ServerName -Services $Services -TargetParam $targetParam `
			-PreviousThumbprint $PreviousThumbprint -ExpectedBackEndThumbprint $BackEndBaseline
		if (-not $rollbackAttempt.Success) {
			$deploymentResult.Error = "$($deploymentResult.Error) Rollback failed: $($rollbackAttempt.Error)"
			Log-Critical "Verified rollback could not be completed on $ServerName. Manual intervention required."
		}
		else {
			Log-Info "RECOVERY VERIFIED: previous public certificate state restored on $ServerName"
		}
	}
	Log-Info "Step 7a (${ServerName}): Snapshotting Exchange certificate state and live Front End ($FrontEndPort) binding..."
	if ($script:NodeSnapshots -and $script:NodeSnapshots.ContainsKey($ServerName)) {
		$snap = $script:NodeSnapshots[$ServerName]
		Log-Info "Using the readiness snapshot of $ServerName (no Exchange change since)."
	}
	else { $snap = Invoke-ExchangeChild -Mode "Snapshot" -TargetServer $targetParam }
	if (-not $snap.Success) {
		$deploymentResult.Error = "Could not snapshot existing certificate state. $($snap.Error)"
		Log-Error "Could not snapshot existing certificate state on ${ServerName}: $($snap.Error)"
		return $deploymentResult
	}
	Log-Info "Exchange certificate snapshot: $(@($snap.Data).Count) certificate(s) on $ServerName"
	$frontEndBaseline = Get-FrontEndCertThumbprint -ComputerName $ServerName
	if ($ManagesIIS) {
		if (-not $frontEndBaseline) {
			$deploymentResult.Error = "Could not determine existing Front End ($FrontEndPort) certificate."
			Log-Critical "Could not determine existing Front End ($FrontEndPort) certificate on $ServerName. Aborting before certificate change."
			return $deploymentResult
		}
		$previousThumbprint = $frontEndBaseline
		Log-Info "Baseline Front End ($FrontEndPort) thumbprint on ${ServerName}: $previousThumbprint (rollback source)"
	}
	else {
		Log-Info "Baseline Front End ($FrontEndPort) thumbprint on ${ServerName}: $frontEndBaseline (not changed - IIS not selected)"
		$previousThumbprint = Select-PreviousServiceCertificate -SnapshotData $snap.Data -Services $Services `
			-NewThumbprint $newThumb -FallbackThumbprint $frontEndBaseline -ServerName $ServerName
		if (-not $previousThumbprint) {
			$deploymentResult.Error = "Could not determine the previous certificate for services $Services."
			Log-Critical "Could not determine the previous certificate for services $Services on $ServerName. Aborting before certificate change."
			return $deploymentResult
		}
	}
	$deploymentResult.PreviousThumbprint = $previousThumbprint
	Log-Info "Step 7b (${ServerName}): Capturing protected Back End ($BackEndPort) baseline (read only)..."
	$backEndBaseline = Get-BackEndCertThumbprint -ComputerName $ServerName
	if (-not $backEndBaseline) {
		$deploymentResult.Error = "Could not establish Back End ($BackEndPort) baseline."
		Log-Critical "Could not establish Back End ($BackEndPort) baseline on $ServerName. Aborting."
		return $deploymentResult
	}
	$deploymentResult.BackEndBaseline = $backEndBaseline
	Log-Info "Baseline Back End ($BackEndPort) thumbprint on ${ServerName}: $backEndBaseline"
	Log-Info "Step 7c (${ServerName}): Enabling new certificate for $Services..."
	$enable = Invoke-ExchangeChild -Mode "Enable" -Thumbprint $thumbprint -Services $Services -TargetServer $targetParam
	if (-not $enable.Success) {
		$deploymentResult.Error = "Enable-ExchangeCertificate failed. $($enable.Error)"
		Log-Error "Enable-ExchangeCertificate failed on ${ServerName}: $($enable.Error)"
		Log-Warn "Service-assignment state may be partial. Attempting verified rollback to the previously active public certificate."
		& $invokeRollback $previousThumbprint $backEndBaseline
		return $deploymentResult
	}
	Log-Success "Enable-ExchangeCertificate completed on $ServerName"
	Log-Info "Step 7d (${ServerName}): Validating service assignment on new certificate..."
	$validate = Invoke-ExchangeChild -Mode "Validate" -Thumbprint $thumbprint -Services $Services -TargetServer $targetParam
	if (-not $validate.Success) {
		$deploymentResult.Error = "Post-enable validation failed. $($validate.Error)"
		Log-Error "Post-enable validation failed on ${ServerName}: $($validate.Error). Rolling back."
		& $invokeRollback $previousThumbprint $backEndBaseline
		return $deploymentResult
	}
	Log-Success "New certificate carries services $($validate.Data) on $ServerName"
	Log-Info "Step 7e (${ServerName}): Reloading Exchange services..."
	$reload = Invoke-ExchangeServiceReload -ServerName $ServerName -ExpectedFrontEndThumbprint $thumbprint -Purpose "deployment"
	if (-not $reload.Success) {
		$deploymentResult.Error = $reload.Error
		Log-Error "$($reload.Error) Attempting verified rollback."
		& $invokeRollback $previousThumbprint $backEndBaseline
		return $deploymentResult
	}
	Log-Info "Step 7f (${ServerName}): Verifying Back End ($BackEndPort) unchanged (before any rollback decision)..."
	$backEndAfter = Get-BackEndCertThumbprint -ComputerName $ServerName
	if (-not $backEndAfter) {
		$deploymentResult.Error = "Could not read Back End ($BackEndPort) binding after deployment."
		Log-Critical "Could not read Back End ($BackEndPort) on $ServerName after deployment. Backend state is unknown. Public certificate rollback will NOT be attempted. Manual investigation required."
		return $deploymentResult
	}
	if ($backEndAfter -ne $backEndBaseline) {
		$deploymentResult.Error = "Back End ($BackEndPort) certificate changed unexpectedly. Baseline=$backEndBaseline Actual=$backEndAfter"
		Log-Critical "Back End ($BackEndPort) certificate CHANGED on $ServerName (was $backEndBaseline, now $backEndAfter). NOT modifying port 444 or rolling back automatically. Manual investigation required immediately."
		return $deploymentResult
	}
	Log-Success "Back End ($BackEndPort) binding unchanged on $ServerName ($backEndAfter)"
	Log-Info "Step 7g (${ServerName}): Verifying live Front End ($FrontEndPort) uses the new certificate..."
	if ($ManagesIIS) {
		$frontEndAfter = Get-FrontEndCertThumbprint -ComputerName $ServerName
		if (-not $frontEndAfter -or $frontEndAfter -ne $newThumb) {
			$deploymentResult.Error = "Front End ($FrontEndPort) is not using the new certificate. Expected=$newThumb Actual=$frontEndAfter"
			Log-Error "Front End ($FrontEndPort) on $ServerName is not using the new certificate. Expected=$newThumb Actual=$frontEndAfter. Back End verified unchanged; rolling back."
			& $invokeRollback $previousThumbprint $backEndBaseline
			return $deploymentResult
		}
		Log-Success "Front End ($FrontEndPort) on $ServerName is using the new certificate ($frontEndAfter)"
	}
	else {
		Log-Info "IIS not selected: Front End ($FrontEndPort) intentionally unchanged on $ServerName."
	}
	Log-Info "Step 7h (${ServerName}): Running Exchange health checks..."
	$health = Invoke-ExchangeChild -Mode "HealthCheck" -TargetServer $targetParam
	if (-not $health.Success) {
		$deploymentResult.Error = "Exchange health check failed. Mailflow=$($health.Data.MailflowResult) UnhealthyRoles=$(@($health.Data.UnhealthyRoles) -join ',') $($health.Error)"
		Log-Error "Health check failed on ${ServerName}: Mailflow=$($health.Data.MailflowResult) UnhealthyRoles=$(@($health.Data.UnhealthyRoles) -join ','). Rolling back."
		& $invokeRollback $previousThumbprint $backEndBaseline
		return $deploymentResult
	}
	Log-Success "Exchange health checks passed on $ServerName (Mailflow=$($health.Data.MailflowResult))"
	Log-Info "Step 7i (${ServerName}): Probing OWA/ECP..."
	$probe = Test-OwaEcp -ServerName $ServerName -ExpectedThumbprint $(if ($ManagesIIS) { $thumbprint } else { "" })
	if (-not $probe.Success) {
		$deploymentResult.Error = "OWA/ECP reachability check failed. OWA=$($probe.Owa) ECP=$($probe.Ecp)"
		Log-Error "OWA/ECP reachability check failed on $ServerName (OWA=$($probe.Owa) ECP=$($probe.Ecp)). Rolling back."
		& $invokeRollback $previousThumbprint $backEndBaseline
		return $deploymentResult
	}
	$deploymentResult.Success = $true
	Log-Success "Certificate $newThumb is live and validated on $ServerName"
	return $deploymentResult
}
function Invoke-CoordinatedRollback {
	param(
		[string]$Reason,
		[object]$HybridSnapshotData,
		[string]$OldLocalThumbprint,
		[string]$OldLocalBackEndThumbprint,
		[string]$OldRemoteThumbprint,
		[string]$OldRemoteBackEndThumbprint,
		[bool]$IncludeRemote = $false
	)
	Complete-Section -Status "FAIL" -Detail "Triggered coordinated rollback"
	Start-Section -Id "S17" -Name "Coordinated rollback (Hybrid and managed nodes)"
	$rollbackResult = [PSCustomObject]@{
		Success         = $false
		HybridRestored  = $false
		RemoteRestored  = $false
		LocalRestored   = $false
		FinalValidation = $false
		Errors          = @()
	}
	Log-Info "Rollback reason: $Reason"
	Log-Info "Rollback scope: Hybrid=$HybridEnabled IncludeRemote=$IncludeRemote NodeMode=$NodeMode"
	Log-Info "Step CR1: Restoring Hybrid TLS state (connectors and Hybrid Configuration)..."
	if ($HybridIsEnabled) {
		try {
			if (-not $HybridSnapshotData) { throw "No captured Hybrid snapshot is available." }
			$restoreJson        = $HybridSnapshotData | ConvertTo-Json -Depth 8 -Compress
			$restoreStateBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($restoreJson))
			$hybridRestore = Invoke-ExchangeChild -Mode "HybridRestore" -HybridRestoreStateBase64 $restoreStateBase64
			if (-not $hybridRestore.Success) { throw $hybridRestore.Error }
			$rollbackResult.HybridRestored = $true
			Log-Success "Hybrid TLS state restored and verified"
		}
		catch {
			Write-LogException -ErrorRecord $_ -Context "Hybrid restore exception" -Level "DEBUG"
			$rollbackResult.Errors += "Hybrid restore failed: $($_.Exception.Message)"
			Log-Critical "Coordinated rollback could not fully restore Hybrid TLS state. $($_.Exception.Message)"
		}
	}
	else {
		$rollbackResult.HybridRestored = $true
		Log-Info "Hybrid not managed ($HybridDisabledReason). Hybrid restore not applicable."
	}
	Log-Info "Step CR2: Restoring secondary public certificate..."
	if ($IncludeRemote) {
		try {
			$remoteRollback = Restore-PreviousCertificate -ServerName $RemoteExchangeServer -Services $RemoteServices -TargetParam $RemoteExchangeServer `
				-PreviousThumbprint $OldRemoteThumbprint -ExpectedBackEndThumbprint $OldRemoteBackEndThumbprint
			if (-not $remoteRollback.Success) { throw $remoteRollback.Error }
			$rollbackResult.RemoteRestored = $true
		}
		catch {
			Write-LogException -ErrorRecord $_ -Context "Secondary rollback exception" -Level "DEBUG"
			$rollbackResult.Errors += "$RemoteExchangeServer rollback failed: $($_.Exception.Message)"
			Log-Critical "Coordinated rollback failed on ${RemoteExchangeServer}: $($_.Exception.Message)"
		}
	}
	else {
		$rollbackResult.RemoteRestored = $true
		Log-Info "Secondary node not in scope (NodeMode=$NodeMode). Skipped."
	}
	Log-Info "Step CR3: Restoring primary public certificate..."
	try {
		$localRollback = Restore-PreviousCertificate -ServerName $LocalServerName -Services $LocalServices -TargetParam "" `
			-PreviousThumbprint $OldLocalThumbprint -ExpectedBackEndThumbprint $OldLocalBackEndThumbprint
		if (-not $localRollback.Success) { throw $localRollback.Error }
		$rollbackResult.LocalRestored = $true
	}
	catch {
		Write-LogException -ErrorRecord $_ -Context "Primary rollback exception" -Level "DEBUG"
		$rollbackResult.Errors += "$LocalServerName rollback failed: $($_.Exception.Message)"
		Log-Critical "Coordinated rollback failed on ${LocalServerName}: $($_.Exception.Message)"
	}
	Log-Info "Step CR4: Post-rollback health and OWA/ECP validation..."
	if ($rollbackResult.HybridRestored -and $rollbackResult.RemoteRestored -and $rollbackResult.LocalRestored) {
		try {
			$localHealth = Invoke-ExchangeChild -Mode "HealthCheck"
			if (-not $localHealth.Success) { throw "Health validation failed on $LocalServerName after rollback. $($localHealth.Error)" }
			$localProbe = Test-OwaEcp -ServerName $LocalServerName -ExpectedThumbprint $(if ($ManagesIIS) { $OldLocalThumbprint } else { "" })
			if (-not $localProbe.Success) { throw "OWA/ECP validation failed on $LocalServerName after rollback." }
			if ($IncludeRemote) {
				$remoteHealth = Invoke-ExchangeChild -Mode "HealthCheck" -TargetServer $RemoteExchangeServer
				if (-not $remoteHealth.Success) { throw "Health validation failed on $RemoteExchangeServer after rollback. $($remoteHealth.Error)" }
				$remoteProbe = Test-OwaEcp -ServerName $RemoteExchangeServer -ExpectedThumbprint $(if ($ManagesIIS) { $OldRemoteThumbprint } else { "" })
				if (-not $remoteProbe.Success) { throw "OWA/ECP validation failed on $RemoteExchangeServer after rollback." }
			}
			$rollbackResult.FinalValidation = $true
			Log-Success "Post-rollback Exchange health and HTTPS validation passed"
		}
		catch {
			Write-LogException -ErrorRecord $_ -Context "Post-rollback validation exception" -Level "DEBUG"
			$rollbackResult.Errors += "Final rollback validation failed: $($_.Exception.Message)"
			Log-Critical "Post-rollback validation failed. $($_.Exception.Message)"
		}
	}
	else {
		Log-Warn "Post-rollback validation skipped because a restore stage failed."
	}
	$rollbackResult.Success = ($rollbackResult.HybridRestored -and $rollbackResult.RemoteRestored -and $rollbackResult.LocalRestored -and $rollbackResult.FinalValidation)
	if ($rollbackResult.Success) {
		Log-Success "COORDINATED ROLLBACK VERIFIED - previous Exchange and Hybrid certificate state restored"
		Complete-Section -Status "PASS" -Detail "Previous state restored"
	}
	else {
		Log-Critical "Coordinated rollback was incomplete. Errors=$($rollbackResult.Errors -join '; ')"
		Complete-Section -Status "FAIL" -Detail "Rollback incomplete"
	}
	return $rollbackResult
}
function Set-ServiceStateBounded {
	param([string]$ComputerName, [string]$ServiceName, [ValidateSet("Stopped", "Running")][string]$State, [int]$TimeoutSeconds)
	$sb = {
		param([string]$n, [string]$st, [int]$to)
		Add-Type -AssemblyName System.ServiceProcess -ErrorAction Stop
		$c = New-Object System.ServiceProcess.ServiceController -ArgumentList $n
		try {
			$S = [System.ServiceProcess.ServiceControllerStatus]
			$target = [System.ServiceProcess.ServiceControllerStatus]$st
			$c.Refresh()
			if ($c.Status -ne $target) {
				if ($st -eq "Stopped") { if ($c.Status -ne $S::StopPending) { $c.Stop() } }
				else { if ($c.Status -ne $S::StartPending) { $c.Start() } }
				$c.WaitForStatus($target, [TimeSpan]::FromSeconds($to))
				$c.Refresh()
			}
			if ($c.Status -ne $target) { throw "$n is $($c.Status), expected $st" }
			return [string]$c.Status
		}
		finally { $c.Dispose() }
	}
	$verb = if ($State -eq "Stopped") { "stop" } else { "start" }
	Log-Info "$ServiceName $verb via: ServiceController on $ComputerName (timeout ${TimeoutSeconds}s)"
	try {
		if ($ComputerName -eq $LocalServerName) { $r = & $sb $ServiceName $State $TimeoutSeconds }
		else { $r = Invoke-Command -ComputerName $ComputerName -ScriptBlock $sb -ArgumentList $ServiceName, $State, $TimeoutSeconds -ErrorAction Stop }
		Log-Info "$ServiceName $verb status on ${ComputerName}: $r"
		return $true
	}
	catch {
		Write-LogException -ErrorRecord $_ -Context "$ServiceName $verb exception" -Level "DEBUG"
		Log-Error "$ServiceName could not be ${verb}ped on ${ComputerName}: $($_.Exception.Message)"
		return $false
	}
}
function Set-SendConnectorTlsName {
	param([string[]]$Identities, [string]$Value)
	$b64 = if ([string]::IsNullOrEmpty($Value)) { "" } else { [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Value)) }
	return (Invoke-ExchangeChild -Mode "SendConnectorTls" -HybridSendConnector ($Identities -join "|") -HybridRestoreStateBase64 $b64)
}
# Microsoft procedure for "These certificates are tagged with following Send
# Connectors" (old and new certificate share Issuer and Subject):
# https://learn.microsoft.com/en-us/troubleshoot/exchange/mailflow/cannot-remove-installed-certificate
#   stop MSExchangeTransport on every source server -> clear TlsCertificateName
#   -> remove the old certificate from ALL servers -> set TlsCertificateName from
#   the new certificate -> start MSExchangeTransport.
function Invoke-TaggedCertificateRemoval {
	param($Outcomes, $Connectors, [string[]]$SourceServers, [string]$NewTlsName)
	$ids = @($Connectors | ForEach-Object { $_.Identity } | Select-Object -Unique)
	$remaining = $TlmTimeLimitSeconds - [int]$script:RunStopwatch.Elapsed.TotalSeconds
	if ($remaining -lt $KbMinimumSeconds) {
		Log-Warn "Old certificate removal deferred: ${remaining}s left of the ${TlmTimeLimitSeconds}s TLM limit (needs ${KbMinimumSeconds}s). Nothing stopped or changed."
		foreach ($o in $Outcomes) { $o.Outcome = "DEFERRED"; $o.Reason = "insufficient time left in the TLM post-script limit" }
		return
	}
	Log-Warn "Old certificate shares Issuer/Subject with the new one and is tagged by send connector(s) $($ids -join '; '). Applying Microsoft KB cannot-remove-installed-certificate; mail flow on $($SourceServers -join ',') pauses until MSExchangeTransport restarts. Time left: ${remaining}s."
	$stopped = @()
	try {
		Log-Info "Step K1: Stopping MSExchangeTransport on source transport servers ($($SourceServers -join ','))..."
		foreach ($srvName in $SourceServers) {
			$stopped += $srvName
			if (-not (Set-ServiceStateBounded -ComputerName $srvName -ServiceName "MSExchangeTransport" -State "Stopped" -TimeoutSeconds $KbTransportStopTimeoutSeconds)) {
				throw "MSExchangeTransport could not be stopped on $srvName."
			}
		}
		Log-Success "MSExchangeTransport stopped on $($SourceServers -join ',')"
		$retry = [Math]::Max(10, $TlmTimeLimitSeconds - [int]$script:RunStopwatch.Elapsed.TotalSeconds - $KbReserveSeconds - 15)
		Log-Info "Step K2-K4: Clearing TlsCertificateName, removing the old certificate from all servers (retry window ${retry}s), setting TlsCertificateName from the new certificate..."
		$b64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($NewTlsName))
		$ChildProcessTimeoutSeconds = $retry + 40
		$kb = Invoke-ExchangeChild -Mode "KbRemove" -HybridSendConnector ($ids -join "|") -HybridRestoreStateBase64 $b64 `
			-ManagedServers (($Outcomes | ForEach-Object { "$($_.Server)=$($_.Thumbprint)" }) -join "|") -RetrySeconds $retry
		foreach ($o in $Outcomes) {
			$r = if ($kb.Data) { @($kb.Data.Results) | Where-Object { [string]$_.Server -ieq $o.Server -and [string]$_.Thumb -eq $o.Thumbprint } | Select-Object -First 1 } else { $null }
			if ($r -and [bool]$r.Removed) { [void](Confirm-OldCertificateRemoved $o) }
			else {
				$o.Outcome = "FAILED"
				$o.Reason  = "Remove-ExchangeCertificate failed: $(if ($r) { $r.Error } else { $kb.Error })"
				Log-Warn "Old certificate removal FAILED on $($o.Server): $($o.Reason). The new certificate remains live."
			}
		}
		if ($kb.Data -and [bool]$kb.Data.RestoreOk) { Log-Success "TlsCertificateName set to $NewTlsName on $($ids -join '; ')" }
		else { throw "send connector TlsCertificateName not confirmed: $(if ($kb.Data) { $kb.Data.RestoreErrors } else { $kb.Error })" }
	}
	catch {
		Write-LogException -ErrorRecord $_ -Context "Tagged removal exception" -Level "DEBUG"
		Log-Warn "Tagged certificate removal: $($_.Exception.Message)"
		foreach ($o in $Outcomes) { if ($o.Outcome -eq "ELIGIBLE") { $o.Outcome = "FAILED"; $o.Reason = $_.Exception.Message } }
		Log-Info "Step K4 (fallback): Setting TlsCertificateName from the new certificate on $($ids -join '; ')..."
		$assign = Set-SendConnectorTlsName -Identities $ids -Value $NewTlsName
		if ($assign.Success) { Log-Success "TlsCertificateName set to $NewTlsName" }
		else {
			Log-Critical "TlsCertificateName could NOT be set on $($ids -join '; '): $($assign.Error). Run manually: Set-SendConnector -Identity '<connector>' -TlsCertificateName '$NewTlsName'"
			foreach ($o in $Outcomes) { $o.Critical = $true }
		}
	}
	finally {
		Log-Info "Step K5: Starting MSExchangeTransport on $($stopped -join ',')..."
		foreach ($srvName in $stopped) {
			if (-not (Set-ServiceStateBounded -ComputerName $srvName -ServiceName "MSExchangeTransport" -State "Running" -TimeoutSeconds $KbTransportStartTimeoutSeconds)) {
				Log-Critical "MSExchangeTransport is NOT running on $srvName. Mail flow is stopped there. Run manually: Start-Service MSExchangeTransport"
				foreach ($o in $Outcomes) { $o.Critical = $true }
			}
		}
		if ($stopped.Count -gt 0) { Log-Success "MSExchangeTransport running on $($stopped -join ',')" }
	}
}
function Invoke-OldCertificateRemoval {
	param(
		[string]$ServerName,
		[bool]$IsLocal,
		[string]$OldThumbprint,
		[string]$BackEndThumbprint,
		[string]$Services,
		$CheckResult = $null,
		[string]$Kind = "previous Front End 443 certificate"
	)
	$targetParam = if ($IsLocal) { "" } else { $ServerName }
	$old         = if ($OldThumbprint) { $OldThumbprint.Trim().ToUpperInvariant() } else { "" }
	$newThumb    = $thumbprint.ToUpperInvariant()
	$outcome = [PSCustomObject]@{ Server = $ServerName; IsLocal = $IsLocal; Thumbprint = $old; Outcome = "SKIPPED"; Reason = ""; Critical = $false }
	Log-Info "Step X1 (${ServerName}): Identifying old certificate candidate..."
	if (-not $old) {
		$outcome.Reason = "no previous Front End ($FrontEndPort) certificate was captured"
		Log-Warn "Old certificate removal skipped on ${ServerName}: $($outcome.Reason)"
		return $outcome
	}
	Log-Info "Old certificate candidate on ${ServerName}: $old ($Kind)"
	if ($old -eq $newThumb) {
		$outcome.Reason = "previous certificate is the newly deployed certificate"
		Log-Info "Old certificate removal skipped on ${ServerName}: $($outcome.Reason)"
		return $outcome
	}
	if ($BackEndThumbprint -and $old -eq $BackEndThumbprint.ToUpperInvariant()) {
		$outcome.Reason = "previous certificate is the Exchange Back End ($BackEndPort) certificate"
		Log-Warn "Old certificate removal skipped on ${ServerName}: $($outcome.Reason)"
		return $outcome
	}
	Log-Info "Step X2 (${ServerName}): Verifying old certificate is not used by any other Exchange feature..."
	$check = if ($CheckResult) { $CheckResult } else { Invoke-ExchangeChild -Mode "RemovalCheck" -Thumbprint $old -TargetServer $targetParam }
	if (-not $check.Success) {
		$outcome.Reason = "eligibility check failed: $($check.Error)"
		Log-Warn "Old certificate removal skipped on ${ServerName}: $($outcome.Reason)"
		return $outcome
	}
	$d = $check.Data
	$cd = @($d.Candidates) | Where-Object { [string]$_.Thumbprint -eq $old } | Select-Object -First 1
	if ($cd) { foreach ($p in "Exists", "Subject", "Issuer", "NotAfter", "IsSelfSigned", "Services") { $d | Add-Member -NotePropertyName $p -NotePropertyValue $cd.$p -Force } }
	Log-Info "Removal eligibility response: Exists=$($d.Exists) SelfSigned=$($d.IsSelfSigned) Services=$($d.Services) NotAfter=$($d.NotAfter)"
	Log-Info "  Subject: $($d.Subject)"
	Log-Info "  Issuer: $($d.Issuer)"
	if (-not [bool]$d.Exists) {
		$outcome.Outcome = "ALREADY_ABSENT"
		$outcome.Reason  = "not present in the Exchange certificate store"
		Log-Info "Old certificate $old is already absent on $ServerName. Nothing to remove."
		return $outcome
	}
	$allowedServices  = @($Services -split "," | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ })
	$assignedServices = @(([string]$d.Services) -split '[,\s]+' | Where-Object { $_ -and $_ -ne "None" } | ForEach-Object { $_.ToUpperInvariant() })
	$unexpected       = @($assignedServices | Where-Object { $allowedServices -notcontains $_ })
	$blockers = @()
	if ([bool]$d.IsSelfSigned) { $blockers += "certificate is self-signed (Exchange internal certificate)" }
	if ($unexpected.Count -gt 0) { $blockers += "still assigned to service(s) not managed by this script: $($unexpected -join ',')" }
	if (-not [bool]$d.AuthCheckOk)                                { $blockers += "Exchange OAuth (Get-AuthConfig) usage could not be verified" }
	elseif (@($d.AuthThumbprints) -contains $old)                 { $blockers += "certificate is an Exchange OAuth (Auth) certificate" }
	if (-not [bool]$d.FederationCheckOk)                          { $blockers += "federation trust usage could not be verified" }
	elseif (@($d.FederationThumbprints) -contains $old)           { $blockers += "certificate is used by the federation trust" }
	if (-not [bool]$d.TransportCheckOk)                           { $blockers += "internal transport certificate could not be verified" }
	elseif ([string]$d.InternalTransportThumbprint -eq $old)      { $blockers += "certificate is the internal transport certificate" }
	if ($blockers.Count -gt 0) {
		$outcome.Reason = $blockers -join "; "
		Log-Warn "Old certificate removal skipped on ${ServerName}: $($outcome.Reason)"
		return $outcome
	}
	Log-Success "Old certificate $old on $ServerName is not used by OAuth, federation, internal transport, or unmanaged Exchange services"
	Log-Info "Step X3 (${ServerName}): Verifying old certificate is not bound in HTTP.sys..."
	$bindings = Get-HttpSysCertificateBindings -ComputerName $ServerName
	if ($null -eq $bindings) {
		$outcome.Reason = "HTTP.sys binding inventory could not be read"
		Log-Warn "Old certificate removal skipped on ${ServerName}: $($outcome.Reason)"
		return $outcome
	}
	$stillBound = @(@($bindings) | Where-Object { $_.Hash -eq $old })
	if ($stillBound.Count -gt 0) {
		$outcome.Reason = "still bound in HTTP.sys: $(($stillBound | ForEach-Object { $_.Binding }) -join ', ')"
		Log-Warn "Old certificate removal skipped on ${ServerName}: $($outcome.Reason)"
		return $outcome
	}
	if ($ManagesIIS) {
		$frontEndNow = Get-FrontEndCertThumbprint -ComputerName $ServerName
		if ($frontEndNow -ne $newThumb) {
			$outcome.Reason = "Front End ($FrontEndPort) is not on the new certificate (actual $frontEndNow)"
			Log-Warn "Old certificate removal skipped on ${ServerName}: $($outcome.Reason)"
			return $outcome
		}
		Log-Success "Old certificate $old is not bound in HTTP.sys on $ServerName; Front End ($FrontEndPort) uses $newThumb"
	}
	else {
		Log-Success "Old certificate $old is not bound in HTTP.sys on $ServerName"
	}
	Log-Info "Step X4 (${ServerName}): Saving public copy of old certificate for audit..."
	$cerPath = Join-Path $archiveDir ("{0}_previous_{1}.cer" -f $ServerName, $old)
	if (Save-CertificatePublicCopy -ComputerName $ServerName -Thumbprint $old -DestinationPath $cerPath) {
		Log-Success "Public copy saved (no private key): $cerPath"
	}
	else {
		Log-Warn "Public copy of $old could not be saved. Continuing."
	}
	if ($RemoveOldCertificate -eq "report") {
		$outcome.Outcome = "REPORT_ONLY"
		$outcome.Reason  = "eligible for removal; not removed (REMOVE_OLD_CERTIFICATE=report)"
		Log-Info "REPORT ONLY: Old certificate $old on $ServerName is eligible for removal. No change made."
		return $outcome
	}
	$outcome.Outcome = "ELIGIBLE"
	return $outcome
}
function Complete-OldCertificateRemoval {
	param($outcome)
	$ServerName  = $outcome.Server
	$old         = $outcome.Thumbprint
	$targetParam = if ($outcome.IsLocal) { "" } else { $ServerName }
	$newThumb    = $thumbprint.ToUpperInvariant()
	Log-Info "Step X5 (${ServerName}): Removing old certificate..."
	$remove = Invoke-ExchangeChild -Mode "RemoveCertificate" -Thumbprint $old -TargetServer $targetParam
	if (-not $remove.Success) {
		$outcome.Outcome = "FAILED"
		$outcome.Reason  = "Remove-ExchangeCertificate failed: $($remove.Error)"
		Log-Warn "Old certificate removal FAILED on ${ServerName}: $($outcome.Reason). The new certificate remains live."
		return $outcome
	}
	return (Confirm-OldCertificateRemoved $outcome)
}
function Confirm-OldCertificateRemoved {
	param($outcome)
	$ServerName = $outcome.Server
	$old        = $outcome.Thumbprint
	$newThumb   = $thumbprint.ToUpperInvariant()
	Log-Info "Step X6 (${ServerName}): Verifying removal..."
	$inStore = Test-CertificateInMachineStore -ComputerName $ServerName -Thumbprint $old
	if ($inStore -eq $true) {
		$outcome.Outcome = "FAILED"
		$outcome.Reason  = "certificate still present in LocalMachine\My after removal"
		Log-Warn "Old certificate removal FAILED on ${ServerName}: $($outcome.Reason)"
		return $outcome
	}
	elseif ($null -eq $inStore) {
		Log-Warn "Could not read LocalMachine\My on $ServerName to confirm removal. Exchange reported the certificate removed."
	}
	else {
		Log-Info "LocalMachine\My check response indicates success: $old not present on $ServerName"
	}
	$frontEndAfter = if ($ManagesIIS) { Get-FrontEndCertThumbprint -ComputerName $ServerName } else { $newThumb }
	if ($frontEndAfter -ne $newThumb) {
		$outcome.Outcome  = "FAILED"
		$outcome.Critical = $true
		$outcome.Reason   = "Front End ($FrontEndPort) is not on the new certificate after removal (actual $frontEndAfter)"
		Log-Critical "Front End ($FrontEndPort) on $ServerName is not on the new certificate after old certificate removal (actual $frontEndAfter). Manual investigation required."
		return $outcome
	}
	$outcome.Outcome = "REMOVED"
	Log-Success "Old certificate $old removed from $ServerName"
	return $outcome
}
trap {
	Write-LogException -ErrorRecord $_ -Context "UNHANDLED TERMINATING ERROR" -Level "CRITICAL"
	Stop-Script -Code 1 -Reason "Unhandled terminating error: $($_.Exception.Message)"
}
Initialize-Logging
Start-Section -Id "S00" -Name "Initialization" -Silent
Write-Banner
Log-Info "Starting DC1_POST_SCRIPT_DATA extraction script (Exchange Server certificate automation v$ScriptVersion)"
Write-Banner
Log-Info "Checking legal notice acceptance..."
if ($LEGAL_NOTICE_ACCEPT -ne "true") {
	Log-Error "Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT=`"true`" to proceed."
	Log-Error "Script execution terminated due to legal notice non-acceptance. No changes made."
	Stop-Script -Code 1 -Reason "Legal notice not accepted"
}
Log-Info "Legal notice accepted, proceeding with script execution."
Log-Info "Configuration:"
Log-Info "  LEGAL_NOTICE_ACCEPT: $LEGAL_NOTICE_ACCEPT"
Log-Info "  LOGFILE: $LogFilePath"
Log-Info "  SCRIPT_VERSION: $ScriptVersion"
Log-Info "  RUN_ID: $($script:RunId)"
Log-Info "  LOG_LEVEL: $LogLevel"
Log-Info "  DEFAULT_NODE_MODE: $NodeMode"
Log-Info "  DEFAULT_PRIMARY_SERVER: $PrimaryServer"
Log-Info "  DEFAULT_SECONDARY_SERVER: $SecondaryServer"
Log-Info "  DEFAULT_HYBRID_ENABLED: $HybridEnabled"
Log-Info "  DEFAULT_REMOVE_OLD_CERTIFICATE: $RemoveOldCertificate"
Log-Info "  COMMAND_LINE_OVERRIDES: $(if ($CommandLineParameters.Count -gt 0) { $CommandLineParameters -join ',' } else { '(none)' })"
Log-Info "  CERTIFICATE_NAMES: taken from the TLM-issued certificate (not hard-coded)"
Log-Info "  ENFORCE_NAME_CONTINUITY: $EnforceNameContinuity"
Log-Info "  DEFAULT_EXCHANGE_SERVICES: $ExchangeServices"
Log-Info "  SUPPORTED_EXCHANGE_SERVICES: $($SupportedExchangeServices -join ', '), ALL"
Log-Info "  HYBRID_SEND_CONNECTORS: $(if (@($HybridSendConnectorOverride).Count -gt 0) { $HybridSendConnectorOverride -join ' | ' } else { '(auto-discover, name not used)' })"
Log-Info "  HYBRID_RECEIVE_OVERRIDE: $(if (@($HybridReceiveConnectorOverride).Count -gt 0) { $HybridReceiveConnectorOverride -join ' | ' } else { '(auto-discover per managed node)' })"
Log-Info "  UPDATE_HYBRID_CONFIGURATION_OBJECT: $UpdateHybridConfigurationObject"
Log-Info "  FRONT_END_PORT: $FrontEndPort"
Log-Info "  BACK_END_PORT: $BackEndPort (READ ONLY - never modified)"
Log-Info "  RESTART_FRONTEND_TRANSPORT: $RestartFrontEndTransport"
Log-Info "  CHILD_PROCESS_TIMEOUT_SECONDS: $ChildProcessTimeoutSeconds"
Log-Info "  TLM_TIME_LIMIT_SECONDS: $TlmTimeLimitSeconds"
Log-Info "  IMPORT_KEY_EXPORTABLE: $ImportKeyExportable"
Complete-Section -Status "PASS"
Start-Section -Id "S01" -Name "DC1_POST_SCRIPT_DATA extraction" -Silent
Log-Info "Checking DC1_POST_SCRIPT_DATA environment variable..."
$base64Json = [System.Environment]::GetEnvironmentVariable("DC1_POST_SCRIPT_DATA")
if ([string]::IsNullOrEmpty($base64Json)) {
	Log-Error "DC1_POST_SCRIPT_DATA is not set. Ensure this script is configured as a TLM Agent post-script."
	Stop-Script -Code 1 -Reason "DC1_POST_SCRIPT_DATA missing"
}
Log-Info "DC1_POST_SCRIPT_DATA is set (length: $($base64Json.Length) characters)"
$certInfo = $base64Json
Log-Info "CERT_INFO length: $($certInfo.Length) characters"
try {
	$jsonString = Decode-Base64 -base64String $certInfo
	$jsonObject = $jsonString | ConvertFrom-Json
	Log-Info "JSON_STRING decoded successfully"
}
catch {
	Write-LogException -ErrorRecord $_ -Context "Payload decode exception" -Level "DEBUG"
	Log-Error "Failed to decode DC1_POST_SCRIPT_DATA. $($_.Exception.Message)"
	Stop-Script -Code 1 -Reason "Payload decode failed"
}
Write-Banner
Log-Info "Raw JSON content: [not logged - payload contains the PFX password]"
Write-Banner
Log-Info "Extracting arguments from JSON..."
$payloadArgs = @()
if ($jsonObject.PSObject.Properties.Name -contains "args" -and $null -ne $jsonObject.args) {
	$payloadArgs = @($jsonObject.args)
	Log-Info "Args array extracted (not logging raw content for security)"
}
else {
	Log-Info "Args array not present in payload; script defaults will be used"
}
$argumentValues = @{}
for ($i = 1; $i -le 6; $i++) {
	$v = ""
	if ($payloadArgs.Count -ge $i -and $null -ne $payloadArgs[$i - 1]) { $v = ([string]$payloadArgs[$i - 1]).Trim() }
	Log-Info "ARGUMENT_${i} extracted: '$v'"
	Log-Info "ARGUMENT_${i} length: $($v.Length)"
	if ($v -match '^(?i)(-|none|n/a|na|default)$') {
		Log-Info "ARGUMENT_${i} is a placeholder ('$v'); the script default will be used"
		$v = ""
	}
	$argumentValues[$i] = $v
}
foreach ($serverIndex in @(2, 3)) {
	if ($argumentValues[$serverIndex] -match '^(?i)(single|ha|true|false|report|all|pop|pop3|imap|imap4|iis|smtp)$' -or $argumentValues[$serverIndex] -match '[,;+|/]') {
		Log-Critical "ARGUMENT_$serverIndex contains '$($argumentValues[$serverIndex])', a setting value, not a server name. Arguments appear shifted (blank argument dropped): enter '-' in unused fields. No changes made."
		Stop-Script -Code 1 -Reason "TLM arguments shifted"
	}
	if ($argumentValues[$serverIndex] -match '\s') {
		Log-Critical "ARGUMENT_$serverIndex contains '$($argumentValues[$serverIndex])'. Server names cannot contain spaces; arguments appear shifted. No changes made."
		Stop-Script -Code 1 -Reason "TLM arguments shifted"
	}
	if ($argumentValues[$serverIndex] -match '\.') {
		Log-Critical "ARGUMENT_$serverIndex contains '$($argumentValues[$serverIndex])'. Use the NetBIOS server name, not an FQDN. No changes made."
		Stop-Script -Code 1 -Reason "TLM arguments shifted or FQDN used as server name"
	}
}
if ($payloadArgs.Count -gt 6) {
	Log-Warn "Payload contains $($payloadArgs.Count) arguments; only ARGUMENT_1..6 are used."
}
$certFolder   = [string]$jsonObject.certfolder
$payloadFiles = @($jsonObject.files | Where-Object { $_ } | ForEach-Object { [string]$_ })
$pfxPassword  = [string]$jsonObject.password
Remove-Variable jsonString, jsonObject, base64Json, certInfo -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($certFolder)) {
	Log-Error "Payload does not contain certfolder."
	Stop-Script -Code 1 -Reason "certfolder missing"
}
if ($payloadFiles.Count -eq 0) {
	Log-Error "Payload does not list any certificate files."
	Stop-Script -Code 1 -Reason "files missing"
}
$pfxFileName = $payloadFiles | Where-Object { $_ -match '(?i)\.(pfx|p12)$' } | Select-Object -First 1
if (-not $pfxFileName) {
	$pfxFileName = $payloadFiles[0]
	Log-Warn "No .pfx/.p12 file in payload ($($payloadFiles -join ',')); using files[0] ($pfxFileName). The TLM profile should deliver PKCS#12."
}
elseif ($payloadFiles.Count -gt 1) {
	Log-Debug "Payload lists $($payloadFiles.Count) files ($($payloadFiles -join ',')); selected PFX: $pfxFileName"
}
$pfxFilePath = Join-Path -Path $certFolder -ChildPath $pfxFileName
Log-Info "Extracted CERT_FOLDER: $certFolder"
Log-Info "Extracted PFX_FILE: $pfxFileName"
Log-Info "Extracted PFX_PASSWORD: $(if ([string]::IsNullOrEmpty($pfxPassword)) { '(empty)' } else { '***' })"
if ([string]::IsNullOrEmpty($pfxPassword)) {
	Log-Error "Payload PFX password is empty. Import-PfxCertificate requires the TLM-generated password. No changes made."
	Stop-Script -Code 1 -Reason "PFX password missing"
}
$settingDefinitions = @(
	[PSCustomObject]@{ Index = 1; Name = "NodeMode";             Key = "NODE_MODE";              Allowed = @("Single", "HA") },
	[PSCustomObject]@{ Index = 2; Name = "PrimaryServer";        Key = "PRIMARY_SERVER";         Allowed = @() },
	[PSCustomObject]@{ Index = 3; Name = "SecondaryServer";      Key = "SECONDARY_SERVER";       Allowed = @() },
	[PSCustomObject]@{ Index = 4; Name = "HybridEnabled";        Key = "HYBRID_ENABLED";         Allowed = @("true", "false") },
	[PSCustomObject]@{ Index = 5; Name = "RemoveOldCertificate"; Key = "REMOVE_OLD_CERTIFICATE"; Allowed = @("true", "false", "report") },
	[PSCustomObject]@{ Index = 6; Name = "ExchangeServices";     Key = "EXCHANGE_SERVICES";      Allowed = @() }
)
$settingSources = @{}
foreach ($def in $settingDefinitions) {
	$argValue = $argumentValues[$def.Index]
	if ($CommandLineParameters -contains $def.Name) {
		$settingSources[$def.Name] = "command line"
		if ($argValue) { Log-Info "ARGUMENT_$($def.Index) ($($def.Name)) ignored: command-line value takes precedence" }
		continue
	}
	if (-not $argValue) {
		$settingSources[$def.Name] = "script default"
		continue
	}
	$value = $argValue
	if (@($def.Allowed).Count -gt 0) {
		$value = $def.Allowed | Where-Object { $_ -ieq $argValue } | Select-Object -First 1
		if (-not $value) {
			Log-Critical "ARGUMENT_$($def.Index) ($($def.Name)) value '$argValue' is invalid. Allowed: $($def.Allowed -join ', '). No changes made."
			Stop-Script -Code 1 -Reason "Invalid ARGUMENT_$($def.Index)"
		}
	}
	Set-Variable -Name $def.Name -Value $value -Scope Script
	$settingSources[$def.Name] = "ARGUMENT_$($def.Index)"
}
$serviceResolution = Resolve-ExchangeServiceList -Value $ExchangeServices
if (-not $serviceResolution.Valid) {
	Log-Critical "EXCHANGE_SERVICES value '$ExchangeServices' (source: $($settingSources['ExchangeServices'])) is invalid: $($serviceResolution.Error). No changes made."
	Stop-Script -Code 1 -Reason "Invalid EXCHANGE_SERVICES"
}
$ExchangeServices         = $serviceResolution.Text
$SelectedExchangeServices = @($serviceResolution.Services)
$LocalServices            = $ExchangeServices
$RemoteServices           = $ExchangeServices
$ManagesIIS               = ($SelectedExchangeServices -contains "IIS")
$ManagesSMTP              = ($SelectedExchangeServices -contains "SMTP")
$HybridRequested      = ($HybridEnabled -eq "true")
$HybridIsEnabled      = ($HybridRequested -and $ManagesSMTP)
$HybridDisabledReason = if (-not $HybridRequested) { "HYBRID_ENABLED=false" } elseif (-not $ManagesSMTP) { "SMTP not in EXCHANGE_SERVICES" } else { "" }
Write-Banner
Log-Info "EXTRACTION SUMMARY:"
Write-Banner
Log-Info "Arguments extracted:"
for ($i = 1; $i -le 6; $i++) { Log-Info "  Argument ${i}: $($argumentValues[$i])" }
Log-Info ""
Log-Info "Effective settings:"
foreach ($def in $settingDefinitions) {
	$current = (Get-Variable -Name $def.Name -Scope Script).Value
	Log-Info "  $($def.Key): $current (source: $($settingSources[$def.Name]))"
}
Log-Info ""
Log-Info "Certificate information:"
Log-Info "  Certificate folder: $certFolder"
Log-Info "  PFX file: $pfxFileName"
Log-Info "  PFX path: $pfxFilePath"
Log-Info "  PFX password: ***"
Log-Info ""
if (-not (Test-Path -LiteralPath $pfxFilePath -PathType Leaf)) {
	Log-Debug "certfolder exists=$(Test-Path -LiteralPath $certFolder) contents=$(if (Test-Path -LiteralPath $certFolder) { (Get-ChildItem -LiteralPath $certFolder -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ',' } else { '(n/a)' })"
	Log-Error "PFX file not found: $pfxFilePath"
	Stop-Script -Code 1 -Reason "PFX file not found"
}
Log-Info "PFX file exists: $pfxFilePath"
Log-Info "PFX file size: $((Get-Item -LiteralPath $pfxFilePath).Length) bytes"
$extractCollection = $null
try {
	$extractCollection = Open-PfxCollection -Path $pfxFilePath -Password $pfxPassword
	$extractLeaf = Select-PfxLeafCertificate -Collection $extractCollection
	Log-Info "Total certificates in file: $($extractCollection.Count)"
	if ($extractLeaf) { Log-Info "Certificate subject: $($extractLeaf.Subject)" }
	Log-Info "Key type: $(Get-CertificateKeyDescription -Certificate $extractLeaf)"
}
catch {
	Write-LogException -ErrorRecord $_ -Context "PFX open exception" -Level "DEBUG"
	Close-PfxCollection $extractCollection
	Log-Error "PFX could not be opened with the payload password: $($_.Exception.Message)"
	Stop-Script -Code 1 -Reason "PFX could not be opened"
}
finally {
	Close-PfxCollection $extractCollection
}
Complete-Section -Status "PASS"
Start-Section -Id "S02" -Name "Environment validation and execution guard"
$runtimeMajor   = $PSVersionTable.PSVersion.Major
$runtimeEdition = if ($PSVersionTable.ContainsKey("PSEdition")) { [string]$PSVersionTable.PSEdition } else { "Desktop" }
Log-Info "PowerShell runtime: $($PSVersionTable.PSVersion) (edition $runtimeEdition)"
if ($runtimeMajor -lt 5) {
	Log-Critical "PowerShell $($PSVersionTable.PSVersion) is not supported. Windows PowerShell 5.0 or 5.1 is required. No changes made."
	Stop-Script -Code 1 -Reason "Unsupported PowerShell version"
}
if ($runtimeEdition -eq "Core") {
	Log-Warn "Running under PowerShell $($PSVersionTable.PSVersion) (Core). Built and validated for Windows PowerShell 5.x; the Exchange child always uses Windows PowerShell."
}
Enable-ModernTlsForProbes
Write-LogEnvironment
$ExpectedLocalServer = $PrimaryServer.Trim().ToUpperInvariant()
Log-Info "Execution guard: expected server $ExpectedLocalServer, current host $LocalServerName"
if ($LocalServerName -ne $ExpectedLocalServer) {
	Log-Critical "Script must run on $ExpectedLocalServer. Current host is $LocalServerName. Check ARGUMENT_2 (PrimaryServer). No changes made."
	Stop-Script -Code 1 -Reason "Wrong host"
}
Log-Success "Execution guard passed: running on $LocalServerName"
Start-Section -Id "S03" -Name "Topology resolution"
$SecondNodeEnabled    = ($NodeMode -eq "HA")
$RemoteExchangeServer = $null
if ($SecondNodeEnabled) {
	if ([string]::IsNullOrWhiteSpace($SecondaryServer)) {
		Log-Critical "NodeMode=HA requires a SecondaryServer (ARGUMENT_3). No changes made."
		Stop-Script -Code 1 -Reason "SecondaryServer missing"
	}
	$RemoteExchangeServer = $SecondaryServer.Trim().ToUpperInvariant()
	if ($RemoteExchangeServer -match '[\\/\.:\s]') {
		Log-Critical "SecondaryServer must be a NetBIOS name (no domain suffix, path, or whitespace). Value=$RemoteExchangeServer. No changes made."
		Stop-Script -Code 1 -Reason "Invalid SecondaryServer"
	}
	if ($RemoteExchangeServer -eq $LocalServerName) {
		Log-Critical "SecondaryServer ($RemoteExchangeServer) is the primary/local server. Use NodeMode=Single for one Exchange server. No changes made."
		Stop-Script -Code 1 -Reason "SecondaryServer equals primary"
	}
}
$ManagedServers = @($LocalServerName)
if ($SecondNodeEnabled) { $ManagedServers += $RemoteExchangeServer }
$script:ManagedServersForSummary = $ManagedServers
$HybridReceiveConnectors = @()
if ($HybridIsEnabled) {
	if (@($HybridReceiveConnectorOverride).Count -gt 0) {
		Log-Info "Hybrid Receive Connector source: explicit override ($(@($HybridReceiveConnectorOverride).Count) entries)"
		$HybridReceiveConnectors = @($HybridReceiveConnectorOverride | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
		foreach ($rcId in $HybridReceiveConnectors) {
			$rcServer = ($rcId -split '\\', 2)[0].Trim().ToUpperInvariant()
			if ($ManagedServers -notcontains $rcServer) {
				Log-Critical "Hybrid Receive Connector override '$rcId' references server '$rcServer', which is not a managed node for NodeMode=$NodeMode (managed: $($ManagedServers -join ',')). No changes made."
				Stop-Script -Code 1 -Reason "Receive connector override outside managed nodes"
			}
		}
	}
	else {
		Log-Info "Hybrid Receive Connector source: auto-discover on every managed node (resolved in the Hybrid TLS snapshot)"
	}
}
$hybridReceiveConnectorArg = [string]::Join("|", $HybridReceiveConnectors)
Log-Info "Topology:"
Log-Info "  Node mode: $NodeMode"
Log-Info "  Managed servers: $($ManagedServers -join ',')"
if (-not $SecondNodeEnabled -and -not [string]::IsNullOrWhiteSpace($SecondaryServer)) {
	Log-Info "  Secondary server: '$SecondaryServer' ignored (NodeMode=Single)"
}
Log-Info "  Exchange services: $ExchangeServices"
Log-Info "  Front End ($FrontEndPort) changed by this run: $ManagesIIS"
Log-Info "  Hybrid enabled: $HybridEnabled (effective: $HybridIsEnabled)"
if ($HybridRequested -and -not $ManagesSMTP) {
	Log-Warn "HYBRID_ENABLED=true but SMTP is not in EXCHANGE_SERVICES ($ExchangeServices); Hybrid connectors and Hybrid Configuration will NOT be changed."
}
if ($HybridIsEnabled) {
	Log-Info "  Hybrid Send Connectors: $(if (@($HybridSendConnectorOverride).Count -gt 0) { $HybridSendConnectorOverride -join ' | ' } else { '(auto-discover)' })"
	Log-Info "  Hybrid Receive Connectors: $(if ($HybridReceiveConnectors.Count -gt 0) { $HybridReceiveConnectors -join ' | ' } else { '(auto-discover)' })"
	Log-Info "  Hybrid Configuration object update: $UpdateHybridConfigurationObject"
}
Log-Info "  Remove old certificate: $RemoveOldCertificate"
Start-Section -Id "S04" -Name "Certificate preflight validation"
$pfxCollection = $null
try {
	Log-Info "Certificate preflight via: X509Certificate2Collection.Import ($pfxFilePath)"
	$pfxHash = (Get-FileHash -LiteralPath $pfxFilePath -Algorithm SHA256 -ErrorAction Stop).Hash
	Log-Debug "PFX SHA256: $pfxHash"
	$pfxCollection = Open-PfxCollection -Path $pfxFilePath -Password $pfxPassword
	foreach ($pc in $pfxCollection) {
		Log-Debug "  PFX certificate: Subject=$($pc.Subject) Thumbprint=$($pc.Thumbprint) HasPrivateKey=$($pc.HasPrivateKey) Issuer=$($pc.Issuer)"
	}
	$x509 = Select-PfxLeafCertificate -Collection $pfxCollection
	if (-not $x509) { throw "PFX does not contain a certificate with a private key." }
	Log-Debug "Leaf Subject: $($x509.Subject)"
	Log-Debug "Leaf Issuer: $($x509.Issuer)"
	Log-Debug "Leaf Serial: $($x509.SerialNumber)"
	Log-Debug "Signature algorithm: $($x509.SignatureAlgorithm.FriendlyName) ($($x509.SignatureAlgorithm.Value))"
	foreach ($ext in $x509.Extensions) {
		Log-Debug "Extension: $($ext.Oid.FriendlyName) ($($ext.Oid.Value)) critical=$($ext.Critical) value=$(($ext.Format($false)) -replace '\r?\n', ' ')"
	}
	if (-not $x509.HasPrivateKey) { throw "Certificate does not contain a private key." }
	if ($x509.PublicKey.Oid.Value -ne "1.2.840.113549.1.1.1") { throw "Certificate public-key algorithm is not RSA. OID=$($x509.PublicKey.Oid.Value)" }
	$now = Get-Date
	if ($x509.NotBefore -gt $now.AddMinutes(5)) { throw "Certificate is not yet valid. NotBefore=$($x509.NotBefore)" }
	if ($x509.NotAfter -le $now) { throw "Certificate is expired. NotAfter=$($x509.NotAfter)" }
	if (Test-IsCertificateAuthority $x509) { throw "The certificate with the private key is a CA certificate, not a server certificate." }
	$ekuExtension = $x509.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.37" } | Select-Object -First 1
	if ($ekuExtension) {
		$ekuOids = @()
		try {
			$typedEku = New-Object System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension($ekuExtension, $ekuExtension.Critical)
			$ekuOids  = @($typedEku.EnhancedKeyUsages | ForEach-Object { $_.Value })
		} catch { }
		$ekuText = $ekuExtension.Format($false)
		if ($ekuOids -notcontains "1.3.6.1.5.5.7.3.1" -and $ekuText -notmatch '(?i)(1\.3\.6\.1\.5\.5\.7\.3\.1|Server Authentication)') {
			throw "Certificate Enhanced Key Usage does not include Server Authentication (1.3.6.1.5.5.7.3.1). EKU=$ekuText"
		}
	}
	$sanExtension = $x509.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.17" } | Select-Object -First 1
	if (-not $sanExtension) { throw "Certificate does not contain a Subject Alternative Name extension." }
	$certificateDnsNames = @(
		[regex]::Matches($sanExtension.Format($false), '(?im)(?:DNS Name=|DNS:)\s*([^,\r\n]+)') |
		ForEach-Object { $_.Groups[1].Value.Trim().ToLowerInvariant() } |
		Select-Object -Unique
	)
	if ($certificateDnsNames.Count -eq 0) { throw "Certificate Subject Alternative Name extension contains no DNS names." }
	$cnMatch = [regex]::Match($x509.Subject, '(?i)(?:^|,\s*)CN=([^,]+)')
	if ($cnMatch.Success) {
		$commonName = $cnMatch.Groups[1].Value.Trim()
		if (-not (Test-DnsNameCovered -Name $commonName -CertificateNames $certificateDnsNames)) {
			Log-Warn "Certificate CN '$commonName' is not listed in the SAN extension. Clients validate SANs only."
		}
	}
	else {
		$commonName = $certificateDnsNames[0]
		Log-Info "Certificate has no CN; using first DNS SAN '$commonName' as the certificate name."
	}
	$newCertificateNames = @(@($certificateDnsNames) + $commonName.ToLowerInvariant() | Select-Object -Unique)
	$expectedThumbprint = $x509.Thumbprint.ToUpper()
	$certNotBefore      = $x509.NotBefore
	$certNotAfter       = $x509.NotAfter
	$certKeyDescription = Get-CertificateKeyDescription -Certificate $x509
	$certIssuer         = $x509.Issuer
	$certSubject        = $x509.Subject
	Log-Info "Certificate preflight response:"
	Log-Info "  Name: $commonName"
	Log-Info "  Subject: $($x509.Subject)"
	Log-Info "  SANs: $($certificateDnsNames -join ', ')"
	Log-Info "  Issuer: $certIssuer"
	Log-Info "  Thumbprint: $expectedThumbprint"
	Log-Info "  NotBefore: $certNotBefore"
	Log-Info "  NotAfter: $certNotAfter (days remaining: $([int]($certNotAfter - $now).TotalDays))"
	Log-Info "  Key: $certKeyDescription"
	Log-Info "Certificate preflight response indicates success"
	Log-Success "Certificate preflight passed for $commonName"
}
catch {
	Write-LogException -ErrorRecord $_ -Context "Certificate preflight exception" -Level "DEBUG"
	Close-PfxCollection $pfxCollection
	Log-Critical "Certificate preflight FAILED. No certificate changes will be made. $($_.Exception.Message)"
	Stop-Script -Code 1 -Reason "Certificate preflight failed"
}
finally {
	Close-PfxCollection $pfxCollection
}
$script:SummaryThumbprint = $expectedThumbprint
$script:SummaryCertName   = $commonName
Start-Section -Id "S05" -Name "PFX archive"
$timestamp  = Get-Date -Format "yyyy_MM_dd_HH_mm_ss"
$safeCertName = ($commonName -replace '\*', 'wildcard')
foreach ($badChar in [System.IO.Path]::GetInvalidFileNameChars()) { $safeCertName = $safeCertName.Replace([string]$badChar, "_") }
$archiveDir = Join-Path -Path $certFolder -ChildPath "${safeCertName}_pfx_${timestamp}"
try {
	New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
	Copy-Item -LiteralPath $pfxFilePath -Destination (Join-Path $archiveDir $pfxFileName)
	try {
		$icacls = Invoke-NativeCapture -FilePath "icacls.exe" -Arguments @($archiveDir, "/grant:r", "SYSTEM:(OI)(CI)F", "BUILTIN\Administrators:(OI)(CI)F")
		Log-Debug "icacls /grant:r exit code: $($icacls.ExitCode) output: $($icacls.Output.Trim() -replace '\r?\n', ' ')"
		if ($icacls.ExitCode -ne 0) { throw "icacls /grant:r returned exit code $($icacls.ExitCode)." }
		$icacls = Invoke-NativeCapture -FilePath "icacls.exe" -Arguments @($archiveDir, "/inheritance:r")
		Log-Debug "icacls /inheritance:r exit code: $($icacls.ExitCode) output: $($icacls.Output.Trim() -replace '\r?\n', ' ')"
		if ($icacls.ExitCode -ne 0) { throw "icacls /inheritance:r returned exit code $($icacls.ExitCode)." }
		Log-Info "Restricted ACL on '$archiveDir' to SYSTEM and Administrators"
	}
	catch {
		Write-LogException -ErrorRecord $_ -Context "Archive ACL exception" -Level "DEBUG"
		Log-Warn "Archive was created, but ACL restriction could not be fully verified. $($_.Exception.Message)"
	}
	Log-Success "Archive folder created: $archiveDir"
}
catch {
	Write-LogException -ErrorRecord $_ -Context "Archive exception" -Level "DEBUG"
	Log-Error "Could not create archive folder. $($_.Exception.Message)"
	Stop-Script -Code 1 -Reason "Archive failed"
}
Start-Section -Id "S06" -Name "HA transport readiness"
if ($SecondNodeEnabled) {
	try {
		Log-Info "WinRM identity probe via: Invoke-Command -ComputerName $RemoteExchangeServer"
		$winrmTimer = [System.Diagnostics.Stopwatch]::StartNew()
		$remoteHostName = Invoke-Command -ComputerName $RemoteExchangeServer -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
		Log-Info "WinRM identity probe response: '$remoteHostName' ($($winrmTimer.ElapsedMilliseconds) ms)"
		if ([string]$remoteHostName -ne $RemoteExchangeServer) {
			throw "WinRM endpoint identity mismatch. Expected=$RemoteExchangeServer Actual=$remoteHostName (check DNS/alias)."
		}
		Log-Success "WinRM reachable on $RemoteExchangeServer (host identity confirmed)"
	}
	catch {
		Write-LogException -ErrorRecord $_ -Context "WinRM readiness exception" -Level "DEBUG"
		Log-Critical "HA readiness failed - WinRM to $RemoteExchangeServer. No changes made. $($_.Exception.Message)"
		Stop-Script -Code 1 -Reason "Secondary WinRM unreachable"
	}
	$probePath = "\\$RemoteExchangeServer\C$\Windows\Temp\ExCertProbe_$([Guid]::NewGuid().ToString('N')).tmp"
	try {
		Log-Info "SMB staging probe via: $probePath"
		Set-Content -LiteralPath $probePath -Value "probe" -ErrorAction Stop
		Remove-Item -LiteralPath $probePath -Force -ErrorAction Stop
		if (Test-Path -LiteralPath $probePath) { throw "Probe file still exists after removal." }
		Log-Success "Administrative share staging path writable on $RemoteExchangeServer"
	}
	catch {
		Write-LogException -ErrorRecord $_ -Context "SMB readiness exception" -Level "DEBUG"
		Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
		Log-Critical "HA readiness failed - cannot stage files to \\$RemoteExchangeServer\C$\Windows\Temp. No changes made. $($_.Exception.Message)"
		Stop-Script -Code 1 -Reason "Secondary SMB staging unavailable"
	}
}
else {
	Log-Info "NodeMode=Single: secondary transport checks not applicable."
	Complete-Section -Status "SKIPPED" -Detail "NodeMode=Single"
}
Start-Section -Id "S07" -Name "Local certificate import on $LocalServerName"
try {
	$pfxSecure = ConvertTo-SecureString -String $pfxPassword -Force -AsPlainText
	$importParams = @{ FilePath = $pfxFilePath; CertStoreLocation = "Cert:\LocalMachine\My"; Password = $pfxSecure }
	if ($ImportKeyExportable) { $importParams["Exportable"] = $true }
	Log-Info "Import-PfxCertificate via: Cert:\LocalMachine\My on $LocalServerName (exportable: $ImportKeyExportable)"
	$importedCertificates = @(Import-PfxCertificate @importParams)
	if ($importedCertificates.Count -eq 0) { throw "Import-PfxCertificate returned no certificates." }
	Log-Info "Import-PfxCertificate response: $($importedCertificates.Count) certificate(s) returned"
	foreach ($ic in $importedCertificates) {
		Log-Debug "  Imported: Thumbprint=$($ic.Thumbprint) HasPrivateKey=$($ic.HasPrivateKey) Subject=$($ic.Subject)"
	}
	$importedLeaf = $importedCertificates | Where-Object { $_.Thumbprint -and ($_.Thumbprint.ToUpper() -eq $expectedThumbprint) } | Select-Object -First 1
	if (-not $importedLeaf) { throw "Expected certificate was not returned by Import-PfxCertificate. Expected=$expectedThumbprint" }
	$storeCertificate = Get-Item -Path "Cert:\LocalMachine\My\$expectedThumbprint" -ErrorAction Stop
	if (-not $storeCertificate.HasPrivateKey) { throw "Imported certificate exists in LocalMachine\My but does not have its private key." }
	$thumbprint = $expectedThumbprint
	Log-Info "Import-PfxCertificate response indicates success"
	Log-Success "Certificate $thumbprint imported on $LocalServerName with private key"
}
catch {
	Write-LogException -ErrorRecord $_ -Context "Local import exception" -Level "DEBUG"
	Log-Error "Failed to import/verify certificate locally. $($_.Exception.Message)"
	Stop-Script -Code 1 -Reason "Local import failed"
}
Remove-Variable pfxSecure -ErrorAction SilentlyContinue
if (-not $SecondNodeEnabled) {
	Remove-Variable pfxPassword -ErrorAction SilentlyContinue
	Log-Debug "NodeMode=Single: PFX password released from memory after local import."
}
else {
	Log-Debug "NodeMode=HA: PFX password retained only until the gated secondary import."
}
Start-Section -Id "S08" -Name "Exchange topology readiness"
$topology = Invoke-ExchangeChild -Mode "Topology"
if ($topology.Success) {
	$orgMailboxServers = @($topology.Data.MailboxServers | ForEach-Object { ([string]$_).ToUpperInvariant() })
	$unmanagedServers  = @($orgMailboxServers | Where-Object { $ManagedServers -notcontains $_ })
	Log-Info "Exchange Mailbox servers in organization: $($orgMailboxServers -join ',')"
	if ($unmanagedServers.Count -gt 0) {
		Log-Warn "Exchange Mailbox server(s) not managed by this run: $($unmanagedServers -join ','). They will not receive certificate $thumbprint."
	}
	if ($SecondNodeEnabled -and ($orgMailboxServers -notcontains $RemoteExchangeServer)) {
		Log-Critical "HA readiness failed - $RemoteExchangeServer is not an Exchange Mailbox server in this organization. No Exchange changes made."
		Stop-Script -Code 1 -Reason "Secondary is not a Mailbox server"
	}
}
elseif ($SecondNodeEnabled) {
	Log-Critical "HA readiness failed - could not enumerate Exchange topology to confirm $RemoteExchangeServer. No Exchange changes made. $($topology.Error)"
	Stop-Script -Code 1 -Reason "Topology unreadable"
}
else {
	Log-Warn "Could not enumerate Exchange topology (informational in Single mode). $($topology.Error)"
}
$continuityFailures = @()
$script:NodeSnapshots = @{}
foreach ($node in $ManagedServers) {
	$isLocalNode = ($node -eq $LocalServerName)
	$nodeTarget  = if ($isLocalNode) { "" } else { $node }
	Log-Info "Readiness check of ${node}..."
	$nodeSnapshot = Invoke-ExchangeChild -Mode "Snapshot" -TargetServer $nodeTarget
	$script:NodeSnapshots[$node] = $nodeSnapshot
	if (-not $nodeSnapshot.Success) {
		Log-Critical "Readiness failed - Exchange certificate state unreadable on $node. No Exchange changes made. $($nodeSnapshot.Error)"
		Stop-Script -Code 1 -Reason "Certificate state unreadable on $node"
	}
	Log-Info "Exchange certificate snapshot: $(@($nodeSnapshot.Data).Count) certificate(s) on $node"
	$nodeFrontEnd = Get-FrontEndCertThumbprint -ComputerName $node
	if (-not $isLocalNode) {
		$nodeBackEnd = Get-BackEndCertThumbprint -ComputerName $node
		if ((-not $nodeFrontEnd -and $ManagesIIS) -or -not $nodeBackEnd) {
			Log-Critical "HA readiness failed - Front End ($FrontEndPort) or Back End ($BackEndPort) binding unreadable on $node. FrontEnd=$nodeFrontEnd BackEnd=$nodeBackEnd. No Exchange changes made."
			Stop-Script -Code 1 -Reason "Secondary bindings unreadable"
		}
		Log-Success "HA readiness passed for $node (Front End $FrontEndPort=$nodeFrontEnd, Back End $BackEndPort=$nodeBackEnd)"
	}
	$continuity = Test-CertificateNameContinuity -ServerName $node -SnapshotData $nodeSnapshot.Data `
		-FrontEndThumbprint $nodeFrontEnd -NewNames $newCertificateNames -NewThumbprint $thumbprint
	if (-not $continuity.Ok) { $continuityFailures += $continuity }
}
if ($continuityFailures.Count -gt 0) {
	foreach ($f in $continuityFailures) {
		$msg = "Name continuity: the new certificate does not carry name(s) that $($f.Server) serves today with certificate $($f.CurrentThumbprint): $($f.Missing -join ', ')."
		if ($EnforceNameContinuity) { Log-Critical $msg } else { Log-Warn $msg }
	}
	if ($EnforceNameContinuity) {
		Log-Critical "Deploying would drop these names from Exchange (OWA/Autodiscover/Hybrid). Issue the certificate in TLM with the same CN/SANs as the current certificate. No Exchange changes made."
		Stop-Script -Code 1 -Reason "New certificate drops names in use"
	}
	Log-Warn "ENFORCE_NAME_CONTINUITY=false: continuing although names will be dropped."
}
else {
	Log-Success "Name continuity verified on all managed servers ($($ManagedServers -join ','))"
}
Start-Section -Id "S09" -Name "Hybrid TLS snapshot"
$hybridSnapshot        = $null
$newTlsCertificateName = ""
$hybridConfigManaged   = $false
if ($HybridIsEnabled) {
	Log-Info "Hybrid connector discovery via: Exchange Management Shell (Get-SendConnector, Get-ReceiveConnector)"
	$sendOverrideArg = [string]::Join("|", @($HybridSendConnectorOverride | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }))
	$discovery = Invoke-ExchangeChild -Mode "HybridDiscover" -HybridSendConnector $sendOverrideArg `
		-HybridReceiveConnectors $hybridReceiveConnectorArg -ManagedServers ($ManagedServers -join "|")
	if (-not $discovery.Success) {
		Log-Critical "Hybrid connector discovery failed. No Exchange changes made. $($discovery.Error)"
		Stop-Script -Code 1 -Reason "Hybrid connector discovery failed"
	}
	$HybridReceiveConnectors   = @($discovery.Data.ReceiveConnectors | ForEach-Object { [string]$_.Identity } | Select-Object -Unique)
	$hybridReceiveConnectorArg = [string]::Join("|", $HybridReceiveConnectors)
	if ($HybridReceiveConnectors.Count -eq 0) {
		Log-Critical "No Hybrid Receive Connectors resolved. No Exchange changes made."
		Stop-Script -Code 1 -Reason "No receive connectors"
	}
	foreach ($r in @($discovery.Data.ReceiveConnectors)) {
		$rcServer = ([string]$r.Server).ToUpperInvariant()
		if (-not $rcServer) { $rcServer = (([string]$r.Identity) -split '\\', 2)[0].Trim().ToUpperInvariant() }
		if ($ManagedServers -notcontains $rcServer) {
			Log-Critical "Hybrid Receive Connector '$($r.Identity)' is on '$rcServer', which is not a managed node (managed: $($ManagedServers -join ',')). No Exchange changes made."
			Stop-Script -Code 1 -Reason "Receive connector outside managed nodes"
		}
	}
	$HybridSendConnectors  = @()
	$mixedSendConnectors   = @()
	$skippedSendConnectors = @()
	Log-Info "Hybrid connector discovery response:"
	foreach ($sc in @($discovery.Data.SendConnectors)) {
		$sources   = @(@($sc.Sources) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToUpperInvariant() })
		$managedIn = @($sources | Where-Object { $ManagedServers -contains $_ })
		$otherIn   = @($sources | Where-Object { $ManagedServers -notcontains $_ })
		$action    = ""
		if ($managedIn.Count -eq 0) {
			$action = "left unchanged (no source server managed by this run)"
			$skippedSendConnectors += $sc
		}
		elseif ($otherIn.Count -gt 0) {
			$action = "update only if its TLS name is unchanged (also sends from unmanaged: $($otherIn -join ','))"
			$mixedSendConnectors += [PSCustomObject]@{ Identity = [string]$sc.Identity; Unmanaged = $otherIn }
			$HybridSendConnectors += [string]$sc.Identity
		}
		else {
			$action = "will be updated"
			$HybridSendConnectors += [string]$sc.Identity
		}
		Log-Info "  Send Connector: $($sc.Identity) [$($sc.Method)]"
		Log-Info "    Source servers: $(if ($sources.Count -gt 0) { $sources -join ',' } else { '(none)' }) -> $action"
	}
	foreach ($r in @($discovery.Data.ReceiveConnectors)) {
		Log-Info "  Receive Connector: $($r.Identity) [$($r.Method)] -> will be updated"
	}
	foreach ($sc in $skippedSendConnectors) {
		Log-Warn "Hybrid Send Connector '$($sc.Identity)' sends only from server(s) not managed by this run ($(@($sc.Sources) -join ',')). It is left unchanged; update those servers with their own run."
	}
	if ($HybridSendConnectors.Count -eq 0) {
		Log-Warn "No Hybrid Send Connector sends from the managed server(s) ($($ManagedServers -join ',')). Only receive connectors and the Hybrid Configuration object will be updated."
	}
	$hybridSendConnectorArg = [string]::Join("|", $HybridSendConnectors)
	$hybridEdgeServers = @($discovery.Data.EdgeTransportServers | Where-Object { $_ })
	if ($hybridEdgeServers.Count -gt 0) {
		Log-Warn "Hybrid Configuration lists Edge Transport server(s): $($hybridEdgeServers -join ','). Hybrid mail flow through Edge uses the Edge servers' certificates, which this script does not manage."
	}
	Log-Success "Hybrid connectors discovered ($($HybridSendConnectors.Count) send, $($HybridReceiveConnectors.Count) receive to update)"
	$hybridSnapshot = Invoke-ExchangeChild -Mode "HybridSnapshot" -Thumbprint $thumbprint `
		-HybridSendConnector $hybridSendConnectorArg -HybridReceiveConnectors $hybridReceiveConnectorArg
	if (-not $hybridSnapshot.Success) {
		Log-Critical "Could not snapshot Hybrid TLS configuration. No Exchange service assignments will be changed. $($hybridSnapshot.Error)"
		Stop-Script -Code 1 -Reason "Hybrid snapshot failed"
	}
	$newTlsCertificateName = [string]$hybridSnapshot.Data.NewTlsCertificateName
	$newTlsNorm            = ConvertTo-NormalizedTlsName $newTlsCertificateName
	foreach ($m in $mixedSendConnectors) {
		$snapEntry = @($hybridSnapshot.Data.SendConnectors) | Where-Object { [string]$_.Identity -eq $m.Identity } | Select-Object -First 1
		$currentNorm = if ($snapEntry) { ConvertTo-NormalizedTlsName ([string]$snapEntry.TlsCertificateName) } else { "" }
		if ($currentNorm -ne $newTlsNorm) {
			Log-Critical "Hybrid Send Connector '$($m.Identity)' also sends from unmanaged server(s) $($m.Unmanaged -join ','), which lack the new certificate; changing its TLS name would break their Hybrid outbound TLS. Cover them with NodeMode=HA. No Exchange changes made."
			Stop-Script -Code 1 -Reason "Send connector has unmanaged source servers"
		}
		Log-Warn "Hybrid Send Connector '$($m.Identity)' also sends from unmanaged server(s) $($m.Unmanaged -join ','); its TLS certificate name does not change, so they are not affected."
	}
	Log-Info "Hybrid TLS snapshot response:"
	Log-Info "  New TlsCertificateName: $newTlsCertificateName"
	foreach ($sc in @($hybridSnapshot.Data.SendConnectors)) {
		Log-Info "  Send Connector $($sc.Identity): $($sc.TlsCertificateName)"
	}
	foreach ($rc in @($hybridSnapshot.Data.ReceiveConnectors)) {
		Log-Info "  Receive Connector $($rc.Identity): $($rc.TlsCertificateName)"
	}
	$hc = $hybridSnapshot.Data.HybridConfiguration
	$hcState = if ($hc) { [string]$hc.State } else { "NotCaptured" }
	Log-Info "  Hybrid Configuration state: $hcState"
	if ($UpdateHybridConfigurationObject) {
		switch ($hcState) {
			"Present" {
				$hybridConfigManaged = $true
				$hcCurrent = [string]$hc.TlsCertificateName
				Log-Info "  Hybrid Configuration TlsCertificateName: $hcCurrent"
				if ((ConvertTo-NormalizedTlsName $hcCurrent) -eq $newTlsNorm) {
					Log-Info "Hybrid Configuration already references the new certificate."
				}
				else {
					Log-Info "Hybrid Configuration references a different certificate and will be updated after all managed nodes pass validation."
				}
				$hcCN = Get-TlsNameSubjectCN $hcCurrent
				if ($hcCN -and $hcCN -ine $commonName) {
					Log-Warn "Certificate CN changes from '$hcCN' to '$commonName'. Update the Exchange Online inbound connector TlsSenderCertificateName (or re-run the HCW)."
				}
				$hcReceiving   = @($hc.ReceivingTransportServers | ForEach-Object { ([string]$_).ToUpperInvariant() })
				$hcSending     = @($hc.SendingTransportServers   | ForEach-Object { ([string]$_).ToUpperInvariant() })
				$hcServers     = @(($hcReceiving + $hcSending) | Where-Object { $_ } | Sort-Object -Unique)
				$hcNotManaged  = @($hcServers | Where-Object { $ManagedServers -notcontains $_ })
				Log-Info "  Hybrid Configuration transport servers: $($hcServers -join ',')"
				if ($hcNotManaged.Count -gt 0) {
					Log-Warn "Hybrid Configuration lists transport server(s) not managed by this run: $($hcNotManaged -join ','). They keep their current certificate."
				}
			}
			"NotPresent" {
				Log-Warn "No Hybrid Configuration object exists (Get-HybridConfiguration returned nothing). Only the Hybrid connectors will be updated."
			}
			default {
				Log-Critical "Hybrid Configuration object could not be read ($hcState). Its TLS certificate name cannot be snapshotted for rollback. No Exchange changes made. $($hc.Error)"
				Stop-Script -Code 1 -Reason "Hybrid Configuration unreadable"
			}
		}
	}
	else {
		Log-Warn "UPDATE_HYBRID_CONFIGURATION_OBJECT=false: the Hybrid Configuration object will NOT be updated and will keep referencing the previous certificate."
	}
	Log-Success "Hybrid TLS snapshot captured for rollback"
}
else {
	Log-Info "Hybrid connectors and Hybrid Configuration are not managed by this run ($HybridDisabledReason)."
	Complete-Section -Status "SKIPPED" -Detail $HybridDisabledReason
}
Start-Section -Id "S10" -Name "Exchange primary certificate deployment on $LocalServerName"
$localDeployment = Deploy-CertificateToServer -ServerName $LocalServerName -Services $LocalServices -IsLocal $true
if ($null -eq $localDeployment -or -not $localDeployment.Success) {
	$untouched = if ($SecondNodeEnabled) { " $RemoteExchangeServer was NOT touched." } else { "" }
	Log-Error "Primary server $LocalServerName did not pass validation.$untouched Reason=$($localDeployment.Error)"
	Stop-Script -Code 1 -Reason "Primary deployment failed"
}
$oldLocalThumbprint        = [string]$localDeployment.PreviousThumbprint
$oldLocalBackEndThumbprint = [string]$localDeployment.BackEndBaseline
Log-Info "Rollback state retained for ${LocalServerName}: Front End $FrontEndPort=$oldLocalThumbprint Back End $BackEndPort=$oldLocalBackEndThumbprint"
$oldRemoteThumbprint        = ""
$oldRemoteBackEndThumbprint = ""
Start-Section -Id "S11" -Name "Secondary certificate staging"
if ($SecondNodeEnabled) {
	$remoteImportOk = Import-CertificateToRemoteServer -ServerName $RemoteExchangeServer -PfxFilePath $pfxFilePath `
		-PfxFileName $pfxFileName -PfxPassword $pfxPassword -ExpectedThumbprint $expectedThumbprint
	Remove-Variable pfxPassword -ErrorAction SilentlyContinue
	if (-not $remoteImportOk) {
		Log-Error "$LocalServerName passed validation, but certificate staging/import on $RemoteExchangeServer failed. Result: PARTIAL ($LocalServerName on new certificate, $RemoteExchangeServer unchanged)."
		Stop-Script -Code 1 -Reason "Secondary staging failed"
	}
	Start-Section -Id "S12" -Name "Exchange secondary certificate deployment on $RemoteExchangeServer"
	$remoteDeployment = Deploy-CertificateToServer -ServerName $RemoteExchangeServer -Services $RemoteServices -IsLocal $false
	if ($null -eq $remoteDeployment -or -not $remoteDeployment.Success) {
		Log-Error "$RemoteExchangeServer failed validation and was rolled back (or requires manual attention). $LocalServerName remains on the new certificate. Result: PARTIAL. Reason=$($remoteDeployment.Error)"
		Stop-Script -Code 1 -Reason "Secondary deployment failed"
	}
	$oldRemoteThumbprint        = [string]$remoteDeployment.PreviousThumbprint
	$oldRemoteBackEndThumbprint = [string]$remoteDeployment.BackEndBaseline
	Log-Info "Rollback state retained for ${RemoteExchangeServer}: Front End $FrontEndPort=$oldRemoteThumbprint Back End $BackEndPort=$oldRemoteBackEndThumbprint"
}
else {
	Log-Info "NodeMode=Single: secondary staging not applicable."
	Complete-Section -Status "SKIPPED" -Detail "NodeMode=Single"
	Start-Section -Id "S12" -Name "Exchange secondary certificate deployment"
	Log-Info "NodeMode=Single: secondary deployment not applicable."
	Complete-Section -Status "SKIPPED" -Detail "NodeMode=Single"
}
$coordinatedRollbackArgs = @{
	HybridSnapshotData         = $(if ($hybridSnapshot) { $hybridSnapshot.Data } else { $null })
	OldLocalThumbprint         = $oldLocalThumbprint
	OldLocalBackEndThumbprint  = $oldLocalBackEndThumbprint
	OldRemoteThumbprint        = $oldRemoteThumbprint
	OldRemoteBackEndThumbprint = $oldRemoteBackEndThumbprint
	IncludeRemote              = $SecondNodeEnabled
}
function Stop-AfterCoordinatedRollback {
	param([string]$Reason)
	$cr = Invoke-CoordinatedRollback -Reason $Reason @coordinatedRollbackArgs
	if ($cr.Success) {
		Log-Error "Result: FAILED / ROLLED BACK. $Reason The previous Exchange and Hybrid certificate state was restored."
	}
	else {
		Log-Critical "Result: FAILED / ROLLBACK INCOMPLETE. $Reason Manual intervention required. Errors=$($cr.Errors -join '; ')"
	}
	Stop-Script -Code 1 -Reason $Reason
}
Start-Section -Id "S13" -Name "Hybrid TLS update"
$hybridConnectorsChanged = $false
if ($HybridIsEnabled) {
	Log-Info "All managed Exchange servers ($($ManagedServers -join ',')) are validated on the new certificate. Updating Hybrid TLS..."
	$hybridUpdate = Invoke-ExchangeChild -Mode "HybridUpdate" -Thumbprint $thumbprint `
		-HybridSendConnector $hybridSendConnectorArg -HybridReceiveConnectors $hybridReceiveConnectorArg
	if (-not $hybridUpdate.Success) {
		Log-Critical "Hybrid TLS update failed after all managed Exchange servers were updated. Starting coordinated rollback. $($hybridUpdate.Error)"
		Stop-AfterCoordinatedRollback -Reason "Hybrid TLS update failed: $($hybridUpdate.Error)"
	}
	$hybridChanges           = @($hybridUpdate.Data.Changes)
	$hybridConnectorsChanged = [bool]$hybridUpdate.Data.ConnectorsChanged
	Log-Info "Hybrid TLS update response: $($hybridChanges.Count) change(s)"
	foreach ($change in $hybridChanges) {
		Log-Info "  $($change.Type) $($change.Identity):"
		Log-Info "    Previous: $($change.OldValue)"
		Log-Info "    New: $($change.NewValue)"
	}
	if ($hybridConfigManaged) {
		Log-Success "Hybrid Configuration TlsCertificateName references the new certificate"
	}
	Log-Info "Hybrid TLS update response indicates success"
	Log-Success "Hybrid connectors$(if ($hybridConfigManaged) { ' and Hybrid Configuration' }) verified on the new certificate"
}
else {
	Log-Info "Hybrid TLS update not applicable ($HybridDisabledReason)."
	Complete-Section -Status "SKIPPED" -Detail $HybridDisabledReason
}
Start-Section -Id "S14" -Name "Hybrid transport reload"
if ($HybridIsEnabled -and $hybridConnectorsChanged) {
	$transportServices = @("MSExchangeTransport")
	if ($RestartFrontEndTransport) { $transportServices += "MSExchangeFrontEndTransport" }
	try {
		foreach ($transportServer in $ManagedServers) {
			foreach ($svc in $transportServices) {
				$r = Restart-ServiceBounded -ComputerName $transportServer -ServiceName $svc `
					-StopTimeoutSeconds $TransportStopTimeoutSeconds -StartTimeoutSeconds $TransportStartTimeoutSeconds
				if (-not $r.Success) { throw "$svc restart failed on $transportServer. $($r.Error)" }
				Log-Success "$svc restarted on $transportServer"
			}
		}
	}
	catch {
		Write-LogException -ErrorRecord $_ -Context "Hybrid transport reload exception" -Level "DEBUG"
		Log-Critical "Hybrid connectors were updated, but the Transport reload failed. Starting coordinated rollback. $($_.Exception.Message)"
		Stop-AfterCoordinatedRollback -Reason "Transport reload failed after Hybrid update: $($_.Exception.Message)"
	}
}
elseif ($HybridIsEnabled) {
	Log-Info "Hybrid connectors already matched the new certificate. No Transport reload required (Hybrid Configuration changes do not require one)."
	Complete-Section -Status "SKIPPED" -Detail "No connector changes"
}
else {
	Log-Info "Hybrid transport reload not applicable ($HybridDisabledReason)."
	Complete-Section -Status "SKIPPED" -Detail $HybridDisabledReason
}
Start-Section -Id "S15" -Name "Final validation gate"
$backEndBaselines = @{ $LocalServerName = $oldLocalBackEndThumbprint }
if ($SecondNodeEnabled) { $backEndBaselines[$RemoteExchangeServer] = $oldRemoteBackEndThumbprint }
foreach ($node in $ManagedServers) {
	$finalBackEnd = Get-BackEndCertThumbprint -ComputerName $node
	if (-not $finalBackEnd) {
		Log-Critical "Final validation could not read Back End ($BackEndPort) on $node. No automatic rollback will be attempted. Manual investigation required."
		Stop-Script -Code 1 -Reason "Final Back End unreadable"
	}
	if ($finalBackEnd -ne $backEndBaselines[$node].ToUpperInvariant()) {
		Log-Critical "Final validation detected Back End ($BackEndPort) drift on $node. Expected=$($backEndBaselines[$node]) Actual=$finalBackEnd. No automatic rollback will be attempted."
		Stop-Script -Code 1 -Reason "Final Back End drift"
	}
}
Log-Success "Back End ($BackEndPort) bindings unchanged on all managed servers ($($ManagedServers -join ','))"
$finalValidationErrors = New-Object System.Collections.ArrayList
function Add-FinalValidationError {
	param([string]$Message)
	[void]$finalValidationErrors.Add($Message)
	Log-Error "Final validation: $Message"
}
foreach ($node in $ManagedServers) {
	Log-Info "Final validation of ${node}..."
	$isLocalNode  = ($node -eq $LocalServerName)
	$nodeTarget   = if ($isLocalNode) { "" } else { $node }
	$nodeServices = if ($isLocalNode) { $LocalServices } else { $RemoteServices }
	if ($ManagesIIS) {
		$finalFrontEnd = Get-FrontEndCertThumbprint -ComputerName $node
		if (-not $finalFrontEnd) {
			Add-FinalValidationError "Could not read Front End ($FrontEndPort) on $node."
		}
		elseif ($finalFrontEnd -ne $thumbprint.ToUpperInvariant()) {
			Add-FinalValidationError "Front End ($FrontEndPort) mismatch on $node. Expected=$($thumbprint.ToUpperInvariant()) Actual=$finalFrontEnd"
		}
	}
	else {
		Log-Info "IIS not selected: Front End ($FrontEndPort) check not applicable on $node."
	}
	if ($FinalFullRevalidation) {
		$finalCertificateValidation = Invoke-ExchangeChild -Mode "Validate" -Thumbprint $thumbprint -Services $nodeServices -TargetServer $nodeTarget
		if (-not $finalCertificateValidation.Success) {
			Add-FinalValidationError "Certificate service validation failed on $node. $($finalCertificateValidation.Error)"
		}
		$finalHealth = Invoke-ExchangeChild -Mode "HealthCheck" -TargetServer $nodeTarget
		if (-not $finalHealth.Success) {
			Add-FinalValidationError "Exchange health validation failed on $node. Mailflow=$($finalHealth.Data.MailflowResult) UnhealthyRoles=$(@($finalHealth.Data.UnhealthyRoles) -join ',')"
		}
	}
	else { Log-Info "Service assignment and health of $node were validated during deployment; final gate re-checks 444, 443, OWA/ECP and Hybrid TLS." }
	$finalProbe = Test-OwaEcp -ServerName $node -ExpectedThumbprint $(if ($ManagesIIS) { $thumbprint } else { "" })
	if (-not $finalProbe.Success) {
		Add-FinalValidationError "OWA/ECP validation failed on $node. OWA=$($finalProbe.Owa) ECP=$($finalProbe.Ecp)"
	}
}
if ($HybridIsEnabled) {
	Log-Info "Final Hybrid TLS verification..."
	$finalHybridSnapshot = Invoke-ExchangeChild -Mode "HybridSnapshot" -Thumbprint $thumbprint `
		-HybridSendConnector $hybridSendConnectorArg -HybridReceiveConnectors $hybridReceiveConnectorArg
	if (-not $finalHybridSnapshot.Success) {
		Add-FinalValidationError "Could not read final Hybrid TLS state. $($finalHybridSnapshot.Error)"
	}
	else {
		$expectedNorm = ConvertTo-NormalizedTlsName $newTlsCertificateName
		foreach ($sc in @($finalHybridSnapshot.Data.SendConnectors)) {
			if ((ConvertTo-NormalizedTlsName ([string]$sc.TlsCertificateName)) -ne $expectedNorm) {
				Add-FinalValidationError "Hybrid Send Connector TLS mismatch for $($sc.Identity). Expected=$newTlsCertificateName Actual=$($sc.TlsCertificateName)"
			}
			else {
				Log-Info "Final Send Connector TLS check response indicates success: $($sc.Identity)"
			}
		}
		foreach ($rc in @($finalHybridSnapshot.Data.ReceiveConnectors)) {
			if ((ConvertTo-NormalizedTlsName ([string]$rc.TlsCertificateName)) -ne $expectedNorm) {
				Add-FinalValidationError "Hybrid Receive Connector TLS mismatch for $($rc.Identity). Expected=$newTlsCertificateName Actual=$($rc.TlsCertificateName)"
			}
			else {
				Log-Info "Final Receive Connector TLS check response indicates success: $($rc.Identity)"
			}
		}
		if ($hybridConfigManaged) {
			$finalHc = $finalHybridSnapshot.Data.HybridConfiguration
			if (-not $finalHc -or [string]$finalHc.State -ne "Present") {
				Add-FinalValidationError "Hybrid Configuration object could not be read during final validation."
			}
			elseif ((ConvertTo-NormalizedTlsName ([string]$finalHc.TlsCertificateName)) -ne $expectedNorm) {
				Add-FinalValidationError "Hybrid Configuration TLS mismatch. Expected=$newTlsCertificateName Actual=$($finalHc.TlsCertificateName)"
			}
			else {
				Log-Info "Final Hybrid Configuration TLS check response indicates success"
			}
		}
	}
}
Log-Info "Final validation collected $($finalValidationErrors.Count) error(s)."
if ($finalValidationErrors.Count -gt 0) {
	$finalValidationReason = $finalValidationErrors -join "; "
	Log-Critical "Final validation failed. Starting coordinated rollback. Errors=$finalValidationReason"
	Stop-AfterCoordinatedRollback -Reason "Final validation failed: $finalValidationReason"
}
Log-Success "Final validation passed on all managed Exchange servers ($($ManagedServers -join ','))$(if ($HybridIsEnabled) { ' and all managed Hybrid TLS settings' })"
Start-Section -Id "S16" -Name "Old certificate removal"
$criticalRemovalFailure = $false
if ($RemoveOldCertificate -eq "false") {
	Log-Info "REMOVE_OLD_CERTIFICATE=false: previous certificates are retained."
	Complete-Section -Status "SKIPPED" -Detail "REMOVE_OLD_CERTIFICATE=false"
}
else {
	Log-Info "Old certificate removal mode: $RemoveOldCertificate"
	$previousByNode = @{ $LocalServerName = $oldLocalThumbprint }
	if ($SecondNodeEnabled) { $previousByNode[$RemoteExchangeServer] = $oldRemoteThumbprint }
	$newNameNorm = ConvertTo-NormalizedTlsName "<I>$certIssuer<S>$certSubject"
	$sameNameSet = @()
	foreach ($node in $ManagedServers) {
		$isLocalNode = ($node -eq $LocalServerName)
		$prev = ([string]$previousByNode[$node]).ToUpperInvariant()
		$nodeCands = @(); if ($prev) { $nodeCands += $prev }
		$snapData = if ($script:NodeSnapshots.ContainsKey($node)) { @($script:NodeSnapshots[$node].Data) } else { @() }
		foreach ($c in $snapData) {
			$ct = ([string]$c.Thumbprint).ToUpperInvariant()
			if (-not $ct -or $ct -eq $thumbprint.ToUpperInvariant() -or [bool]$c.IsSelfSigned) { continue }
			if ((ConvertTo-NormalizedTlsName "<I>$($c.Issuer)<S>$($c.Subject)") -ne $newNameNorm) { continue }
			$sameNameSet += $ct
			if ($nodeCands -notcontains $ct) { $nodeCands += $ct; Log-Info "Superseded certificate on ${node}: $ct (same Issuer/Subject as the new certificate, NotAfter $($c.NotAfter))" }
		}
		if ($nodeCands.Count -eq 0) { Log-Info "No old certificate candidates on $node."; continue }
		$nodeCheck = Invoke-ExchangeChild -Mode "RemovalCheck" -Thumbprint ($nodeCands -join "|") -TargetServer $(if ($isLocalNode) { "" } else { $node })
		foreach ($ct in $nodeCands) {
			try {
				$r = Invoke-OldCertificateRemoval -ServerName $node -IsLocal $isLocalNode -OldThumbprint $ct -BackEndThumbprint $backEndBaselines[$node] `
					-Services $(if ($isLocalNode) { $LocalServices } else { $RemoteServices }) -CheckResult $nodeCheck `
					-Kind $(if ($ct -eq $prev) { "previous Front End 443 certificate" } else { "superseded same-name certificate" })
			}
			catch {
				Write-LogException -ErrorRecord $_ -Context "Old certificate removal exception" -Level "DEBUG"
				Log-Warn "Old certificate removal on $node stopped by an unexpected error: $($_.Exception.Message). The new certificate remains live."
				$r = [PSCustomObject]@{ Server = $node; IsLocal = $isLocalNode; Thumbprint = $ct; Outcome = "FAILED"; Reason = $_.Exception.Message; Critical = $false }
			}
			[void]$script:OldCertificateResults.Add($r)
		}
	}
	$candidates = @($script:OldCertificateResults | Where-Object { $_.Outcome -eq "ELIGIBLE" -or $_.Outcome -eq "REPORT_ONLY" })
	$directRemoval = @(); $taggedRemoval = @(); $taggedConnectors = @{}; $kbBlockers = @(); $kbNewName = ""; $tiCache = @{}
	Log-Info "Elapsed $([int]$script:RunStopwatch.Elapsed.TotalSeconds)s of the ${TlmTimeLimitSeconds}s TLM post-script limit."
	foreach ($o in $candidates) {
		Log-Info "Step X4b ($($o.Server)): Checking send connectors that reference the old certificate name..."
		$tiKey = if ($sameNameSet -contains $o.Thumbprint) { "SAMENAME" } else { $o.Thumbprint }
		if ($tiCache.ContainsKey($tiKey)) { $ti = $tiCache[$tiKey]; Log-Info "Same certificate name as checked before; reusing the result." }
		else {
			$ti = Invoke-ExchangeChild -Mode "TaggedConnectors" -Thumbprint $o.Thumbprint -PreviousThumbprint $thumbprint -TargetServer $(if ($o.IsLocal) { "" } else { $o.Server })
			if ($ti.Success) { $tiCache[$tiKey] = $ti }
		}
		if (-not $ti.Success) {
			if ($o.Outcome -eq "ELIGIBLE") { $o.Outcome = "FAILED"; $o.Reason = "send connector check failed: $($ti.Error)" }
			Log-Warn "Send connector check failed on $($o.Server): $($ti.Error)"
			continue
		}
		$conns = @($ti.Data.Connectors | Where-Object { $_ })
		if ($conns.Count -eq 0) { Log-Info "No send connector references the old certificate name on $($o.Server)."; if ($o.Outcome -eq "ELIGIBLE") { $directRemoval += $o }; continue }
		foreach ($cn in $conns) { $taggedConnectors[[string]$cn.Identity] = $cn }
		if (-not [bool]$ti.Data.SameName) { $kbBlockers += "$($o.Server): send connector(s) reference the OLD certificate name, which differs from the new certificate" }
		elseif (-not [bool]$ti.Data.NewValid) { $kbBlockers += "$($o.Server): new certificate is not valid or has no private key" }
		$kbNewName = [string]$ti.Data.NewTlsName
		$taggedRemoval += $o
	}
	$kbSources = @($taggedConnectors.Values | ForEach-Object { ([string]$_.Sources) -split "," } | Where-Object { $_ } | ForEach-Object { $_.Trim().ToUpperInvariant() } | Select-Object -Unique)
	$unmanagedSources = @($kbSources | Where-Object { $ManagedServers -notcontains $_ })
	if ($unmanagedSources.Count -gt 0) { $kbBlockers += "send connector source server(s) not managed by this run: $($unmanagedSources -join ',')" }
	if ($taggedRemoval.Count -gt 0) {
		Log-Info "Tagged send connector(s): $($taggedConnectors.Keys -join '; ') | source transport servers: $($kbSources -join ',')"
		if ($kbBlockers.Count -gt 0) {
			Log-Warn "Microsoft KB removal procedure cannot run automatically: $($kbBlockers -join '; '). Old certificate(s) kept."
			foreach ($o in $taggedRemoval) { if ($o.Outcome -eq "ELIGIBLE") { $o.Outcome = "SKIPPED"; $o.Reason = "send connector tagged; $($kbBlockers -join '; ')" } }
			$taggedRemoval = @()
		}
		elseif ($RemoveOldCertificate -eq "report") {
			Log-Info "REPORT ONLY: removal would use the Microsoft procedure: stop MSExchangeTransport on $($kbSources -join ','), clear TlsCertificateName on $($taggedConnectors.Keys -join '; '), remove the old certificate from all servers, set TlsCertificateName to $kbNewName, start MSExchangeTransport."
			$taggedRemoval = @()
		}
	}
	foreach ($o in $directRemoval) { [void](Complete-OldCertificateRemoval $o) }
	$taggedRemoval = @($taggedRemoval | Where-Object { $_.Outcome -eq "ELIGIBLE" })
	if ($taggedRemoval.Count -gt 0) {
		Invoke-TaggedCertificateRemoval -Outcomes $taggedRemoval -Connectors @($taggedConnectors.Values) -SourceServers $kbSources -NewTlsName $kbNewName
	}
	foreach ($o in $script:OldCertificateResults) { if ($o.Critical) { $criticalRemovalFailure = $true } }
	if ($criticalRemovalFailure) {
		Stop-Script -Code 1 -Reason "Critical failure during old certificate removal - see CRITICAL lines"
	}
}
if ($HybridIsEnabled -and $newTlsCertificateName) {
	$left = $TlmTimeLimitSeconds - [int]$script:RunStopwatch.Elapsed.TotalSeconds
	if ($left -lt 25) { Log-Warn "Hybrid certificate resolution check skipped: ${left}s left of the TLM limit." }
	else {
		Log-Info "Step X7: Verifying the Hybrid TLS name resolves only to the new certificate on every managed server..."
		$nm = Invoke-ExchangeChild -Mode "NameMatch" -ManagedServers ($ManagedServers -join "|") -HybridRestoreStateBase64 ([System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($newTlsCertificateName)))
		if (-not $nm.Success) { Log-Warn "Hybrid certificate resolution check failed: $($nm.Error)" }
		else {
			foreach ($row in @($nm.Data.Servers)) {
				$ms = @(([string]$row.Matches) -split "," | Where-Object { $_ })
				if ($ms.Count -eq 1 -and $ms[0] -eq $thumbprint.ToUpperInvariant()) { Log-Success "Hybrid send/receive connectors resolve to exactly one certificate on $($row.Server): $($ms[0])" }
				elseif ($ms -contains $thumbprint.ToUpperInvariant()) { Log-Warn "Hybrid TLS name matches $($ms.Count) certificates on $($row.Server): $($ms -join ','). Exchange may present any of them until the extra(s) are removed." }
				else { Log-Error "Hybrid TLS name does not match the new certificate on $($row.Server) (matches: $($ms -join ','))." }
			}
		}
	}
}
Log-Success "Certificate replacement completed. NodeMode=$NodeMode Servers=$($ManagedServers -join ',') CN=$commonName Thumbprint=$thumbprint Archive=$archiveDir"
Stop-Script -Code 0
