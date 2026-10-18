# CallerRecon v1.7 — Amazon Linux 2023 EC2 deployment

This package contains **the complete CallerRecon v1.7 application** and an Amazon Linux 2023 deployment kit. It provides Gunicorn, Nginx HTTPS with initial self-signed TLS, HTTP Basic authentication, systemd, a dedicated unprivileged account, encrypted S3 backup tooling, and IAM guidance.

**Security scope:** Private single-user/small-team deployment. This is not a fully audited multi-user SaaS deployment. HTTP Basic auth is a perimeter control; CallerRecon itself has no granular application authorization. Do not publish this service directly to the Internet. Prefer private subnet, AWS Systems Manager (SSM), or a VPN. Calls and evidence may contain sensitive personal data.

## Quick start (EC2)

1. Launch Amazon Linux 2023 x86_64 EC2, suggested t3.large, 50 GiB gp3 encrypted EBS. Assign an IAM instance profile with `AmazonSSMManagedInstanceCore` plus a separate least-privilege S3/KMS backup policy if backups are enabled. Use a **private subnet** with access to required AWS services and installation repositories through NAT or appropriate VPC endpoints. Do not assume all dnf/PyPI dependencies are available through VPC endpoints alone.
2. Security group: **no inbound rules** for SSM-only deployment; outbound TCP 443 to required endpoints. If using VPN-based HTTPS access, allow inbound TCP 443 **only from your VPN CIDR**, never 0.0.0.0/0. No inbound SSH/5050 required. EC2 Instance Connect or SSM should be used for administration.
3. Copy/extract this bundle to the EC2 host, e.g. `/tmp/callerrecon-deploy`, then:

   ```bash
   cd /tmp/callerrecon-deploy
   sudo bash scripts/install.sh "$PWD/spam-caller-recon-v1.7.zip"
   sudo systemctl status callerrecon nginx --no-pager
   curl -k -I https://127.0.0.1/soc
   ```

   The installer interactively asks for the initial HTTP Basic password; run in an interactive session. It creates `/opt/callerrecon/app`, `/opt/callerrecon/venv`, `/etc/callerrecon/app.env` and systemd/Nginx configuration. Installation requires outbound access to OS repositories and PyPI.

4. Use **SSM port forwarding to remote host** or a VPN. For SSM port forwarding directly to EC2 port 443, run on your workstation (AWS CLI + Session Manager plugin installed):

   ```bash
   aws ssm start-session --target i-REPLACE --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["443"],"localPortNumber":["8443"]}'
   ```

   Visit `https://localhost:8443/soc` and authenticate as `analyst`. The initial certificate is self-signed for `callerrecon.internal` and will show a hostname/trust warning at localhost. **Do not bypass certificate warnings for normal production use.** Install a trusted private CA certificate covering your actual access hostname, distribute trust to analyst workstations, or configure an appropriate trusted TLS endpoint. The installer self-signed cert is only a bootstrap placeholder and expires after 30 days.

## TLS and authentication

- Nginx: `/etc/nginx/conf.d/callerrecon.conf`; TLS certificate/key: `/etc/nginx/callerrecon/server.crt` and `server.key`.
- Replace the certificate and key with a valid pair and run `sudo nginx -t && sudo systemctl reload nginx`.
- For a private hostname, consider ACM Private CA or your organization's CA. ACM public certificates generally cannot be directly exported for use on an EC2 Nginx server unless issued as exportable certificates; alternatively terminate TLS at an ALB (with additional access controls).
- Rotate Basic auth password: `sudo htpasswd /etc/nginx/callerrecon/users analyst` then `sudo systemctl reload nginx`.
- Flask secret is randomly generated in `/etc/callerrecon/app.env` (0600); keep it private. Gunicorn binds to 127.0.0.1:5050, not the network interface.
- Enable secure logging and retention policies according to your organization's needs. Protect the database, recordings, and backup archives.

## S3 + KMS encrypted backups

1. Create a **private S3 bucket** with Block Public Access, bucket versioning, default SSE-KMS encryption, and lifecycle retention suitable for your legal/evidence requirements. Create or select a customer-managed KMS key and allow the EC2 role to use it. Backups may be immutable under S3 Object Lock if you need retention enforcement; configure Object Lock when creating the bucket.
2. Attach `iam/instance-policy.json` to the EC2 instance role after replacing `REPLACE_BUCKET` and `REPLACE_KMS_KEY_ARN`. This is an example minimum for backup upload; tighten KMS policy, resource conditions, and organization guardrails as needed. Also attach AWS managed `AmazonSSMManagedInstanceCore` for Session Manager. Do not store AWS keys on the VM.
3. Install backup script and timer:

   ```bash
   sudo install -m 0750 scripts/backup.sh /usr/local/sbin/callerrecon-backup
   sudo install -m 0644 config/callerrecon-backup.service /etc/systemd/system/
   sudo install -m 0644 config/callerrecon-backup.timer /etc/systemd/system/
   sudo bash -c 'cat > /etc/callerrecon/backup.env <<EOF2
   S3_BUCKET=REPLACE_BUCKET
   KMS_KEY_ARN=REPLACE_KMS_KEY_ARN
   EOF2'
   sudo chmod 0600 /etc/callerrecon/backup.env
   sudo systemctl daemon-reload
   sudo systemctl enable --now callerrecon-backup.timer
   sudo systemctl start callerrecon-backup.service
   sudo journalctl -u callerrecon-backup -n 30 --no-pager
   ```

   The backup runs daily near 03:15 UTC with a randomized delay. It uses the SQLite online backup API, copies evidence files, creates SHA-256 checksums, and uploads a tar.gz using S3 SSE-KMS. **Evidence files may change during copying; for strict point-in-time consistency stop the app or use filesystem snapshots and confirm custody requirements.** Backup archives are encrypted in S3 but not independently client-side encrypted.

4. **Restore drill**: stop CallerRecon; download the chosen S3 object using an authorized recovery role; unpack in an isolated directory; run `sha256sum -c SHA256SUMS`; copy `investigations.db` and `evidence_files` to `/opt/callerrecon/app`; `chown -R callerrecon:callerrecon /opt/callerrecon/app`; start the service; validate `/soc` and sample case integrity. Do not overwrite live data without a separately verified backup. Document the recovery event.

## Upgrade from an earlier version

Before installing over an existing deployment, stop `callerrecon` and back up `investigations.db` and `evidence_files/`. The installer copies v1.7 application files into the app directory and preserves any files not in the archive. **Do not blindly overwrite an existing deployment without a maintenance window and rollback plan.**

## Operations

```bash
sudo systemctl status callerrecon nginx
sudo journalctl -u callerrecon -f
sudo nginx -t
sudo systemctl restart callerrecon
sudo systemctl list-timers callerrecon-backup.timer
```

## Validation and limitations

Deployment scripts were checked with `bash -n`; Python application syntax can be checked using `python3.11 -m compileall /opt/callerrecon/app`. **The EC2 installation, Nginx, IAM permissions, and application behavior have not been end-to-end tested on an actual EC2 instance.** Test in a nonproduction environment first. Verify available AL2023 package names, outbound connectivity, certificate handling, SELinux configuration, and access paths for your account.
