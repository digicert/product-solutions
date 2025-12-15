 # Azure Configuration
$tenantId = "7637ffcf-4082-46e2-8e89-c9814eb8b3c4"
$clientId = "4b9d544a-c7ef-499b-9ba9-c8087ab82e92"
$certThumbprint = "CC7CE8BB04AD220D393A6593249DF71A679A6227"
$appProxyObjectId = "e5d4a899-317b-4de7-82db-e1d2cc4891b0"
  
Import-Module AzureAD
  
# Connect to Azure AD
Write-Host "Connecting to Azure AD..." -ForegroundColor Cyan
Connect-AzureAD -TenantId $tenantId -ApplicationId $clientId -CertificateThumbprint $certThumbprint | Out-Null
  
# Get App Proxy configuration
Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "App Proxy Configuration" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
  
$appProxy = Get-AzureADApplicationProxyApplication -ObjectId $appProxyObjectId
Write-Host "External URL: $($appProxy.ExternalUrl)"
Write-Host "Internal URL: $($appProxy.InternalUrl)"
Write-Host "Authentication: $($appProxy.ExternalAuthenticationType)"
  
# Get certificate details
Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "SSL Certificate Details" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
  
$certMetadata = $appProxy.VerifiedCustomDomainCertificatesMetadata
if ($certMetadata) {
    Write-Host "Subject: $($certMetadata.SubjectName)" -ForegroundColor Green
    Write-Host "Thumbprint: $($certMetadata.Thumbprint)" -ForegroundColor Green
    Write-Host "Issue Date: $($certMetadata.IssueDate)" -ForegroundColor Green
    Write-Host "Expiry Date: $($certMetadata.ExpiryDate)" -ForegroundColor Green
    
    # Check expiry
    $expiryDate = [DateTime]::Parse($certMetadata.ExpiryDate)
    $daysUntilExpiry = ($expiryDate - (Get-Date)).Days
    
    Write-Host ""
    if ($daysUntilExpiry -lt 0) {
        Write-Host "STATUS: Certificate EXPIRED!" -ForegroundColor Red
    } elseif ($daysUntilExpiry -lt 30) {
        Write-Host "STATUS: Expires in $daysUntilExpiry days" -ForegroundColor Yellow
    } else {
        Write-Host "STATUS: Valid for $daysUntilExpiry days" -ForegroundColor Green
    }
} else {
    Write-Host "No certificate configured" -ForegroundColor Red
}
  
Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan 

