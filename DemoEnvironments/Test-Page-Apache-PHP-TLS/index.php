<?php
date_default_timezone_set('UTC');

/* ==========================
   CONFIGURATION
   ========================== */
$servers = [
    ["url" => "gitlab.tls.guru:443",     "label" => "GitLab"],
    ["url" => "resilience.tls.guru:443",  "label" => "Resilience"],
    ["url" => "cyberark.tls.guru:443",    "label" => "CyberArk"],
    ["url" => "nextlabs.tls.guru:443",    "label" => "NextLabs"],
];

/* ==========================
   HOSTNAME
   ========================== */
$hostname = gethostname();

/* ==========================
   APACHE STATUS
   ========================== */
$apacheStatus = trim(shell_exec("systemctl is-active apache2 2>&1"));

/* ==========================
   CERTIFICATE SCAN FUNCTION
   ========================== */
function getCertInfo($checkUrl) {
    $hostOnly = explode(':', $checkUrl)[0];
    $certOutput = shell_exec("echo | timeout 10 openssl s_client -connect $checkUrl -servername $hostOnly 2>/dev/null | openssl x509 -noout -dates -issuer -subject -serial 2>/dev/null");

    $certInfo = [
        "issuer"         => "Unavailable",
        "subject"        => "Unavailable",
        "serial"         => "Unavailable",
        "valid_from"     => "Unavailable",
        "valid_to"       => "Unavailable",
        "days_remaining" => "Unavailable"
    ];

    if ($certOutput) {
        foreach (explode("\n", $certOutput) as $line) {
            if (strpos($line, "issuer=") !== false) {
                $certInfo["issuer"] = trim(str_replace("issuer=", "", $line));
            }
            if (strpos($line, "subject=") !== false) {
                $certInfo["subject"] = trim(str_replace("subject=", "", $line));
            }
            if (strpos($line, "serial=") !== false) {
                $certInfo["serial"] = trim(str_replace("serial=", "", $line));
            }
            if (strpos($line, "notBefore=") !== false) {
                $certInfo["valid_from"] = trim(str_replace("notBefore=", "", $line));
            }
            if (strpos($line, "notAfter=") !== false) {
                $certInfo["valid_to"] = trim(str_replace("notAfter=", "", $line));

                $expiry = strtotime($certInfo["valid_to"]);
                $now = time();
                $daysRemaining = floor(($expiry - $now) / 86400);
                $certInfo["days_remaining"] = $daysRemaining;
            }
        }
    }

    return $certInfo;
}

/* ==========================
   GATHER ALL CERT DATA
   ========================== */
$serverData = [];
foreach ($servers as $server) {
    $serverData[] = [
        "label"    => $server["label"],
        "url"      => $server["url"],
        "certInfo" => getCertInfo($server["url"])
    ];
}
?>
<!DOCTYPE html>
<html>
<head>
    <title>TLS Certificate Dashboard - <?php echo htmlspecialchars($hostname); ?></title>
    <meta charset="UTF-8">
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }

        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: #0f1923;
            color: #c8d6e5;
            padding: 30px;
            min-height: 100vh;
        }

        .dashboard-header {
            text-align: center;
            margin-bottom: 30px;
        }

        .dashboard-header h1 {
            font-size: 28px;
            color: #ffffff;
            letter-spacing: 1px;
            margin-bottom: 8px;
        }

        .dashboard-header .meta {
            font-size: 14px;
            color: #6b7c93;
        }

        .dashboard-header .meta span {
            color: #8fa4ba;
        }

        .apache-banner {
            text-align: center;
            margin-bottom: 25px;
            padding: 10px 20px;
            border-radius: 8px;
            display: inline-block;
            margin-left: auto;
            margin-right: auto;
            font-size: 14px;
            font-weight: 600;
            letter-spacing: 0.5px;
        }

        .apache-banner.running {
            background: rgba(0, 200, 83, 0.1);
            border: 1px solid rgba(0, 200, 83, 0.3);
            color: #00c853;
        }

        .apache-banner.stopped {
            background: rgba(255, 61, 61, 0.1);
            border: 1px solid rgba(255, 61, 61, 0.3);
            color: #ff3d3d;
        }

        .apache-wrap {
            text-align: center;
            margin-bottom: 25px;
        }

        /* 2x2 Grid */
        .grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
            max-width: 1100px;
            margin: 0 auto 30px auto;
        }

        .card {
            background: #1a2736;
            border: 1px solid #2a3a4e;
            border-radius: 12px;
            padding: 22px 25px;
            transition: border-color 0.3s ease;
        }

        .card:hover {
            border-color: #3d5a80;
        }

        .card-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 18px;
            padding-bottom: 12px;
            border-bottom: 1px solid #2a3a4e;
        }

        .card-header h2 {
            font-size: 18px;
            color: #ffffff;
        }

        .card-header .host {
            font-size: 12px;
            color: #6b7c93;
            font-family: 'Courier New', monospace;
            background: #0f1923;
            padding: 3px 10px;
            border-radius: 4px;
        }

        .badge {
            display: inline-block;
            padding: 3px 12px;
            border-radius: 20px;
            font-size: 12px;
            font-weight: 700;
            letter-spacing: 0.5px;
        }

        .badge.good {
            background: rgba(0, 200, 83, 0.15);
            color: #00c853;
            border: 1px solid rgba(0, 200, 83, 0.3);
        }

        .badge.warning {
            background: rgba(255, 171, 0, 0.15);
            color: #ffab00;
            border: 1px solid rgba(255, 171, 0, 0.3);
        }

        .badge.critical {
            background: rgba(255, 61, 61, 0.15);
            color: #ff3d3d;
            border: 1px solid rgba(255, 61, 61, 0.3);
        }

        .badge.unknown {
            background: rgba(107, 124, 147, 0.15);
            color: #6b7c93;
            border: 1px solid rgba(107, 124, 147, 0.3);
        }

        .cert-row {
            display: flex;
            padding: 6px 0;
            font-size: 13px;
            line-height: 1.5;
        }

        .cert-row .lbl {
            width: 120px;
            flex-shrink: 0;
            color: #6b7c93;
            font-weight: 600;
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: 0.3px;
        }

        .cert-row .val {
            color: #c8d6e5;
            word-break: break-all;
        }

        .days-row {
            margin-top: 12px;
            padding-top: 12px;
            border-top: 1px solid #2a3a4e;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .days-count {
            font-size: 28px;
            font-weight: 700;
        }

        .days-count.good    { color: #00c853; }
        .days-count.warning { color: #ffab00; }
        .days-count.critical{ color: #ff3d3d; }
        .days-count.unknown { color: #6b7c93; }

        .days-label {
            font-size: 12px;
            color: #6b7c93;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }

        .footer {
            text-align: center;
            margin-top: 10px;
        }

        .refresh-btn {
            padding: 10px 28px;
            border: 1px solid #3d5a80;
            background: transparent;
            color: #8fa4ba;
            border-radius: 6px;
            cursor: pointer;
            font-size: 14px;
            font-weight: 600;
            letter-spacing: 0.5px;
            transition: all 0.2s ease;
        }

        .refresh-btn:hover {
            background: #3d5a80;
            color: #ffffff;
        }

        @media (max-width: 768px) {
            .grid {
                grid-template-columns: 1fr;
            }
            body { padding: 15px; }
        }
    </style>
    <script>
        function updateTime() {
            const now = new Date();
            document.getElementById("datetime").innerText = now.toUTCString();
        }
        setInterval(updateTime, 1000);
        window.onload = updateTime;
    </script>
</head>
<body>

<div class="dashboard-header">
    <h1>TLS Certificate Dashboard</h1>
    <p class="meta">
        Hostname: <span><?php echo htmlspecialchars($hostname); ?></span>
        &nbsp;&bull;&nbsp;
        UTC: <span id="datetime"></span>
    </p>
</div>

<div class="apache-wrap">
    <div class="apache-banner <?php echo ($apacheStatus == 'active') ? 'running' : 'stopped'; ?>">
        ● Apache: <?php echo strtoupper(htmlspecialchars($apacheStatus)); ?>
    </div>
</div>

<div class="grid">
<?php foreach ($serverData as $s):
    $cert = $s["certInfo"];

    // Determine status class
    $statusClass = "unknown";
    $badgeText = "UNKNOWN";
    if (is_numeric($cert["days_remaining"])) {
        if ($cert["days_remaining"] < 0) {
            $statusClass = "critical";
            $badgeText = "EXPIRED";
        } elseif ($cert["days_remaining"] < 30) {
            $statusClass = "warning";
            $badgeText = "EXPIRING SOON";
        } else {
            $statusClass = "good";
            $badgeText = "VALID";
        }
    }
?>
    <div class="card">
        <div class="card-header">
            <h2><?php echo htmlspecialchars($s["label"]); ?></h2>
            <span class="host"><?php echo htmlspecialchars($s["url"]); ?></span>
        </div>

        <div style="margin-bottom: 14px;">
            <span class="badge <?php echo $statusClass; ?>"><?php echo $badgeText; ?></span>
        </div>

        <div class="cert-row">
            <span class="lbl">Subject</span>
            <span class="val"><?php echo htmlspecialchars($cert["subject"]); ?></span>
        </div>
        <div class="cert-row">
            <span class="lbl">Serial</span>
            <span class="val" style="font-family: 'Courier New', monospace; font-size: 12px;"><?php echo htmlspecialchars($cert["serial"]); ?></span>
        </div>
        <div class="cert-row">
            <span class="lbl">Issuer</span>
            <span class="val"><?php echo htmlspecialchars($cert["issuer"]); ?></span>
        </div>
        <div class="cert-row">
            <span class="lbl">Valid From</span>
            <span class="val"><?php echo htmlspecialchars($cert["valid_from"]); ?></span>
        </div>
        <div class="cert-row">
            <span class="lbl">Valid To</span>
            <span class="val"><?php echo htmlspecialchars($cert["valid_to"]); ?></span>
        </div>

        <div class="days-row">
            <div>
                <div class="days-count <?php echo $statusClass; ?>">
                    <?php echo htmlspecialchars($cert["days_remaining"]); ?>
                </div>
                <div class="days-label">Days Remaining</div>
            </div>
        </div>
    </div>
<?php endforeach; ?>
</div>

<div class="footer">
    <button class="refresh-btn" onclick="location.reload();">↻ Refresh</button>
</div>

</body>
</html>