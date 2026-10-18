#!/usr/bin/env bash
set -euo pipefail
source /etc/callerrecon/backup.env
: "${S3_BUCKET:?Set S3_BUCKET}" "${KMS_KEY_ARN:?Set KMS_KEY_ARN}"
DATE=$(date -u +%Y%m%dT%H%M%SZ)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# SQLite online backup provides a consistent database snapshot while application is running.
python3.11 - "$WORK/investigations.db" <<'PY'
import sqlite3,sys
src=sqlite3.connect('file:/opt/callerrecon/app/investigations.db?mode=ro',uri=True)
dst=sqlite3.connect(sys.argv[1]); src.backup(dst); dst.close(); src.close()
PY
if [[ -d /opt/callerrecon/app/evidence_files ]]; then cp -a /opt/callerrecon/app/evidence_files "$WORK/"; fi
(cd "$WORK" && find . -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
tar -C "$WORK" -czf "$WORK/callerrecon-${DATE}.tar.gz" investigations.db SHA256SUMS $( [[ -d "$WORK/evidence_files" ]] && echo evidence_files )
aws s3 cp "$WORK/callerrecon-${DATE}.tar.gz" "s3://${S3_BUCKET}/callerrecon/${DATE}.tar.gz" --sse aws:kms --sse-kms-key-id "$KMS_KEY_ARN" --no-progress
printf 'Backup uploaded: %s\n' "$DATE"
