<#
.SYNOPSIS
    DigiCert TLM Agent - Azure App Proxy Certificate Retrieval Script
.DESCRIPTION
    Retrieves and displays current certificate and App Proxy configuration from Azure AD
.NOTES
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
#>

# Configuration
$LEGAL_NOTICE_ACCEPT = "false" # Set to "true" to accept the legal notice and proceed with execution

# Check legal notice acceptance
if ($LEGAL_NOTICE_ACCEPT -ne "true") {
    Write-Host "ERROR: Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT=`"true`" to proceed." -ForegroundColor Red
    exit 1
}

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