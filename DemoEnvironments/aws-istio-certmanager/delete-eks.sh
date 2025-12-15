#!/usr/bin/env bash
set -euo pipefail

AWS_PAGER=""

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Error: '$1' is required." >&2; exit 1; }
}
require aws
require eksctl
require awk
require mktemp

# Resolve region: prefer AWS_DEFAULT_REGION, else use AWS CLI configured default
REGION="${AWS_DEFAULT_REGION:-}"
if [ -z "$REGION" ]; then
  REGION="$(aws configure get region || true)"
fi
if [ -z "$REGION" ]; then
  echo "Error: No region set. Export AWS_DEFAULT_REGION or set a default with 'aws configure'." >&2
  exit 1
fi

echo "Scanning EKS clusters in region: $REGION"
NAMES="$(aws eks list-clusters --region "$REGION" --query 'clusters[]' --output text 2>/dev/null || true)"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

for NAME in $NAMES; do
  [ -z "${NAME:-}" ] && continue
  printf "%s\t%s\n" "$NAME" "$REGION" >> "$TMP"
done

if ! [ -s "$TMP" ]; then
  echo "No EKS clusters found in region: $REGION"
  exit 0
fi

echo
echo "Found the following clusters in $REGION:"
i=1
while IFS=$'\t' read -r NAME _REGION; do
  printf " %2d) %s\n" "$i" "$NAME"
  i=$((i+1))
done < "$TMP"
echo

read -r -p "Enter the number of the cluster you want to delete: " SEL
case "$SEL" in
  (''|*[!0-9]*) echo "Invalid selection."; exit 1;;
esac

TOTAL="$(wc -l < "$TMP" | tr -d ' ')"
if [ "$SEL" -lt 1 ] || [ "$SEL" -gt "$TOTAL" ]; then
  echo "Selection out of range."; exit 1
fi

CLUSTER="$(awk -v n="$SEL" 'NR==n{print $1}' "$TMP")"

echo
echo "You chose: $CLUSTER (region: $REGION)"
read -r -p "Type the cluster name ('$CLUSTER') to confirm deletion: " CONFIRM
if [ "$CONFIRM" != "$CLUSTER" ]; then
  echo "Confirmation did not match. Aborting."
  exit 1
fi

echo
echo "Deleting EKS cluster '$CLUSTER' in region '$REGION'..."
eksctl delete cluster \
  --name "$CLUSTER" \
  --region "$REGION" \
  --disable-nodegroup-eviction \
  --wait

echo "Done. (CloudFormation deletions may continue in the background.)"