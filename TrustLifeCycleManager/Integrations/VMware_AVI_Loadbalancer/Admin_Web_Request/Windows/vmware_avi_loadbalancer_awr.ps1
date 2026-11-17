#requires -Version 5.1
<#
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

DigiCert TLM AWR post-delivery script for Windows.
Revision: 2026-11-17-win1.1. Based on the Linux v5.3 binding workflow.
Save as UTF-8 WITH BOM so Windows PowerShell 5.1 reads the Legal Notice and
other non-ASCII text correctly. LF or CRLF line endings both work.
Target: Windows PowerShell 5.1 or PowerShell 7 on Windows.
Dependencies: curl.exe and OpenSSL (openssl.exe). No Bash, jq or Python needed.

AWR arguments, in the same order as the Linux script:
 1 Controller hostname/IPv4[:port], WITHOUT https:// or a path.
 2 Username.
 3 Password. Configure in TLM, never hardcode in this file.
 4 Tenant name.
 5 Comma-separated Virtual Service names/UUIDs: web-vs,api-vs.
   Dots, hyphens and underscores are supported: www.example.com_VIP.
   A single target also works. No semicolons, empty entries or control chars.
 6 Certificate object name prefix: tlm-web (1-40 letters/digits/_/-).
 7 AUTO_SINGLE (default), slot:N (zero based), old certificate name/UUID,
   or NONE (only for an empty certificate binding).
 8 dry-run (default) or apply.
 9 API version (default 30.2.2).
10 Optional PEM CA bundle path on the Windows Agent, e.g. C:\PKI\avi-ca.pem.

Arguments 1-6 are required. Argument 7 applies to every target to be updated.
All VSs must be in the selected Controller/tenant. Use separate runs otherwise.
Select the SNI child to change only its binding. Its parent is read to check
the listener. To update the parent too, explicitly list it in argument 5.
Normal VSs, SNI children and explicit SNI parents are supported; EVH is not.

Delivery format: PEM .crt plus exactly one matching, UNENCRYPTED PEM .key.
Optional intermediate PEM files ending in _ica.cer or _ica.crt are included.
PFX/P12, JKS, encrypted keys and Windows certificate-store imports are not
implemented in this port. Select the same .crt delivery format used on Linux.

After accepting the Legal Notice, set $LEGAL_NOTICE_ACCEPT = "true" below.
Any other value, including "false" or an empty string, stops the script.
Upload this .ps1 as an Admin request post-delivery script and select it on the
Windows Agent integration. Follow your organization's PowerShell execution
and signing policy; the script does not modify execution policy.

Tools must be visible to the Agent SERVICE ACCOUNT. Optional process/machine
environment variables allow absolute executable paths:
  AVI_CURL_PATH       C:\Windows\System32\curl.exe
  AVI_OPENSSL_PATH    C:\Program Files\OpenSSL-Win64\bin\openssl.exe
  AVI_LOGFILE         C:\ProgramData\DigiCert\TLM\AVI-AWR\avi-upload.log
Use curl.exe 7.70 or newer (not the PowerShell curl alias), with HTTPS support.
Use an organization-approved, maintained OpenSSL distribution.
Check tool paths/trust under the Agent account, not only an interactive user.

HTTPS certificate verification is enabled. If necessary provide argument 10.
The Agent may inherit proxy variables; configure NO_PROXY for the Controller
when it should be reached directly. The script does not change proxy settings.

Use dry-run first, then apply. Verify hostname/SNI and certificate SAN coverage.
The script reads back AVI configuration, but does not probe endpoint TLS.
Bindings are sequential, NOT transactional. First failure stops execution;
earlier successes remain. No automatic retry/rollback or old-object deletion.
The previous-binding snapshots contain references, not private keys, and
are not an automatic restore mechanism. Inspect AVI before retrying a timeout.
Do not run concurrent writers against the same VS.

Logging: every run appends to the log file (default
%ProgramData%\DigiCert\TLM\AVI-AWR\avi-upload.log, override with AVI_LOGFILE).
Lines carry a UTC timestamp and run id. The log records inputs, tool versions,
the selected certificate, each API call (method, path, HTTP status), the plan,
snapshots, writes and a per-VS RESULT line. It never records the password,
private key, cookies, CSRF token or Controller response bodies.

This Windows port requires validation on the target Windows Agent and AVI.
#>

$LEGAL_NOTICE_ACCEPT = "false"   # Set to "true" after accepting the notice above.
$script:Revision = '2026-11-17-win1.1'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Lf = [string][char]10
$script:WindowsHost = [System.IO.Path]::DirectorySeparatorChar -eq '\'
$script:LogPath = $null
$script:WorkDir = $null
$script:Targets = New-Object 'System.Collections.Generic.List[object]'
$script:RunId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + $PID
$script:Phase = 'INPUT'
$script:Mode = 'unknown'
$script:ActiveTarget = $null
$script:SummaryReady = $false

function Stop-Avi {
    param([string]$Message)
    throw [System.InvalidOperationException]::new('[AVI] ' + $Message)
}

function Get-Field {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return ,$Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return ,$Default }
    return ,$property.Value
}

function Write-AviLog {
    param([string]$Message)
    if ($script:LogPath) {
        $line = '[{0}] [run={1}] {2}{3}' -f [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'), $script:RunId, $Message, $script:Lf
        [IO.File]::AppendAllText($script:LogPath, $line, $script:Utf8)
    }
}

function Get-SafeText {
    param([AllowNull()][string]$Text, [int]$MaxLength = 240)
    # Single line, no control characters, bounded length: safe for the log.
    if (-not $Text) { return '' }
    $clean = [regex]::Replace($Text, '[\x00-\x1f\x7f]', ' ').Trim()
    if ($clean.Length -gt $MaxLength) { $clean = $clean.Substring(0, $MaxLength) }
    return $clean
}

function Get-CurlReason {
    param([string]$StdErr)
    # Only curl's own "curl: (N) reason" line (DNS, TLS trust, proxy, timeout).
    # --silent --show-error prints no request or response data, but filter anyway.
    $match = [regex]::Match([string]$StdErr, '(?m)^curl: \([0-9]+\)[^\r\n]*')
    if ($match.Success) { return Get-SafeText $match.Value }
    return 'no curl diagnostic'
}

function Set-PrivateAccess {
    param([string]$Path, [switch]$Directory)
    if ($script:WindowsHost) {
        $acl = if ($Directory) {
            New-Object System.Security.AccessControl.DirectorySecurity
        } else {
            New-Object System.Security.AccessControl.FileSecurity
        }
        $acl.SetAccessRuleProtection($true, $false)
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.SetOwner($currentSid)
        foreach ($sid in @($currentSid.Value, 'S-1-5-18', 'S-1-5-32-544') | Select-Object -Unique) {
            $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
            if ($Directory) {
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $identity, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
            } else {
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $identity, 'FullControl', 'Allow')
            }
            [void]$acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $Path -AclObject $acl
    } else {
        # Enables the offline suite on PowerShell 7/Linux; not a Windows ACL test.
        $permissions = if ($Directory) { '700' } else { '600' }
        & chmod -- $permissions $Path
        if ($LASTEXITCODE -ne 0) { Stop-Avi 'Unable to restrict local file permissions.' }
    }
}

function Write-PrivateText {
    param([string]$Path, [string]$Text)
    if (-not [IO.File]::Exists($Path)) {
        $stream = [IO.File]::Create($Path)
        $stream.Dispose()
    }
    if (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-Avi 'Refusing to write through a reparse point.'
    }
    Set-PrivateAccess -Path $Path
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}

function Write-JsonFile {
    param([string]$Path, $Value)
    Write-PrivateText -Path $Path -Text (ConvertTo-Json -InputObject $Value -Depth 40 -Compress)
}

function Get-ToolPath {
    param([string]$Override, [string]$Name)
    if ($Override) {
        if (-not [IO.Path]::IsPathRooted($Override) -or -not [IO.File]::Exists($Override)) {
            Stop-Avi ('Configured executable path is invalid for {0}.' -f $Name)
        }
        return [IO.Path]::GetFullPath($Override)
    }
    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { Stop-Avi ('Missing {0}; configure its path for the Agent service account.' -f $Name) }
    return $command.Source
}

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    # Windows CRT quoting. Handles spaces, quotes and trailing backslashes.
    # ProcessStartInfo.UseShellExecute=false: no cmd.exe or shell expansion.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-NativeProcess {
    param([string]$Executable, [string[]]$Arguments, [int]$TimeoutSeconds = 110)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { Stop-Avi 'Unable to start a required executable.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            Stop-Avi 'External process timed out; inspect Controller state if a write was attempted.'
        }
        $process.WaitForExit()
        return [pscustomobject]@{
            Code = $process.ExitCode
            Out = $stdout.GetAwaiter().GetResult()
            Err = $stderr.GetAwaiter().GetResult()
        }
    } finally { $process.Dispose() }
}

function Invoke-OpenSsl {
    param([string[]]$Arguments)
    return Invoke-NativeProcess -Executable $script:OpenSsl -Arguments $Arguments
}

function Get-Fingerprint {
    param([string]$Path)
    $result = Invoke-OpenSsl @('x509', '-in', $Path, '-noout', '-fingerprint', '-sha256')
    if ($result.Code -ne 0 -or $result.Out -notmatch '=\s*([0-9A-Fa-f:]+)\s*$') {
        Stop-Avi 'Unable to read a PEM certificate fingerprint.'
    }
    $fingerprint = $Matches[1].Replace(':', '').ToLowerInvariant()
    if ($fingerprint -notmatch '\A[0-9a-f]{64}\z') { Stop-Avi 'Invalid SHA256 fingerprint.' }
    return $fingerprint
}

function Get-ErrorCategory {
    param([string]$Body)
    switch -Regex ($Body) {
        'csrf|cross.site request forgery' { return 'CSRF_SESSION: check session/token and request origin' }
        'permission|privilege|rbac|not authori[sz]ed|access denied|authori[sz]ation failed' {
            return 'AUTHORIZATION: check account role and tenant/object scope'
        }
        'tenant' { return 'TENANT_SCOPE: check tenant access and object scope' }
        'session.*expir|authentication|not authenticated|login required' { return 'AUTHENTICATION: check Controller session' }
        'method not allowed|unsupported method' { return 'HTTP_METHOD: unsupported method' }
        default { return 'UNCLASSIFIED: consult Controller API/audit logs' }
    }
}

function Get-Csrf {
    $token = $null
    if ([IO.File]::Exists($script:CookieFile)) {
        foreach ($line in [IO.File]::ReadAllLines($script:CookieFile)) {
            $fields = $line.Split([char]9)
            if ($fields.Count -eq 7 -and $fields[5] -ceq 'csrftoken') { $token = $fields[6] }
        }
    }
    if (-not $token -or $token -match '[\r\n]') { Stop-Avi 'No valid CSRF cookie in the current Controller session.' }
    return $token
}

function Invoke-CurlRequest {
    param([string]$Method, [string]$Path, [string]$BodyPath = '', [switch]$Login)
    $responsePath = Join-Path $script:WorkDir 'response.json'
    $headerPath = Join-Path $script:WorkDir 'headers.txt'
    $headers = @('Content-Type: application/json')
    if (-not $Login) {
        $headers += 'X-CSRFToken: ' + (Get-Csrf)
        $headers += 'X-Avi-Version: ' + $script:ApiVersion
        $headers += 'X-Avi-Tenant: ' + $script:Tenant
        $headers += 'Referer: https://' + $script:Controller + '/'
    }
    Write-PrivateText $headerPath (($headers -join $script:Lf) + $script:Lf)
    $curlArguments = @(
        '--disable', '--silent', '--show-error', '--connect-timeout', '15',
        '--max-time', '90', '--proto', '=https', '--cookie-jar', $script:CookieFile,
        '--header', ('@' + $headerPath), '--request', $Method,
        '--output', $responsePath, '--write-out', '%{http_code}'
    )
    if (-not $Login) { $curlArguments += @('--cookie', $script:CookieFile) }
    if ($script:CaBundle) { $curlArguments += @('--cacert', $script:CaBundle) }
    if ($BodyPath) { $curlArguments += @('--data-binary', ('@' + $BodyPath)) }
    $curlArguments += 'https://' + $script:Controller + $Path
    # Log the path without its query string (names are logged elsewhere).
    $apiPath = $Path.Split([char]'?')[0]
    $result = Invoke-NativeProcess -Executable $script:Curl -Arguments $curlArguments
    if ($result.Code -ne 0) {
        # Never print raw stderr; Get-CurlReason keeps only curl's reason line.
        Stop-Avi ('{0} {1} transport failure (curl exit {2}: {3}); check Controller reachability, DNS, proxy, TLS trust (argument 10) and state before retrying.' -f $Method, $apiPath, $result.Code, (Get-CurlReason $result.Err))
    }
    $code = $result.Out.Trim()
    $body = if ([IO.File]::Exists($responsePath)) { [IO.File]::ReadAllText($responsePath) } else { '' }
    if (($Login -and $code -cne '200') -or (-not $Login -and $code -notmatch '\A2[0-9]{2}\z')) {
        Stop-Avi ('{0} {1} failed (HTTP {2}). {3}. No automatic retry.' -f $Method, $apiPath, $code, (Get-ErrorCategory $body))
    }
    Write-AviLog ('API: {0} {1} HTTP {2}' -f $Method, $apiPath, $code)
    if ($Login) { return }
    try { $value = ConvertFrom-Json -InputObject $body -ErrorAction Stop } catch { Stop-Avi 'Invalid JSON API response.' }
    if ($null -eq $value -or $value -isnot [pscustomobject]) { Stop-Avi 'API response is not a JSON object.' }
    return $value
}

function Invoke-AviApi {
    param([string]$Method, [string]$Path, $Body = $null)
    $bodyPath = ''
    if ($null -ne $Body) {
        $bodyPath = Join-Path $script:WorkDir 'request-body.json'
        Write-JsonFile $bodyPath $Body
    }
    return Invoke-CurlRequest -Method $Method -Path $Path -BodyPath $bodyPath
}

function Resolve-AviObject {
    param([string]$Kind, [string]$Selector)
    if ($Selector -cmatch ('\A' + $Kind + '-[a-fA-F0-9-]+\z')) {
        $object = Invoke-AviApi 'GET' ('/api/{0}/{1}' -f $Kind, $Selector)
        if ((Get-Field $object 'uuid') -cne $Selector) { Stop-Avi 'Resolved object UUID does not match the requested UUID.' }
    } else {
        $response = Invoke-AviApi 'GET' ('/api/{0}?name={1}&page_size=2' -f $Kind, [Uri]::EscapeDataString($Selector))
        $items = Get-Field $response 'results' @()
        if ($items -isnot [array] -or (Get-Field $response 'count' -1) -ne 1 -or $items.Count -ne 1 -or
            (Get-Field $items[0] 'name') -cne $Selector) { Stop-Avi ('No unique {0} match for the specified selector.' -f $Kind) }
        $object = $items[0]
    }
    $uuid = Get-Field $object 'uuid' ''
    if ($uuid -cnotmatch ('\A' + $Kind + '-[a-fA-F0-9-]+\z')) { Stop-Avi 'API object has no valid UUID.' }
    return $object
}

function Get-CertReferences {
    param($Vs)
    $value = Get-Field $Vs 'ssl_key_and_certificate_refs' @()
    if ($value -isnot [array]) { Stop-Avi 'Invalid Virtual Service certificate reference list.' }
    foreach ($reference in $value) {
        if ($reference -isnot [string]) { Stop-Avi 'Invalid certificate reference type.' }
        $reference
    }
}

function Get-ReferenceIds {
    param([object[]]$References)
    foreach ($reference in $References) { ($reference -split '/')[-1].Split('?')[0] }
}

function Get-BindingSignature {
    param($Vs)
    return ConvertTo-Json -InputObject @(Get-ReferenceIds @(Get-CertReferences $Vs)) -Compress
}

function Test-TlsListener {
    param($Vs)
    $services = Get-Field $Vs 'services' @()
    foreach ($service in $services) {
        if ((Get-Field $service 'enable_ssl' $false) -eq $true) { return $true }
    }
    return $false
}

function Get-ValidatedTopology {
    param($Vs, [string]$ExpectedUuid)
    if ((Get-Field $Vs 'uuid') -cne $ExpectedUuid) { Stop-Avi 'Virtual Service response UUID mismatch.' }
    $type = Get-Field $Vs 'type' 'VS_TYPE_NORMAL'
    $parentUuid = ''
    switch -CaseSensitive ($type) {
        'VS_TYPE_NORMAL' {
            if (-not (Test-TlsListener $Vs)) { Stop-Avi 'Selected Virtual Service has no TLS-enabled listener.' }
        }
        'VS_TYPE_VH_CHILD' {
            if ((Get-Field $Vs 'vh_type' 'VS_TYPE_VH_SNI') -cne 'VS_TYPE_VH_SNI') { Stop-Avi 'Enhanced Virtual Hosting (EVH) is not supported.' }
            $parentRef = Get-Field $Vs 'vh_parent_vs_ref' ''
            if ($parentRef -isnot [string] -or
                $parentRef -cnotmatch '\A(?:https?://[^/\s?#]+)?/api/virtualservice/(?<uuid>virtualservice-[a-fA-F0-9-]+)(?:\?[^\s#]*)?\z') {
                Stop-Avi 'SNI child has no valid vh_parent_vs_ref; no parent will be guessed.'
            }
            $parentUuid = $Matches['uuid']
            if ($parentUuid -ceq $ExpectedUuid) { Stop-Avi 'SNI child references itself as parent.' }
            Write-AviLog ('SNI_PARENT_CHECK: child={0} parent={1} action=GET_ONLY' -f $ExpectedUuid, $parentUuid)
            $parent = Invoke-AviApi 'GET' ('/api/virtualservice/' + $parentUuid)
            if ((Get-Field $parent 'uuid') -cne $parentUuid -or (Get-Field $parent 'type') -cne 'VS_TYPE_VH_PARENT') {
                Stop-Avi 'SNI parent response has an unexpected UUID or type.'
            }
            if ((Get-Field $parent 'vh_type' 'VS_TYPE_VH_SNI') -cne 'VS_TYPE_VH_SNI') { Stop-Avi 'Referenced parent is not SNI; EVH is not supported.' }
            if (-not (Test-TlsListener $parent)) { Stop-Avi 'SNI parent has no TLS-enabled listener.' }
        }
        'VS_TYPE_VH_PARENT' {
            if ((Get-Field $Vs 'vh_type' 'VS_TYPE_VH_SNI') -cne 'VS_TYPE_VH_SNI') { Stop-Avi 'Enhanced Virtual Hosting (EVH) is not supported.' }
            if (-not (Test-TlsListener $Vs)) { Stop-Avi 'Explicitly selected SNI parent has no TLS-enabled listener.' }
            Write-AviLog ('SNI_PARENT_TARGET: {0} explicitly selected in argument 5.' -f $ExpectedUuid)
        }
        default { Stop-Avi 'Unsupported Virtual Service type.' }
    }
    $null = @(Get-CertReferences $Vs)
    return '{0}:{1}' -f $type, $parentUuid
}

function Confirm-Target {
    param($Target)
    $vs = Invoke-AviApi 'GET' ('/api/virtualservice/' + $Target.Uuid)
    $topology = Get-ValidatedTopology $vs $Target.Uuid
    if ($topology -cne $Target.Topology) { Stop-Avi 'Virtual Service type or SNI parent changed concurrently.' }
    if ((Get-BindingSignature $vs) -cne $Target.Before) { Stop-Avi 'Bindings changed concurrently; refusing to overwrite.' }
    return $vs
}

function Get-ArgumentValue {
    param([object[]]$Arguments, [int]$Index, [string]$Default = '')
    if ($Index -ge $Arguments.Count -or $null -eq $Arguments[$Index] -or $Arguments[$Index] -ceq '') { return $Default }
    if ($Arguments[$Index] -isnot [string]) { Stop-Avi ('Argument {0} must be a string.' -f ($Index + 1)) }
    return [string]$Arguments[$Index]
}

function Invoke-AviMain {
    # Exact string match: a boolean $false or the string "false" both stop here.
    if ([string]$LEGAL_NOTICE_ACCEPT -ne 'true') { Stop-Avi 'Legal notice not accepted. Set $LEGAL_NOTICE_ACCEPT = "true" after accepting the Legal Notice.' }
    Write-AviLog 'LEGAL_NOTICE: accepted (LEGAL_NOTICE_ACCEPT="true").'
    $script:Curl = Get-ToolPath $env:AVI_CURL_PATH 'curl.exe'
    $script:OpenSsl = Get-ToolPath $env:AVI_OPENSSL_PATH 'openssl.exe'
    $curlVersion = Get-SafeText (((Invoke-NativeProcess -Executable $script:Curl -Arguments @('--version') -TimeoutSeconds 15).Out -split '\r?\n')[0]) 80
    $openSslVersion = Get-SafeText (Invoke-OpenSsl @('version')).Out 80
    Write-AviLog ('INPUT_RUNTIME: revision={0} PowerShell={1} curl={2} [{3}] openssl={4} [{5}]' -f $script:Revision, $PSVersionTable.PSVersion, $script:Curl, $curlVersion, $script:OpenSsl, $openSslVersion)
    if (-not $env:DC1_POST_SCRIPT_DATA) { Stop-Avi 'DC1_POST_SCRIPT_DATA is missing.' }
    try {
        $decoded = $script:Utf8.GetString([Convert]::FromBase64String($env:DC1_POST_SCRIPT_DATA))
        $request = ConvertFrom-Json -InputObject $decoded -ErrorAction Stop
    } catch { Stop-Avi 'Invalid Base64 or JSON AWR execution data.' }
    $arguments = Get-Field $request 'args'
    $files = Get-Field $request 'files'
    $certFolder = Get-Field $request 'certfolder'
    if ($arguments -isnot [array] -or $files -isnot [array] -or $certFolder -isnot [string]) { Stop-Avi 'Invalid AWR JSON schema.' }
    $script:Controller = Get-ArgumentValue $arguments 0
    $username = Get-ArgumentValue $arguments 1
    $password = Get-ArgumentValue $arguments 2
    $script:Tenant = Get-ArgumentValue $arguments 3
    $targetList = Get-ArgumentValue $arguments 4
    $prefix = Get-ArgumentValue $arguments 5
    $selector = Get-ArgumentValue $arguments 6 'AUTO_SINGLE'
    $script:Mode = Get-ArgumentValue $arguments 7 'dry-run'
    $script:ApiVersion = Get-ArgumentValue $arguments 8 '30.2.2'
    $script:CaBundle = Get-ArgumentValue $arguments 9
    if (-not $script:Controller -or -not $username -or -not $password -or -not $script:Tenant -or -not $targetList -or -not $prefix) {
        Stop-Avi 'Arguments 1 through 6 are required.'
    }
    if ($script:Controller -cnotmatch '\A[a-zA-Z0-9.-]+(:[0-9]+)?\z') { Stop-Avi 'Controller must be hostname/IPv4[:port], without scheme/path.' }
    if ($script:ApiVersion -notmatch '\A[0-9]+\.[0-9]+\.[0-9]+\z') { Stop-Avi 'Invalid API version.' }
    if ($prefix -cnotmatch '\A[a-zA-Z0-9_-]{1,40}\z') { Stop-Avi 'Certificate prefix must be 1-40 letters, digits, underscores or hyphens.' }
    if ($script:Mode -cne 'dry-run' -and $script:Mode -cne 'apply') { Stop-Avi 'Mode must be dry-run or apply.' }
    if ($script:Tenant -match '[\r\n]' -or $username -match '[\r\n]') { Stop-Avi 'Invalid newline in input.' }
    $invalid = @()
    for ($index = 0; $index -lt $targetList.Length; $index++) {
        $code = [int]$targetList[$index]
        if ($code -eq 59 -or $code -lt 32 -or $code -eq 127) {
            $kind = switch ($code) { 13 { 'CR' } 10 { 'LF' } 9 { 'TAB' } 59 { 'SEMICOLON' } 127 { 'DEL' } default { 'CONTROL' } }
            $invalid += [ordered]@{ position = $index + 1; codepoint = $code; kind = $kind }
        }
    }
    $report = ConvertTo-Json -InputObject ([ordered]@{ type = 'string'; characters = $targetList.Length; commas = ([regex]::Matches($targetList, ',')).Count; invalid = @($invalid) }) -Depth 8 -Compress
    Write-AviLog ('INPUT_CHECK: ' + $report)
    [Console]::WriteLine('AVI AWR INPUT_CHECK: ' + $report)
    if ($invalid.Count -gt 0) { Stop-Avi 'Argument 5 contains prohibited characters; see INPUT_CHECK. Use commas only.' }
    foreach ($name in $targetList.Split([char]',')) {
        $trimmed = $name.Trim([char]' ')
        if (-not $trimmed) { Stop-Avi 'Argument 5 contains an empty entry.' }
        $script:Targets.Add([pscustomobject]@{
            Name = $trimmed; Uuid = ''; Status = 'PENDING'; Before = ''; Topology = ''; Index = -1; Snapshot = ''
        })
    }
    $script:SummaryReady = $true
    Write-AviLog ('START: revision={0} mode={1} controller={2} api_version={3} tenant={4} selector={5} prefix={6} requested_targets={7}' -f $script:Revision, $script:Mode, $script:Controller, $script:ApiVersion, $script:Tenant, $selector, $prefix, $script:Targets.Count)
    if ($script:CaBundle -and -not [IO.File]::Exists($script:CaBundle)) { Stop-Avi 'Controller CA bundle does not exist.' }
    if ($script:CaBundle) { Write-AviLog ('TLS_TRUST: CA bundle ' + $script:CaBundle) }
    else { Write-AviLog 'TLS_TRUST: curl default trust store (argument 10 not set)' }
    if (-not [IO.Path]::IsPathRooted($certFolder) -or -not [IO.Directory]::Exists($certFolder)) { Stop-Avi 'AWR certificate directory must be an existing absolute path.' }
    foreach ($file in $files) {
        if ($file -isnot [string] -or -not $file -or $file -match '[/\\:\x00-\x1f]' -or $file -eq '.' -or $file -eq '..') {
            Stop-Avi 'AWR files must be basenames, without paths or alternate data streams.'
        }
        if (-not [IO.File]::Exists((Join-Path $certFolder $file))) { Stop-Avi 'A delivered file listed in the manifest is missing.' }
    }
    $keys = @($files | Where-Object { $_ -match '\.key\z' })
    $crts = @($files | Where-Object { $_ -match '\.crt\z' })
    if ($keys.Count -ne 1) { Stop-Avi 'Deliver PEM .crt with exactly one unencrypted .key; PFX/P12 is not supported.' }
    $keyPath = Join-Path $certFolder $keys[0]
    $keyResult = Invoke-OpenSsl @('pkey', '-in', $keyPath, '-passin', 'pass:', '-pubout')
    if ($keyResult.Code -ne 0) { Stop-Avi 'Private key is unreadable or encrypted.' }
    $matching = @()
    foreach ($crt in $crts) {
        $candidate = Join-Path $certFolder $crt
        $public = Invoke-OpenSsl @('x509', '-in', $candidate, '-pubkey', '-noout')
        if ($public.Code -eq 0 -and $public.Out.Trim() -ceq $keyResult.Out.Trim()) { $matching += $candidate }
    }
    if ($matching.Count -ne 1) { Stop-Avi 'Expected exactly one PEM .crt matching the delivered private key.' }
    $crtPath = $matching[0]
    if ((Invoke-OpenSsl @('x509', '-in', $crtPath, '-checkend', '0', '-noout')).Code -ne 0) { Stop-Avi 'Delivered certificate has expired or is invalid.' }
    $fingerprint = Get-Fingerprint $crtPath
    $certName = $prefix + '-' + $fingerprint
    $chainInput = [IO.File]::ReadAllText($crtPath)
    foreach ($file in $files) {
        $path = Join-Path $certFolder $file
        if ($file -match '_ica\.(cer|crt)\z' -and $path -cne $crtPath) { $chainInput += $script:Lf + [IO.File]::ReadAllText($path) }
    }
    $chainParts = [regex]::Matches($chainInput, '-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----')
    if ($chainParts.Count -eq 0) { Stop-Avi 'No PEM certificates found.' }
    $chain = ''
    $seenCertificates = @{}
    $partPath = Join-Path $script:WorkDir 'part.pem'
    foreach ($part in $chainParts) {
        Write-PrivateText $partPath $part.Value
        $partFingerprint = Get-Fingerprint $partPath
        if (-not $seenCertificates.ContainsKey($partFingerprint)) {
            $chain += $part.Value.Replace(([string][char]13), '') + $script:Lf
            $seenCertificates[$partFingerprint] = $true
        }
    }
    $details = @{}
    $detailResult = Invoke-OpenSsl @('x509', '-in', $crtPath, '-noout', '-subject', '-nameopt', 'RFC2253', '-enddate', '-serial')
    foreach ($detailLine in ($detailResult.Out -split '\r?\n')) {
        if ($detailLine -match '\A(subject|notAfter|serial)\s*=\s*(.*)\z') { $details[$Matches[1]] = Get-SafeText $Matches[2] }
    }
    Write-AviLog ('CERT_SELECTED: file={0} key={1} subject={2} serial={3} not_after={4} SHA256={5} chain_certs={6} object_name={7}' -f
        [IO.Path]::GetFileName($crtPath), $keys[0], $details['subject'], $details['serial'], $details['notAfter'], $fingerprint, $seenCertificates.Count, $certName)
    $script:CookieFile = Join-Path $script:WorkDir 'cookies.txt'
    $loginPath = Join-Path $script:WorkDir 'login.json'
    Write-JsonFile $loginPath @{ username = $username; password = $password }
    Write-AviLog ('LOGIN: POST https://{0}/login' -f $script:Controller)
    Invoke-CurlRequest -Method 'POST' -Path '/login' -BodyPath $loginPath -Login
    $null = Get-Csrf
    Write-AviLog 'LOGIN: succeeded (HTTP 200)'

    $script:Phase = 'PREFLIGHT'
    $newUuid = ''
    $existing = Invoke-AviApi 'GET' ('/api/sslkeyandcertificate?name=' + [Uri]::EscapeDataString($certName) + '&page_size=2')
    $existingCount = Get-Field $existing 'count' -1
    if ($existingCount -eq 1) {
        $items = Get-Field $existing 'results' @()
        if ($items -isnot [array] -or $items.Count -ne 1 -or (Get-Field $items[0] 'name') -cne $certName) { Stop-Avi 'Certificate lookup is ambiguous.' }
        $newUuid = Get-Field $items[0] 'uuid' ''
        if ($newUuid -cnotmatch '\Asslkeyandcertificate-[a-fA-F0-9-]+\z') { Stop-Avi 'Invalid existing certificate UUID.' }
        $existingPem = Join-Path $script:WorkDir 'existing.pem'
        Write-PrivateText $existingPem (Get-Field (Get-Field $items[0] 'certificate') 'certificate' '')
        if ((Get-Fingerprint $existingPem) -cne $fingerprint) { Stop-Avi 'Versioned name exists with a different certificate.' }
        Write-AviLog ('CERTIFICATE_LOOKUP: object {0} already exists (uuid={1}, same SHA256); it will be reused.' -f $certName, $newUuid)
    } elseif ($existingCount -ne 0) { Stop-Avi 'Certificate lookup is ambiguous or missing its count.' }
    else { Write-AviLog ('CERTIFICATE_LOOKUP: object {0} not found; it will be uploaded in apply mode.' -f $certName) }
    $seenTargets = @{}
    $updates = 0
    $oldUuid = ''
    foreach ($target in $script:Targets) {
        $script:ActiveTarget = $target
        Write-AviLog ('Preflight: target=' + $target.Name)
        $vs = Resolve-AviObject 'virtualservice' $target.Name
        $target.Uuid = Get-Field $vs 'uuid'
        if ($seenTargets.ContainsKey($target.Uuid)) {
            $target.Status = 'DUPLICATE_SKIPPED'
            Write-AviLog ('Duplicate target skipped: VS={0} selector={1}' -f $target.Uuid, $target.Name)
            continue
        }
        $seenTargets[$target.Uuid] = $true
        $target.Topology = Get-ValidatedTopology $vs $target.Uuid
        $references = @(Get-CertReferences $vs)
        $ids = @(Get-ReferenceIds $references)
        $target.Before = Get-BindingSignature $vs
        if ($newUuid -and $ids -ccontains $newUuid) {
            $target.Status = 'ALREADY_ASSOCIATED'
            Write-AviLog ('Already associated: VS={0} certificate={1} SHA256={2}. No changes planned.' -f $target.Uuid, $newUuid, $fingerprint)
            continue
        }
        switch -CaseSensitive -Regex ($selector) {
            '\ANONE\z' {
                if ($ids.Count -ne 0) { Stop-Avi 'NONE only permits an empty certificate list.' }
            }
            '\AAUTO_SINGLE\z' {
                if ($ids.Count -ne 1) { Stop-Avi 'AUTO_SINGLE requires exactly one bound certificate on each target.' }
                $target.Index = 0
            }
            '\Aslot:' {
                $slotValue = $selector.Substring(5)
                if ($slotValue -notmatch '\A(0|[1-9][0-9]{0,6})\z') { Stop-Avi 'Invalid slot index.' }
                $target.Index = [int]$slotValue
                if ($target.Index -ge $ids.Count) { Stop-Avi 'Slot index out of range.' }
            }
            default {
                if (-not $oldUuid) { $oldUuid = Get-Field (Resolve-AviObject 'sslkeyandcertificate' $selector) 'uuid' }
                $indices = @()
                for ($j = 0; $j -lt $ids.Count; $j++) { if ($ids[$j] -ceq $oldUuid) { $indices += $j } }
                if ($indices.Count -ne 1) { Stop-Avi 'Old certificate must be bound exactly once to every target needing an update.' }
                $target.Index = $indices[0]
            }
        }
        $target.Status = 'READY'
        $updates++
        Write-AviLog ('Plan: mode={0} tenant={1} VS={2} selector={3} index={4} new_object={5} SHA256={6} previous_refs={7}' -f $script:Mode, $script:Tenant, $target.Uuid, $selector, $target.Index, $certName, $fingerprint, $target.Before)
    }
    $script:ActiveTarget = $null
    Write-AviLog ('PREFLIGHT completed: unique_targets={0} updates={1}. No certificate upload or binding changes yet.' -f $seenTargets.Count, $updates)
    if ($script:Mode -ceq 'dry-run') {
        foreach ($target in $script:Targets) { if ($target.Status -ceq 'READY') { $target.Status = 'PLANNED' } }
        $script:Phase = 'DRY_RUN_DONE'
        Write-AviLog 'DRY-RUN completed. No certificate uploaded and no Virtual Service modified. This does not validate write permissions or endpoint TLS.'
        return
    }
    $script:Phase = 'PREWRITE'
    foreach ($target in $script:Targets) {
        if ($target.Status -ceq 'DUPLICATE_SKIPPED') { continue }
        $script:ActiveTarget = $target
        $vs = Confirm-Target $target
        if ($target.Status -ceq 'READY') {
            $target.Snapshot = Join-Path ([IO.Path]::GetDirectoryName($script:LogPath)) ('avi-binding-{0}-{1}.json' -f $target.Uuid, $script:RunId)
            Write-JsonFile $target.Snapshot @{
                uuid = $target.Uuid; name = $target.Name; type = (Get-Field $vs 'type')
                vh_type = (Get-Field $vs 'vh_type'); vh_parent_vs_ref = (Get-Field $vs 'vh_parent_vs_ref')
                tenant_ref = (Get-Field $vs 'tenant_ref'); ssl_key_and_certificate_refs = @(Get-CertReferences $vs)
            }
            Write-AviLog ('Previous bindings saved to ' + $target.Snapshot)
        }
    }
    $script:ActiveTarget = $null
    if ($updates -eq 0) {
        $script:Phase = 'DONE'
        Write-AviLog 'SUCCESS: all unique targets already associated. No API writes.'
        return
    }
    $script:Phase = 'CERTIFICATE'
    if (-not $newUuid) {
        $uploaded = Invoke-AviApi 'POST' '/api/sslkeyandcertificate' @{
            name = $certName; type = 'SSL_CERTIFICATE_TYPE_VIRTUALSERVICE'
            certificate = @{ certificate = $chain }; key = [IO.File]::ReadAllText($keyPath)
        }
        $newUuid = Get-Field $uploaded 'uuid' ''
        if ($newUuid -cnotmatch '\Asslkeyandcertificate-[a-fA-F0-9-]+\z') { Stop-Avi 'Upload did not return a valid certificate UUID.' }
        Write-AviLog ('CERTIFICATE_UPLOADED: name={0} uuid={1} chain_certs={2}' -f $certName, $newUuid, $seenCertificates.Count)
    } else {
        Write-AviLog ('CERTIFICATE_REUSED: name={0} uuid={1}' -f $certName, $newUuid)
    }
    $verified = Invoke-AviApi 'GET' ('/api/sslkeyandcertificate/' + $newUuid)
    $verifiedPem = Join-Path $script:WorkDir 'verified.pem'
    Write-PrivateText $verifiedPem (Get-Field (Get-Field $verified 'certificate') 'certificate' '')
    if ((Get-Fingerprint $verifiedPem) -cne $fingerprint) { Stop-Avi 'Installed certificate fingerprint does not match the delivered certificate.' }
    Write-AviLog ('CERTIFICATE_VERIFIED: uuid={0} SHA256={1}' -f $newUuid, $fingerprint)
    $script:Phase = 'BINDING'
    foreach ($target in $script:Targets) {
        if ($target.Status -cne 'READY') { continue }
        $script:ActiveTarget = $target
        Write-AviLog ('Binding: target={0} VS={1}' -f $target.Name, $target.Uuid)
        $current = Confirm-Target $target
        $nextReferences = @(Get-CertReferences $current)
        if ($selector -ceq 'NONE') { $nextReferences = @('/api/sslkeyandcertificate/' + $newUuid) }
        else { $nextReferences[$target.Index] = '/api/sslkeyandcertificate/' + $newUuid }
        $expected = ConvertTo-Json -InputObject @(Get-ReferenceIds $nextReferences) -Compress
        $target.Status = 'PATCH_ATTEMPTED'
        $null = Invoke-AviApi 'PATCH' ('/api/virtualservice/' + $target.Uuid) @{
            replace = @{ ssl_key_and_certificate_refs = @($nextReferences) }
        }
        $readback = Invoke-AviApi 'GET' ('/api/virtualservice/' + $target.Uuid)
        if ((Get-ValidatedTopology $readback $target.Uuid) -cne $target.Topology) { Stop-Avi 'Virtual Service topology changed during binding verification.' }
        if ((Get-BindingSignature $readback) -cne $expected) { Stop-Avi 'Binding verification failed; inspect Controller and previous-binding snapshot.' }
        $target.Status = 'UPDATED'
        Write-AviLog ('SUCCESS: certificate={0} bound to VS={1}. Previous objects retained. Verify endpoint TLS/SNI separately.' -f $newUuid, $target.Uuid)
    }
    $script:ActiveTarget = $null
    $script:Phase = 'DONE'
    Write-AviLog ('SUCCESS: batch completed; updated={0} unique_targets={1} certificate={2} SHA256={3}. Verify endpoint TLS/SNI separately.' -f $updates, $seenTargets.Count, $newUuid, $fingerprint)
}

# ENTRYPOINT. Offline tests load functions above this marker without executing it.
$exitCode = 1
try {
    $defaultBase = if ($env:ProgramData) { $env:ProgramData } else { [IO.Path]::GetTempPath() }
    $script:LogPath = if ($env:AVI_LOGFILE) { $env:AVI_LOGFILE } else {
        Join-Path $defaultBase 'DigiCert/TLM/AVI-AWR/avi-upload.log'
    }
    $script:LogPath = [IO.Path]::GetFullPath($script:LogPath)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:LogPath))
    if (-not [IO.File]::Exists($script:LogPath)) { Write-PrivateText $script:LogPath '' }
    else { Set-PrivateAccess -Path $script:LogPath }
    Write-AviLog '=========================================='
    Write-AviLog ('INIT: revision={0} pid={1} user={2} log={3}' -f $script:Revision, $PID, [Environment]::UserName, $script:LogPath)
    $script:WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('avi-awr-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:WorkDir)
    Set-PrivateAccess -Path $script:WorkDir -Directory
    Invoke-AviMain
    $exitCode = 0
} catch {
    $message = $_.Exception.Message
    $detail = ''
    if ($message.StartsWith('[AVI] ')) { $message = $message.Substring(6) }
    else {
        # The exception text goes to the private log only, never to the console.
        $detail = ' Detail: ' + (Get-SafeText $_.Exception.Message 300)
        $message = 'Unexpected failure at line {0} ({1}) in phase {2}. Inspect Controller state before retrying a write.' -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.GetType().Name, $script:Phase
    }
    try { Write-AviLog ('ERROR: ' + $message + $detail) } catch { }
    if ($script:LogPath) { [Console]::Error.WriteLine(('AVI AWR ERROR: {0} (see {1})' -f $message, $script:LogPath)) }
    else { [Console]::Error.WriteLine('AVI AWR ERROR: ' + $message) }
} finally {
    if ($script:SummaryReady) {
        if ($exitCode -ne 0 -and $null -ne $script:ActiveTarget) {
            if ($script:ActiveTarget.Status -ceq 'PATCH_ATTEMPTED') { $script:ActiveTarget.Status = 'FAILED_OR_UNCONFIRMED' }
            elseif ($script:ActiveTarget.Status -in @('PENDING', 'READY', 'ALREADY_ASSOCIATED')) { $script:ActiveTarget.Status = 'FAILED' }
        }
        $resultName = if ($exitCode -eq 0) { 'SUCCESS' } else { 'FAILED' }
        [Console]::WriteLine(('AVI AWR {0}: mode={1}, targets={2}, phase={3} (see {4})' -f $resultName, $script:Mode, $script:Targets.Count, $script:Phase, $script:LogPath))
        try { Write-AviLog ('SUMMARY: result={0} mode={1} phase={2} targets={3} exit={4}' -f $resultName, $script:Mode, $script:Phase, $script:Targets.Count, $exitCode) } catch { }
        foreach ($target in $script:Targets) {
            $status = $target.Status
            if ($exitCode -ne 0 -and $status -in @('READY', 'PENDING')) { $status = 'NOT_ATTEMPTED' }
            [Console]::WriteLine(('VS={0}: {1}' -f $target.Name, $status))
            $resultUuid = if ($target.Uuid) { $target.Uuid } else { 'unresolved' }
            try { Write-AviLog ('RESULT: VS={0} uuid={1} status={2}' -f $target.Name, $resultUuid, $status) } catch { }
        }
        if ($exitCode -ne 0) { [Console]::WriteLine('Earlier successful changes remain. No automatic rollback; inspect Controller before retrying.') }
    }
    if ($script:WorkDir -and [IO.Directory]::Exists($script:WorkDir)) {
        try { [IO.Directory]::Delete($script:WorkDir, $true) } catch { [Console]::Error.WriteLine('Temporary-file cleanup failed; check permissions on the Agent host.') }
    }
}
exit $exitCode
