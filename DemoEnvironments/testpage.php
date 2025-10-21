<?php
// Get server information
$server_info = [
    'Hostname' => gethostname(),
    'Server Software' => $_SERVER['SERVER_SOFTWARE'] ?? 'Unknown',
    'Server IP' => $_SERVER['SERVER_ADDR'] ?? 'Unknown',
    'Server Port' => $_SERVER['SERVER_PORT'] ?? 'Unknown',
    'PHP Version' => phpversion(),
    'Operating System' => php_uname(),
    'Document Root' => $_SERVER['DOCUMENT_ROOT'] ?? 'Unknown',
    'Server Protocol' => $_SERVER['SERVER_PROTOCOL'] ?? 'Unknown',
    'Request Time' => date('Y-m-d H:i:s', $_SERVER['REQUEST_TIME']),
];

// Function to get certificate from live server
function getLiveCertificate() {
    $cert_info = null;
    $cert_data = null;
    $method_used = 'none';
    
    // Method 1: Try to get certificate from current HTTPS connection
    if (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] === 'on') {
        // Get the host and port
        $host = $_SERVER['HTTP_HOST'] ?? gethostname();
        $port = $_SERVER['SERVER_PORT'] ?? 443;
        
        // Remove port from host if it's included
        $host = preg_replace('/:\d+$/', '', $host);
        
        // Method 1a: Use stream_context to connect to ourselves
        $stream_context = stream_context_create([
            "ssl" => [
                "capture_peer_cert" => true,
                "verify_peer" => false,
                "verify_peer_name" => false,
                "allow_self_signed" => true
            ]
        ]);
        
        $stream = @stream_socket_client(
            "ssl://{$host}:{$port}",
            $errno,
            $errstr,
            30,
            STREAM_CLIENT_CONNECT,
            $stream_context
        );
        
        if ($stream) {
            $params = stream_context_get_params($stream);
            if (isset($params['options']['ssl']['peer_certificate'])) {
                $cert_data = openssl_x509_parse($params['options']['ssl']['peer_certificate']);
                if ($cert_data) {
                    $method_used = 'stream_socket';
                    // Export certificate for fingerprint calculation
                    openssl_x509_export($params['options']['ssl']['peer_certificate'], $cert_pem);
                }
            }
            fclose($stream);
        }
        
        // Method 1b: If stream failed, try using openssl s_client command
        if (!$cert_data && function_exists('shell_exec')) {
            $cmd = "timeout 3 openssl s_client -connect {$host}:{$port} -servername {$host} 2>/dev/null </dev/null | openssl x509 2>/dev/null";
            $cert_pem = @shell_exec($cmd);
            
            if ($cert_pem && strpos($cert_pem, '-----BEGIN CERTIFICATE-----') !== false) {
                $cert_data = openssl_x509_parse($cert_pem);
                if ($cert_data) {
                    $method_used = 'openssl_s_client';
                }
            }
        }
        
        // Method 1c: Try curl if available
        if (!$cert_data && function_exists('curl_init')) {
            $ch = curl_init();
            curl_setopt($ch, CURLOPT_URL, "https://{$host}:{$port}/");
            curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
            curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
            curl_setopt($ch, CURLOPT_SSL_VERIFYHOST, false);
            curl_setopt($ch, CURLOPT_CERTINFO, true);
            curl_setopt($ch, CURLOPT_TIMEOUT, 3);
            curl_setopt($ch, CURLOPT_NOBODY, true);
            
            curl_exec($ch);
            $certinfo = curl_getinfo($ch, CURLINFO_CERTINFO);
            curl_close($ch);
            
            if (!empty($certinfo) && isset($certinfo[0]['Cert'])) {
                $cert_pem = $certinfo[0]['Cert'];
                $cert_data = openssl_x509_parse($cert_pem);
                if ($cert_data) {
                    $method_used = 'curl';
                }
            }
        }
    }
    
    // Method 2: Fallback to reading from file if no live cert found
    if (!$cert_data) {
        $cert_files = [
            '/etc/lighttpd/ssl/demo2me.pem',
            '/etc/lighttpd/ssl/server.pem',
            '/etc/ssl/certs/ssl-cert-snakeoil.pem',
            '/etc/apache2/ssl/apache.pem',
            '/etc/nginx/ssl/nginx.pem'
        ];
        
        foreach ($cert_files as $cert_file) {
            if (file_exists($cert_file)) {
                $cert_pem = file_get_contents($cert_file);
                $cert_data = openssl_x509_parse($cert_pem);
                if ($cert_data) {
                    $method_used = 'file: ' . $cert_file;
                    break;
                }
            }
        }
    }
    
    // Process certificate data if found
    if ($cert_data && isset($cert_pem)) {
        // Start with essential fields that are always present
        $cert_info = [
            'Detection Method' => $method_used,
        ];
        
        // Add subject fields only if they exist
        if (isset($cert_data['subject']['CN'])) {
            $cert_info['Common Name (CN)'] = $cert_data['subject']['CN'];
        }
        
        // Add organizational fields only if they exist
        if (isset($cert_data['subject']['O'])) {
            $cert_info['Organization (O)'] = $cert_data['subject']['O'];
        }
        if (isset($cert_data['subject']['OU'])) {
            $cert_info['Organizational Unit (OU)'] = $cert_data['subject']['OU'];
        }
        if (isset($cert_data['subject']['C'])) {
            $cert_info['Country (C)'] = $cert_data['subject']['C'];
        }
        if (isset($cert_data['subject']['ST'])) {
            $cert_info['State/Province (ST)'] = $cert_data['subject']['ST'];
        }
        if (isset($cert_data['subject']['L'])) {
            $cert_info['Locality (L)'] = $cert_data['subject']['L'];
        }
        if (isset($cert_data['subject']['emailAddress'])) {
            $cert_info['Email Address'] = $cert_data['subject']['emailAddress'];
        }
        
        // Certificate Type Detection
        $cert_type = 'Unknown';
        if (isset($cert_data['issuer']['CN']) && isset($cert_data['subject']['CN'])) {
            if ($cert_data['issuer']['CN'] === $cert_data['subject']['CN']) {
                $cert_type = 'Self-Signed';
            } elseif (strpos($cert_data['issuer']['CN'], "Let's Encrypt") !== false) {
                $cert_type = "Let's Encrypt";
            } elseif (isset($cert_data['subject']['O'])) {
                $cert_type = 'Organization Validated (OV)';
            } else {
                $cert_type = 'Domain Validated (DV)';
            }
        }
        $cert_info['Certificate Type'] = $cert_type;
        
        // Issuer information
        if (isset($cert_data['issuer']['CN'])) {
            $cert_info['Issuer'] = $cert_data['issuer']['CN'];
        }
        if (isset($cert_data['issuer']['O']) && $cert_data['issuer']['O'] !== $cert_data['issuer']['CN']) {
            $cert_info['Issuer Organization'] = $cert_data['issuer']['O'];
        }
        
        // Serial number and signature
        if (isset($cert_data['serialNumber'])) {
            $cert_info['Serial Number'] = $cert_data['serialNumber'];
        }
        if (isset($cert_data['signatureTypeSN'])) {
            $cert_info['Signature Algorithm'] = $cert_data['signatureTypeSN'];
        }
        
        // Validity dates
        $cert_info['Valid From'] = date('Y-m-d H:i:s', $cert_data['validFrom_time_t']);
        $cert_info['Valid Until'] = date('Y-m-d H:i:s', $cert_data['validTo_time_t']);
        
        // Add Subject Alternative Names if present
        if (isset($cert_data['extensions']['subjectAltName'])) {
            $san = $cert_data['extensions']['subjectAltName'];
            // Clean up the SAN display
            $san = str_replace('DNS:', '', $san);
            $cert_info['Subject Alt Names'] = $san;
        }
        
        // Key usage if present
        if (isset($cert_data['extensions']['keyUsage'])) {
            $cert_info['Key Usage'] = $cert_data['extensions']['keyUsage'];
        }
        
        // Extended key usage if present
        if (isset($cert_data['extensions']['extendedKeyUsage'])) {
            $cert_info['Extended Key Usage'] = $cert_data['extensions']['extendedKeyUsage'];
        }
        
        // Calculate thumbprints
        $fingerprint = openssl_x509_fingerprint($cert_pem, 'sha1');
        $cert_info['Thumbprint (SHA-1)'] = wordwrap(strtoupper($fingerprint), 2, ':', true);
        
        $fingerprint_sha256 = openssl_x509_fingerprint($cert_pem, 'sha256');
        $cert_info['Thumbprint (SHA-256)'] = wordwrap(strtoupper($fingerprint_sha256), 2, ':', true);
        
        // Check certificate status
        $days_until_expiry = floor(($cert_data['validTo_time_t'] - time()) / 86400);
        $cert_info['Days Until Expiry'] = $days_until_expiry . ' days';
        
        // Validity period in days
        $total_days = floor(($cert_data['validTo_time_t'] - $cert_data['validFrom_time_t']) / 86400);
        $cert_info['Validity Period'] = $total_days . ' days';
        
        if ($days_until_expiry < 0) {
            $cert_status = 'expired';
            $cert_info['Status'] = '❌ Expired';
        } elseif ($days_until_expiry <= 30) {
            $cert_status = 'warning';
            $cert_info['Status'] = '⚠️ Expiring Soon';
        } else {
            $cert_status = 'valid';
            $cert_info['Status'] = '✅ Valid';
        }
        
        return ['info' => $cert_info, 'status' => $cert_status, 'days' => $days_until_expiry];
    }
    
    return null;
}

// Get certificate information
$cert_result = getLiveCertificate();
$cert_info = $cert_result['info'] ?? null;
$cert_status = $cert_result['status'] ?? null;
$days_until_expiry = $cert_result['days'] ?? null;

// Add refresh timestamp
$refresh_time = date('Y-m-d H:i:s');
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="refresh" content="60">
    <title>Server Status - <?php echo $server_info['Hostname']; ?></title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
            color: #333;
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
        }

        .header {
            text-align: center;
            color: white;
            margin-bottom: 30px;
            padding: 20px;
        }

        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.2);
        }

        .header p {
            font-size: 1.2em;
            opacity: 0.9;
        }

        .refresh-info {
            text-align: center;
            color: rgba(255,255,255,0.8);
            margin-bottom: 20px;
            font-size: 0.9em;
        }

        .refresh-button {
            background: rgba(255,255,255,0.2);
            border: 1px solid rgba(255,255,255,0.3);
            color: white;
            padding: 8px 16px;
            border-radius: 20px;
            cursor: pointer;
            font-size: 0.9em;
            margin-left: 10px;
            transition: all 0.3s;
        }

        .refresh-button:hover {
            background: rgba(255,255,255,0.3);
        }

        .cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(500px, 1fr));
            gap: 20px;
            margin-bottom: 20px;
        }

        .card {
            background: white;
            border-radius: 12px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.2);
            overflow: hidden;
        }

        .card-header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 20px;
            font-size: 1.5em;
            font-weight: 600;
            display: flex;
            align-items: center;
            justify-content: space-between;
        }

        .card-header-title {
            display: flex;
            align-items: center;
        }

        .card-header-title::before {
            content: '🖥️';
            margin-right: 10px;
            font-size: 1.2em;
        }

        .card-header.cert .card-header-title::before {
            content: '🔒';
        }

        .card-body {
            padding: 20px;
        }

        .info-row {
            display: flex;
            padding: 12px 0;
            border-bottom: 1px solid #f0f0f0;
        }

        .info-row:last-child {
            border-bottom: none;
        }

        .info-label {
            font-weight: 600;
            color: #667eea;
            min-width: 200px;
            flex-shrink: 0;
        }

        .info-value {
            color: #555;
            word-break: break-all;
            font-family: 'Courier New', monospace;
            font-size: 0.95em;
            flex: 1;
        }
        
        .info-value.fingerprint {
            font-size: 0.85em;
            line-height: 1.4;
        }
        
        .cert-summary {
            background: #f0f4ff;
            border-radius: 8px;
            padding: 15px;
            margin-bottom: 20px;
            border: 1px solid #e0e7ff;
        }
        
        .cert-summary-title {
            font-weight: 600;
            color: #4338ca;
            margin-bottom: 10px;
            font-size: 1.1em;
        }
        
        .cert-type-badge {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 0.85em;
            font-weight: 600;
            background: #818cf8;
            color: white;
            margin-left: 10px;
        }

        .status-badge {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 0.85em;
            font-weight: 600;
            text-transform: uppercase;
        }

        .status-valid {
            background: #10b981;
            color: white;
        }

        .status-warning {
            background: #f59e0b;
            color: white;
        }

        .status-expired {
            background: #ef4444;
            color: white;
        }

        .detection-method {
            background: #e0e7ff;
            color: #4338ca;
            padding: 2px 8px;
            border-radius: 4px;
            font-size: 0.85em;
        }

        .alert {
            background: #fef3c7;
            border-left: 4px solid #f59e0b;
            padding: 15px;
            margin-bottom: 20px;
            border-radius: 4px;
            color: #92400e;
        }

        .alert-error {
            background: #fee2e2;
            border-left-color: #ef4444;
            color: #991b1b;
        }

        .footer {
            text-align: center;
            color: white;
            padding: 20px;
            font-size: 0.9em;
            opacity: 0.8;
        }

        @keyframes pulse {
            0% { opacity: 1; }
            50% { opacity: 0.5; }
            100% { opacity: 1; }
        }

        .updating {
            animation: pulse 1.5s ease-in-out infinite;
        }

        @media (max-width: 768px) {
            .cards {
                grid-template-columns: 1fr;
            }

            .info-row {
                flex-direction: column;
            }

            .info-label {
                margin-bottom: 5px;
            }
        }
    </style>
    <script>
        function refreshPage() {
            document.body.classList.add('updating');
            location.reload();
        }
        
        // Auto-refresh countdown
        let countdown = 60;
        setInterval(function() {
            countdown--;
            if (countdown <= 0) {
                countdown = 60;
            }
            document.getElementById('countdown').textContent = countdown;
        }, 1000);
    </script>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 Server Status Dashboard</h1>
            <p><?php echo $server_info['Hostname']; ?></p>
        </div>

        <div class="refresh-info">
            Last updated: <?php echo $refresh_time; ?> | Auto-refresh in <span id="countdown">60</span>s
            <button class="refresh-button" onclick="refreshPage()">Refresh Now</button>
        </div>

        <?php if ($cert_info && isset($cert_status) && $cert_status === 'warning'): ?>
        <div class="alert">
            ⚠️ <strong>Warning:</strong> SSL certificate will expire in <?php echo $days_until_expiry; ?> days!
        </div>
        <?php endif; ?>

        <?php if ($cert_info && isset($cert_status) && $cert_status === 'expired'): ?>
        <div class="alert alert-error">
            ❌ <strong>Alert:</strong> SSL certificate has expired!
        </div>
        <?php endif; ?>

        <div class="cards">
            <div class="card">
                <div class="card-header">
                    <div class="card-header-title">Server Information</div>
                </div>
                <div class="card-body">
                    <?php foreach ($server_info as $label => $value): ?>
                    <div class="info-row">
                        <div class="info-label"><?php echo htmlspecialchars($label); ?></div>
                        <div class="info-value"><?php echo htmlspecialchars($value); ?></div>
                    </div>
                    <?php endforeach; ?>
                </div>
            </div>

            <?php if ($cert_info): ?>
            <div class="card">
                <div class="card-header cert">
                    <div class="card-header-title">SSL Certificate Details</div>
                    <?php if (isset($cert_status)): ?>
                    <span class="status-badge status-<?php echo $cert_status; ?>">
                        <?php echo $cert_info['Status']; ?>
                    </span>
                    <?php endif; ?>
                </div>
                <div class="card-body">
                    <?php 
                    // Show certificate summary
                    $domain = $cert_info['Common Name (CN)'] ?? $cert_info['Subject Alt Names'] ?? 'Unknown Domain';
                    $issuer = isset($cert_info['Issuer']) ? $cert_info['Issuer'] : 'Unknown Issuer';
                    $cert_type = $cert_info['Certificate Type'] ?? 'Unknown';
                    ?>
                    <div class="cert-summary">
                        <div class="cert-summary-title">
                            Certificate Summary
                            <span class="cert-type-badge"><?php echo htmlspecialchars($cert_type); ?></span>
                        </div>
                        <div style="color: #666; line-height: 1.6;">
                            This certificate is for <strong><?php echo htmlspecialchars($domain); ?></strong>
                            <?php if ($cert_type !== 'Self-Signed'): ?>
                            and was issued by <strong><?php echo htmlspecialchars($issuer); ?></strong>.
                            <?php else: ?>
                            and is self-signed.
                            <?php endif; ?>
                            <br>
                            <?php if (isset($days_until_expiry)): ?>
                                <?php if ($days_until_expiry > 0): ?>
                                    It will expire in <strong><?php echo $days_until_expiry; ?> days</strong>
                                    (<?php echo htmlspecialchars($cert_info['Valid Until']); ?>).
                                <?php else: ?>
                                    It <strong>expired <?php echo abs($days_until_expiry); ?> days ago</strong>
                                    (<?php echo htmlspecialchars($cert_info['Valid Until']); ?>).
                                <?php endif; ?>
                            <?php endif; ?>
                        </div>
                    </div>
                    
                    <?php foreach ($cert_info as $label => $value): ?>
                    <?php if ($label === 'Status' || $label === 'Certificate Type') continue; ?>
                    <div class="info-row">
                        <div class="info-label"><?php echo htmlspecialchars($label); ?></div>
                        <div class="info-value<?php echo (strpos($label, 'Thumbprint') !== false) ? ' fingerprint' : ''; ?>">
                            <?php
                            if ($label === 'Days Until Expiry' && isset($cert_status)) {
                                echo '<span class="status-badge status-' . $cert_status . '">' . htmlspecialchars($value) . '</span>';
                            } elseif ($label === 'Detection Method') {
                                echo '<span class="detection-method">' . htmlspecialchars($value) . '</span>';
                            } else {
                                echo htmlspecialchars($value);
                            }
                            ?>
                        </div>
                    </div>
                    <?php endforeach; ?>
                </div>
            </div>
            <?php else: ?>
            <div class="card">
                <div class="card-header cert">
                    <div class="card-header-title">SSL Certificate Details</div>
                </div>
                <div class="card-body">
                    <div class="info-row">
                        <div class="info-value" style="color: #999;">
                            <strong>Certificate information not available.</strong><br><br>
                            Possible reasons:<br>
                            • The server is not using HTTPS<br>
                            • Certificate detection methods failed<br>
                            • PHP lacks necessary SSL extensions<br>
                            • Network connectivity issues<br><br>
                            <small>Attempted methods: stream_socket, openssl s_client, curl, file system</small>
                        </div>
                    </div>
                </div>
            </div>
            <?php endif; ?>
        </div>

        <div class="footer">
            Generated on <?php echo date('Y-m-d H:i:s'); ?> | Powered by lighttpd & PHP <?php echo phpversion(); ?>
        </div>
    </div>
</body>
</html>