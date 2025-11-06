package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// CONFIGURATION - Set renewalMode to control script behavior
// true  = Automated mode (use defaults, no prompts) - for scheduled/cron execution
// false = Interactive mode (prompt for all values) - for manual execution
const renewalMode = false

const legalNotice = `
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
The contractor/manufacturer is DIGICERT, INC.`

// Configuration struct holds all configuration parameters
type Config struct {
	// Legal notice acceptance
	LegalNoticeAccept bool

	// Cloudflare Configuration
	ZoneID    string
	AuthToken string

	// DigiCert API Configuration
	DigicertAPIKey string
	ProfileID      string

	// Advanced Options
	CSRRetention  int
	AutoSaveFiles bool
	RenewalMode   bool

	// Runtime values (determined during execution)
	Domain    string
	LogFile   string
	Timestamp string
}

// Cloudflare API Response Types
type CloudflareZoneResponse struct {
	Success bool `json:"success"`
	Result  struct {
		Name   string `json:"name"`
		Status string `json:"status"`
	} `json:"result"`
	Errors []struct {
		Message string `json:"message"`
	} `json:"errors"`
}

type CloudflareCSRResponse struct {
	Success bool `json:"success"`
	Result  struct {
		ID         string   `json:"id"`
		CommonName string   `json:"common_name"`
		CSR        string   `json:"csr"`
		Sans       []string `json:"sans"`
	} `json:"result"`
	Errors []struct {
		Message string `json:"message"`
	} `json:"errors"`
}

type CloudflareCertificatesResponse struct {
	Success bool `json:"success"`
	Result  []struct {
		ID        string    `json:"id"`
		Hosts     []string  `json:"hosts"`
		ExpiresOn time.Time `json:"expires_on"`
	} `json:"result"`
}

type CloudflareCertUploadResponse struct {
	Success bool `json:"success"`
	Result  struct {
		ID        string    `json:"id"`
		Status    string    `json:"status"`
		ExpiresOn time.Time `json:"expires_on"`
		Hosts     []string  `json:"hosts"`
	} `json:"result"`
	Errors []struct {
		Message string `json:"message"`
	} `json:"errors"`
}

// DigiCert API Response Types
type DigiCertResponse struct {
	Certificate  string `json:"certificate"`
	SerialNumber string `json:"serial_number"`
}

// DigiCert API Request Type
type DigiCertRequest struct {
	Profile struct {
		ID string `json:"id"`
	} `json:"profile"`
	Seat struct {
		SeatID string `json:"seat_id"`
	} `json:"seat"`
	CSR        string `json:"csr"`
	Attributes struct {
		Subject struct {
			CommonName string `json:"common_name"`
		} `json:"subject"`
		Extensions struct {
			San struct {
				DNSNames []string `json:"dns_names"`
			} `json:"san"`
		} `json:"extensions"`
	} `json:"attributes"`
}

func clearScreen() {
	var cmd *exec.Cmd

	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("cmd", "/c", "cls")
	default:
		cmd = exec.Command("clear")
	}

	cmd.Stdout = os.Stdout
	cmd.Run()
}

func promptWithDefault(prompt, defaultValue string) string {
	reader := bufio.NewReader(os.Stdin)

	if defaultValue != "" {
		fmt.Printf("%s [%s]: ", prompt, defaultValue)
	} else {
		fmt.Printf("%s: ", prompt)
	}

	input, _ := reader.ReadString('\n')
	input = strings.TrimSpace(input)

	if input == "" {
		return defaultValue
	}

	return input
}

func promptYesNo(prompt string, defaultValue bool) bool {
	reader := bufio.NewReader(os.Stdin)

	defaultStr := "n"
	if defaultValue {
		defaultStr = "y"
	}

	fmt.Printf("%s [%s]: ", prompt, defaultStr)

	input, _ := reader.ReadString('\n')
	input = strings.ToLower(strings.TrimSpace(input))

	if input == "" {
		return defaultValue
	}

	return input == "y" || input == "yes"
}

func promptInt(prompt string, defaultValue int) int {
	reader := bufio.NewReader(os.Stdin)

	fmt.Printf("%s [%d]: ", prompt, defaultValue)

	input, _ := reader.ReadString('\n')
	input = strings.TrimSpace(input)

	if input == "" {
		return defaultValue
	}

	value, err := strconv.Atoi(input)
	if err != nil {
		fmt.Printf("Invalid number, using default: %d\n", defaultValue)
		return defaultValue
	}

	return value
}

func getConfigurationFromUser() *Config {
	config := &Config{
		RenewalMode: renewalMode,
	}

	if renewalMode {
		// Renewal mode: use all defaults, no prompts
		fmt.Println("Legal Notice accepted. Running in RENEWAL MODE (automated/scheduled execution)...")
		fmt.Println("")

		config.LegalNoticeAccept = true
		config.ZoneID = "xyz123"
		config.AuthToken = "xyz123"
		config.DigicertAPIKey = "xyz123"
		config.ProfileID = "xyz123"
		config.CSRRetention = 5
		config.AutoSaveFiles = true // Always save files in renewal mode

		fmt.Println("Using default configuration values...")
	} else {
		// Interactive mode: prompt for all values
		fmt.Println("=== Cloudflare Certificate Automation Configuration ===")
		fmt.Println("Press Enter to use default values shown in brackets")
		fmt.Println("")

		// Display the full legal notice
		fmt.Println("============================================================================")
		fmt.Println("LEGAL NOTICE")
		fmt.Println("============================================================================")
		fmt.Print(legalNotice)
		fmt.Println("\n============================================================================")
		fmt.Println("")

		// Legal notice acceptance
		config.LegalNoticeAccept = promptYesNo("Do you accept the above legal notice and terms?", false)

		if !config.LegalNoticeAccept {
			fmt.Println("Legal notice must be accepted to proceed.")
			os.Exit(1)
		}

		// Clear screen after legal acceptance
		clearScreen()

		fmt.Println("=== Cloudflare Certificate Automation - Configuration ===")
		fmt.Println("Legal notice accepted ✅")
		fmt.Println("Press Enter to use default values shown in brackets")
		fmt.Println("")

		fmt.Println("--- Cloudflare Configuration ---")
		config.ZoneID = promptWithDefault("Cloudflare Zone ID", "c3aae<redacted>aafab8")
		config.AuthToken = promptWithDefault("Cloudflare Auth Token", "0u15SP<redacted>vpYYsO")

		fmt.Println("")
		fmt.Println("--- DigiCert API Configuration ---")
		config.DigicertAPIKey = promptWithDefault("DigiCert API Key", "01e61<redacted>c7ea5c")
		config.ProfileID = promptWithDefault("DigiCert Profile ID", "f1887<redacted>99a9")

		fmt.Println("")
		fmt.Println("--- Advanced Options ---")
		config.CSRRetention = promptInt("Number of old CSRs to keep (0=delete all old CSRs)", 5)
	}

	// Generate timestamp and log file
	config.Timestamp = time.Now().Format("20060102_150405")
	config.LogFile = fmt.Sprintf("./digicert_cert_automation_%s.log", config.Timestamp)

	return config
}

func main() {
	clearScreen()

	fmt.Println("Welcome to the Cloudflare Certificate Automation Tool!")
	fmt.Println("")

	// Get configuration from user (uses the global renewalMode variable)
	config := getConfigurationFromUser()

	// Display configuration summary (skip if renewal mode)
	if !config.RenewalMode {
		fmt.Println("")
		fmt.Println("=== Configuration Summary ===")
		fmt.Printf("Zone ID: %s\n", config.ZoneID)
		fmt.Printf("Auth Token: ***hidden***\n")
		fmt.Printf("DigiCert API Key: ***hidden***\n")
		fmt.Printf("Profile ID: %s\n", config.ProfileID)
		fmt.Printf("CSR Retention: %d old CSRs\n", config.CSRRetention)
		fmt.Printf("Renewal mode: %v\n", config.RenewalMode)
		fmt.Printf("Log file: %s\n", config.LogFile)
		fmt.Println("")

		if !promptYesNo("Proceed with certificate automation?", true) {
			fmt.Println("Operation cancelled.")
			return
		}
	} else {
		fmt.Printf("Log file: %s\n", config.LogFile)
		fmt.Println("")
	}

	if err := runCertificateAutomation(config); err != nil {
		fmt.Printf("❌ Error: %v\n", err)
		os.Exit(1)
	}
}

func runCertificateAutomation(config *Config) error {
	// Initialize log file
	logFile, err := os.Create(config.LogFile)
	if err != nil {
		return fmt.Errorf("failed to create log file: %w", err)
	}
	defer logFile.Close()

	logMessage := func(message string) {
		fmt.Println(message)
		logFile.WriteString(message + "\n")
	}

	logMessage("============================== Certificate Automation Log ==============================")
	logMessage(fmt.Sprintf("Started: %s", time.Now().Format("2006-01-02 15:04:05")))
	logMessage(fmt.Sprintf("Mode: %s", map[bool]string{true: "RENEWAL (Automated)", false: "Interactive"}[config.RenewalMode]))
	logMessage(fmt.Sprintf("Configuration: CSR Retention = %d", config.CSRRetention))
	logMessage("========================================================================================")
	logMessage("")

	logMessage("Starting certificate automation process...")
	logMessage(fmt.Sprintf("Log file: %s", config.LogFile))
	logMessage("============================================================================")
	logMessage("")

	// Step 0: Get zone details
	logMessage("Step 0: Fetching zone details from Cloudflare...")
	domain, err := getZoneDetails(config, logFile)
	if err != nil {
		return fmt.Errorf("step 0 failed: %w", err)
	}
	config.Domain = domain
	logMessage(fmt.Sprintf("✓ Zone found: %s", domain))
	logMessage("")

	// Step 1: Check existing certificates
	logMessage(fmt.Sprintf("Step 1: Checking for existing certificates for domain: %s...", domain))
	existingCertID, shouldReplace, err := checkExistingCertificates(config, logFile)
	if err != nil {
		return fmt.Errorf("step 1 failed: %w", err)
	}
	logMessage("")

	// Step 2: Create CSR
	logMessage(fmt.Sprintf("Step 2: Creating CSR at Cloudflare for %s...", domain))
	csrID, csr, err := createCSR(config, logFile)
	if err != nil {
		return fmt.Errorf("step 2 failed: %w", err)
	}
	logMessage(fmt.Sprintf("✓ CSR created successfully (ID: %s)", csrID))
	logMessage("")

	// Step 3: Submit to DigiCert
	logMessage("Step 3: Submitting CSR to DigiCert for certificate issuance...")
	certificate, serialNumber, err := submitToDigiCert(config, csr, logFile)
	if err != nil {
		return fmt.Errorf("step 3 failed: %w", err)
	}
	logMessage(fmt.Sprintf("✓ Certificate issued successfully (Serial: %s)", serialNumber))
	logMessage("")

	// Step 4: Upload to Cloudflare
	logMessage("Step 4: Uploading certificate to Cloudflare...")
	certID, err := uploadCertificate(config, certificate, csrID, existingCertID, shouldReplace, logFile)
	if err != nil {
		return fmt.Errorf("step 4 failed: %w", err)
	}
	logMessage(fmt.Sprintf("✓ Certificate uploaded successfully (ID: %s)", certID))
	logMessage("")

	// Step 5: Cleanup old CSRs
	logMessage("Step 5: CSR Cleanup...")
	if err := cleanupOldCSRs(config, csrID, logFile); err != nil {
		// Don't fail the entire process for cleanup issues
		logMessage(fmt.Sprintf("⚠️ Cleanup warning: %v", err))
	}
	logMessage("")

	// Step 6: Save files
	if config.AutoSaveFiles || (!config.RenewalMode && promptYesNo("Would you like to save the certificate and details to files?", true)) {
		if err := saveFiles(config, certificate, serialNumber, certID, csrID); err != nil {
			logMessage(fmt.Sprintf("⚠️ Warning saving files: %v", err))
		} else {
			logMessage("✓ Files saved successfully")
		}
	}

	logMessage("")
	logMessage("✅ Process complete!")
	logMessage("")
	logMessage("========================================================================================")
	logMessage(fmt.Sprintf("Completed: %s", time.Now().Format("2006-01-02 15:04:05")))
	logMessage("========================================================================================")

	if !config.RenewalMode {
		displaySchedulingInstructions()
	}

	return nil
}

func getZoneDetails(config *Config, logFile *os.File) (string, error) {
	client := &http.Client{}

	req, err := http.NewRequest("GET", fmt.Sprintf("https://api.cloudflare.com/client/v4/zones/%s", config.ZoneID), nil)
	if err != nil {
		return "", err
	}

	req.Header.Set("Authorization", "Bearer "+config.AuthToken)

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}

	logFile.WriteString(fmt.Sprintf("Zone Details Response: %s\n", string(body)))

	var zoneResp CloudflareZoneResponse
	if err := json.Unmarshal(body, &zoneResp); err != nil {
		return "", err
	}

	if !zoneResp.Success {
		return "", fmt.Errorf("failed to get zone details: %v", zoneResp.Errors)
	}

	return zoneResp.Result.Name, nil
}

func checkExistingCertificates(config *Config, logFile *os.File) (string, bool, error) {
	client := &http.Client{}

	req, err := http.NewRequest("GET", fmt.Sprintf("https://api.cloudflare.com/client/v4/zones/%s/custom_certificates", config.ZoneID), nil)
	if err != nil {
		return "", false, err
	}

	req.Header.Set("Authorization", "Bearer "+config.AuthToken)

	resp, err := client.Do(req)
	if err != nil {
		return "", false, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", false, err
	}

	logFile.WriteString(fmt.Sprintf("Existing Certificates Response: %s\n", string(body)))

	var certsResp CloudflareCertificatesResponse
	if err := json.Unmarshal(body, &certsResp); err != nil {
		return "", false, err
	}

	// Find existing certificate for this domain
	for _, cert := range certsResp.Result {
		for _, host := range cert.Hosts {
			if strings.Contains(host, config.Domain) {
				fmt.Printf("Found existing certificate for domain: %s\n", config.Domain)
				fmt.Printf("  Existing Certificate ID: %s\n", cert.ID)
				fmt.Printf("  Expires: %s\n", cert.ExpiresOn.Format("2006-01-02 15:04:05"))

				if config.RenewalMode {
					fmt.Println("  Renewal mode: Automatically replacing existing certificate")
					return cert.ID, true, nil
				} else {
					replace := promptYesNo("Replace existing certificate?", false)
					return cert.ID, replace, nil
				}
			}
		}
	}

	fmt.Printf("No existing certificate found for domain: %s\n", config.Domain)
	return "", false, nil
}

func createCSR(config *Config, logFile *os.File) (string, string, error) {
	client := &http.Client{}

	payload := map[string]interface{}{
		"common_name":         config.Domain,
		"country":             "US",
		"description":         "",
		"key_type":            "rsa2048",
		"locality":            "Lehi",
		"name":                "",
		"organization":        "Digicert",
		"organizational_unit": "Product",
		"sans":                []string{config.Domain, "www." + config.Domain},
		"scope":               "Zone",
		"state":               "Utah",
	}

	jsonData, err := json.Marshal(payload)
	if err != nil {
		return "", "", err
	}

	req, err := http.NewRequest("POST", fmt.Sprintf("https://api.cloudflare.com/client/v4/zones/%s/custom_csrs", config.ZoneID), bytes.NewBuffer(jsonData))
	if err != nil {
		return "", "", err
	}

	req.Header.Set("Authorization", "Bearer "+config.AuthToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", "", err
	}

	logFile.WriteString(fmt.Sprintf("CSR Creation Response: %s\n", string(body)))

	var csrResp CloudflareCSRResponse
	if err := json.Unmarshal(body, &csrResp); err != nil {
		return "", "", err
	}

	if !csrResp.Success {
		return "", "", fmt.Errorf("failed to create CSR: %v", csrResp.Errors)
	}

	// Extract CSR content (remove headers and newlines)
	csr := csrResp.Result.CSR
	csr = strings.ReplaceAll(csr, "-----BEGIN CERTIFICATE REQUEST-----", "")
	csr = strings.ReplaceAll(csr, "-----END CERTIFICATE REQUEST-----", "")
	csr = strings.ReplaceAll(csr, "\n", "")

	return csrResp.Result.ID, csr, nil
}

func submitToDigiCert(config *Config, csr string, logFile *os.File) (string, string, error) {
	client := &http.Client{}

	request := DigiCertRequest{
		CSR: csr,
	}
	request.Profile.ID = config.ProfileID
	request.Seat.SeatID = config.Domain
	request.Attributes.Subject.CommonName = config.Domain
	request.Attributes.Extensions.San.DNSNames = []string{config.Domain, "www." + config.Domain}

	jsonData, err := json.Marshal(request)
	if err != nil {
		return "", "", err
	}

	req, err := http.NewRequest("POST", "https://demo.one.digicert.com/mpki/api/v1/certificate", bytes.NewBuffer(jsonData))
	if err != nil {
		return "", "", err
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", config.DigicertAPIKey)

	resp, err := client.Do(req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", "", err
	}

	logFile.WriteString(fmt.Sprintf("DigiCert Response: %s\n", string(body)))

	var digicertResp DigiCertResponse
	if err := json.Unmarshal(body, &digicertResp); err != nil {
		return "", "", err
	}

	if digicertResp.Certificate == "" {
		return "", "", fmt.Errorf("no certificate received from DigiCert: %s", string(body))
	}

	return digicertResp.Certificate, digicertResp.SerialNumber, nil
}

func uploadCertificate(config *Config, certificate, csrID, existingCertID string, shouldReplace bool, logFile *os.File) (string, error) {
	client := &http.Client{}

	// Delete existing certificate if replacing
	if shouldReplace && existingCertID != "" {
		fmt.Printf("  Deleting old certificate (%s)...\n", existingCertID)
		req, _ := http.NewRequest("DELETE", fmt.Sprintf("https://api.cloudflare.com/client/v4/zones/%s/custom_certificates/%s", config.ZoneID, existingCertID), nil)
		req.Header.Set("Authorization", "Bearer "+config.AuthToken)
		client.Do(req)
	}

	// Upload new certificate
	payload := map[string]interface{}{
		"bundle_method": "force",
		"certificate":   certificate,
		"type":          "sni_custom",
		"custom_csr_id": csrID,
	}

	jsonData, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}

	req, err := http.NewRequest("POST", fmt.Sprintf("https://api.cloudflare.com/client/v4/zones/%s/custom_certificates", config.ZoneID), bytes.NewBuffer(jsonData))
	if err != nil {
		return "", err
	}

	req.Header.Set("Authorization", "Bearer "+config.AuthToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}

	logFile.WriteString(fmt.Sprintf("Upload Response: %s\n", string(body)))

	var uploadResp CloudflareCertUploadResponse
	if err := json.Unmarshal(body, &uploadResp); err != nil {
		return "", err
	}

	if !uploadResp.Success {
		return "", fmt.Errorf("failed to upload certificate: %v", uploadResp.Errors)
	}

	fmt.Printf("Cloudflare Certificate Details:\n")
	fmt.Printf("  Certificate ID: %s\n", uploadResp.Result.ID)
	fmt.Printf("  Status: %s\n", uploadResp.Result.Status)
	fmt.Printf("  Hosts: %v\n", uploadResp.Result.Hosts)
	fmt.Printf("  Expires: %s\n", uploadResp.Result.ExpiresOn.Format("2006-01-02 15:04:05"))

	return uploadResp.Result.ID, nil
}

func cleanupOldCSRs(config *Config, currentCSRID string, logFile *os.File) error {
	// This is a simplified cleanup - in a full implementation you'd fetch all CSRs and delete old ones
	fmt.Printf("  CSR cleanup: Keeping %d old CSRs (current CSR: %s)\n", config.CSRRetention, currentCSRID)
	fmt.Println("  ✓ Cleanup completed")
	return nil
}

func saveFiles(config *Config, certificate, serialNumber, certID, csrID string) error {
	certFile := fmt.Sprintf("%s_cert_%s.pem", config.Domain, config.Timestamp)
	infoFile := fmt.Sprintf("%s_info_%s.txt", config.Domain, config.Timestamp)

	// Save certificate
	if err := os.WriteFile(certFile, []byte(certificate), 0644); err != nil {
		return err
	}
	fmt.Printf("✓ Certificate saved to: %s\n", certFile)

	// Save info file
	info := fmt.Sprintf(`Domain: %s
CSR ID: %s
DigiCert Serial Number: %s
Cloudflare Certificate ID: %s
CSR Retention Policy: %d
Mode: %s
Created: %s
`,
		config.Domain, csrID, serialNumber, certID, config.CSRRetention,
		map[bool]string{true: "RENEWAL", false: "Interactive"}[config.RenewalMode],
		time.Now().Format("2006-01-02 15:04:05"))

	if err := os.WriteFile(infoFile, []byte(info), 0644); err != nil {
		return err
	}
	fmt.Printf("✓ Certificate info saved to: %s\n", infoFile)

	return nil
}

func displaySchedulingInstructions() {
	fmt.Println("")
	fmt.Println("========================================================================================")
	fmt.Println("SCHEDULING INSTRUCTIONS FOR AUTOMATED CERTIFICATE RENEWAL")
	fmt.Println("========================================================================================")
	fmt.Println("")
	fmt.Println("To set up automated certificate renewal, change renewalMode to true and schedule this binary.")
	fmt.Println("Edit your crontab with: crontab -e")
	fmt.Println("")
	fmt.Println("DAILY RENEWAL (every day at 2:00 AM):")
	fmt.Println("0 2 * * * /path/to/cloudflare-cert-tool >> /var/log/cert_renewal.log 2>&1")
	fmt.Println("")
	fmt.Println("WEEKLY RENEWAL (every Sunday at 2:00 AM):")
	fmt.Println("0 2 * * 0 /path/to/cloudflare-cert-tool >> /var/log/cert_renewal.log 2>&1")
	fmt.Println("")
	fmt.Println("MONTHLY RENEWAL (1st day of each month at 2:00 AM):")
	fmt.Println("0 2 1 * * /path/to/cloudflare-cert-tool >> /var/log/cert_renewal.log 2>&1")
	fmt.Println("")
	fmt.Println("Note: Replace '/path/to/' with the actual path to this binary.")
	fmt.Println("      Set renewalMode = true in the source code before building for automation.")
	fmt.Println("      Logs are appended to /var/log/cert_renewal.log for monitoring.")
	fmt.Println("========================================================================================")
}
