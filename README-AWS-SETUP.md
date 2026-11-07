# Blue-Green automatic rollback bundle

## Behavior
- Checks production `/health` every 30 seconds using HTTP success status only.
- Declares an incident after 3 consecutive failed checks (usually around 60-90 seconds from the first failure).
- Sends an SNS email, then attempts the existing `rollback-app.sh` once per incident.
- Sends an immediate result email and repeats an unresolved-incident email every 600 seconds.
- Sends a recovery email when the health endpoint returns a successful HTTP status again.
- It does not repeatedly flip between Blue and Green during one incident.

This is a learning-project baseline, not a production SLO monitor. It checks from the EC2 host, so it cannot detect every external-network/client-path issue. A host failure also prevents this local monitor from alerting. A future improvement is an external CloudWatch Synthetics canary/alarm.

## Files
- `.github/workflows/ci.yml`: updated CI/deploy workflow, HTTP health check, workflow concurrency.
- `.github/workflows/rollback.yml`: manual rollback workflow, shares concurrency group with deploy.
- `scripts/deploy-blue-green.sh`: user's existing reviewed deployment script.
- `scripts/rollback-app.sh`: user's existing reviewed rollback script.
- `scripts/monitor-production.sh`: new monitor and automatic rollback controller.
- `install-monitor.sh`: installs and enables the monitor service on EC2.

## AWS setup
1. Reuse your existing SNS topic `cicd-demo-alerts` in `ap-southeast-2`; do not create a duplicate.
2. Your email subscription is already confirmed.
3. Your EC2 instance role already has the SNS publish permission for this topic. Do not add a duplicate policy unless the ARN changes:
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Action": "sns:Publish",
       "Resource": "arn:aws:sns:ap-southeast-2:ACCOUNT_ID:blue-green-alerts"
     }]
   }
   Replace ACCOUNT_ID and region/topic ARN with your actual values. Do not put AWS access keys on EC2.
4. Copy this bundle to the EC2 host (or commit it and deliver the two scripts through SSM). Install AWS CLI v2 if absent; the EC2 instance role must be available to it.
5. On EC2, from the extracted bundle directory, run:
   `sudo SNS_TOPIC_ARN='arn:aws:sns:ap-southeast-2:886576333122:cicd-demo-alerts' AWS_REGION='ap-southeast-2' bash install-monitor.sh`
6. Check:
   `sudo systemctl status blue-green-monitor`
   `sudo journalctl -u blue-green-monitor -f`
   The monitor's own log is `/home/ubuntu/blue-green/monitor/monitor.log`.
7. Confirm SNS permissions by publishing a test message:
   `aws sns publish --region ap-southeast-2 --topic-arn 'YOUR_TOPIC_ARN' --subject 'Blue-Green SNS test' --message 'SNS notification test'`
   Run as the EC2 instance role (for example, through SSM).

## Important caveats
- - The monitor uses the same lock as deployment and manual rollback. If a deployment is running when the failure threshold is reached, the monitor retries rollback up to five times, waiting five seconds between attempts when the lock is busy. If rollback still cannot complete, the monitor logs the failure and sends a critical alert. Test deployment/monitor race conditions before relying on automatic rollback.

- Deployment, rollback, and monitoring do not inspect `/app.txt` or compare response bodies. They check HTTP status from `/health` and record image IDs/digests as release identity. The current `/health` is static Nginx content, so it verifies HTTP serving only—not application dependencies.
- A local EC2 monitor cannot notify you if EC2 itself is stopped, unreachable, or the monitor process cannot run. For that, add an external CloudWatch alarm/Synthetics canary and SNS.
- A health endpoint should reflect the critical dependencies your app requires. A static `/health` file only proves Nginx can serve a file; it does not prove downstream application dependencies work.
- Verify behavior in a controlled test before relying on it. Do not simulate an outage on a production-critical service.


## Response-independent checks

Deployment, rollback, and monitoring validate successful HTTP status codes from `/health`; they do not compare `/app.txt` or any response body to a hardcoded string. Release identity is tracked using immutable Docker image IDs/digests. The current `/health` endpoint in this learning image is a static Nginx file, so it verifies HTTP serving, not application dependencies or business logic. For a real application, implement a meaningful readiness endpoint.
