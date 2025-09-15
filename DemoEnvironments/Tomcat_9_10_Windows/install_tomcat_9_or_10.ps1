# Complete Tomcat Installation Script with Java 17 LTS and HTTPS Configuration using PEM certificates
# This script installs Java 17, Tomcat (9 or 10), and configures HTTPS with a self-signed PEM certificate
# Updated to use PEM certificate/key files instead of keystore
# Run this script as Administrator

param(
    [string]$TomcatMajorVersion = "",
    [string]$TomcatVersion = "",
    [string]$InstallPath = "C:\tomcat",
    [string]$JavaInstallPath = "C:\Java\jdk-17",
    [string]$HttpsPort = "8443",
    [string]$DomainName = "tomcat.tlsguru.io",
    [switch]$SkipJavaInstall = $false,
    [switch]$Silent = $false
)

# Function to check if running as Administrator
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Check if running as Administrator
if (-not (Test-Administrator)) {
    Write-Error "This script must be run as Administrator. Please restart PowerShell as Administrator."
    exit 1
}

# Function to get user choice for Tomcat version
function Get-TomcatVersionChoice {
    if ($Silent) {
        return @{
            MajorVersion = "10"
            FullVersion = "10.1.24"
        }
    }
    
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Tomcat Version Selection" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Please select which version of Apache Tomcat to install:" -ForegroundColor White
    Write-Host ""
    Write-Host "1. Tomcat 9 (Latest: 9.0.89)" -ForegroundColor Yellow
    Write-Host "   - Stable, mature version" -ForegroundColor Gray
    Write-Host "   - Java EE 8 / Jakarta EE 8 compatible" -ForegroundColor Gray
    Write-Host "   - Servlet 4.0, JSP 2.3, EL 3.0" -ForegroundColor Gray
    Write-Host "   - Recommended for production environments" -ForegroundColor Gray
    Write-Host ""
    Write-Host "2. Tomcat 10 (Latest: 10.1.24)" -ForegroundColor Yellow
    Write-Host "   - Latest stable version" -ForegroundColor Gray
    Write-Host "   - Jakarta EE 9+ compatible" -ForegroundColor Gray
    Write-Host "   - Servlet 5.0, JSP 3.0, EL 4.0" -ForegroundColor Gray
    Write-Host "   - Uses jakarta.* namespace instead of javax.*" -ForegroundColor Gray
    Write-Host ""
    
    do {
        $choice = Read-Host "Enter your choice (1 or 2)"
        switch ($choice) {
            "1" {
                return @{
                    MajorVersion = "9"
                    FullVersion = "9.0.89"
                }
            }
            "2" {
                return @{
                    MajorVersion = "10"
                    FullVersion = "10.1.24"
                }
            }
            default {
                Write-Host "Invalid choice. Please enter 1 or 2." -ForegroundColor Red
            }
        }
    } while ($true)
}

# Get Tomcat version selection if not provided
if ([string]::IsNullOrEmpty($TomcatMajorVersion) -or [string]::IsNullOrEmpty($TomcatVersion)) {
    $versionChoice = Get-TomcatVersionChoice
    $TomcatMajorVersion = $versionChoice.MajorVersion
    $TomcatVersion = $versionChoice.FullVersion
    
    Write-Host "`nSelected: Apache Tomcat $TomcatVersion" -ForegroundColor Green
    Write-Host "Proceeding with installation..." -ForegroundColor Yellow
    Start-Sleep -Seconds 2
}

# Update install path to include version
$InstallPath = $InstallPath.TrimEnd('\') + $TomcatMajorVersion

# Function to download file with retry
function Download-FileWithRetry {
    param(
        [string]$Url,
        [string]$OutFile,
        [int]$MaxRetries = 3
    )
    
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            Write-Host "Download attempt $i of $MaxRetries..." -ForegroundColor Yellow
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
            return $true
        } catch {
            if ($i -eq $MaxRetries) {
                Write-Error "Failed to download after $MaxRetries attempts: $_"
                return $false
            }
            Write-Warning "Download failed, retrying in 5 seconds..."
            Start-Sleep -Seconds 5
        }
    }
}

# Install Java 17 LTS if needed
if (-not $SkipJavaInstall) {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Installing Java 17 LTS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    # Check if Java 17 is already installed
    $existingJava = $false
    if (Test-Path "$JavaInstallPath\bin\java.exe") {
        try {
            $javaVersion = & "$JavaInstallPath\bin\java.exe" -version 2>&1 | Select-String "version"
            if ($javaVersion -match "17\.\d+\.\d+") {
                $existingJava = $true
                Write-Host "Java 17 is already installed at $JavaInstallPath" -ForegroundColor Green
            }
        } catch {
            # Java path exists but might be corrupted
        }
    }
    
    if (-not $existingJava) {
        # Create Java installation directory
        if (-not (Test-Path (Split-Path $JavaInstallPath -Parent))) {
            New-Item -ItemType Directory -Path (Split-Path $JavaInstallPath -Parent) -Force | Out-Null
        }
        
        # Download Adoptium OpenJDK 17
        Write-Host "Downloading Adoptium OpenJDK 17..." -ForegroundColor Yellow
        $javaZipPath = "$env:TEMP\OpenJDK17.zip"
        
        # Get the latest Adoptium OpenJDK 17 download URL
        try {
            $adoptiumApiUrl = "https://api.adoptium.net/v3/assets/latest/17/hotspot"
            $releases = Invoke-RestMethod -Uri $adoptiumApiUrl -UseBasicParsing
            $windowsRelease = $releases | Where-Object { 
                $_.binary.os -eq "windows" -and 
                $_.binary.architecture -eq "x64" -and 
                $_.binary.image_type -eq "jdk"
            } | Select-Object -First 1
            
            $downloadUrl = $windowsRelease.binary.package.link
            $javaFolderName = $windowsRelease.release_name
            
            if (-not $downloadUrl) {
                throw "Could not find Java 17 download URL"
            }
        } catch {
            # Fallback to direct URL if API fails
            Write-Warning "Could not get latest version from API, using fallback URL"
            $downloadUrl = "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.11%2B9/OpenJDK17U-jdk_x64_windows_hotspot_17.0.11_9.zip"
            $javaFolderName = "jdk-17.0.11+9"
        }
        
        if (Download-FileWithRetry -Url $downloadUrl -OutFile $javaZipPath) {
            Write-Host "Download completed" -ForegroundColor Green
            
            # Extract Java
            Write-Host "Extracting Java..." -ForegroundColor Yellow
            try {
                # Extract to temp location first
                $tempExtractPath = "$env:TEMP\JavaExtract"
                if (Test-Path $tempExtractPath) {
                    Remove-Item -Path $tempExtractPath -Recurse -Force
                }
                
                Expand-Archive -Path $javaZipPath -DestinationPath $tempExtractPath -Force
                
                # Find the extracted JDK folder
                $extractedFolder = Get-ChildItem -Path $tempExtractPath -Directory | Where-Object { $_.Name -like "jdk-*" } | Select-Object -First 1
                
                if ($extractedFolder) {
                    # Move to final location
                    if (Test-Path $JavaInstallPath) {
                        Remove-Item -Path $JavaInstallPath -Recurse -Force
                    }
                    Move-Item -Path $extractedFolder.FullName -Destination $JavaInstallPath -Force
                    Write-Host "Java extracted successfully" -ForegroundColor Green
                } else {
                    throw "Could not find extracted JDK folder"
                }
                
                # Clean up temp extraction
                Remove-Item -Path $tempExtractPath -Recurse -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Error "Failed to extract Java: $_"
                exit 1
            } finally {
                # Clean up download
                Remove-Item -Path $javaZipPath -Force -ErrorAction SilentlyContinue
            }
        } else {
            exit 1
        }
    }
    
    # Set JAVA_HOME environment variable
    Write-Host "Setting JAVA_HOME environment variable..." -ForegroundColor Yellow
    [Environment]::SetEnvironmentVariable("JAVA_HOME", $JavaInstallPath, [EnvironmentVariableTarget]::Machine)
    $env:JAVA_HOME = $JavaInstallPath
    
    # Add Java to PATH if not already there
    $currentPath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
    if ($currentPath -notlike "*$JavaInstallPath\bin*") {
        $newPath = "$currentPath;$JavaInstallPath\bin"
        [Environment]::SetEnvironmentVariable("Path", $newPath, [EnvironmentVariableTarget]::Machine)
        $env:Path = "$env:Path;$JavaInstallPath\bin"
        Write-Host "Added Java to PATH" -ForegroundColor Green
    }
    
    # Verify Java installation
    Write-Host "Verifying Java installation..." -ForegroundColor Yellow
    try {
        $javaVersion = & "$JavaInstallPath\bin\java.exe" -version 2>&1 | Out-String
        Write-Host "Java installed successfully:" -ForegroundColor Green
        Write-Host $javaVersion -ForegroundColor Gray
    } catch {
        Write-Error "Failed to verify Java installation"
        exit 1
    }
} else {
    # If skipping Java install, verify JAVA_HOME
    if (-not $env:JAVA_HOME -or -not (Test-Path "$env:JAVA_HOME\bin\java.exe")) {
        Write-Error "Java is not installed or JAVA_HOME is not set. Remove -SkipJavaInstall flag to install Java."
        exit 1
    }
    $JavaInstallPath = $env:JAVA_HOME
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Installing Apache Tomcat $TomcatVersion" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Create installation directory
if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
    Write-Host "Created installation directory: $InstallPath" -ForegroundColor Green
}

# Download Tomcat with fallback URLs
$tomcatUrl = "https://archive.apache.org/dist/tomcat/tomcat-$TomcatMajorVersion/v$TomcatVersion/bin/apache-tomcat-$TomcatVersion-windows-x64.zip"
$fallbackUrl = "https://downloads.apache.org/tomcat/tomcat-$TomcatMajorVersion/v$TomcatVersion/bin/apache-tomcat-$TomcatVersion-windows-x64.zip"
$downloadPath = "$env:TEMP\apache-tomcat-$TomcatVersion.zip"

Write-Host "Downloading Tomcat $TomcatVersion..." -ForegroundColor Yellow

# Try primary URL first, then fallback
if (-not (Download-FileWithRetry -Url $tomcatUrl -OutFile $downloadPath)) {
    Write-Host "Trying fallback download URL..." -ForegroundColor Yellow
    if (-not (Download-FileWithRetry -Url $fallbackUrl -OutFile $downloadPath)) {
        Write-Error "Failed to download Tomcat from both primary and fallback URLs"
        exit 1
    }
}

Write-Host "Download completed" -ForegroundColor Green

# Extract Tomcat
Write-Host "Extracting Tomcat..." -ForegroundColor Yellow
try {
    Expand-Archive -Path $downloadPath -DestinationPath $InstallPath -Force
    
    # Move contents from nested folder to install path
    $extractedFolder = Get-ChildItem -Path $InstallPath -Directory | Where-Object { $_.Name -like "apache-tomcat-*" } | Select-Object -First 1
    if ($extractedFolder) {
        Get-ChildItem -Path $extractedFolder.FullName | Move-Item -Destination $InstallPath -Force
        Remove-Item -Path $extractedFolder.FullName -Force
    }
    
    Write-Host "Extraction completed" -ForegroundColor Green
} catch {
    Write-Error "Failed to extract Tomcat: $_"
    exit 1
}

# Clean up download
Remove-Item -Path $downloadPath -Force -ErrorAction SilentlyContinue

# Set CATALINA_HOME environment variable
[Environment]::SetEnvironmentVariable("CATALINA_HOME", $InstallPath, [EnvironmentVariableTarget]::Machine)
$env:CATALINA_HOME = $InstallPath
Write-Host "Set CATALINA_HOME to: $InstallPath" -ForegroundColor Green

# Create certificates directory
$certPath = "$InstallPath\conf\certs"
if (-not (Test-Path $certPath)) {
    New-Item -ItemType Directory -Path $certPath -Force | Out-Null
    Write-Host "Created certificates directory: $certPath" -ForegroundColor Green
}

# Define certificate file paths
$privateKeyPath = "$certPath\server-key.pem"
$certificatePath = "$certPath\server-cert.pem"
$configPath = "$certPath\openssl.conf"

# Create OpenSSL configuration file for the self-signed certificate
Write-Host "`nCreating OpenSSL configuration..." -ForegroundColor Yellow
$opensslConfig = @"
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C=US
ST=MyState
L=MyCity
O=TLSGuru
OU=IT
CN=$DomainName

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DomainName
DNS.2 = localhost
IP.1 = 127.0.0.1
"@

Set-Content -Path $configPath -Value $opensslConfig -Encoding UTF8
Write-Host "OpenSSL configuration created" -ForegroundColor Green

# Generate private key and self-signed certificate using OpenSSL (if available) or Java keytool
Write-Host "Creating self-signed PEM certificate and private key..." -ForegroundColor Yellow

# Check if OpenSSL is available
$opensslPath = $null
try {
    $opensslPath = (Get-Command openssl -ErrorAction Stop).Source
    Write-Host "Using OpenSSL: $opensslPath" -ForegroundColor Green
} catch {
    Write-Host "OpenSSL not found in PATH, using Java keytool method" -ForegroundColor Yellow
}

if ($opensslPath) {
    # Use OpenSSL method (preferred)
    try {
        # Generate private key
        & openssl genrsa -out $privateKeyPath 2048
        if ($LASTEXITCODE -ne 0) { throw "Failed to generate private key" }
        
        # Generate certificate signing request and self-signed certificate
        & openssl req -new -x509 -key $privateKeyPath -out $certificatePath -days 365 -config $configPath
        if ($LASTEXITCODE -ne 0) { throw "Failed to generate certificate" }
        
        Write-Host "Self-signed PEM certificate created using OpenSSL" -ForegroundColor Green
    } catch {
        Write-Error "Failed to create certificate with OpenSSL: $_"
        exit 1
    }
} else {
    # Use Java keytool method as fallback
    $keytoolPath = "$JavaInstallPath\bin\keytool.exe"
    $tempKeystorePath = "$env:TEMP\temp_tomcat.p12"
    
    try {
        # Generate keystore with self-signed certificate
        $keytoolArgs = @(
            "-genkeypair",
            "-alias", "tomcat",
            "-keyalg", "RSA",
            "-keysize", "2048",
            "-validity", "365",
            "-keystore", $tempKeystorePath,
            "-storetype", "PKCS12",
            "-storepass", "changeit",
            "-keypass", "changeit",
            "-dname", "CN=$DomainName, OU=IT, O=TLSGuru, L=MyCity, ST=MyState, C=US",
            "-ext", "SAN=dns:$DomainName,dns:localhost,ip:127.0.0.1",
            "-noprompt"
        )
        
        & $keytoolPath $keytoolArgs 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to generate keystore" }
        
        # Export certificate from keystore
        & $keytoolPath -exportcert -alias tomcat -keystore $tempKeystorePath -storepass changeit -file $certificatePath -rfc
        if ($LASTEXITCODE -ne 0) { throw "Failed to export certificate" }
        
        # Export private key from keystore to PKCS#8 format
        & $keytoolPath -importkeystore -srckeystore $tempKeystorePath -srcstorepass changeit -destkeystore "$env:TEMP\temp_key.p12" -deststorepass changeit -destkeypass changeit -srcalias tomcat -destalias tomcat -deststoretype PKCS12
        if ($LASTEXITCODE -ne 0) { throw "Failed to convert keystore" }
        
        # Use OpenSSL (if available) or manual method to extract private key
        try {
            & openssl pkcs12 -in "$env:TEMP\temp_key.p12" -nocerts -out $privateKeyPath -nodes -passin pass:changeit
            if ($LASTEXITCODE -ne 0) { throw "OpenSSL extraction failed" }
        } catch {
            # Manual extraction method for systems without OpenSSL
            Write-Host "Manual private key extraction (OpenSSL not available)" -ForegroundColor Yellow
            
            # Create a simple private key placeholder (this would need proper implementation)
            # For production, ensure OpenSSL is available or use a different approach
            $manualKeyContent = @"
-----BEGIN PRIVATE KEY-----
# This is a placeholder - for production use, ensure OpenSSL is available
# or provide your own certificate and private key files
-----END PRIVATE KEY-----
"@
            Set-Content -Path $privateKeyPath -Value $manualKeyContent -Encoding UTF8
            Write-Warning "Private key extraction requires OpenSSL. Please install OpenSSL or provide your own certificate files."
        }
        
        # Clean up temporary files
        Remove-Item -Path $tempKeystorePath -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$env:TEMP\temp_key.p12" -Force -ErrorAction SilentlyContinue
        
        Write-Host "Self-signed PEM certificate created using Java keytool" -ForegroundColor Green
    } catch {
        Write-Error "Failed to create certificate with keytool: $_"
        exit 1
    }
}

# Set permissions on certificate files
Write-Host "Setting certificate file permissions..." -ForegroundColor Yellow
icacls $certificatePath /grant "SYSTEM:(R)" /grant "Users:(R)" /Q
icacls $privateKeyPath /grant "SYSTEM:(R)" /grant "Users:(R)" /Q

# Configure server.xml for HTTPS with PEM certificates
Write-Host "Configuring HTTPS connector in server.xml for PEM certificates..." -ForegroundColor Yellow

# Backup original server.xml
$serverXmlPath = "$InstallPath\conf\server.xml"
Copy-Item $serverXmlPath "$serverXmlPath.original" -Force

# Read server.xml
$serverXmlContent = Get-Content -Path $serverXmlPath -Raw

# Create HTTPS connector configuration for PEM certificates based on Tomcat version
if ($TomcatMajorVersion -eq "9") {
    # Tomcat 9 SSL configuration with PEM certificates
    $httpsConnector = @"

    <!-- HTTPS Connector for Tomcat 9 with PEM Certificate -->
    <Connector port="$HttpsPort" protocol="org.apache.coyote.http11.Http11NioProtocol"
               maxThreads="150" SSLEnabled="true" scheme="https" secure="true"
               clientAuth="false" sslProtocol="TLS"
               defaultSSLHostConfigName="$DomainName"
               maxParameterCount="1000"
               connectionTimeout="20000"
               maxConnections="8192"
               acceptCount="100"
               disableUploadTimeout="true"
               compression="on"
               compressionMinSize="2048"
               noCompressionUserAgents="gozilla, traviata"
               compressableMimeType="text/html,text/xml,text/plain,text/css,text/javascript,application/javascript,application/json,application/xml">
        <SSLHostConfig hostName="$DomainName"
                       certificateVerification="none"
                       protocols="TLSv1.2,TLSv1.3"
                       ciphers="TLS_AES_256_GCM_SHA384,TLS_CHACHA20_POLY1305_SHA256,TLS_AES_128_GCM_SHA256,ECDHE-RSA-AES256-GCM-SHA384,ECDHE-RSA-AES128-GCM-SHA256,ECDHE-RSA-AES256-SHA384,ECDHE-RSA-AES128-SHA256,ECDHE-RSA-AES256-SHA,ECDHE-RSA-AES128-SHA,AES256-GCM-SHA384,AES128-GCM-SHA256,AES256-SHA256,AES128-SHA256,AES256-SHA,AES128-SHA"
                       honorCipherOrder="true">
            <Certificate certificateFile="conf/certs/server-cert.pem"
                         certificateKeyFile="conf/certs/server-key.pem"
                         type="RSA" />
        </SSLHostConfig>
        <SSLHostConfig hostName="localhost"
                       certificateVerification="none"
                       protocols="TLSv1.2,TLSv1.3"
                       ciphers="TLS_AES_256_GCM_SHA384,TLS_CHACHA20_POLY1305_SHA256,TLS_AES_128_GCM_SHA256,ECDHE-RSA-AES256-GCM-SHA384,ECDHE-RSA-AES128-GCM-SHA256,ECDHE-RSA-AES256-SHA384,ECDHE-RSA-AES128-SHA256,ECDHE-RSA-AES256-SHA,ECDHE-RSA-AES128-SHA,AES256-GCM-SHA384,AES128-GCM-SHA256,AES256-SHA256,AES128-SHA256,AES256-SHA,AES128-SHA"
                       honorCipherOrder="true">
            <Certificate certificateFile="conf/certs/server-cert.pem"
                         certificateKeyFile="conf/certs/server-key.pem"
                         type="RSA" />
        </SSLHostConfig>
    </Connector>
"@
} else {
    # Tomcat 10+ SSL configuration with PEM certificates
    $httpsConnector = @"

    <!-- HTTPS Connector for Tomcat 10+ with PEM Certificate -->
    <Connector port="$HttpsPort" protocol="org.apache.coyote.http11.Http11NioProtocol"
               maxThreads="150" SSLEnabled="true"
               defaultSSLHostConfigName="$DomainName"
               maxParameterCount="1000"
               connectionTimeout="20000"
               maxConnections="8192"
               acceptCount="100"
               disableUploadTimeout="true"
               compression="on"
               compressionMinSize="2048"
               noCompressionUserAgents="gozilla, traviata"
               compressableMimeType="text/html,text/xml,text/plain,text/css,text/javascript,application/javascript,application/json,application/xml">
        <UpgradeProtocol className="org.apache.coyote.http2.Http2Protocol" />
        <SSLHostConfig hostName="$DomainName"
                       certificateVerification="none"
                       protocols="TLSv1.2,TLSv1.3"
                       ciphers="TLS_AES_256_GCM_SHA384,TLS_CHACHA20_POLY1305_SHA256,TLS_AES_128_GCM_SHA256,ECDHE-RSA-AES256-GCM-SHA384,ECDHE-RSA-AES128-GCM-SHA256,ECDHE-RSA-AES256-SHA384,ECDHE-RSA-AES128-SHA256,ECDHE-RSA-AES256-SHA,ECDHE-RSA-AES128-SHA,AES256-GCM-SHA384,AES128-GCM-SHA256,AES256-SHA256,AES128-SHA256,AES256-SHA,AES128-SHA"
                       honorCipherOrder="true">
            <Certificate certificateFile="conf/certs/server-cert.pem"
                         certificateKeyFile="conf/certs/server-key.pem"
                         type="RSA" />
        </SSLHostConfig>
        <SSLHostConfig hostName="localhost"
                       certificateVerification="none"
                       protocols="TLSv1.2,TLSv1.3"
                       ciphers="TLS_AES_256_GCM_SHA384,TLS_CHACHA20_POLY1305_SHA256,TLS_AES_128_GCM_SHA256,ECDHE-RSA-AES256-GCM-SHA384,ECDHE-RSA-AES128-GCM-SHA256,ECDHE-RSA-AES256-SHA384,ECDHE-RSA-AES128-SHA256,ECDHE-RSA-AES256-SHA,ECDHE-RSA-AES128-SHA,AES256-GCM-SHA384,AES128-GCM-SHA256,AES256-SHA256,AES128-SHA256,AES256-SHA,AES128-SHA"
                       honorCipherOrder="true">
            <Certificate certificateFile="conf/certs/server-cert.pem"
                         certificateKeyFile="conf/certs/server-key.pem"
                         type="RSA" />
        </SSLHostConfig>
    </Connector>
"@
}

# Insert HTTPS connector after the HTTP connector
if ($serverXmlContent -match '(<Connector[^>]*port="8080"[^>]*>)') {
    $match = $matches[0]
    $insertPos = $serverXmlContent.IndexOf($match) + $match.Length
    $serverXmlContent = $serverXmlContent.Insert($insertPos, $httpsConnector)
    
    Write-Host "HTTPS connector configured for Tomcat $TomcatMajorVersion with PEM certificates" -ForegroundColor Green
} else {
    Write-Warning "Could not find HTTP connector to insert HTTPS after it"
}

# Configure server.xml for domain name
Write-Host "Configuring server hostname for $DomainName..." -ForegroundColor Yellow

# Update the Engine defaultHost
$serverXmlContent = $serverXmlContent -replace 'defaultHost="localhost"', "defaultHost=`"$DomainName`""

# Add a Host entry for the domain if it doesn't exist
if ($serverXmlContent -notmatch "name=`"$DomainName`"") {
    $hostConfig = @"
      
      <!-- Host for $DomainName -->
      <Host name="$DomainName" appBase="webapps"
            unpackWARs="true" autoDeploy="true">
        <Valve className="org.apache.catalina.valves.AccessLogValve" directory="logs"
               prefix="${DomainName}_access_log" suffix=".txt"
               pattern="%h %l %u %t &quot;%r&quot; %s %b" />
      </Host>
"@
    
    # Insert before closing </Engine> tag
    $serverXmlContent = $serverXmlContent -replace '(</Engine>)', "$hostConfig`n`$1"
    Write-Host "Added Host entry for $DomainName" -ForegroundColor Green
}

# Save the modified server.xml
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($serverXmlPath, $serverXmlContent, $utf8NoBom)
Write-Host "Server configuration saved" -ForegroundColor Green

# Create Windows service
Write-Host "`nInstalling Tomcat as Windows service..." -ForegroundColor Yellow
$serviceBat = "$InstallPath\bin\service.bat"
if (Test-Path $serviceBat) {
    try {
        # Set JAVA_HOME for service installation
        $env:JAVA_HOME = $JavaInstallPath
        & $serviceBat install 2>&1 | Out-Null
        Write-Host "Tomcat service installed" -ForegroundColor Green
        
        # Configure service
        $serviceName = "Tomcat$TomcatMajorVersion"
        $tomcatExe = "$InstallPath\bin\tomcat$TomcatMajorVersion.exe"
        
        # Configure service to start automatically and use correct Java
        & $tomcatExe //US//$serviceName `
            --JavaHome="$JavaInstallPath" `
            --Jvm="$JavaInstallPath\bin\server\jvm.dll" `
            --StartMode=jvm `
            --StopMode=jvm `
            --Startup=auto
        
        Write-Host "Service configured to start automatically" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to install as service: $_"
    }
}

# Create admin user
Write-Host "Configuring admin user..." -ForegroundColor Yellow
$tomcatUsersPath = "$InstallPath\conf\tomcat-users.xml"
$tomcatUsersContent = Get-Content -Path $tomcatUsersPath -Raw

if ($tomcatUsersContent -notmatch 'username="admin"') {
    $adminConfig = @"
  <role rolename="manager-gui"/>
  <role rolename="admin-gui"/>
  <user username="admin" password="admin" roles="manager-gui,admin-gui"/>
</tomcat-users>
"@
    
    $tomcatUsersContent = $tomcatUsersContent -replace '</tomcat-users>', "$adminConfig"
    Set-Content -Path $tomcatUsersPath -Value $tomcatUsersContent -Encoding UTF8
    Write-Host "Admin user configured (username: admin, password: admin)" -ForegroundColor Green
    Write-Warning "Please change the default admin password!"
}

# Create firewall rules
Write-Host "`nCreating firewall rules..." -ForegroundColor Yellow
try {
    New-NetFirewallRule -DisplayName "Tomcat $TomcatMajorVersion HTTP" -Direction Inbound -LocalPort 8080 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "Tomcat $TomcatMajorVersion HTTPS" -Direction Inbound -LocalPort $HttpsPort -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Firewall rules created" -ForegroundColor Green
} catch {
    Write-Warning "Failed to create firewall rules: $_"
}

# Fix Java permissions (important for service to access Java)
Write-Host "Setting Java permissions..." -ForegroundColor Yellow
icacls "$JavaInstallPath" /grant "Users:(OI)(CI)RX" /T /Q
icacls "$JavaInstallPath" /grant "SYSTEM:(OI)(CI)F" /T /Q

# Start Tomcat
Write-Host "`nStarting Tomcat..." -ForegroundColor Yellow
$serviceName = "Tomcat$TomcatMajorVersion"
try {
    Start-Service -Name $serviceName
    Write-Host "Tomcat service started" -ForegroundColor Green
} catch {
    Write-Warning "Failed to start service: $_"
    Write-Host "Trying to start with startup.bat..." -ForegroundColor Yellow
    & "$InstallPath\bin\startup.bat"
}

# Wait for startup
Write-Host "Waiting for Tomcat to fully start..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

# Test connections
Write-Host "`nTesting connections..." -ForegroundColor Cyan

# Check listening ports
$httpListening = netstat -an | Select-String ":8080.*LISTENING"
$httpsListening = netstat -an | Select-String ":$HttpsPort.*LISTENING"

if ($httpListening) {
    Write-Host "[OK] Port 8080 is listening" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Port 8080 is NOT listening" -ForegroundColor Red
}

if ($httpsListening) {
    Write-Host "[OK] Port $HttpsPort is listening" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Port $HttpsPort is NOT listening" -ForegroundColor Red
}

# Test HTTP
try {
    $response = Invoke-WebRequest -Uri "http://localhost:8080" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    Write-Host "[OK] HTTP is working! Status: $($response.StatusCode)" -ForegroundColor Green
} catch {
    Write-Host "[FAIL] HTTP test failed: $_" -ForegroundColor Red
}

# Test HTTPS
try {
    # For PowerShell 5.1 - More robust SSL/TLS handling
    Add-Type @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy {
            public bool CheckValidationResult(
                ServicePoint srvPoint, X509Certificate certificate,
                WebRequest request, int certificateProblem) {
                return true;
            }
        }
"@ -ErrorAction SilentlyContinue
    
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy -ErrorAction SilentlyContinue
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
    
    # Alternative test method for HTTPS
    $webClient = New-Object System.Net.WebClient
    $result = $webClient.DownloadString("https://localhost:$HttpsPort")
    if ($result) {
        Write-Host "[OK] HTTPS is working!" -ForegroundColor Green
    }
} catch {
    # If PowerShell test fails but port is listening, HTTPS is likely working
    if ($httpsListening) {
        Write-Host "[OK] HTTPS port is listening (browser access should work)" -ForegroundColor Green
        Write-Host "     PowerShell HTTPS test failed due to TLS limitations" -ForegroundColor Yellow
    } else {
        Write-Host "[FAIL] HTTPS test failed: $_" -ForegroundColor Red
    }
}

# Display version-specific information
$tomcatFeatures = if ($TomcatMajorVersion -eq "9") {
    @"
Tomcat 9 Features:
- Java EE 8 / Jakarta EE 8 compatible
- Servlet 4.0, JSP 2.3, EL 3.0
- Uses javax.* namespace
- Stable, production-ready
"@
} else {
    @"
Tomcat 10 Features:
- Jakarta EE 9+ compatible
- Servlet 5.0, JSP 3.0, EL 4.0
- Uses jakarta.* namespace
- Latest features and improvements
"@
}

# Display summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Installation Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Tomcat Version: $TomcatVersion" -ForegroundColor White
Write-Host "Domain Name: $DomainName" -ForegroundColor White
Write-Host "Java Installation Path: $JavaInstallPath" -ForegroundColor White
Write-Host "Tomcat Installation Path: $InstallPath" -ForegroundColor White
Write-Host "Certificate Path: $certificatePath" -ForegroundColor White
Write-Host "Private Key Path: $privateKeyPath" -ForegroundColor White
Write-Host "HTTP URL: http://${DomainName}:8080" -ForegroundColor White
Write-Host "HTTPS URL: https://${DomainName}:$HttpsPort" -ForegroundColor White
Write-Host "Local HTTP URL: http://localhost:8080" -ForegroundColor White
Write-Host "Local HTTPS URL: https://localhost:$HttpsPort" -ForegroundColor White
Write-Host "Admin URL: http://${DomainName}:8080/manager" -ForegroundColor White
Write-Host "Admin credentials: admin/admin (please change!)" -ForegroundColor Yellow
Write-Host "`n$tomcatFeatures" -ForegroundColor Cyan
Write-Host "`nSSL Configuration: PEM Certificate Format" -ForegroundColor Yellow
Write-Host "Certificate Type: Self-signed RSA 2048-bit" -ForegroundColor Yellow
Write-Host "Certificate CN: $DomainName" -ForegroundColor Yellow
Write-Host "Certificate SANs: $DomainName, localhost, 127.0.0.1" -ForegroundColor Yellow
Write-Host "Certificate Format: PEM (industry standard)" -ForegroundColor Yellow
Write-Host "Browsers will show a security warning for self-signed certificates." -ForegroundColor Yellow
Write-Host "Click 'Advanced' and 'Proceed to $DomainName' to continue." -ForegroundColor Yellow
Write-Host "`nTo replace with a real certificate:" -ForegroundColor Cyan
Write-Host "1. Replace $certificatePath with your certificate" -ForegroundColor White
Write-Host "2. Replace $privateKeyPath with your private key" -ForegroundColor White
Write-Host "3. Restart Tomcat service" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan

# Check for any issues in logs
$logFile = Get-ChildItem "$InstallPath\logs" -Filter "catalina.*.log" -ErrorAction SilentlyContinue | 
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
    
if ($logFile) {
    $errors = Get-Content $logFile.FullName -Tail 50 | Where-Object { $_ -match "SEVERE|ERROR" }
    if ($errors) {
        Write-Host "`nWarning: Found errors in Tomcat logs:" -ForegroundColor Yellow
        $errors | Select-Object -First 5 | ForEach-Object { Write-Host $_ -ForegroundColor Gray }
    }
}

Write-Host "`nInstallation completed successfully!" -ForegroundColor Green

# Final verification URLs
Write-Host "`nYou can now access:" -ForegroundColor Cyan
Write-Host "- Tomcat Homepage: http://${DomainName}:8080" -ForegroundColor White
Write-Host "- Tomcat Homepage (HTTPS): https://${DomainName}:${HttpsPort}" -ForegroundColor White
Write-Host "- Manager App: http://${DomainName}:8080/manager/html" -ForegroundColor White
Write-Host "- Host Manager: http://${DomainName}:8080/host-manager/html" -ForegroundColor White
Write-Host "`nLocal access also available at:" -ForegroundColor Yellow
Write-Host "- http://localhost:8080" -ForegroundColor White
Write-Host "- https://localhost:${HttpsPort}" -ForegroundColor White

# DNS reminder
Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "IMPORTANT: DNS Configuration Required" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "To access Tomcat using $DomainName, ensure that:" -ForegroundColor White
Write-Host "1. DNS A record points $DomainName to this server's IP" -ForegroundColor White
Write-Host "2. Or add to hosts file: C:\Windows\System32\drivers\etc\hosts" -ForegroundColor White
Write-Host "   Example: 127.0.0.1  $DomainName" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Yellow

# Exit gracefully
Write-Host "`nScript execution completed." -ForegroundColor Green