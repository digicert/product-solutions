# DigiCert Trust Lifecycle Manager Integrations

<div align="center">
  <img src="https://upload.wikimedia.org/wikipedia/commons/4/48/DigiCert_logo.svg" alt="DigiCert Logo" width="300">
  
  <h3>Enterprise Certificate Automation Solutions</h3>
  
  [![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
  [![TLM](https://img.shields.io/badge/DigiCert-TLM-orange.svg)](https://www.digicert.com/tls-ssl/trust-lifecycle-manager)
  [![Documentation](https://img.shields.io/badge/docs-latest-green.svg)](https://docs.digicert.com/)
</div>

---

## 📚 Integration Solutions

Streamline your certificate management with our production-ready integration scripts for DigiCert Trust Lifecycle Manager.

<table>
  <tr>
    <td align="center" width="33%">
      <a href="https://github.com/digicert/product-solutions/tree/master/TrustLifeCycleManager/Integrations/Imperva">
        <img src="https://img.shields.io/badge/Imperva-Cloud_WAF-5B9BD5?style=for-the-badge&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0iI2ZmZmZmZiIgZD0iTTEyIDJDNi40OCAyIDIgNi40OCAyIDEyczQuNDggMTAgMTAgMTAgMTAtNC40OCAxMC0xMFMxNy41MiAyIDEyIDJ6bTAgMThjLTQuNDEgMC04LTMuNTktOC04czMuNTktOCA4LTggOCAzLjU5IDggOC0zLjU5IDgtOCA4em0wLTE0Yy0zLjMxIDAtNiAyLjY5LTYgNnMyLjY5IDYgNiA2IDYtMi42OSA2LTYtMi42OS02LTYtNnoiLz48L3N2Zz4=" alt="Imperva">
        <br><br>
        <strong>Imperva Integration</strong>
      </a>
      <br><br>
      <sub>Automated certificate deployment to Imperva Cloud WAF with full chain support and intelligent key type detection.</sub>
    </td>
    <td align="center" width="33%">
      <a href="https://github.com/digicert/product-solutions/tree/master/TrustLifeCycleManager/Integrations/Cloudflare/Cloudflare_Generated_CSR">
        <img src="https://img.shields.io/badge/Cloudflare-CSR-F38020?style=for-the-badge&logo=cloudflare&logoColor=white" alt="Cloudflare CSR">
        <br><br>
        <strong>Cloudflare (CF Generated CSR)</strong>
      </a>
      <br><br>
      <sub>Deploy certificates using Cloudflare-generated CSRs for seamless zone integration.</sub>
    </td>
    <td align="center" width="33%">
      <a href="https://github.com/digicert/product-solutions/tree/master/TrustLifeCycleManager/Integrations/Cloudflare/Digicert_Generated_CSR">
        <img src="https://img.shields.io/badge/Cloudflare-DigiCert_CSR-F38020?style=for-the-badge&logo=cloudflare&logoColor=white" alt="DigiCert CSR">
        <br><br>
        <strong>Cloudflare (DigiCert CSR)</strong>
      </a>
      <br><br>
      <sub>Deploy certificates with DigiCert-generated CSRs for enhanced control and compatibility.</sub>
    </td>
  </tr>
</table>

---

## 🚀 Quick Start

### Prerequisites
- DigiCert Trust Lifecycle Manager account
- API credentials for your target platform
- Bash 4.0+ (Linux/macOS) or PowerShell 5.1+ (Windows)

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/digicert/product-solutions.git
   cd product-solutions/TrustLifeCycleManager/Integrations
   ```

2. **Choose your integration**
   - [Imperva Cloud WAF](https://github.com/digicert/product-solutions/tree/master/TrustLifeCycleManager/Integrations/Imperva)
   - [Cloudflare with Cloudflare CSR](https://github.com/digicert/product-solutions/tree/master/TrustLifeCycleManager/Integrations/Cloudflare/Cloudflare_Generated_CSR)
   - [Cloudflare with DigiCert CSR](https://github.com/digicert/product-solutions/tree/master/TrustLifeCycleManager/Integrations/Cloudflare/Digicert_Generated_CSR)

3. **Follow the integration-specific README** for detailed setup instructions

---

## 📋 Features

### All Integrations Include

✅ **Automated Certificate Deployment** - Hands-free certificate lifecycle management  
✅ **Comprehensive Logging** - Detailed audit trails and debugging capabilities  
✅ **Error Handling** - Robust validation and recovery mechanisms  
✅ **Security Best Practices** - Credential masking and secure data handling  
✅ **Multi-Environment Support** - Development, staging, and production configurations  

### Platform-Specific Features

#### 🛡️ Imperva Integration
- Full certificate chain processing
- Automatic key type detection (RSA/ECC)
- Base64 encoding for API transmission
- Site-specific deployment targeting

#### ☁️ Cloudflare Integrations
- Zone-based certificate management
- CSR flexibility (Cloudflare or DigiCert generated)
- Bundle method configuration
- Automatic certificate replacement

---

## 📖 Documentation

### General Resources
- [DigiCert Trust Lifecycle Manager Documentation](https://docs.digicert.com/)
- [API Reference](https://dev.digicert.com/)
- [Best Practices Guide](https://www.digicert.com/kb/)

### Integration Guides
Each integration folder contains:
- Detailed README with setup instructions
- Configuration examples
- Troubleshooting guides
- Security recommendations

---

## 🤝 Contributing

We welcome contributions! Please see our [Contributing Guidelines](CONTRIBUTING.md) for details.

### How to Contribute
1. Fork the repository
2. Create a feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## 🆘 Support

### Get Help
- 📧 **Email**: support@digicert.com
- 💬 **Community**: [DigiCert Community Forum](https://community.digicert.com/)
- 📚 **Knowledge Base**: [DigiCert KB Articles](https://knowledge.digicert.com/)
- 🎫 **Support Portal**: [DigiCert Support](https://www.digicert.com/support)

### Report Issues
Found a bug or have a feature request? Please [open an issue](https://github.com/digicert/product-solutions/issues).

---

## 🏢 About DigiCert

DigiCert is the world's leading provider of scalable TLS/SSL, PKI solutions for identity and encryption. The most innovative companies choose DigiCert for its expertise in identity and encryption for web servers and IoT devices.

<div align="center">
  <br>
  <a href="https://www.digicert.com">Website</a> •
  <a href="https://www.linkedin.com/company/digicert">LinkedIn</a> •
  <a href="https://twitter.com/digicert">Twitter</a> •
  <a href="https://www.youtube.com/digicert">YouTube</a>
  <br><br>
  <sub>© 2024 DigiCert, Inc. All rights reserved.</sub>
</div>
