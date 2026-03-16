<# 
LEGAL_NOTICE
Legal Notice (version October 29, 2024)
Copyright © 2024 DigiCert. All rights reserved.
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
LEGAL_NOTICE
#>

# ============================
# Configuration (matches bash)
# ============================
$LEGAL_NOTICE_ACCEPT = "false"
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\kemp_data.log"

# ============================
# Helper Functions
# ============================

function Write-Log {
    param([string]$Message)
    try {
        $dir = Split-Path -Parent $LOGFILE
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -LiteralPath $LOGFILE -Value "[$timestamp] $Message"
    } catch {
        # Best-effort logging; swallow exceptions to not stop the script
    }
}

function Obfuscate-String {
    param(
        [string]$InputString,
        [int]$ShowChars = 3
    )
    if ($null -eq $InputString) { return "" }
    if ($InputString.Length -le $ShowChars) { return $InputString }
    return ($InputString.Substring(0, $ShowChars) + "***")
}

function Obfuscate-Url {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $Url }
    # Detect scheme://user:pass@rest
    $regex = '^(?<scheme>.+?://)(?<userinfo>[^@/]+)@(?<rest>.+)$'
    $m = [Regex]::Match($Url, $regex)
    if ($m.Success) {
        $scheme = $m.Groups['scheme'].Value
        $userinfo = $m.Groups['userinfo'].Value
        $rest = $m.Groups['rest'].Value

        $uParts = $userinfo.Split(':',2)
        $user = if ($uParts.Count -ge 1) { $uParts[0] } else { "" }
        $pass = if ($uParts.Count -ge 2) { $uParts[1] } else { "" }

        $obsUser = if ($user.Length -le 3) { $user } else { $user.Substring(0,3) + "***" }
        $obsPass = if ($pass.Length -le 3) { $pass } else { $pass.Substring(0,3) + "***" }
        return "$scheme$obsUser`:$obsPass@$rest"
    } else {
        return $Url
    }
}

function Extract-UrlCredential {
    <#
      Returns an object with:
        - BaseUrl (credentials removed if present)
        - Credential (PSCredential or $null)
    #>
    param([string]$Url)

    # Fixed syntax for creating PSObject with properties
    $result = New-Object PSObject -Property @{ 
        BaseUrl = $Url
        Credential = $null 
    }

    if ([string]::IsNullOrWhiteSpace($Url)) { return $result }

    $regex = '^(?<scheme>https?://)(?<userinfo>[^@/]+)@(?<rest>.+)$'
    $m = [Regex]::Match($Url, $regex)
    if ($m.Success) {
        $scheme = $m.Groups['scheme'].Value
        $userinfo = $m.Groups['userinfo'].Value
        $rest = $m.Groups['rest'].Value

        $uParts = $userinfo.Split(':',2)
        $user = $uParts[0]
        $pass = if ($uParts.Count -ge 2) { $uParts[1] } else { "" }

        # Percent-decoding in case creds are URL-encoded
        try {
            $user = [uri]::UnescapeDataString($user)
            $pass = [uri]::UnescapeDataString($pass)
        } catch {}

        $secure = ConvertTo-SecureString $pass -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential ($user, $secure)

        $result.BaseUrl = "$scheme$rest"
        $result.Credential = $cred
        return $result
    }

    return $result
}

function Set-FilePrivate {
    <#
      Tries to mimic 'chmod 600':
      - On Windows PowerShell 5.1: restrict ACL to the current user (FullControl).
      - If 'chmod' exists (e.g., Cygwin/WSL), attempts to call it, but failure is ignored.
    #>
    param([string]$Path)

    try {
        if ($env:OS -like "*Windows*") {
            $file = Get-Item -LiteralPath $Path -ErrorAction Stop
            $acl = New-Object System.Security.AccessControl.FileSecurity
            $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($user, "FullControl", "Allow")
            $acl.SetOwner((New-Object System.Security.Principal.NTAccount($user)))
            $acl.SetAccessRuleProtection($true,$false)
            $acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $file.FullName -AclObject $acl
        } else {
            # Non-Windows environment or compat layer: try chmod if present
            $chmod = Get-Command chmod -ErrorAction SilentlyContinue
            if ($chmod) {
                & $chmod 600 -- $Path 2>$null
            }
        }
    } catch {
        # Non-fatal; continue
    }
}

function Invoke-KempApiRequest {
    <#
      Improved API request function specifically for Kemp LoadMaster
      Handles file upload with proper binary encoding
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [ValidateSet('GET','POST')][string]$Method = 'GET',
        [hashtable]$Headers,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$FilePath,
        [switch]$SkipCertValidation
    )
    
    # Set up certificate validation bypass if needed
    $prevCallback = $null
    if ($SkipCertValidation) {
        try { $prevCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback } catch {}
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }
    
    # Use TLS 1.2
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    } catch {}
    
    try {
        # Create the HttpWebRequest
        $request = [System.Net.HttpWebRequest]::Create($Uri)
        $request.Method = $Method
        $request.Timeout = 30000  # 30 seconds
        
        # Add credentials if provided
        if ($Credential) {
            $request.Credentials = New-Object System.Net.NetworkCredential($Credential.UserName, $Credential.GetNetworkCredential().Password)
            $request.PreAuthenticate = $true
        }
        
        # Add headers
        if ($Headers) {
            foreach ($key in $Headers.Keys) {
                if ($key -eq 'Content-Type') {
                    $request.ContentType = $Headers[$key]
                } else {
                    $request.Headers.Add($key, $Headers[$key])
                }
            }
        }
        
        # Handle file upload for POST
        if ($Method -eq 'POST' -and $FilePath) {
            # Read file as bytes
            $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)
            $request.ContentLength = $fileBytes.Length
            
            # Write bytes to request stream
            $requestStream = $request.GetRequestStream()
            $requestStream.Write($fileBytes, 0, $fileBytes.Length)
            $requestStream.Close()
        }
        
        # Get response
        $response = $request.GetResponse()
        $statusCode = [int]$response.StatusCode
        
        # Read response content
        $responseStream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($responseStream)
        $content = $reader.ReadToEnd()
        $reader.Close()
        $response.Close()
        
        return @{ StatusCode = $statusCode; Content = $content }
        
    } catch [System.Net.WebException] {
        $we = $_.Exception
        $statusCode = 0
        $content = ""
        
        try {
            if ($we.Response) {
                if ($we.Response.StatusCode) {
                    $statusCode = [int]$we.Response.StatusCode
                }
                if ($we.Response.GetResponseStream()) {
                    $sr = New-Object System.IO.StreamReader($we.Response.GetResponseStream())
                    $content = $sr.ReadToEnd()
                    $sr.Close()
                }
            }
        } catch {}
        
        # Log error details
        Write-Log "WebException occurred: $($we.Message)"
        if ($content) {
            Write-Log "Response content: $content"
        }
        
        return @{ StatusCode = $statusCode; Content = $content }
        
    } finally {
        if ($SkipCertValidation -and $prevCallback -ne $null) {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $prevCallback
        }
    }
}

# ==========================================
# Start logging
# ==========================================
Write-Log "=========================================="
Write-Log "Starting DC1_POST_SCRIPT_DATA extraction script (v2)"
Write-Log "=========================================="

# Check legal notice acceptance
Write-Log "Checking legal notice acceptance..."
if ($LEGAL_NOTICE_ACCEPT -ne "true") {
    Write-Log "ERROR: Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT=`"true`" to proceed."
    Write-Log "Script execution terminated due to legal notice non-acceptance."
    Write-Log "=========================================="
    exit 1
} else {
    Write-Log "Legal notice accepted, proceeding with script execution."
}

# Log initial configuration
Write-Log "Configuration:"
Write-Log "  LEGAL_NOTICE_ACCEPT: $LEGAL_NOTICE_ACCEPT"
Write-Log "  LOGFILE: $LOGFILE"

# Log environment variable check
Write-Log "Checking DC1_POST_SCRIPT_DATA environment variable..."
if ([string]::IsNullOrEmpty($env:DC1_POST_SCRIPT_DATA)) {
    Write-Log "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set"
    exit 1
} else {
    Write-Log ("DC1_POST_SCRIPT_DATA is set (length: {0} characters)" -f $env:DC1_POST_SCRIPT_DATA.Length)
}

# Read the Base64-encoded JSON string from the environment variable
$CERT_INFO = $env:DC1_POST_SCRIPT_DATA
Write-Log ("CERT_INFO length: {0} characters" -f $CERT_INFO.Length)

# Decode JSON string
try {
    $bytes = [Convert]::FromBase64String($CERT_INFO)
    $JSON_STRING = [Text.Encoding]::UTF8.GetString($bytes)
    Write-Log "JSON_STRING decoded successfully"
} catch {
    Write-Log "ERROR: Failed to Base64-decode DC1_POST_SCRIPT_DATA"
    exit 1
}

# Log the raw JSON for debugging (with obfuscation if it contains sensitive data)
Write-Log "=========================================="
Write-Log "Raw JSON content: [Content logged but check for sensitive data]"
# Note: Not logging raw JSON to avoid exposing credentials that might be in args
Write-Log "=========================================="

# Extract arguments from JSON
Write-Log "Extracting arguments from JSON..."
try {
    $json = $JSON_STRING | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Log "ERROR: JSON parsing failed."
    exit 1
}

# First, let's log the args array (without raw content)
$ARGS_ARRAY = @()
if ($json.PSObject.Properties.Name -contains 'args') {
    $ARGS_ARRAY = @($json.args)
}
Write-Log "Args array extracted (not logging raw content for security)"

# Extract Argument_1 - Argument_5
if ($ARGS_ARRAY.Count -ge 1) {
    $ARGUMENT_1 = ([string]$ARGS_ARRAY[0]).Replace("`r","").Replace("`n","")
} else {
    $ARGUMENT_1 = ""
}

if ($ARGS_ARRAY.Count -ge 2) {
    $ARGUMENT_2 = ([string]$ARGS_ARRAY[1]).Replace("`r","").Replace("`n","")
} else {
    $ARGUMENT_2 = ""
}

if ($ARGS_ARRAY.Count -ge 3) {
    $ARGUMENT_3 = ([string]$ARGS_ARRAY[2]).Replace("`r","").Replace("`n","")
} else {
    $ARGUMENT_3 = ""
}

if ($ARGS_ARRAY.Count -ge 4) {
    $ARGUMENT_4 = ([string]$ARGS_ARRAY[3]).Replace("`r","").Replace("`n","")
} else {
    $ARGUMENT_4 = ""
}

if ($ARGS_ARRAY.Count -ge 5) {
    $ARGUMENT_5 = ([string]$ARGS_ARRAY[4]).Replace("`r","").Replace("`n","")
} else {
    $ARGUMENT_5 = ""
}

# Clean arguments (remove whitespace)
$ARGUMENT_1 = ($ARGUMENT_1 -replace '\s','')
$ARGUMENT_2 = ($ARGUMENT_2 -replace '\s','')
$ARGUMENT_3 = ($ARGUMENT_3 -replace '\s','')
$ARGUMENT_4 = ($ARGUMENT_4 -replace '\s','')
$ARGUMENT_5 = ($ARGUMENT_5 -replace '\s','')

Write-Log ("ARGUMENT_1 extracted: '{0}'" -f (Obfuscate-Url $ARGUMENT_1))
Write-Log ("ARGUMENT_1 length: {0}" -f $ARGUMENT_1.Length)
Write-Log ("ARGUMENT_2 extracted: '{0}'" -f $ARGUMENT_2)
Write-Log ("ARGUMENT_2 length: {0}" -f $ARGUMENT_2.Length)
Write-Log ("ARGUMENT_3 extracted: '{0}'" -f $ARGUMENT_3)
Write-Log ("ARGUMENT_3 length: {0}" -f $ARGUMENT_3.Length)
Write-Log ("ARGUMENT_4 extracted: '{0}'" -f $ARGUMENT_4)
Write-Log ("ARGUMENT_4 length: {0}" -f $ARGUMENT_4.Length)
Write-Log ("ARGUMENT_5 extracted: '{0}'" -f $ARGUMENT_5)
Write-Log ("ARGUMENT_5 length: {0}" -f $ARGUMENT_5.Length)

# Extract cert folder
$CERT_FOLDER = ""
if ($json.PSObject.Properties.Name -contains 'certfolder') {
    $CERT_FOLDER = [string]$json.certfolder
}
Write-Log "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract the .crt and .key file names using the same approach as the working Cloudflare script
$CRT_FILE = ""
$KEY_FILE = ""
if ($json.PSObject.Properties.Name -contains 'files') {
    # Use -like instead of -match for more reliable matching
    $CRT_FILE = $json.files | Where-Object { $_ -like "*.crt" } | Select-Object -First 1
    $KEY_FILE = $json.files | Where-Object { $_ -like "*.key" } | Select-Object -First 1
    
    # Ensure they are strings
    if ($CRT_FILE) { $CRT_FILE = [string]$CRT_FILE }
    if ($KEY_FILE) { $KEY_FILE = [string]$KEY_FILE }
}

Write-Log "Extracted CRT_FILE: $CRT_FILE"
Write-Log "Extracted KEY_FILE: $KEY_FILE"

# Build full paths - handle both forward slash and backslash
$CRT_FILE_PATH = if ($CERT_FOLDER) { 
    Join-Path $CERT_FOLDER $CRT_FILE 
} else { 
    $CRT_FILE 
}

$KEY_FILE_PATH = if ($CERT_FOLDER) { 
    Join-Path $CERT_FOLDER $KEY_FILE 
} else { 
    $KEY_FILE 
}

Write-Log "=========================================="
Write-Log "EXTRACTION SUMMARY:"
Write-Log "=========================================="
Write-Log "Arguments extracted:"
Write-Log ("  Argument 1: {0}" -f (Obfuscate-Url $ARGUMENT_1))
Write-Log "  Argument 2: $ARGUMENT_2"
Write-Log "  Argument 3: $ARGUMENT_3"
Write-Log "  Argument 4: $ARGUMENT_4"
Write-Log "  Argument 5: $ARGUMENT_5"
Write-Log ""
Write-Log "Certificate information:"
Write-Log "  Certificate folder: $CERT_FOLDER"
Write-Log "  Certificate file: $CRT_FILE"
Write-Log "  Private key file: $KEY_FILE"
Write-Log "  Certificate path: $CRT_FILE_PATH"
Write-Log "  Private key path: $KEY_FILE_PATH"
Write-Log ""

# Check if files exist & basic metadata
if (Test-Path -LiteralPath $CRT_FILE_PATH) {
    $crtItem = Get-Item -LiteralPath $CRT_FILE_PATH
    Write-Log "Certificate file exists: $CRT_FILE_PATH"
    Write-Log ("Certificate file size: {0} bytes" -f $crtItem.Length)
    try {
        $certCount = (Select-String -Path $CRT_FILE_PATH -Pattern 'BEGIN CERTIFICATE' | Measure-Object).Count
        Write-Log "Total certificates in file: $certCount"
    } catch { Write-Log "WARNING: Unable to count certificates in $CRT_FILE_PATH" }
} else {
    Write-Log "WARNING: Certificate file not found: $CRT_FILE_PATH"
}

if (Test-Path -LiteralPath $KEY_FILE_PATH) {
    $keyItem = Get-Item -LiteralPath $KEY_FILE_PATH
    Write-Log "Private key file exists: $KEY_FILE_PATH"
    Write-Log ("Private key file size: {0} bytes" -f $keyItem.Length)
    try {
        $keyText = Get-Content -LiteralPath $KEY_FILE_PATH -Raw
        if ($keyText -match 'BEGIN RSA PRIVATE KEY') {
            Write-Log "Key type: RSA (BEGIN RSA PRIVATE KEY found)"
        } elseif ($keyText -match 'BEGIN EC PRIVATE KEY') {
            Write-Log "Key type: ECC (BEGIN EC PRIVATE KEY found)"
        } elseif ($keyText -match 'BEGIN PRIVATE KEY') {
            Write-Log "Key type: PKCS#8 format (BEGIN PRIVATE KEY found)"
        } else {
            Write-Log "Key type: Unknown"
        }
    } catch { Write-Log "WARNING: Unable to inspect key type for $KEY_FILE_PATH" }
} else {
    Write-Log "WARNING: Private key file not found: $KEY_FILE_PATH"
}

# ============================================================================
# CUSTOM SCRIPT SECTION - KEMP LOADMASTER CERTIFICATE DEPLOYMENT
# ============================================================================
#
# This section uploads a certificate and private key to a Kemp LoadMaster (LM)
# and assigns the certificate to a target Virtual Service (VS).
#
# ARGUMENTS (from the JSON "args" array in DC1_POST_SCRIPT_DATA)
# ---------------------------------------------------------------------------
#   ARGUMENT_1  Base URL **including scheme, credentials, host and port** of
#               the LoadMaster REST API endpoint.
#               Example:
#               https://bal:Tra1ning123!@ec2-3-145-191-244.us-east-2.compute.amazonaws.com:8444
#
#   ARGUMENT_2  Virtual Service IP address to update.
#               Example: 172.31.7.5
#
#   ARGUMENT_3  Virtual Service port to update.
#               Example: 443
#
#   ARGUMENT_4  Certificate name (identifier) on the LoadMaster.
#               This is how the certificate will appear in the LM UI/API.
#               Example: Certificate
#
#   ARGUMENT_5  (Optional / currently unused) Reserved for future use.
#
# WHAT THIS SECTION DOES
# ---------------------------------------------------------------------------
# 1) Combine the CRT and KEY that were just downloaded by DigiCert into a
#    single PEM bundle:
#       cat <certificate.crt> <private.key> > <CertificateName>.pem
# 2) Check the LoadMaster for an existing certificate with that name:
#       GET  {ARG1}/access/listcert
#    (response is XML; parsed with xmllint if available, else grep)
# 3) Upload the PEM to the LoadMaster:
#       POST {ARG1}/access/addcert?cert={ARG4}&replace={0|1}
#       Body: --data-binary @<CertificateName>.pem
#       Headers: Content-Type: application/x-x509-ca-cert
# 4) Assign the certificate to the Virtual Service:
#       GET  {ARG1}/access/modvs?vs={ARG2}&port={ARG3}&prot=tcp&CertFile={ARG4}
#
# NOTE:
# - The combined PEM should contain your full server cert plus private key.
#   If your .crt already includes the intermediate chain, it will be preserved.
# - The REST API is typically XML-based and must be enabled on the LoadMaster.
#   See official docs for enabling and using the API.
# ============================================================================

Write-Log "=========================================="
Write-Log "Starting Kemp LoadMaster certificate deployment..."
Write-Log "=========================================="

# Validate required arguments for Kemp flow
if ([string]::IsNullOrWhiteSpace($ARGUMENT_1)) { Write-Log "ERROR: Argument 1 (Base URL with credentials) is not provided"; exit 1 }
if ([string]::IsNullOrWhiteSpace($ARGUMENT_2)) { Write-Log "ERROR: Argument 2 (Virtual Service IP) is not provided"; exit 1 }
if ([string]::IsNullOrWhiteSpace($ARGUMENT_3)) { Write-Log "ERROR: Argument 3 (Virtual Service Port) is not provided"; exit 1 }
if ([string]::IsNullOrWhiteSpace($ARGUMENT_4)) { Write-Log "ERROR: Argument 4 (Certificate Name) is not provided"; exit 1 }

$BASE_URL = $ARGUMENT_1
$VS_IP    = $ARGUMENT_2
$VS_PORT  = $ARGUMENT_3
$CERT_NAME = $ARGUMENT_4

Write-Log "Kemp target:"
Write-Log ("  Base URL: {0}" -f (Obfuscate-Url $BASE_URL))
Write-Log ("  VS: {0}:{1} (tcp)" -f $VS_IP,$VS_PORT)
Write-Log ("  Certificate name: {0}" -f $CERT_NAME)

# Step 1: Build combined PEM (cert + key)
$COMBINED_PEM_PATH = if ($CERT_FOLDER) { 
    Join-Path $CERT_FOLDER "$CERT_NAME.pem" 
} else { 
    "$CERT_NAME.pem" 
}

if ((Test-Path -LiteralPath $CRT_FILE_PATH) -and (Test-Path -LiteralPath $KEY_FILE_PATH)) {
    Write-Log "Combining certificate and key into PEM..."
    try {
        # Read files as text to ensure proper PEM format
        $certContent = Get-Content -LiteralPath $CRT_FILE_PATH -Raw -Encoding UTF8
        $keyContent = Get-Content -LiteralPath $KEY_FILE_PATH -Raw -Encoding UTF8
        
        # Ensure proper line endings (Unix-style)
        $certContent = $certContent -replace "`r`n", "`n"
        $keyContent = $keyContent -replace "`r`n", "`n"
        
        # Ensure content ends with newline
        if (-not $certContent.EndsWith("`n")) { $certContent += "`n" }
        if (-not $keyContent.EndsWith("`n")) { $keyContent += "`n" }
        
        # Combine and write with UTF8 encoding (no BOM)
        $combinedContent = $certContent + $keyContent
        [System.IO.File]::WriteAllText($COMBINED_PEM_PATH, $combinedContent, [System.Text.UTF8Encoding]::new($false))
        
        Set-FilePrivate -Path $COMBINED_PEM_PATH
        $pemSize = (Get-Item -LiteralPath $COMBINED_PEM_PATH).Length
        Write-Log "Combined PEM created: $COMBINED_PEM_PATH"
        Write-Log ("Combined PEM size: {0} bytes" -f $pemSize)
        
        # Log first few lines for debugging (without exposing sensitive data)
        $pemLines = $combinedContent -split "`n"
        Write-Log "PEM structure validation:"
        foreach ($line in $pemLines[0..2]) {
            if ($line -match "BEGIN") {
                Write-Log "  Found: $line"
            }
        }
    } catch {
        Write-Log "ERROR: Failed to create combined PEM: $_"
        exit 1
    }
} else {
    Write-Log "ERROR: Missing certificate or key file."
    Write-Log "  Expected certificate: $CRT_FILE_PATH"
    Write-Log "  Expected key:         $KEY_FILE_PATH"
    exit 1
}

# Ensure cleanup like 'trap ... EXIT'
$cleanupPem = $true
try {
    # Prepare BaseUrl + credential (support URLs with embedded creds)
    $urlInfo = Extract-UrlCredential -Url $BASE_URL
    $baseUrlNoCreds = $urlInfo.BaseUrl
    $psCred = $urlInfo.Credential

    # Step 2: Check if certificate already exists on LoadMaster
    $LISTCERT_URL = "$baseUrlNoCreds/access/listcert"
    Write-Log ("Checking certificate existence via: {0}" -f (Obfuscate-Url $LISTCERT_URL))

    $listResp = Invoke-KempApiRequest -Uri $LISTCERT_URL -Method GET -Credential $psCred -SkipCertValidation
    Write-Log ("listcert HTTP status: {0}" -f $listResp.StatusCode)

    $CERT_EXISTS = $false
    if ($listResp.Content) {
        # Log a sample of the response for debugging
        $sampleContent = if ($listResp.Content.Length -gt 200) { 
            $listResp.Content.Substring(0, 200) + "..." 
        } else { 
            $listResp.Content 
        }
        Write-Log "listcert response sample: $sampleContent"
        
        try {
            [xml]$xml = $listResp.Content
            # Try different XML paths that Kemp might use
            $nodes = $xml.SelectNodes("//name") 
            if (-not $nodes -or $nodes.Count -eq 0) {
                $nodes = $xml.SelectNodes("//cert/name")
            }
            if (-not $nodes -or $nodes.Count -eq 0) {
                $nodes = $xml.SelectNodes("//certificate/name")
            }
            
            if ($nodes -and $nodes.Count -gt 0) {
                Write-Log "Found $($nodes.Count) certificates on LoadMaster"
                foreach ($n in $nodes) {
                    $certName = if ($n.'#text') { $n.'#text' } else { $n.InnerText }
                    Write-Log "  Certificate found: $certName"
                    if ($certName -eq $CERT_NAME) { 
                        $CERT_EXISTS = $true
                        break 
                    }
                }
            } else {
                Write-Log "No certificate nodes found in XML, trying text match"
                # Fallback: simple text match
                if ($listResp.Content -match "<name>$([Regex]::Escape($CERT_NAME))</name>") { 
                    $CERT_EXISTS = $true 
                }
            }
        } catch {
            Write-Log "XML parsing failed: $_. Trying text match"
            if ($listResp.Content -match "<name>$([Regex]::Escape($CERT_NAME))</name>") { 
                $CERT_EXISTS = $true 
            }
        }
    }
    Write-Log ("Certificate '{0}' exists on LoadMaster? {1}" -f $CERT_NAME, ($CERT_EXISTS.ToString().ToLower()))

    # Step 3: Upload or overwrite the certificate
    $encodedName = [uri]::EscapeDataString($CERT_NAME)
    $UPLOAD_URL = "$baseUrlNoCreds/access/addcert?cert=$encodedName"
    if ($CERT_EXISTS) {
        $UPLOAD_URL = "$UPLOAD_URL&replace=1"
        Write-Log "Certificate exists; will POST with replace=1"
    } else {
        Write-Log "Certificate not found; will POST without replace=1"
    }

    Write-Log ("Uploading PEM to: {0}" -f (Obfuscate-Url $UPLOAD_URL))
    Write-Log ("PEM file path: {0}" -f $COMBINED_PEM_PATH)
    Write-Log ("PEM file exists: {0}" -f (Test-Path -LiteralPath $COMBINED_PEM_PATH))
    
    $headers = @{ 'Content-Type' = 'application/x-x509-ca-cert' }
    $uploadResp = Invoke-KempApiRequest -Uri $UPLOAD_URL -Method POST -Headers $headers -FilePath $COMBINED_PEM_PATH -Credential $psCred -SkipCertValidation
    
    Write-Log ("addcert HTTP status: {0}" -f $uploadResp.StatusCode)
    Write-Log ("addcert response: {0}" -f $uploadResp.Content)
    
    if ($uploadResp.Content -match '(Success|success|OK)') {
        Write-Log "addcert response indicates success"
    } elseif ($uploadResp.Content -match 'error') {
        Write-Log "addcert response contains error"
    }

    # Check if upload was successful
    if ($uploadResp.StatusCode -eq 200 -or $uploadResp.StatusCode -eq 201) {
        Write-Log "Certificate upload successful (HTTP $($uploadResp.StatusCode))"
    } elseif ($uploadResp.StatusCode -eq 422) {
        Write-Log "ERROR: Certificate upload failed with HTTP 422 (Unprocessable Entity)"
        Write-Log "This typically means the certificate format is invalid or there's an issue with the certificate content"
        Write-Log "Please verify:"
        Write-Log "  1. The certificate and key are in proper PEM format"
        Write-Log "  2. The certificate and key match"
        Write-Log "  3. The certificate chain is complete"
        exit 1
    } else {
        Write-Log "ERROR: Certificate upload failed with HTTP $($uploadResp.StatusCode)"
        exit 1
    }

    # Step 4: Assign the certificate to the Virtual Service
    $ASSIGN_URL = "$baseUrlNoCreds/access/modvs?vs=$($VS_IP)&port=$($VS_PORT)&prot=tcp&CertFile=$encodedName"
    Write-Log ("Assigning certificate to VS via: {0}" -f (Obfuscate-Url $ASSIGN_URL))

    $assignResp = Invoke-KempApiRequest -Uri $ASSIGN_URL -Method GET -Credential $psCred -SkipCertValidation
    Write-Log ("modvs HTTP status: {0}" -f $assignResp.StatusCode)
    Write-Log ("modvs response: {0}" -f $assignResp.Content)
    
    if ($assignResp.Content -match '(Success|success|OK)') {
        Write-Log "modvs response indicates success"
    }

    if (($assignResp.StatusCode -eq 200) -or ($assignResp.StatusCode -eq 201)) {
        Write-Log ("SUCCESS: '{0}' assigned to VS {1}:{2}" -f $CERT_NAME, $VS_IP, $VS_PORT)
    } else {
        Write-Log "WARNING: modvs returned status $($assignResp.StatusCode); verify assignment in the LM UI."
    }

    Write-Log "Kemp LoadMaster certificate deployment section completed"
    Write-Log "=========================================="
}
catch {
    Write-Log "ERROR: An unexpected error occurred: $_"
    exit 1
}
finally {
    if ($cleanupPem -and (Test-Path -LiteralPath $COMBINED_PEM_PATH)) {
        try { 
            Remove-Item -LiteralPath $COMBINED_PEM_PATH -Force -ErrorAction SilentlyContinue 
            Write-Log "Cleaned up temporary PEM file"
        } catch {
            Write-Log "WARNING: Could not remove temporary PEM file"
        }
    }
}

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

Write-Log "=========================================="
Write-Log "Script execution completed successfully"
Write-Log "=========================================="

exit 0