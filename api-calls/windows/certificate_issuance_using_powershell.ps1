# Function to prompt for input with a default value
function Prompt-ForInput {
    param (
        [string]$promptText,
        [string]$defaultValue
    )
    
    $input = Read-Host "$promptText [$defaultValue]"
    if ([string]::IsNullOrEmpty($input)) {
        return $defaultValue
    }
    return $input
}

# Prompt the user for each variable with defaults
$url = Prompt-ForInput "Enter API URL" "https://demo.one.digicert.com/mpki/api/v1/certificate"
$apiKey = Prompt-ForInput "Enter API key" "017a8251489a8aba3e5f41508b_2c7538e640095df54ccff4722fde746590bcf917450ead1ef962968fd485a6ac"
$profileId = Prompt-ForInput "Enter profile ID" "3fd3a871-ff22-4cb9-be4b-3f04c7818460"
$commonName = Prompt-ForInput "Enter common name (CN)" "domain.com"
$seatId = Prompt-ForInput "Enter seat ID" "domain.com"
$country = Prompt-ForInput "Enter country code (C)" "US"
$state = Prompt-ForInput "Enter state or province (ST)" "Utah"
$locality = Prompt-ForInput "Enter locality or city (L)" "Lehi"
$organization = Prompt-ForInput "Enter organization name (O)" "Digicert"




# Validate if URL is not null or empty
if (-not $url) {
    Write-Host "The API URL cannot be null or empty. Exiting script."
    exit
}

# Get current date in the desired format (e.g., 18Oct2024)
$currentDate = Get-Date -Format "ddMMMyyyy"

# Define folder name with commonName and current date
$folderName = "$commonName-$currentDate"

# Create the folder if it doesn't exist
if (-Not (Test-Path $folderName)) {
    New-Item -Path $folderName -ItemType Directory
}

# Adjust paths to be within the new folder
$csrPath = Join-Path $folderName "csr.csr"
$keyPath = Join-Path $folderName "key.key"
$certPath = Join-Path $folderName "cert.pem"

# Check if CSR already exists
if (-Not (Test-Path $csrPath)) {
    # Generate CSR
    $subj = "/C=$country/ST=$state/L=$locality/O=$organization/CN=$commonName"
    $opensslCmd = "openssl req -new -newkey rsa:2048 -nodes -keyout $keyPath -out $csrPath -subj `"$subj`""
    Invoke-Expression $opensslCmd
}

# Check CSR content
if (Test-Path $csrPath) {
    Get-Content $csrPath
}

# Send CSR request
if (Test-Path $csrPath) {
    # Read the CSR content and remove unwanted characters
    $csrContent = Get-Content $csrPath -Raw | Out-String | ForEach-Object { $_.Trim() -replace "`r`n", "`n" }

    # Create the JSON payload using PowerShell objects and ConvertTo-Json
    $payload = @{
        profile = @{
            id = $profileId
        }
        seat = @{
            seat_id = $seatId
        }
        csr = $csrContent
        attributes = @{
            subject = @{
                common_name = $commonName
            }
        }
    }

    # Convert the payload to JSON
    $jsonPayload = $payload | ConvertTo-Json -Compress

    # Set the headers for the API request
    $headers = @{
        "x-api-key" = $apiKey
        "Content-Type" = "application/json"
    }

    # Send the CSR to the API and store the JSON response
    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $jsonPayload
    }
    catch {
        Write-Host "Error during API call: $_"
        exit
    }

    # Check if the response contains a certificate
    if ($response.certificate) {
        # Clean the certificate content (remove extra newlines and unwanted characters)
        $certContent = $response.certificate -replace "`n", "`r`n" -replace "`r`n{2,}", "`r`n"

        # Write the cleaned certificate content to the output file
        Set-Content -Path $certPath -Value $certContent

        Write-Host "Certificate successfully saved to $certPath"
    } else {
        Write-Host "No certificate found in the response."
    }
}
