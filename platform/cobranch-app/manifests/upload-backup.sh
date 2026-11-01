#!/bin/sh
# Uploads the dump that the CronJob's first container wrote to $BACKUP_FILE into bucket $BUCKET, named by the time it
# finished, as ServiceAccount cobranch-backup, whose Google token comes from GKE's metadata server. The grant only
# creates objects, and x-goog-if-generation-match: 0 refuses to replace one, so a run can't touch an earlier dump.
set -eu

token="$(curl -fsS -H 'Metadata-Flavor: Google' \
  'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' |
  sed -n 's/.*"access_token" *: *"\([^"]*\)".*/\1/p')"
if [ -z "$token" ]; then
  echo "The metadata server gave no access token" >&2
  exit 1
fi

name="cobranch-$(date -u +%Y-%m-%dT%H%M%SZ).dump"
curl -fsS --upload-file "$BACKUP_FILE" \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/octet-stream' \
  -H 'x-goog-if-generation-match: 0' \
  "https://storage.googleapis.com/$BUCKET/$name"
echo "Uploaded $(wc -c <"$BACKUP_FILE") bytes to gs://$BUCKET/$name"
