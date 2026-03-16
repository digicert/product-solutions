#!/bin/bash
# radius_cert_test.sh
# Wrapper for eapol_test that displays only key certificate and authentication details
#
# Usage: ./radius_cert_test.sh <radius_server_ip> <port> <shared_secret> [local_ip] [config_file]
# Example: ./radius_cert_test.sh 10.160.184.104 1645 Pwosd2003
# Example: ./radius_cert_test.sh 10.160.184.104 1645 Pwosd2003 10.160.115.190

RADIUS_IP="${1:?Usage: $0 <radius_ip> <port> <shared_secret> [local_ip] [config_file]}"
RADIUS_PORT="${2:?Usage: $0 <radius_ip> <port> <shared_secret> [local_ip] [config_file]}"
SHARED_SECRET="${3:?Usage: $0 <radius_ip> <port> <shared_secret> [local_ip] [config_file]}"
LOCAL_IP="${4:-}"
CONFIG_FILE="${5:-eapol_test.conf}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file '$CONFIG_FILE' not found."
    exit 1
fi

echo "=============================================="
echo " NPS RADIUS Certificate Verification Test"
echo "=============================================="
echo " Server:  $RADIUS_IP:$RADIUS_PORT"
[ -n "$LOCAL_IP" ] && echo " Local:   $LOCAL_IP"
echo " Config:  $CONFIG_FILE"
echo " Time:    $(date)"
echo "=============================================="
echo ""

# Build eapol_test command
CMD="eapol_test -c $CONFIG_FILE -a $RADIUS_IP -p $RADIUS_PORT -s $SHARED_SECRET -t 3"
if [ -n "$LOCAL_IP" ]; then
    CMD="$CMD -A $LOCAL_IP"
fi

# Run eapol_test, capture both stdout and stderr
TMPFILE=$(mktemp)
timeout 30 $CMD > "$TMPFILE" 2>&1
EXIT_CODE=$?

OUTPUT=$(cat "$TMPFILE")
rm -f "$TMPFILE"

# --- 1. Server Certificate Details (depth=0 = leaf certificate) ---
echo "--- Server Certificate (Leaf) ---"

# Get the line number of the depth=0 certificate section
# eapol_test outputs "depth=0" for the leaf cert followed by the certificate dump
DEPTH0_LINE=$(echo "$OUTPUT" | grep -n "CTRL-EVENT-EAP-PEER-CERT depth=0" | head -1 | cut -d: -f1)

if [ -n "$DEPTH0_LINE" ]; then
    # Extract subject from the depth=0 PEER-CERT line
    LEAF_SUBJECT=$(echo "$OUTPUT" | grep -m1 "CTRL-EVENT-EAP-PEER-CERT depth=0" | sed "s/.*subject='//" | sed "s/' hash.*//")
    LEAF_HASH=$(echo "$OUTPUT" | grep -m1 "CTRL-EVENT-EAP-PEER-CERT depth=0" | sed 's/.*hash=//')
    LEAF_SAN=$(echo "$OUTPUT" | grep -m1 "CTRL-EVENT-EAP-PEER-ALT depth=0" | sed 's/.*depth=0 //')
    
    # For the validity dates and issuer, we need the certificate dump that follows depth=0
    # eapol_test prints "Peer certificate - depth 0" followed by the OpenSSL certificate text
    # Extract the block between "depth 0" and the next "depth" or end of cert section
    CERT_BLOCK=$(echo "$OUTPUT" | sed -n "/Peer certificate - depth 0/,/Peer certificate - depth [1-9]\|CTRL-EVENT/p" | head -20)
    
    LEAF_ISSUER=$(echo "$CERT_BLOCK" | grep "Issuer:" | head -1 | sed 's/^[[:space:]]*//')
    LEAF_NOT_BEFORE=$(echo "$CERT_BLOCK" | grep "Not Before" | head -1 | sed 's/^[[:space:]]*//')
    LEAF_NOT_AFTER=$(echo "$CERT_BLOCK" | grep "Not After" | head -1 | sed 's/^[[:space:]]*//')
    
    # Serial number may span two lines in OpenSSL output - extract and join
    LEAF_SERIAL=$(echo "$CERT_BLOCK" | grep -A1 "Serial Number:" | tail -1 | sed 's/^[[:space:]]*//' | tr -d ':')

    echo "  Subject: $LEAF_SUBJECT"
    [ -n "$LEAF_ISSUER" ] && echo "  $LEAF_ISSUER"
    [ -n "$LEAF_SERIAL" ] && echo "  Serial: $LEAF_SERIAL"
    [ -n "$LEAF_NOT_BEFORE" ] && echo "  $LEAF_NOT_BEFORE"
    [ -n "$LEAF_NOT_AFTER" ] && echo "  $LEAF_NOT_AFTER"
    [ -n "$LEAF_HASH" ] && echo "  Hash: $LEAF_HASH"
    [ -n "$LEAF_SAN" ] && echo "  SAN: $LEAF_SAN"
else
    # Fallback: try original method if depth=0 markers not found
    SUBJECT=$(echo "$OUTPUT" | grep -m1 "Subject:" | grep "CN=" | sed 's/^[[:space:]]*//')
    if [ -n "$SUBJECT" ]; then
        echo "  $SUBJECT"
        ISSUER=$(echo "$OUTPUT" | grep -m1 "Issuer:" | sed 's/^[[:space:]]*//')
        NOT_BEFORE=$(echo "$OUTPUT" | grep -m1 "Not Before" | sed 's/^[[:space:]]*//')
        NOT_AFTER=$(echo "$OUTPUT" | grep -m1 "Not After" | sed 's/^[[:space:]]*//')
        [ -n "$ISSUER" ] && echo "  $ISSUER"
        [ -n "$NOT_BEFORE" ] && echo "  $NOT_BEFORE"
        [ -n "$NOT_AFTER" ] && echo "  $NOT_AFTER"
    else
        echo "  No certificate details found in output."
    fi
fi

echo ""

# --- 2. Certificate Chain ---
CHAIN_DEPTH=$(echo "$OUTPUT" | grep -c "CTRL-EVENT-EAP-PEER-CERT depth=")
if [ "$CHAIN_DEPTH" -gt 1 ]; then
    echo "--- Certificate Chain ---"
    echo "$OUTPUT" | grep "CTRL-EVENT-EAP-PEER-CERT depth=" | while read -r line; do
        DEPTH=$(echo "$line" | sed 's/.*depth=//' | sed 's/ .*//')
        SUBJ=$(echo "$line" | sed "s/.*subject='//" | sed "s/' hash.*//")
        echo "  [$DEPTH] $SUBJ"
    done
    echo ""
fi

# --- 3. Certificate Verification ---
echo "--- Certificate Verification ---"

if echo "$OUTPUT" | grep -q "remote certificate verification.*success"; then
    echo "  Result: PASSED (certificate trusted)"
elif echo "$OUTPUT" | grep -q "remote certificate verification"; then
    REASON=$(echo "$OUTPUT" | grep "tls_verify_cb" | grep "preverify_ok=0" | head -1 | sed 's/.*err=[0-9]* (\(.*\)).*/\1/')
    echo "  Result: FAILED ($REASON)"
else
    echo "  Result: No verification result found"
fi

echo ""

# --- 4. EAP/PEAP Authentication ---
echo "--- PEAP Authentication ---"

TLS_VER=$(echo "$OUTPUT" | grep "Using TLS version" | tail -1 | sed 's/.*Using //')
[ -n "$TLS_VER" ] && echo "  $TLS_VER"

if echo "$OUTPUT" | grep -q "EAP-MSCHAPV2: Authentication succeeded"; then
    echo "  MSCHAPv2: Succeeded"
elif echo "$OUTPUT" | grep -qi "EAP-MSCHAPV2.*fail"; then
    echo "  MSCHAPv2: Failed"
else
    echo "  MSCHAPv2: No result"
fi

echo ""

# --- 5. RADIUS Result ---
echo "--- RADIUS Result ---"

if echo "$OUTPUT" | grep -q "CTRL-EVENT-EAP-SUCCESS"; then
    echo "  Response: Access-Accept"
    echo "  EAP: Authentication completed successfully"
    echo ""
    echo "  *** RESULT: SUCCESS ***"
elif echo "$OUTPUT" | grep -q "^SUCCESS"; then
    echo "  Response: Access-Accept"
    echo "  EAP: Authentication completed successfully"
    echo ""
    echo "  *** RESULT: SUCCESS ***"
elif echo "$OUTPUT" | grep -q "CTRL-EVENT-EAP-FAILURE"; then
    echo "  Response: Access-Reject"
    echo "  EAP: Authentication failed"
    echo ""
    echo "  *** RESULT: FAILED ***"
elif echo "$OUTPUT" | grep -q "^FAILURE"; then
    echo "  Response: Authentication failed"
    echo ""
    echo "  *** RESULT: FAILED ***"
else
    echo "  Response: No definitive result (timeout or error)"
    echo ""
    echo "  *** RESULT: INCONCLUSIVE ***"
fi

echo ""
echo "=============================================="

exit $EXIT_CODE