# Incident response runbooks

Referenced directly from CloudWatch alarm descriptions, so an on-call engineer paged at 3am has a first step rather than a blank console.

Set these once per shell:

```bash
export ENV=prod
export CLUSTER=finzla-$ENV-cluster
export SERVICE=finzla-$ENV-app
export LOG_GROUP=/ecs/finzla-$ENV/app
export TG_ARN=$(aws elbv2 describe-target-groups --names finzla-$ENV-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
```

---

## First 60 seconds, any alarm

```bash
# 1. Is the service actually serving?
curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' https://<APP_URL>/health

# 2. What does the ALB think?
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table

# 3. Did anything just deploy?
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].{desired:desiredCount,running:runningCount,taskDef:taskDefinition}'
```

**If a deployment happened in the last 30 minutes and the service is degraded, roll back first and diagnose after.** See [Rollback](#rollback).

---

## Elevated 5xx

**Alarm:** `finzla-<env>-app-5xx-rate` · CRITICAL

### Triage

```bash
# Application errors, most recent first
aws logs tail "$LOG_GROUP" --since 15m --format short | grep -i error | head -40

# Structured query
aws logs start-query --log-group-name "$LOG_GROUP" \
  --start-time $(($(date +%s) - 900)) --end-time $(date +%s) \
  --query-string 'fields @timestamp, level, msg | filter level = "ERROR" | sort @timestamp desc | limit 50'
```

Distinguish the two 5xx sources — they are different problems:

| Metric | Meaning |
|---|---|
| `HTTPCode_Target_5XX_Count` | the **application** returned 5xx |
| `HTTPCode_ELB_5XX_Count` | the **load balancer** could not get a valid response (no healthy target, timeout, connection reset) |

In the ALB access logs, `elb_status_code 503` with `target_status_code -` means no healthy target was available — the request never reached the app.

### Common causes

| Cause | Check |
|---|---|
| Bad release | correlate onset with deployment time → roll back |
| Downstream dependency | logs show connection/timeout errors to a specific host |
| Resource exhaustion | `MemoryUtilization` near 100%, `exitCode` 137 |
| Unhandled edge case in new data | errors cluster on one endpoint or one input shape |

---

## Unhealthy targets

**Alarm:** `finzla-<env>-no-healthy-targets` · CRITICAL — customer-facing outage

Full diagnostic walkthrough for the "tasks running but targets unhealthy" case is in the main [README section 9](../README.md#9-incident-investigation--503s-with-healthy-tasks). Quick version:

```bash
# The Reason field is decisive
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Desc:TargetHealth.Description}' \
  --output table

# Service events — placement and registration failures
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].events[:15].[createdAt,message]' --output table

# Why did tasks stop? stoppedReason is the single most useful field.
for T in $(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" \
    --desired-status STOPPED --query 'taskArns[:5]' --output text); do
  aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$T" \
    --query 'tasks[0].{stopCode:stopCode,reason:stoppedReason,containers:containers[].{name:name,exitCode:exitCode,reason:reason}}'
done
```

### Reading the signals

| Target health `Reason` | Means |
|---|---|
| `Target.FailedHealthChecks` | connected, `/health` returned non-200 → application-level |
| `Target.Timeout` | no response in time → slow start, or not listening on that port |
| `Target.ResponseCodeMismatch` | responded with the wrong status |
| `Target.NotRegistered` | task not in the target group — registration problem |

| Container `exitCode` | Means |
|---|---|
| 137 | SIGKILL — almost always OOM |
| 139 | segfault |
| 1 | application error on startup — read the logs |
| 255 | uncaught exception |

`CannotPullContainerError` in `stoppedReason` means an image or registry problem, not an application problem — check the tag exists and the execution role can reach ECR.

---

## High latency

**Alarm:** `finzla-<env>-latency-p99` · WARNING

Often the early warning for an outage that has not happened yet.

```bash
# Where is the time going — queue or target?
aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB \
  --metric-name TargetResponseTime --dimensions Name=LoadBalancer,Value=<alb-suffix> \
  --start-time $(date -u -d '1 hour ago' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
  --period 300 --extended-statistics p50 p99

# Saturation?
aws cloudwatch get-metric-statistics --namespace AWS/ECS \
  --metric-name CPUUtilization \
  --dimensions Name=ClusterName,Value=$CLUSTER Name=ServiceName,Value=$SERVICE \
  --start-time $(date -u -d '1 hour ago' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
  --period 300 --statistics Average Maximum

# Is autoscaling responding?
aws application-autoscaling describe-scaling-activities --service-namespace ecs \
  --resource-id "service/$CLUSTER/$SERVICE" --max-results 10
```

If `RequestCountPerTarget` is high and CPU is low, the bottleneck is concurrency or I/O rather than compute — scaling out helps, scaling up does not.

---

## Memory pressure

**Alarm:** `finzla-<env>-memory-high` · WARNING

Read the *shape* of the curve over 24 hours:

- **steady ramp, never recovering** → leak. Restarting buys time; the fix is in the code.
- **sawtooth** → tasks are being OOM-killed and restarted. Check `exitCode` 137.
- **step change after a deploy** → the new version's baseline is genuinely higher. Raise `task_memory` in Terraform.

```bash
aws cloudwatch get-metric-statistics --namespace AWS/ECS \
  --metric-name MemoryUtilization \
  --dimensions Name=ClusterName,Value=$CLUSTER Name=ServiceName,Value=$SERVICE \
  --start-time $(date -u -d '24 hours ago' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
  --period 900 --statistics Average Maximum
```

---

## Rollback

The ECS circuit breaker should handle this automatically. When it has not:

```bash
# Current and available revisions
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].taskDefinition'
aws ecs list-task-definitions --family-prefix "finzla-$ENV-app" \
  --sort DESC --max-items 5

# Capture evidence BEFORE rolling back — it destroys the failing tasks
aws logs tail "$LOG_GROUP" --since 30m > incident-logs-$(date +%FT%H%M).txt
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].events[:20]' > incident-events.json
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" > incident-targets.json

# Roll back
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --task-definition "finzla-$ENV-app:<PREVIOUS>" --force-new-deployment

aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"

# Verify what is actually live
curl -sS https://<APP_URL>/version
```

The `/version` check at the end matters — it confirms which commit is serving, rather than trusting that the rollback did what you asked.

If rollback does not resolve the incident, the release was not the cause. Check dependencies, certificate expiry, and the [AWS Health Dashboard](https://health.aws.amazon.com/health/home).

---

## Emergency access

ECS Exec is **disabled in prod** by design — a standing interactive shell into a task holding customer data is not an acceptable capability.

To enable temporarily during an incident, set `enable_execute_command = true` in `terraform/envs/prod/main.tf` and apply. Then:

```bash
aws ecs execute-command --cluster "$CLUSTER" --task <task-arn> \
  --container app --interactive --command "/bin/sh"
```

Every session is recorded in CloudTrail. **Revert the Terraform change once the incident is closed** — and note in the incident review that it was enabled, for how long, and by whom.

---

## After the incident

1. Write it up: timeline, customer impact, root cause, what was tried.
2. Add a CI check that would have caught it. This is the step that actually prevents recurrence — everything else is documentation.
3. If an alarm did not fire when it should have, fix the alarm.
4. If an alarm fired that nobody acted on, delete it or change its threshold. Noisy alarms train people to ignore the channel, which is worse than having no alarm at all.
