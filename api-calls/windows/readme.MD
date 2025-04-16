The following script issues a certificate using Powershell. 
It should work with Powershell on Windows,Mac as well as Linux. 

Make sure to change the defaults of the variables from line 16 to line 24. When the script is run, you can either confirm the defaults with Enter or paste different values. 

```powershell
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
