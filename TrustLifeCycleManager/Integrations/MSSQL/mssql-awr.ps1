# Function to decode base64 encoded string
function Decode-Base64 {
    param (
        [string]$base64String
    )
    $bytes = [System.Convert]::FromBase64String($base64String)
    $decodedString = [System.Text.Encoding]::UTF8.GetString($bytes)
    return $decodedString
}

# Base64 encoded JSON input
$base64Json = [System.Environment]::GetEnvironmentVariable("DC1_POST_SCRIPT_DATA")

# Decode the base64 encoded JSON
$jsonString = Decode-Base64 -base64String $base64Json

# Convert JSON string to PowerShell object
$jsonObject = $jsonString | ConvertFrom-Json

Write-Host "Arguments : "$jsonObject.args

# Extract values from JSON object
$certFolder = $jsonObject.certfolder
$pfxFile = Join-Path -Path $certFolder -ChildPath $jsonObject.files[0]
$password = $jsonObject.password

# Validate inputs
if (-not (Test-Path -Path $pfxFile)) {
    Write-Error "ERROR: The PFX file does not exist."
    exit 1
}

# Import the PFX file into the LocalMachine\My store
try {
    $cert = Import-PfxCertificate -FilePath $pfxFile -CertStoreLocation Cert:\LocalMachine\My -Password (ConvertTo-SecureString -String $password -Force -AsPlainText)
    if ($null -eq $cert) {
        throw "Failed to import the certificate."
    }
    Write-Output "Certificate imported successfully."
    
    # Get the thumbprint from the imported certificate
    $thumbprint = $cert.Thumbprint.ToLower()  # Convert thumbprint to lowercase
    Write-Output "Certificate thumbprint (lowercase): $thumbprint"
    
    # Use certutil to get the unique container name
    $certUtilOutput = certutil -store my $thumbprint
    
    # Parse the certutil output to extract the unique container name
    $uniqueContainerNameLine = $certUtilOutput | Where-Object { $_ -match "Unique container name:" }
    if ($uniqueContainerNameLine) {
        $uniqueContainerName = ($uniqueContainerNameLine -split "Unique container name: ")[1].Trim()
        Write-Output "Unique container name: $uniqueContainerName"
        
        # Construct the path to the key file
        $keyFilePath = Join-Path -Path "C:\ProgramData\Microsoft\Crypto\Keys" -ChildPath $uniqueContainerName
        
        if (Test-Path -Path $keyFilePath) {
            Write-Output "Key file found at: $keyFilePath"
            
            # Add read permissions for the SQL Server service account
            $acl = Get-Acl -Path $keyFilePath
            $serviceAccount = "NT Service\MSSQLSERVER"
            $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($serviceAccount, "Read", "Allow")
            $acl.AddAccessRule($accessRule)
            Set-Acl -Path $keyFilePath -AclObject $acl
            
            Write-Output "Read permissions added for $serviceAccount to the key file."
            
            # Configure SQL Server to use the certificate for encryption via Registry
            Write-Output "Configuring SQL Server to use the certificate for encryption via registry..."
            
            try {
                # Use the correct registry path you provided
                $registryPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQLServer\SuperSocketNetLib"
                
                # Set the certificate thumbprint in the registry
                if (Test-Path -Path $registryPath) {
                    Set-ItemProperty -Path $registryPath -Name "Certificate" -Value $thumbprint
                    Write-Output "Successfully configured SQL Server to use certificate with thumbprint: $thumbprint (lowercase)"
                    
                    # Restart SQL Server service to apply changes
                    Write-Output "Restarting SQL Server service to apply changes..."
                    Restart-Service -Name MSSQLSERVER -Force
                    Write-Output "SQL Server service restarted successfully."
                } else {
                    Write-Error "ERROR: Registry path '$registryPath' does not exist."
                    exit 1
                }
            }
            catch {
                Write-Error "ERROR: Failed to configure SQL Server to use the certificate via registry. $_"
                exit 1
            }
        } else {
            Write-Error "ERROR: Key file not found at expected location: $keyFilePath"
            exit 1
        }
    } else {
        Write-Error "ERROR: Could not find unique container name in certutil output."
        exit 1
    }
} catch {
    Write-Error "ERROR: Failed to process the certificate. $_"
    exit 1
}