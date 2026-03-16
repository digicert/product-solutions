<?php
date_default_timezone_set('UTC');

/* ==========================
   SINGLE SERVER CONFIG ONLY
   ========================== */
$server = ["url" => "netscaler.tls.guru:443", "label" => "NetScaler"];

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
   GATHER CERT DATA (single)
   ========================== */
$cert = getCertInfo($server["url"]);

/* Determine status class */
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

        .page {
            max-width: 980px;
            margin: 0 auto;
            display: flex;
            flex-direction: column;
            align-items: center;
        }

        .dashboard-header {
            text-align: center;
            margin-bottom: 22px;
            width: 100%;
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

        .apache-wrap {
            text-align: center;
            margin-bottom: 18px;
            width: 100%;
        }

        .apache-banner {
            text-align: center;
            padding: 10px 20px;
            border-radius: 8px;
            display: inline-block;
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

        .card-wrap {
            width: 100%;
            display: flex;
            justify-content: center;
            margin-bottom: 18px;
        }

        .card {
            width: 100%;
            max-width: 900px;
            background: #1a2736;
            border: 1px solid #2a3a4e;
            border-radius: 12px;
            padding: 22px 25px;
            transition: border-color 0.3s ease;
        }

        .card:hover { border-color: #3d5a80; }

        .card-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 18px;
            padding-bottom: 12px;
            border-bottom: 1px solid #2a3a4e;
            gap: 12px;
        }

        .card-header h2 { font-size: 18px; color: #ffffff; }

        .card-header .host {
            font-size: 12px;
            color: #6b7c93;
            font-family: 'Courier New', monospace;
            background: #0f1923;
            padding: 3px 10px;
            border-radius: 4px;
            overflow: hidden;
            text-overflow: ellipsis;
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
            gap: 12px;
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
            flex: 1;
        }

        .days-row {
            margin-top: 12px;
            padding-top: 12px;
            border-top: 1px solid #2a3a4e;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .days-count { font-size: 28px; font-weight: 700; }
        .days-count.good { color: #00c853; }
        .days-count.warning { color: #ffab00; }
        .days-count.critical { color: #ff3d3d; }
        .days-count.unknown { color: #6b7c93; }

        .days-label {
            font-size: 12px;
            color: #6b7c93;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }

        .footer { text-align: center; margin-top: 6px; width: 100%; }

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

        .refresh-btn:hover { background: #3d5a80; color: #ffffff; }

        @media (max-width: 768px) {
            body { padding: 15px; }
            .card-header { flex-direction: column; align-items: flex-start; }
            .card-header .host { width: 100%; }
            .cert-row { flex-direction: column; }
            .cert-row .lbl { width: auto; }
        }
    </style>
    <script>
        function updateTime() {
            const now = new Date();
            const el = document.getElementById("datetime");
            if (el) el.innerText = now.toUTCString();
        }
        setInterval(updateTime, 1000);
        window.onload = updateTime;
    </script>
</head>
<body>

<div class="page">
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

    <div class="card-wrap">
        <div class="card">
            <div class="card-header">
                <h2><?php echo htmlspecialchars($server["label"]); ?></h2>
                <span class="host"><?php echo htmlspecialchars($server["url"]); ?></span>
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
    </div>

    <div class="footer">
        <button class="refresh-btn" onclick="location.reload();">↻ Refresh</button>
    </div>
</div>

</body>
</html>