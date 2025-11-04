# Simple test script for TLM Agent
$logFile = "$env:TEMP\tlm_test_$(Get-Date -Format 'yyyyMMddHHmmss').log"

function Write-Log {
    param($Message)
    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $Message"
    Add-Content -Path $logFile -Value $entry -Force
}

Write-Log "=== TLM Agent Test Script ==="
Write-Log "PowerShell Version: $($PSVersionTable.PSVersion)"
Write-Log "User: $env:USERNAME"
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "Temp: $env:TEMP"
Write-Log "Script Path: $PSCommandPath"

# Check for DC1_POST_SCRIPT_DATA
$data = $env:DC1_POST_SCRIPT_DATA
if ($data) {
    Write-Log "DC1_POST_SCRIPT_DATA exists: Length = $($data.Length)"
    
    try {
        $decoded = [System.Convert]::FromBase64String($data)
        $json = [System.Text.Encoding]::UTF8.GetString($decoded)
        $obj = $json | ConvertFrom-Json
        Write-Log "JSON decoded successfully"
        Write-Log "Args count: $($obj.args.Count)"
        Write-Log "Cert folder: $($obj.certfolder)"
    } catch {
        Write-Log "Error: $_"
    }
} else {
    Write-Log "DC1_POST_SCRIPT_DATA not found"
}

Write-Log "Test completed successfully"
Write-Log "Log file: $logFile"

# Always exit 0 for testing
exit 0