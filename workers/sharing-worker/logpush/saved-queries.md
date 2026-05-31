# Sharing Worker — Cloudflare Logs Saved Queries

Run these in Cloudflare dashboard → **Workers & Pages → Logs** (SQL tab) or via the Logs API.
All structured events come from `SessionRoom.ts:log()` and appear in the `Logs[*].Message` field as JSON strings.

## 1. Active sessions in the last hour

```sql
SELECT DISTINCT JSONExtractString(Logs[1].Message, 'sessionId') AS sessionId
FROM workers_trace_events
WHERE ScriptName = 'rishi-sharing-worker'
  AND JSONExtractString(Logs[1].Message, 'event') = 'session.created'
  AND toDateTime(EventTimestampMs / 1000) > now() - INTERVAL 1 HOUR
```

## 2. Peak peers per session (last 24h)

```sql
SELECT
  JSONExtractString(Logs[1].Message, 'sessionId') AS sessionId,
  countIf(JSONExtractString(Logs[1].Message, 'event') = 'peer.admitted') AS peersAdmitted
FROM workers_trace_events
WHERE ScriptName = 'rishi-sharing-worker'
  AND EventTimestampMs > toUnixTimestamp(now() - INTERVAL 24 HOUR) * 1000
GROUP BY sessionId
ORDER BY peersAdmitted DESC
LIMIT 20
```

## 3. Session ends with reason (last 7 days)

```sql
SELECT
  JSONExtractString(Logs[1].Message, 'sessionId') AS sessionId,
  JSONExtractString(Logs[1].Message, 'reason') AS reason,
  toDateTime(EventTimestampMs / 1000) AS endedAt
FROM workers_trace_events
WHERE ScriptName = 'rishi-sharing-worker'
  AND JSONExtractString(Logs[1].Message, 'event') = 'session.ended'
  AND toDateTime(EventTimestampMs / 1000) > now() - INTERVAL 7 DAY
ORDER BY EventTimestampMs DESC
LIMIT 100
```

## 4. Worker error rate per 5-minute window (last 6h)

```sql
SELECT
  toStartOfFiveMinutes(toDateTime(EventTimestampMs / 1000)) AS window,
  countIf(Outcome = 'exception') AS errors,
  count() AS total,
  round(countIf(Outcome = 'exception') / count() * 100, 2) AS errorPct
FROM workers_trace_events
WHERE ScriptName = 'rishi-sharing-worker'
  AND toDateTime(EventTimestampMs / 1000) > now() - INTERVAL 6 HOUR
GROUP BY window
ORDER BY window DESC
```

## 5. Peer approval queue activity (last 24h)

```sql
SELECT
  JSONExtractString(Logs[1].Message, 'sessionId') AS sessionId,
  JSONExtractString(Logs[1].Message, 'event') AS event,
  JSONExtractString(Logs[1].Message, 'userId') AS userId,
  toDateTime(EventTimestampMs / 1000) AS ts
FROM workers_trace_events
WHERE ScriptName = 'rishi-sharing-worker'
  AND JSONExtractString(Logs[1].Message, 'event') IN ('peer.queued', 'peer.admitted', 'peer.rejected')
  AND toDateTime(EventTimestampMs / 1000) > now() - INTERVAL 24 HOUR
ORDER BY EventTimestampMs DESC
```

## Alerts to set up in Cloudflare Notifications

Navigate to **Account Home → Notifications → Add Notification → Workers**:

1. **5xx rate spike**: Metric = `Error rate`, threshold > 1%, evaluation window = 5 min, channel = email (matovu90@gmail.com).
2. **CPU overrun**: Metric = `CPU time P99 > 50ms`, sustained 5 min, channel = email.
3. **`session.ended reason=error` spike**: Cloudflare does not support log-content alerts natively. Post-v1 mitigation: a scheduled Cron Worker reads recent Logpush objects from R2, counts `reason=error` entries, and posts to a Slack/email webhook if count > 3 in a 10-minute window.
