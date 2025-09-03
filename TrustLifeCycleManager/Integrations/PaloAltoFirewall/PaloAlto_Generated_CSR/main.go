package main

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"
)

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
	// Legal notice acceptance - MUST BE SET TO true TO RUN THE SCRIPT
	LegalNoticeAccept bool

	// PAN-OS Configuration
	FirewallIP   string
	APIKey       string
	CertName     string
	CommonName   string
	Organization string
	Locality     string
	State        string
	Country      string

	// DigiCert API Configuration
	DigicertAPIKey  string
	DigicertProfile string
	DigicertSeatID  string

	// Advanced Options
	AutoCommit bool

	// File Path Configuration
	OutputDir            string
	CSRCleanFile         string
	CSRSingleLineFile    string
	DigicertResponseFile string
	SignedCertFile       string
	RawResponseFile      string
}

// DigiCertResponse represents the response from DigiCert API
type DigiCertResponse struct {
	Certificate  string `json:"certificate"`
	SerialNumber string `json:"serial_number"`
}

// DigiCertRequest represents the request to DigiCert API
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
	} `json:"attributes"`
}

func clearScreen() {
	var cmd *exec.Cmd

	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("cmd", "/c", "cls")
	default: // Linux, macOS, Unix
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

func getConfigurationFromUser() *Config {
	fmt.Println("=== PAN-OS Certificate Automation Configuration ===")
	fmt.Println("Press Enter to use default values shown in brackets")
	fmt.Println("")

	config := &Config{}

	// Display the full legal notice
	fmt.Println("============================================================================")
	fmt.Println("LEGAL NOTICE")
	fmt.Println("============================================================================")
	fmt.Println(legalNotice)
	fmt.Println("============================================================================")
	fmt.Println("")

	// Legal notice acceptance
	config.LegalNoticeAccept = promptYesNo("Do you accept the above legal notice and terms?", false)

	if !config.LegalNoticeAccept {
		fmt.Println("Legal notice must be accepted to proceed.")
		os.Exit(1)
	}

	// Clear screen after legal acceptance for clean configuration interface
	clearScreen()

	fmt.Println("=== PAN-OS Certificate Automation - Configuration ===")
	fmt.Println("Legal notice accepted ✅")
	fmt.Println("Press Enter to use default values shown in brackets")
	fmt.Println("")

	fmt.Println("--- PAN-OS Firewall Configuration ---")
	config.FirewallIP = promptWithDefault("Firewall IP/Hostname", "ec2-3-145-216-176.us-east-2.compute.amazonaws.com")
	config.APIKey = promptWithDefault("API Key", "REMOVED_SECRET")

	fmt.Println("")
	fmt.Println("--- Advanced Options ---")
	config.AutoCommit = promptYesNo("Automatically commit configuration changes to PAN-OS?", false)

	fmt.Println("")
	fmt.Println("--- Certificate Configuration ---")
	config.CertName = promptWithDefault("Certificate Name", "tlsguru.io")
	config.CommonName = promptWithDefault("Common Name (CN)", "tlsguru.io")
	config.Organization = promptWithDefault("Organization (O)", "Digicert")
	config.Locality = promptWithDefault("Locality/City (L)", "Lehi")
	config.State = promptWithDefault("State/Province (ST)", "Utah")
	config.Country = promptWithDefault("Country Code (C)", "US")

	fmt.Println("")
	fmt.Println("--- DigiCert API Configuration ---")
	config.DigicertAPIKey = promptWithDefault("DigiCert API Key", "REMOVED_SECRET")
	config.DigicertProfile = promptWithDefault("DigiCert Profile ID", "f1887d29-ee87-48f7-a873-1a0254dc99a9")
	config.DigicertSeatID = promptWithDefault("DigiCert Seat ID", "tlsguru.io")

	fmt.Println("")
	fmt.Println("--- File Configuration ---")
	config.OutputDir = promptWithDefault("Output Directory", "./certs")

	// Initialize file paths based on certificate name and output directory
	config.CSRCleanFile = filepath.Join(config.OutputDir, config.CertName+"_clean.csr")
	config.CSRSingleLineFile = filepath.Join(config.OutputDir, config.CertName+"_single_line.txt")
	config.DigicertResponseFile = filepath.Join(config.OutputDir, config.CertName+"_digicert_response.json")
	config.SignedCertFile = filepath.Join(config.OutputDir, config.CertName+"_signed_certificate.crt")
	config.RawResponseFile = filepath.Join(config.OutputDir, config.CertName+"_raw_response.xml")

	return config
}

func main() {
	// Clear the screen for a clean start
	clearScreen()

	fmt.Println("Welcome to the PAN-OS Certificate Automation Tool!")
	fmt.Println("")

	// Get configuration from user
	config := getConfigurationFromUser()

	// Display configuration summary
	fmt.Println("")
	fmt.Println("=== Configuration Summary ===")
	fmt.Printf("Firewall: %s\n", config.FirewallIP)
	fmt.Printf("Certificate: %s (%s)\n", config.CertName, config.CommonName)
	fmt.Printf("Organization: %s, %s, %s, %s\n", config.Organization, config.Locality, config.State, config.Country)
	fmt.Printf("Output Directory: %s\n", config.OutputDir)
	if config.AutoCommit {
		fmt.Printf("Auto-commit: Yes ✅\n")
	} else {
		fmt.Printf("Auto-commit: No ⚠️  (manual commit required)\n")
	}
	fmt.Println("")

	if !promptYesNo("Proceed with certificate automation?", true) {
		fmt.Println("Operation cancelled.")
		return
	}

	if err := runCertificateAutomation(config); err != nil {
		fmt.Printf("❌ Error: %v\n", err)
		os.Exit(1)
	}
}

func runCertificateAutomation(config *Config) error {
	// Check legal notice acceptance
	if !config.LegalNoticeAccept {
		fmt.Println("============================================================================")
		fmt.Println("LEGAL NOTICE NOT ACCEPTED")
		fmt.Println("============================================================================")
		fmt.Println("")
		fmt.Println("To use this script, you must accept the DigiCert Legal Notice.")
		fmt.Println("")
		fmt.Println("Please review the legal notice and set LegalNoticeAccept to true")
		fmt.Println("in the configuration.")
		fmt.Println("")
		fmt.Println("Script execution terminated.")
		fmt.Println("============================================================================")
		return fmt.Errorf("legal notice not accepted")
	}

	// Create output directory
	if err := os.MkdirAll(config.OutputDir, 0755); err != nil {
		return fmt.Errorf("failed to create output directory: %w", err)
	}

	fmt.Println("=== PAN-OS Certificate Automation Script ===")
	fmt.Printf("Certificate Name: %s\n", config.CertName)
	fmt.Printf("Common Name: %s\n", config.CommonName)
	fmt.Println("")

	// Create HTTP client that ignores SSL verification (for PAN-OS)
	tr := &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}
	client := &http.Client{Transport: tr}

	// Step 1: Generate CSR in PAN-OS
	fmt.Println("Step 1: Generating CSR in PAN-OS...")
	if err := generateCSR(client, config); err != nil {
		return fmt.Errorf("step 1 failed: %w", err)
	}

	// Step 2: Extract CSR from PAN-OS
	fmt.Println("")
	fmt.Println("Step 2: Extracting CSR from PAN-OS...")
	csrContent, err := extractCSR(client, config)
	if err != nil {
		return fmt.Errorf("step 2 failed: %w", err)
	}

	// Step 3: Submit CSR to DigiCert
	fmt.Println("")
	fmt.Println("Step 3: Submitting CSR to DigiCert...")
	serialNumber, err := submitToDigiCert(csrContent, config)
	if err != nil {
		return fmt.Errorf("step 3 failed: %w", err)
	}

	// Step 4: Extract certificate from response
	fmt.Println("")
	fmt.Println("Step 4: Extracting certificate from DigiCert response...")
	if err := extractCertificate(config); err != nil {
		return fmt.Errorf("step 4 failed: %w", err)
	}

	// Step 5: Import certificate to PAN-OS
	fmt.Println("")
	fmt.Println("Step 5: Importing signed certificate to PAN-OS...")
	if err := importCertificate(client, config); err != nil {
		return fmt.Errorf("step 5 failed: %w", err)
	}

	// Step 6: Commit configuration
	fmt.Println("")
	fmt.Println("Step 6: Committing PAN-OS configuration...")
	if err := commitConfiguration(client, config); err != nil {
		return fmt.Errorf("step 6 failed: %w", err)
	}

	// Step 7: Verify installation
	fmt.Println("")
	fmt.Println("Step 7: Verifying certificate installation...")
	if err := verifyCertificate(client, config); err != nil {
		return fmt.Errorf("step 7 failed: %w", err)
	}

	// Print completion summary
	printCompletionSummary(config, serialNumber)
	return nil
}

func generateCSR(client *http.Client, config *Config) error {
	cmd := fmt.Sprintf(`<request><certificate><generate><certificate-name>%s</certificate-name><name>CN=%s,O=%s,L=%s,ST=%s,C=%s</name><algorithm><RSA><rsa-nbits>2048</rsa-nbits></RSA></algorithm><signed-by>external</signed-by></generate></certificate></request>`,
		config.CertName, config.CommonName, config.Organization, config.Locality, config.State, config.Country)

	data := url.Values{}
	data.Set("type", "op")
	data.Set("key", config.APIKey)
	data.Set("cmd", cmd)

	resp, err := client.PostForm(fmt.Sprintf("https://%s/api/", config.FirewallIP), data)
	if err != nil {
		return fmt.Errorf("failed to generate CSR: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("failed to read response: %w", err)
	}

	if strings.Contains(string(body), "success") {
		fmt.Println("✅ CSR generated successfully in PAN-OS")
		return nil
	}

	return fmt.Errorf("failed to generate CSR in PAN-OS: %s", string(body))
}

func extractCSR(client *http.Client, config *Config) (string, error) {
	data := url.Values{}
	data.Set("key", config.APIKey)
	data.Set("type", "config")
	data.Set("action", "get")
	data.Set("xpath", fmt.Sprintf("/config/shared/certificate/entry[@name='%s']", config.CertName))

	resp, err := client.PostForm(fmt.Sprintf("https://%s/api/", config.FirewallIP), data)
	if err != nil {
		return "", fmt.Errorf("failed to extract CSR: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read response: %w", err)
	}

	fmt.Printf("Debug - CSR Extraction Response: %s\n", string(body))

	// Save raw response
	if err := os.WriteFile(config.RawResponseFile, body, 0644); err != nil {
		return "", fmt.Errorf("failed to save raw response: %w", err)
	}

	// Try multiple regex patterns for CSR extraction
	patterns := []string{
		`<csr[^>]*>(.*?)</csr>`, // Original pattern
		`<csr>(.*?)</csr>`,      // Simple pattern
		`-----BEGIN CERTIFICATE REQUEST-----(.*?)-----END CERTIFICATE REQUEST-----`,
	}

	var csrContent string
	var found bool

	for _, pattern := range patterns {
		csrRegex := regexp.MustCompile(`(?s)` + pattern) // (?s) makes . match newlines
		matches := csrRegex.FindStringSubmatch(string(body))
		if len(matches) >= 2 {
			csrContent = strings.TrimSpace(matches[1])
			found = true
			fmt.Printf("✅ Found CSR using pattern: %s\n", pattern)
			break
		}
	}

	if !found {
		// Let's also try to find any PEM-like content
		pemPattern := regexp.MustCompile(`-----BEGIN CERTIFICATE REQUEST-----.*?-----END CERTIFICATE REQUEST-----`)
		if match := pemPattern.FindString(string(body)); match != "" {
			csrContent = match
			found = true
			fmt.Println("✅ Found CSR using PEM pattern")
		}
	}

	if !found {
		return "", fmt.Errorf("CSR not found in response. Response saved to %s for debugging", config.RawResponseFile)
	}

	// Save clean CSR
	if err := os.WriteFile(config.CSRCleanFile, []byte(csrContent), 0644); err != nil {
		return "", fmt.Errorf("failed to save clean CSR: %w", err)
	}
	fmt.Printf("✅ CSR extracted to %s\n", config.CSRCleanFile)

	// Create single-line CSR for DigiCert API
	lines := strings.Split(csrContent, "\n")
	var singleLineCSR strings.Builder
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if !strings.Contains(line, "BEGIN CERTIFICATE REQUEST") &&
			!strings.Contains(line, "END CERTIFICATE REQUEST") &&
			line != "" {
			singleLineCSR.WriteString(line)
		}
	}

	singleLineContent := singleLineCSR.String()

	if err := os.WriteFile(config.CSRSingleLineFile, []byte(singleLineContent), 0644); err != nil {
		return "", fmt.Errorf("failed to save single-line CSR: %w", err)
	}
	fmt.Printf("✅ Single-line CSR saved to %s\n", config.CSRSingleLineFile)

	return singleLineContent, nil
}

func submitToDigiCert(csrContent string, config *Config) (string, error) {
	request := DigiCertRequest{
		CSR: csrContent,
	}
	request.Profile.ID = config.DigicertProfile
	request.Seat.SeatID = config.DigicertSeatID
	request.Attributes.Subject.CommonName = config.CommonName

	jsonData, err := json.Marshal(request)
	if err != nil {
		return "", fmt.Errorf("failed to marshal request: %w", err)
	}

	req, err := http.NewRequest("POST", "https://demo.one.digicert.com/mpki/api/v1/certificate", bytes.NewBuffer(jsonData))
	if err != nil {
		return "", fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", config.DigicertAPIKey)

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to submit to DigiCert: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read response: %w", err)
	}

	// Save DigiCert response
	if err := os.WriteFile(config.DigicertResponseFile, body, 0644); err != nil {
		return "", fmt.Errorf("failed to save DigiCert response: %w", err)
	}

	// Parse response
	var digicertResp DigiCertResponse
	if err := json.Unmarshal(body, &digicertResp); err != nil {
		return "", fmt.Errorf("failed to parse DigiCert response: %w", err)
	}

	if digicertResp.Certificate == "" {
		return "", fmt.Errorf("no certificate in DigiCert response: %s", string(body))
	}

	fmt.Println("✅ Certificate issued by DigiCert")
	fmt.Printf("Certificate Serial: %s\n", digicertResp.SerialNumber)

	return digicertResp.SerialNumber, nil
}

func extractCertificate(config *Config) error {
	// Read DigiCert response
	responseData, err := os.ReadFile(config.DigicertResponseFile)
	if err != nil {
		return fmt.Errorf("failed to read DigiCert response: %w", err)
	}

	var response DigiCertResponse
	if err := json.Unmarshal(responseData, &response); err != nil {
		return fmt.Errorf("failed to parse DigiCert response: %w", err)
	}

	// Replace \n with actual newlines
	certificate := strings.ReplaceAll(response.Certificate, "\\n", "\n")

	// Save certificate
	if err := os.WriteFile(config.SignedCertFile, []byte(certificate), 0644); err != nil {
		return fmt.Errorf("failed to save certificate: %w", err)
	}

	fmt.Printf("✅ Certificate extracted to %s\n", config.SignedCertFile)

	// Verify certificate
	if err := verifyCertificateFile(config.SignedCertFile); err != nil {
		fmt.Printf("⚠️  Certificate validation failed: %v\n", err)
	} else {
		fmt.Println("✅ Certificate is valid")

		// Get expiry date
		if expiry, err := getCertificateExpiry(config.SignedCertFile); err == nil {
			fmt.Printf("Certificate expires: %s\n", expiry.Format(time.RFC1123))
		}
	}

	return nil
}

func importCertificate(client *http.Client, config *Config) error {
	// Create multipart form
	var b bytes.Buffer
	writer := multipart.NewWriter(&b)

	// Add file
	file, err := os.Open(config.SignedCertFile)
	if err != nil {
		return fmt.Errorf("failed to open certificate file: %w", err)
	}
	defer file.Close()

	part, err := writer.CreateFormFile("file", filepath.Base(config.SignedCertFile))
	if err != nil {
		return fmt.Errorf("failed to create form file: %w", err)
	}

	if _, err := io.Copy(part, file); err != nil {
		return fmt.Errorf("failed to copy file: %w", err)
	}

	writer.Close()

	// Create request
	url := fmt.Sprintf("https://%s/api/?key=%s&type=import&category=certificate&certificate-name=%s&format=pem",
		config.FirewallIP, config.APIKey, config.CertName)

	req, err := http.NewRequest("POST", url, &b)
	if err != nil {
		return fmt.Errorf("failed to create import request: %w", err)
	}

	req.Header.Set("Content-Type", writer.FormDataContentType())

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("failed to import certificate: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("failed to read response: %w", err)
	}

	if strings.Contains(string(body), "success") {
		fmt.Println("✅ Certificate imported to PAN-OS successfully")
		return nil
	}

	return fmt.Errorf("failed to import certificate to PAN-OS: %s", string(body))
}

func commitConfiguration(client *http.Client, config *Config) error {
	url := fmt.Sprintf("https://%s/api/?type=commit&cmd=<commit></commit>&key=%s",
		config.FirewallIP, config.APIKey)

	resp, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("failed to commit configuration: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("failed to read response: %w", err)
	}

	if strings.Contains(string(body), "success") {
		fmt.Println("✅ Configuration committed successfully")
		return nil
	}

	fmt.Printf("❌ Failed to commit configuration: %s\n", string(body))
	return nil // Don't fail the entire process for commit issues
}

func verifyCertificate(client *http.Client, config *Config) error {
	data := url.Values{}
	data.Set("key", config.APIKey)
	data.Set("type", "config")
	data.Set("action", "get")
	data.Set("xpath", fmt.Sprintf("/config/shared/certificate/entry[@name='%s']", config.CertName))

	resp, err := client.PostForm(fmt.Sprintf("https://%s/api/", config.FirewallIP), data)
	if err != nil {
		return fmt.Errorf("failed to verify certificate: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("failed to read response: %w", err)
	}

	responseStr := string(body)
	if strings.Contains(responseStr, "private-key") && strings.Contains(responseStr, "common-name") {
		fmt.Println("✅ Certificate with private key verified in PAN-OS")
	} else {
		fmt.Println("⚠️  Certificate verification incomplete")
	}

	return nil
}

func verifyCertificateFile(filename string) error {
	data, err := os.ReadFile(filename)
	if err != nil {
		return err
	}

	block, _ := pem.Decode(data)
	if block == nil {
		return fmt.Errorf("failed to decode PEM block")
	}

	_, err = x509.ParseCertificate(block.Bytes)
	return err
}

func getCertificateExpiry(filename string) (time.Time, error) {
	data, err := os.ReadFile(filename)
	if err != nil {
		return time.Time{}, err
	}

	block, _ := pem.Decode(data)
	if block == nil {
		return time.Time{}, fmt.Errorf("failed to decode PEM block")
	}

	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return time.Time{}, err
	}

	return cert.NotAfter, nil
}

func printCompletionSummary(config *Config, serialNumber string) {
	fmt.Println("")
	fmt.Println("=== Certificate Installation Complete ===")
	fmt.Printf("Certificate Name: %s\n", config.CertName)
	fmt.Printf("Common Name: %s\n", config.CommonName)
	fmt.Printf("Serial Number: %s\n", serialNumber)
	fmt.Printf("Output Directory: %s\n", config.OutputDir)
	fmt.Println("")
	fmt.Println("Files created:")
	fmt.Printf("- %s (original CSR)\n", config.CSRCleanFile)
	fmt.Printf("- %s (single-line CSR for APIs)\n", config.CSRSingleLineFile)
	fmt.Printf("- %s (DigiCert API response)\n", config.DigicertResponseFile)
	fmt.Printf("- %s (final signed certificate)\n", config.SignedCertFile)
	fmt.Printf("- %s (PAN-OS API response)\n", config.RawResponseFile)
	fmt.Println("")
	fmt.Println("The certificate is now ready for use in SSL/TLS configurations!")
}
