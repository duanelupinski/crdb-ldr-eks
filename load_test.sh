#!/bin/bash

# ── Configuration ─────────────────────────────────────────────────────────────
REGION="${1:-$REGION}"        # also used as the namespace
CONTEXT="${2:-$CONTEXT}"
SLEEP_INTERVAL=1              # seconds between inserts
DURATION=600                  # 5 minutes

# ── Validate inputs ────────────────────────────────────────────────────────────
if [ -z "$REGION" ] || [ -z "$CONTEXT" ]; then
  echo "Usage: $0 <REGION> <CONTEXT>"
  echo "  or:  REGION=east CONTEXT=my-k8s-context $0"
  exit 1
fi

# ── Find a running CockroachDB pod ─────────────────────────────────────────────
echo "🔍 Finding a CockroachDB pod in context '$CONTEXT', namespace '$REGION'..."
POD=$(kubectl --context="$CONTEXT" get pods -n "$REGION" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
  | tr ' ' '\n' \
  | grep '^cockroachdb-[0-9]' \
  | head -1)

if [ -z "$POD" ]; then
  echo "❌ No running CockroachDB pod found."
  echo "   Check: kubectl --context=$CONTEXT get pods -n $REGION"
  exit 1
fi

echo "✅ Using pod: $POD"
echo "🌎 Region/NS: $REGION"
echo "⏱  Running for $DURATION seconds (every ${SLEEP_INTERVAL}s)..."
echo "─────────────────────────────────────────────────────────────"

# ── Insert loop ────────────────────────────────────────────────────────────────
END=$((SECONDS + DURATION))
COUNT=0

while [ $SECONDS -lt $END ]; do
  kubectl --context="$CONTEXT" exec -n "$REGION" "$POD" -- \
    ./cockroach sql \
      --certs-dir=/cockroach/cockroach-certs \
      --database=mydb \
      -e "INSERT INTO mydb.public.mytable (data) VALUES ('from $REGION ' || now()::string);" \
      > /dev/null 2>&1

  COUNT=$((COUNT + 1))
  REMAINING=$((END - SECONDS))
  echo "$(date -u '+%H:%M:%S') UTC | row $COUNT inserted | ${REMAINING}s remaining"
  sleep $SLEEP_INTERVAL
done

echo "─────────────────────────────────────────────────────────────"
echo "✅ Done — $COUNT rows inserted from '$REGION' over 10 minutes"
