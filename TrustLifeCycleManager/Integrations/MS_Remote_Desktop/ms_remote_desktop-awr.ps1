# Function to write to log file
function Write-Log {
    param(
        [string]$Message
    )
    $logMessage = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $Message"
    Add-Content -Path $logFile -Value $logMessage
}

# Function to decode base64 encoded string
function Decode-Base64 {
    param (
        [string]$base64String
    )
    $bytes = [System.Convert]::FromBase64String($base64String)
    $decodedString = [System.Text.Encoding]::UTF8.GetString($bytes)
    return $decodedString
}

# Set up logging
$logFile = "C:\CertificateImport.log"
Write-Log "Script execution started"

try {
    # Base64 encoded JSON input
    $base64Json = [System.Environment]::GetEnvironmentVariable("DC1_POST_SCRIPT_DATA")
    Write-Log "Retrieved environment variable DC1_POST_SCRIPT_DATA"

    # Decode the base64 encoded JSON
    $jsonString = Decode-Base64 -base64String $base64Json
    Write-Log "Decoded base64 string successfully"

    # Convert JSON string to PowerShell object
    $jsonObject = $jsonString | ConvertFrom-Json
    Write-Log "Converted JSON string to object"

    Write-Log "Arguments: $($jsonObject.args)"

    # Extract values from JSON object
    $certFolder = $jsonObject.certfolder
    $pfxFile = Join-Path -Path $certFolder -ChildPath $jsonObject.files[0]
    $password = $jsonObject.password
    Write-Log "Certificate folder: $certFolder"
    Write-Log "PFX file path: $pfxFile"

    # Validate inputs
    if (-not (Test-Path -Path $pfxFile)) {
        Write-Log "ERROR: The PFX file does not exist at path: $pfxFile"
        throw "The PFX file does not exist."
    }
    Write-Log "PFX file exists"

    # Get certificate thumbprint and store it in a text file
try {
    $pfxCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
    
    # First validate if we can read the password
    Write-Log "Attempting to verify password..."
    $securePassword = ConvertTo-SecureString -String $password -Force -AsPlainText
    
    # Add password debugging information
    Write-Log "Password length: $($password.Length)"
    Write-Log "First character of password: $($password[0])"
    Write-Log "Password value (first 2 chars): $($password.Substring(0, [Math]::Min(2, $password.Length)))"
    
    # Try to import with more detailed error handling
    try {
        $pfxCert.Import($pfxFile, $password, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
    }
    catch [System.Security.Cryptography.CryptographicException] {
        Write-Log "ERROR: Invalid password or corrupted PFX file. Please verify the password is correct."
        throw "Invalid certificate password or corrupted PFX file."
    }
    
    $thumbprint = $pfxCert.Thumbprint
    Write-Log "Retrieved certificate thumbprint: $thumbprint"
    
    # Create thumbprint file in the same folder as the certificate
    $thumbprintFile = Join-Path -Path $certFolder -ChildPath "certificate_thumbprint.txt"
    $thumbprint | Out-File -FilePath $thumbprintFile -Force
    Write-Log "Saved thumbprint to file: $thumbprintFile"
    
    # Dispose of the certificate object
    $pfxCert.Dispose()
    Write-Log "Disposed certificate object"
} catch {
    Write-Log "ERROR: Failed to get certificate thumbprint. Error: $_"
    throw $_
}

    # Import the PFX file into the LocalMachine\My store
    try {
        $cert = Import-PfxCertificate -FilePath $pfxFile -CertStoreLocation Cert:\LocalMachine\My -Password (ConvertTo-SecureString -String $password -Force -AsPlainText)
        if ($null -eq $cert) {
            Write-Log "ERROR: Failed to import the certificate"
            throw "Failed to import the certificate."
        }
        Write-Log "Certificate imported successfully"
    } catch {
        Write-Log "ERROR: Failed to import the certificate. Error: $_"
        throw $_
    }

    # Step 2: Grant access to the private key to NETWORK SERVICE using certutil
    Write-Log "Attempting to repair certificate store for thumbprint: $thumbprint"
    $certutilCommand = "certutil -repairstore my $thumbprint"
    try {
        Start-Process cmd.exe -ArgumentList "/c $certutilCommand" -Wait -NoNewWindow
        Write-Log "Successfully ran certutil repair command"
    } catch {
        Write-Log "ERROR: Failed to run certutil command. Error: $_"
        throw $_
    }

    # Step 3: Use WMI to set the RDP listener certificate
    try {
        $tsConfig = Get-WmiObject -Namespace "Root\CIMv2\TerminalServices" -Class Win32_TSGeneralSetting -Filter "TerminalName='RDP-Tcp'"
        
        if ($tsConfig) {
            # Use reflection to set the SSLThumbprint
            $tsConfig.PSBase.Properties["SSLCertificateSHA1Hash"].Value = $thumbprint
            $tsConfig.Put()
            Write-Log "Successfully updated certificate thumbprint via WMI"
        } else {
            Write-Log "ERROR: Failed to retrieve the TS configuration"
            throw "Failed to retrieve the TS configuration"
        }
    } catch {
        Write-Log "ERROR: Failed to set certificate thumbprint via WMI. Error: $_"
        throw $_
    }

    # Step 4: Restart the RDP service to apply changes
    try {
        Restart-Service -Name "TermService" -Force
        Write-Log "Successfully restarted the Terminal Services service"
    } catch {
        Write-Log "ERROR: Failed to restart Terminal Services. Error: $_"
        throw $_
    }

} catch {
    Write-Log "CRITICAL ERROR: $_"
    Write-Log "Script execution failed"
    exit 1
}

Write-Log "Script execution completed successfully"