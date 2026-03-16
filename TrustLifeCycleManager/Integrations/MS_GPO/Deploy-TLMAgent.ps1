<#
.SYNOPSIS
    Comprehensive TLM Agent deployment script for installation and activation.

.DESCRIPTION
    This script handles the complete deployment lifecycle of the DigiCert TLM Agent:
    - Installation with customizable parameters
    - Automatic service detection
    - Agent activation with API key and business unit configuration
    - Uninstallation with optional data preservation
    - Comprehensive error handling and logging
    - Support for proxy configuration

.PARAMETER Action
    The action to perform: Install, Activate, InstallAndActivate (default), Upgrade, Uninstall, or UninstallPreserveData

.PARAMETER InstallerPath
    Path to the TLM Agent installer executable. Defaults to script directory.

.PARAMETER InstallDir
    Custom installation directory. If not specified, uses default Program Files location.

.PARAMETER ApiKey
    API key for agent activation. Can also be set via DC_API_KEY environment variable.

.PARAMETER BusinessUnitId
    Business unit ID for agent activation. Can also be set via TLM_BUSINESS_UNIT environment variable.

.PARAMETER AgentName
    Custom agent name. Defaults to computer name.

.PARAMETER Proxy
    Proxy server URL for agent communication.

.PARAMETER DcOneHost
    DigiCert ONE host. Can also be set via DCONE_HOST environment variable.

.PARAMETER LogFile
    Path to log file. Defaults to C:\tlm_agent_deployment.log

.EXAMPLE
    .\Deploy-TLMAgent.ps1 -Action InstallAndActivate -ApiKey "your-api-key" -BusinessUnitId "your-bu-id"

.EXAMPLE
    .\Deploy-TLMAgent.ps1 -Action Install -InstallDir "D:\CustomPath\TLMAgent"

.EXAMPLE
    .\Deploy-TLMAgent.ps1 -Action Activate -AgentName "WebServer01" -Proxy "http://proxy.company.com:8080"

.EXAMPLE
    .\Deploy-TLMAgent.ps1 -Action Upgrade -InstallerPath "C:\Temp\NewVersion.exe"

.EXAMPLE
    .\Deploy-TLMAgent.ps1 -Action Uninstall
    
.EXAMPLE
    .\Deploy-TLMAgent.ps1 -Action UninstallPreserveData
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Activate', 'InstallAndActivate', 'Upgrade', 'Uninstall', 'UninstallPreserveData')]
    [string]$Action = 'InstallAndActivate',

    [Parameter(Mandatory = $false)]
    [string]$InstallerPath,

    [Parameter(Mandatory = $false)]
    [string]$InstallDir,

    [Parameter(Mandatory = $false)]
    [string]$ApiKey,

    [Parameter(Mandatory = $false)]
    [string]$BusinessUnitId,

    [Parameter(Mandatory = $false)]
    [string]$AgentName,

    [Parameter(Mandatory = $false)]
    [string]$Proxy,

    [Parameter(Mandatory = $false)]
    [string]$DcOneHost,

    [Parameter(Mandatory = $false)]
    [string]$LogFile = "$env:SystemDrive\tlm_agent_deployment.log"
)

# === CONFIGURATION ===
$ErrorActionPreference = 'Stop'
$ServiceName = "DigiCertAdmAgentService"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Set default installer path if not provided
if (-not $InstallerPath) {
    $InstallerPath = Join-Path $ScriptDir "DigiCert TLM Agent.exe"
}

# Use environment variables as fallback for API key and Business Unit
if (-not $ApiKey -and $env:DC_API_KEY) {
    $ApiKey = $env:DC_API_KEY
}

if (-not $BusinessUnitId -and $env:TLM_BUSINESS_UNIT) {
    $BusinessUnitId = $env:TLM_BUSINESS_UNIT
}

if (-not $AgentName -and $env:TLM_AGENT_NAME) {
    $AgentName = $env:TLM_AGENT_NAME
}

if (-not $DcOneHost -and $env:DCONE_HOST) {
    $DcOneHost = $env:DCONE_HOST
}

# Default agent name to computer name
if (-not $AgentName) {
    $AgentName = $env:COMPUTERNAME
}

# === FUNCTIONS ===

function Write-Log {
    <#
    .SYNOPSIS
        Writes a message to both console and log file with timestamp.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Write to console with color
    switch ($Level) {
        'ERROR' { Write-Host $logMessage -ForegroundColor Red }
        'WARNING' { Write-Host $logMessage -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $logMessage -ForegroundColor Green }
        default { Write-Host $logMessage }
    }
    
    # Write to log file
    try {
        Add-Content -Path $LogFile -Value $logMessage -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warning "Failed to write to log file: $_"
    }
}

function Test-Administrator {
    <#
    .SYNOPSIS
        Checks if the script is running with administrator privileges.
    #>
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-TLMAgent {
    <#
    .SYNOPSIS
        Installs the TLM Agent using the provided installer.
    #>
    param(
        [string]$InstallerPath,
        [string]$InstallDir,
        [string]$DcOneHost,
        [string]$LogFile
    )
    
    Write-Log "==========================================" -Level INFO
    Write-Log "Starting TLM Agent Installation" -Level INFO
    Write-Log "==========================================" -Level INFO
    Write-Log "Installer path: $InstallerPath" -Level INFO
    
    if ($InstallDir) {
        Write-Log "Custom installation directory: $InstallDir" -Level INFO
    }
    else {
        Write-Log "Using default Program Files location" -Level INFO
    }
    
    # Verify installer exists
    if (-not (Test-Path $InstallerPath)) {
        Write-Log "Installer not found at: $InstallerPath" -Level ERROR
        throw "Installer file not found"
    }
    
    # Build installation arguments
    $installArgs = @(
        '/install',
        '/quiet',
        '/norestart',
        'ACCEPTEULA=yes',
        "/log `"$LogFile`""
    )
    
    if ($InstallDir) {
        $installArgs += "INSTALLDIR=`"$InstallDir`""
    }
    
    if ($DcOneHost) {
        $installArgs += "DCONE_HOST=`"$DcOneHost`""
    }
    
    # Execute installer
    Write-Log "Executing installer with arguments: $($installArgs -join ' ')" -Level INFO
    
    try {
        $process = Start-Process -FilePath $InstallerPath -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
        $exitCode = $process.ExitCode
        
        if ($exitCode -eq 0) {
            Write-Log "Installation completed successfully" -Level SUCCESS
            return $true
        }
        else {
            Write-Log "Installer exited with code: $exitCode" -Level ERROR
            return $false
        }
    }
    catch {
        Write-Log "Installation failed with exception: $_" -Level ERROR
        throw
    }
}

function Update-TLMAgent {
    <#
    .SYNOPSIS
        Upgrades the TLM Agent to a newer version.
    #>
    param(
        [string]$InstallerPath,
        [string]$LogFile
    )
    
    Write-Log "==========================================" -Level INFO
    Write-Log "Starting TLM Agent Upgrade" -Level INFO
    Write-Log "==========================================" -Level INFO
    Write-Log "Installer path: $InstallerPath" -Level INFO
    
    # Verify installer exists
    if (-not (Test-Path $InstallerPath)) {
        Write-Log "Installer not found at: $InstallerPath" -Level ERROR
        throw "Installer file not found"
    }
    
    # Check if service exists before upgrade
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Log "Service '$ServiceName' not found. Agent may not be installed." -Level WARNING
        Write-Log "Consider using -Action Install instead of Upgrade" -Level WARNING
    }
    else {
        Write-Log "Current service status: $($service.Status)" -Level INFO
    }
    
    # Build installation arguments for upgrade
    $installArgs = @(
        '/install',
        '/quiet',
        '/norestart',
        'ACCEPTEULA=yes',
        'ISUPDATE=1',
        "/log `"$LogFile`""
    )
    
    # Execute installer
    Write-Log "Executing Upgrade with arguments: $($installArgs -join ' ')" -Level INFO
    
    try {
        $process = Start-Process -FilePath $InstallerPath -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
        $exitCode = $process.ExitCode
        
        if ($exitCode -eq 0) {
            Write-Log "Upgrade completed successfully" -Level SUCCESS
            return $true
        }
        else {
            Write-Log "Upgrade exited with code: $exitCode" -Level ERROR
            return $false
        }
    }
    catch {
        Write-Log "Upgrade failed with exception: $_" -Level ERROR
        throw
    }
}

function Uninstall-TLMAgent {
    <#
    .SYNOPSIS
        Uninstalls the TLM Agent.
    #>
    param(
        [string]$InstallerPath,
        [string]$LogFile,
        [bool]$PreserveData = $false
    )
    
    $actionType = if ($PreserveData) { "Uninstall (Preserve Data)" } else { "Uninstall" }
    
    Write-Log "==========================================" -Level INFO
    Write-Log "Starting TLM Agent $actionType" -Level INFO
    Write-Log "==========================================" -Level INFO
    Write-Log "Installer path: $InstallerPath" -Level INFO
    
    # Verify installer exists
    if (-not (Test-Path $InstallerPath)) {
        Write-Log "Installer not found at: $InstallerPath" -Level ERROR
        throw "Installer file not found"
    }
    
    # Check if service exists before uninstall
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Log "Service '$ServiceName' not found. Agent may not be installed." -Level WARNING
    }
    else {
        Write-Log "Current service status: $($service.Status)" -Level INFO
    }
    
    # Build uninstallation arguments
    $uninstallArgs = @(
        '/uninstall',
        '/quiet',
        '/norestart',
        "/log `"$LogFile`""
    )
    
    if ($PreserveData) {
        $uninstallArgs += 'PRESERVEDATA=1'
    }
    
    # Execute uninstaller
    Write-Log "Executing $actionType with arguments: $($uninstallArgs -join ' ')" -Level INFO
    
    try {
        $process = Start-Process -FilePath $InstallerPath -ArgumentList $uninstallArgs -Wait -PassThru -NoNewWindow
        $exitCode = $process.ExitCode
        
        if ($exitCode -eq 0) {
            Write-Log "$actionType completed successfully" -Level SUCCESS
            return $true
        }
        else {
            Write-Log "$actionType exited with code: $exitCode" -Level ERROR
            return $false
        }
    }
    catch {
        Write-Log "$actionType failed with exception: $_" -Level ERROR
        throw
    }
}

function Get-ServiceExecutablePath {
    <#
    .SYNOPSIS
        Retrieves the executable path of the TLM Agent service.
    #>
    param(
        [string]$ServiceName
    )
    
    Write-Log "Retrieving service executable path for: $ServiceName" -Level INFO
    
    # Check if service exists
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Log "Service '$ServiceName' not found" -Level ERROR
        throw "Service not found. Agent may not be installed."
    }
    
    Write-Log "Service found: $($service.DisplayName)" -Level INFO
    
    # Get service configuration using WMI
    $serviceWmi = Get-WmiObject -Class Win32_Service -Filter "Name='$ServiceName'"
    $servicePath = $serviceWmi.PathName
    
    # Remove quotes and extract .exe path
    $servicePath = $servicePath.Trim('"')
    
    # Handle paths with arguments
    if ($servicePath -match '^(.+\.exe)') {
        $exePath = $matches[1]
    }
    else {
        $exePath = $servicePath
    }
    
    if (-not (Test-Path $exePath)) {
        Write-Log "Service executable not found at: $exePath" -Level ERROR
        throw "Service executable not found"
    }
    
    Write-Log "Service executable: $exePath" -Level INFO
    return $exePath
}

function Get-InstallationDirectory {
    <#
    .SYNOPSIS
        Gets the installation directory from the service executable path.
    #>
    param(
        [string]$ExePath
    )
    
    # Get the bin directory
    $binDir = Split-Path -Parent $ExePath
    
    # Get the installation directory (one level up from bin)
    $installDir = Split-Path -Parent $binDir
    
    Write-Log "Installation directory: $installDir" -Level INFO
    return $installDir
}

function Invoke-AgentActivation {
    <#
    .SYNOPSIS
        Activates the TLM Agent with the provided configuration.
    #>
    param(
        [string]$ApiKey,
        [string]$BusinessUnitId,
        [string]$AgentName,
        [string]$Proxy
    )
    
    Write-Log "==========================================" -Level INFO
    Write-Log "Starting TLM Agent Activation" -Level INFO
    Write-Log "==========================================" -Level INFO
    
    # Validate API key
    if (-not $ApiKey) {
        Write-Log "API Key is required for activation" -Level ERROR
        Write-Log "Set via -ApiKey parameter or DC_API_KEY environment variable" -Level ERROR
        throw "API Key not provided"
    }
    
    # Log configuration (hide API key)
    Write-Log "Configuration:" -Level INFO
    Write-Log "  API Key: ****** (hidden)" -Level INFO
    
    if ($BusinessUnitId) {
        Write-Log "  Business Unit: $BusinessUnitId" -Level INFO
    }
    else {
        Write-Log "  Business Unit: Not provided" -Level INFO
    }
    
    if ($AgentName) {
        Write-Log "  Agent Name: $AgentName" -Level INFO
    }
    else {
        Write-Log "  Agent Name: Not provided" -Level INFO
    }
    
    if ($Proxy) {
        Write-Log "  Proxy: $Proxy" -Level INFO
    }
    else {
        Write-Log "  Proxy: Not provided" -Level INFO
    }
    
    # Get service executable path
    $exePath = Get-ServiceExecutablePath -ServiceName $ServiceName
    
    # Get installation directory
    $installDir = Get-InstallationDirectory -ExePath $exePath
    
    # Check for activation script
    $activationScript = Join-Path $installDir "activate-and-start-tlm-agent.bat"
    
    if (-not (Test-Path $activationScript)) {
        Write-Log "Activation script not found at: $activationScript" -Level ERROR
        throw "Activation script not found"
    }
    
    Write-Log "Activation script found: $activationScript" -Level INFO
    
    # Build activation command arguments
    $activationArgs = @("--apikey", $ApiKey)
    
    if ($BusinessUnitId) {
        $activationArgs += @("--businessunitid", $BusinessUnitId)
    }
    
    if ($AgentName) {
        $activationArgs += @("--agentname", $AgentName)
    }
    
    if ($Proxy) {
        $activationArgs += @("--proxy", $Proxy)
    }
    
    # Change to installation directory
    Push-Location $installDir
    
    try {
        Write-Log "Executing activation script..." -Level INFO
        Write-Log "Command: $activationScript $($activationArgs -join ' ')" -Level INFO
        
        # Execute activation script
        $process = Start-Process -FilePath $activationScript -ArgumentList $activationArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\tlm_activation_output.log" -RedirectStandardError "$env:TEMP\tlm_activation_error.log"
        
        $exitCode = $process.ExitCode
        
        # Read output
        if (Test-Path "$env:TEMP\tlm_activation_output.log") {
            $output = Get-Content "$env:TEMP\tlm_activation_output.log" -Raw
            if ($output) {
                Write-Log "Activation output: $output" -Level INFO
            }
        }
        
        if (Test-Path "$env:TEMP\tlm_activation_error.log") {
            $errorOutput = Get-Content "$env:TEMP\tlm_activation_error.log" -Raw
            if ($errorOutput) {
                Write-Log "Activation errors: $errorOutput" -Level WARNING
            }
        }
        
        if ($exitCode -eq 0) {
            Write-Log "Activation completed successfully" -Level SUCCESS
            return $true
        }
        else {
            Write-Log "Activation failed with exit code: $exitCode" -Level ERROR
            return $false
        }
    }
    catch {
        Write-Log "Activation failed with exception: $_" -Level ERROR
        throw
    }
    finally {
        Pop-Location
        
        # Cleanup temp files
        Remove-Item "$env:TEMP\tlm_activation_output.log" -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\tlm_activation_error.log" -ErrorAction SilentlyContinue
    }
}

function Test-ServiceStatus {
    <#
    .SYNOPSIS
        Checks the status of the TLM Agent service.
    #>
    param(
        [string]$ServiceName
    )
    
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    
    if ($service) {
        Write-Log "Service Status: $($service.Status)" -Level INFO
        Write-Log "Service Start Type: $($service.StartType)" -Level INFO
        return $service
    }
    else {
        Write-Log "Service not found: $ServiceName" -Level WARNING
        return $null
    }
}

# === MAIN EXECUTION ===

try {
    Write-Log "==========================================" -Level INFO
    Write-Log "TLM Agent Deployment Script" -Level INFO
    Write-Log "==========================================" -Level INFO
    Write-Log "Action: $Action" -Level INFO
    Write-Log "Log file: $LogFile" -Level INFO
    
    # Check administrator privileges
    if (-not (Test-Administrator)) {
        Write-Log "This script requires administrator privileges" -Level ERROR
        throw "Insufficient permissions. Please run as administrator."
    }
    
    $installSuccess = $false
    $activationSuccess = $false
    $upgradeSuccess = $false
    $uninstallSuccess = $false
    
    # Perform installation if required
    if ($Action -eq 'Install' -or $Action -eq 'InstallAndActivate') {
        $installSuccess = Install-TLMAgent -InstallerPath $InstallerPath -InstallDir $InstallDir -DcOneHost $DcOneHost -LogFile $LogFile
        
        if (-not $installSuccess) {
            Write-Log "Installation failed. Aborting." -Level ERROR
            exit 1
        }
        
        # Wait a moment for service registration
        Start-Sleep -Seconds 5
        
        # Check service status after installation
        $service = Test-ServiceStatus -ServiceName $ServiceName
    }
    
    # Perform upgrade if required
    if ($Action -eq 'Upgrade') {
        $upgradeSuccess = Update-TLMAgent -InstallerPath $InstallerPath -LogFile $LogFile
        
        if (-not $upgradeSuccess) {
            Write-Log "Upgrade failed. Aborting." -Level ERROR
            exit 1
        }
        
        # Wait a moment for service update
        Start-Sleep -Seconds 5
        
        # Check service status after upgrade
        $service = Test-ServiceStatus -ServiceName $ServiceName
    }
    
    # Perform uninstall if required
    if ($Action -eq 'Uninstall') {
        $uninstallSuccess = Uninstall-TLMAgent -InstallerPath $InstallerPath -LogFile $LogFile -PreserveData $false
        
        if (-not $uninstallSuccess) {
            Write-Log "Uninstall failed. Aborting." -Level ERROR
            exit 1
        }
        
        Write-Log "Uninstall completed. All agent data has been removed." -Level INFO
    }
    
    # Perform uninstall with data preservation if required
    if ($Action -eq 'UninstallPreserveData') {
        $uninstallSuccess = Uninstall-TLMAgent -InstallerPath $InstallerPath -LogFile $LogFile -PreserveData $true
        
        if (-not $uninstallSuccess) {
            Write-Log "Uninstall (Preserve Data) failed. Aborting." -Level ERROR
            exit 1
        }
        
        Write-Log "Uninstall completed. Data and certificates have been preserved for rollback." -Level INFO
    }
    
    # Perform activation if required
    if ($Action -eq 'Activate' -or $Action -eq 'InstallAndActivate') {
        try {
            $activationSuccess = Invoke-AgentActivation -ApiKey $ApiKey -BusinessUnitId $BusinessUnitId -AgentName $AgentName -Proxy $Proxy
            
            if (-not $activationSuccess) {
                Write-Log "Activation failed" -Level ERROR
                
                if ($Action -eq 'InstallAndActivate') {
                    Write-Log "Installation completed but activation failed" -Level WARNING
                    exit 2
                }
                else {
                    exit 1
                }
            }
        }
        catch {
            Write-Log "Activation error: $_" -Level ERROR
            
            if ($Action -eq 'InstallAndActivate') {
                Write-Log "Installation completed but activation failed with exception" -Level WARNING
                exit 2
            }
            else {
                throw
            }
        }
        
        # Final service status check
        Start-Sleep -Seconds 2
        $service = Test-ServiceStatus -ServiceName $ServiceName
    }
    
    # Summary
    Write-Log "==========================================" -Level INFO
    Write-Log "Deployment Summary" -Level INFO
    Write-Log "==========================================" -Level INFO
    
    if ($Action -eq 'Install' -or $Action -eq 'InstallAndActivate') {
        if ($installSuccess) {
            Write-Log "Installation: SUCCESS" -Level SUCCESS
        }
        else {
            Write-Log "Installation: FAILED" -Level ERROR
        }
    }
    
    if ($Action -eq 'Upgrade') {
        if ($upgradeSuccess) {
            Write-Log "Upgrade: SUCCESS" -Level SUCCESS
        }
        else {
            Write-Log "Upgrade: FAILED" -Level ERROR
        }
    }
    
    if ($Action -eq 'Uninstall' -or $Action -eq 'UninstallPreserveData') {
        if ($uninstallSuccess) {
            Write-Log "Uninstall: SUCCESS" -Level SUCCESS
        }
        else {
            Write-Log "Uninstall: FAILED" -Level ERROR
        }
    }
    
    if ($Action -eq 'Activate' -or $Action -eq 'InstallAndActivate') {
        if ($activationSuccess) {
            Write-Log "Activation: SUCCESS" -Level SUCCESS
        }
        else {
            Write-Log "Activation: FAILED" -Level ERROR
        }
    }
    
    Write-Log "Deployment completed" -Level SUCCESS
    exit 0
    
}
catch {
    Write-Log "Critical error: $_" -Level ERROR
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
