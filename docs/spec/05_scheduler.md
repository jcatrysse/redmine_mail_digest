# Scheduler and Rake Task Specification — redmine_mail_digest

## 1. Rake Task Overview

### Namespace and task names

```
namespace :redmine do
  namespace :issue_digest do
    task :send    # Main delivery task
    task :cleanup # Prune old run records
  end
end
```

### File location

`plugins/redmine_mail_digest/lib/tasks/issue_digest.rake`

---

## 2. Main Task: `redmine:issue_digest:send`

### 2.1 Purpose

Find all active, due digest rules; resolve recipients; apply issue filters;
generate and deliver emails; record run history.

### 2.2 Environment variables (arguments)

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `DRY_RUN` | `'1'` | — | If set, print planned sends without sending or recording |
| `PROJECT_IDENTIFIER` | string | — | Restrict execution to a specific project by identifier |
| `RULE_ID` | integer | — | Restrict execution to a specific digest rule by ID |
| `VERBOSE` | `'1'` | — | Enable verbose output (rule names, recipient counts, issue counts) |
| `FORCE` | `'1'` | — | Ignore schedule_key idempotency check (re-send even if already sent in window) |
| `MANUAL` | `'1'` | — | Manual one-off mode. Without `RULE_ID`, only active `schedule_type=manual` rules are processed. With `RULE_ID`, that rule is processed manually regardless of schedule type. Sets `trigger: 'manual'` in the run record and bypasses schedule-window idempotency. |

### 2.3 Usage examples

```bash
# Standard cron invocation
bundle exec rake redmine:issue_digest:send RAILS_ENV=production

# Dry-run: see what would be sent
bundle exec rake redmine:issue_digest:send DRY_RUN=1 RAILS_ENV=production

# Limit to one project
bundle exec rake redmine:issue_digest:send PROJECT_IDENTIFIER=my-project RAILS_ENV=production

# Process a single rule by ID
bundle exec rake redmine:issue_digest:send RULE_ID=42 RAILS_ENV=production

# Verbose output
bundle exec rake redmine:issue_digest:send VERBOSE=1 RAILS_ENV=production

# Force re-send (ignore idempotency guard)
bundle exec rake redmine:issue_digest:send RULE_ID=42 FORCE=1 RAILS_ENV=production

# Manual one-off send for a specific rule
bundle exec rake redmine:issue_digest:send RULE_ID=42 MANUAL=1 RAILS_ENV=production

# Manual one-off send for all active manual schedule_type rules
bundle exec rake redmine:issue_digest:send MANUAL=1 RAILS_ENV=production

# Combined
bundle exec rake redmine:issue_digest:send DRY_RUN=1 VERBOSE=1 RAILS_ENV=production
```

---

## 3. Task Execution Flow

```
rake redmine:issue_digest:send
  1. Parse ENV vars: dry_run, project_identifier, rule_id, verbose, force
  2. Log: "[IssueDigest] Starting at #{Time.current.utc.iso8601}"
  3. Acquire lock: IssueDigest::LockManager.with_lock do
     a. Query due rules:
        - Load IssueDigestRule records
        - JOIN projects WHERE projects.status != STATUS_ARCHIVED
        - WHERE active = true
        - IF project_identifier: WHERE projects.identifier = ENV['PROJECT_IDENTIFIER']
        - IF rule_id: WHERE issue_digest_rules.id = ENV['RULE_ID']
        - Evaluate each rule with ScheduleEvaluator (or skip if FORCE=1)
     b. For each due rule:
        - Log: "[IssueDigest] Processing rule ##{rule.id}: #{rule.name}"
        - IF DRY_RUN: call DigestSender.new(rule, dry_run: true).send; print summary; next
        - ELSE: call DigestSender.new(rule, dry_run: false).send
        - Log run result
     c. Log: "[IssueDigest] Finished. Rules processed: N, Emails sent: M, Failures: K"
  4. IF lock not acquired:
     - Log: "[IssueDigest] Could not acquire lock; another process may be running. Exiting."
     - Exit with status 0 (not an error; just a no-op)
  5. Log: "[IssueDigest] Task completed at #{Time.current.utc.iso8601}"
```

---

## 4. Rule Selection Query

### 4.1 SQL pattern

```ruby
scope = IssueDigestRule
  .joins(:project)
  .where("#{Project.table_name}.status != ?", Project::STATUS_ARCHIVED)
  .where(active: true)
  .includes(:project, :query)

scope = scope.where("#{Project.table_name}.identifier = ?", project_identifier) if project_identifier
scope = scope.where(id: rule_id) if rule_id

rules = scope.to_a
due_rules = rules.select { |r| force || IssueDigest::ScheduleEvaluator.new(r).due? }
```

### 4.2 Due-check is done in Ruby (not SQL)

Rationale: schedule logic involves timezone conversion and date arithmetic that is
complex and DB-specific. Selecting all active rules into memory and filtering in Ruby
is safe for typical Redmine instances (expected: < 1000 rules per instance).

**Performance guard**: if `rules.count > 10_000`, log a warning and proceed (do not fail).

---

## 5. Locking Strategy

**Decision (OQ-04)**: DB advisory lock using PostgreSQL `pg_try_advisory_xact_lock`,
with a file-based fallback for MySQL/SQLite3 deployments.

### 5.1 Goal

Prevent two concurrent rake processes from sending the same digests twice.

### 5.2 PostgreSQL advisory lock (primary strategy)

```ruby
# IssueDigest::LockManager
LOCK_KEY = 'issue_digest_send'.bytes.sum  # deterministic integer key

def self.with_lock(&block)
  ActiveRecord::Base.connection.transaction do
    acquired = ActiveRecord::Base.connection.execute(
      "SELECT pg_try_advisory_xact_lock(#{LOCK_KEY})"
    ).first['pg_try_advisory_xact_lock']

    if acquired
      block.call
    else
      Rails.logger.warn "[IssueDigest] Could not acquire advisory lock"
      false
    end
  end
end
```

### 5.3 File-based lock (fallback for MySQL / SQLite3)

```ruby
def self.with_lock(&block)
  lock_file = Rails.root.join('tmp', 'issue_digest.lock')
  File.open(lock_file, File::RDWR | File::CREAT, 0o644) do |f|
    if f.flock(File::LOCK_EX | File::LOCK_NB)
      begin
        block.call
      ensure
        f.flock(File::LOCK_UN)
      end
    else
      Rails.logger.warn "[IssueDigest] Could not acquire file lock"
      false
    end
  end
end
```

**Detection**: Check `ActiveRecord::Base.connection.adapter_name` at runtime to choose strategy.

### 5.4 Defense in depth: schedule_key atomic claim

Before processing each rule (even without lock), atomically claim the current scheduling window:

```ruby
evaluator    = IssueDigest::ScheduleEvaluator.new(rule, time: current_time, force: force)
schedule_key = evaluator.compute_schedule_key

claimed = IssueDigestRule
  .where(id: rule.id)
  .where("last_schedule_key IS NULL OR last_schedule_key != ?", schedule_key)
  .update_all(last_schedule_key: schedule_key, last_run_at: Time.current.utc)

next if claimed == 0  # Another process already claimed this window
```

This replaces the previous `last_run_at` window-date comparison and is more robust:
- Works correctly across all 8 schedule types without per-type date arithmetic.
- Idempotent even if the lock fails (two processes competing → first UPDATE wins).
- The `schedule_key` uniquely encodes rule + window; there is no ambiguity.

---

## 6. Idempotency Strategy

A rule fires at most once per scheduling window. The window is identified by its
`schedule_key` (see functional spec §2.5). Idempotency is achieved in order of strength:

1. **DB advisory / file lock** — prevents concurrent processes from evaluating the same rules simultaneously.
2. **Schedule key atomic claim** — even without the lock, the `UPDATE … WHERE last_schedule_key != ?` ensures only one process proceeds per window.
3. **`ScheduleEvaluator#due?` returning false** — the in-memory check in the evaluator (step 3.5) short-circuits re-evaluation if the key matches, avoiding the DB write entirely on repeated cron runs.

`FORCE=1` or `MANUAL=1` bypasses guards 2 and 3. Guard 1 (lock) always applies unless `--no-lock` is explicitly documented (not supported in v1).

---

## 7. Update Timing

**`last_schedule_key` and `last_run_at`**: updated **before** sending emails, atomically in the claim step (section 5.4).

- Rationale: if the process crashes mid-delivery, the window is considered "claimed", preventing re-sends to recipients who already received the email.
- Trade-off: recipients who had NOT yet received their email in a crashed run will miss it until the next window.
- Mitigation: `FORCE=1 RULE_ID=X` for manual recovery.

**`last_success_at`**: updated **after** all deliveries complete with status `success` or `partial_failure`.

---

## 8. What Is Logged to Rails.logger

### Log format

```
[IssueDigest] <message>
```

### Log events

| Level | Message |
|-------|---------|
| INFO | `Starting at 2026-05-27T08:00:00Z (dry_run=false, force=false)` |
| INFO | `Lock acquired` |
| INFO | `Found N due rules` |
| INFO | `Processing rule #42: "Daily open issues" (project: my-project)` |
| INFO | `Rule #42: resolved 5 recipients` |
| INFO | `Rule #42: sending to user #7 (issues: 12)` |
| INFO | `Rule #42: sent to user #7` |
| INFO | `Rule #42: completed (success, 5 emails sent, 0 failed)` |
| INFO | `Finished at 2026-05-27T08:00:03Z (3 rules, 15 emails, 0 failures)` |
| WARN | `Rule #42: query #99 not found; blocking delivery` |
| WARN | `Rule #42: no recipients resolved; skipping` |
| WARN | `Rule #42: user #7 has no email address; skipping` |
| WARN | `Rule #42: user #7 is not active; skipping` |
| WARN | `Could not acquire lock; another process may be running. Exiting.` |
| ERROR | `Rule #42: delivery to user #7 failed: Net::SMTPAuthenticationError: ...` |
| ERROR | `Rule #42: issue resolution failed: <exception>` |
| ERROR | `Rule #42: invalid schedule_config; skipping` |

**PII policy**: No email addresses, usernames, issue subjects, or personal data in logs.
Log only IDs.

---

## 9. What Is Stored in the Database

For each rule execution:

1. `issue_digest_runs` row created at start with `status: 'running'`.
2. Per-recipient `issue_digest_deliveries` rows created as deliveries complete.
3. `issue_digest_runs` row updated at end with final status, counts, timestamps.
4. `issue_digest_rules.last_run_at` updated before sending.
5. `issue_digest_rules.last_success_at` updated if any delivery succeeded.

**Dry-run mode**: Nothing is stored. No DB writes. Output to STDOUT only.

---

## 10. Exit Codes

The rake task does not set a custom exit code. Standard rake behavior:

| Scenario | Exit code |
|----------|-----------|
| All rules processed (success or partial failure) | 0 |
| Lock not acquired | 0 (graceful) |
| No due rules found | 0 |
| Unhandled exception in task setup | 1 (rake default) |

**Rationale**: Cron monitors log output and DB history, not exit codes. A non-zero exit
from cron triggers alerts for infrastructure issues, not digest-level failures.
If strict exit code control is needed, document as an enhancement.

---

## 11. Cleanup Task: `redmine:issue_digest:cleanup`

### Purpose
Prune old run and delivery records according to the retention policy.

### Behavior

```ruby
retention_days = Setting.plugin_redmine_mail_digest['run_history_retention_days'].to_i
cutoff = retention_days.days.ago

IssueDigestRun
  .where("started_at < ?", cutoff)
  .destroy_all  # cascade destroys deliveries
```

### Usage

```bash
bundle exec rake redmine:issue_digest:cleanup RAILS_ENV=production
```

### Logging

```
[IssueDigest] Cleanup: deleting runs older than 90 days
[IssueDigest] Cleanup: deleted 42 runs, 387 deliveries
```

---

## 12. Recommended Cron Configuration

### Every 15 minutes (recommended for minute-granularity scheduling)

```cron
*/15 * * * * cd /path/to/redmine && bundle exec rake redmine:issue_digest:send RAILS_ENV=production >> log/issue_digest.log 2>&1
```

### Hourly (simpler; digest send times rounded to nearest hour)

```cron
0 * * * * cd /path/to/redmine && bundle exec rake redmine:issue_digest:send RAILS_ENV=production >> log/issue_digest.log 2>&1
```

### Daily cleanup at midnight

```cron
0 0 * * * cd /path/to/redmine && bundle exec rake redmine:issue_digest:cleanup RAILS_ENV=production >> log/issue_digest.log 2>&1
```

### With bundler and RVM example

```cron
*/15 * * * * cd /path/to/redmine && /usr/local/rvm/bin/rvm default do bundle exec rake redmine:issue_digest:send RAILS_ENV=production >> log/issue_digest.log 2>&1
```

---

## 13. DigestSender Execution Detail

```
DigestSender.new(rule, dry_run: false).send
  1. recorder = RunRecorder.new(rule, trigger: :scheduled)
  2. recorder.start  → creates IssueDigestRun(status: 'running')
  3. Update rule.last_run_at = Time.current.utc (atomic)
  4. Resolve candidates scope (for assignee/watcher mode): IssueResolver.new(rule, user: nil).base_scope
  5. recipients = RecipientResolver.new(rule, issues_scope: candidates).resolve
  6. If recipients.empty?
     recorder.finish(:skipped, recipients_count: 0)
     return
  7. For each user in recipients:
     a. issues = IssueResolver.new(rule, user: user).resolve.limit(max_issues_per_email)
     b. If issues.empty? && !rule.send_empty?
        recorder.record_delivery(user, :skipped, issues_count: 0)
        next
     c. grouped_issues = group_issues(issues, rule.group_by)
     d. IF dry_run:
        puts "  [DRY_RUN] Would send #{issues.count} issues to user ##{user.id}"
        next
     e. begin
          IssueDigestMailer.digest_email(rule, user, issues, grouped_issues).deliver_now
          recorder.record_delivery(user, :sent, issues_count: issues.count, sent_at: Time.current)
        rescue => e
          Rails.logger.error "[IssueDigest] Rule ##{rule.id}: delivery to user ##{user.id} failed: #{e.class}: #{e.message.truncate(200)}"
          recorder.record_delivery(user, :failed, error_message: e.message.truncate(2000))
        end
  8. final_status = compute_final_status(deliveries)
  9. recorder.finish(final_status, recipients_count: recipients.count, emails_sent_count: ..., ...)
  10. Update rule.last_success_at = Time.current.utc if final_status in [:success, :partial_failure]
  11. return run record
```

---

## 14. Error Escalation Table

| Error | Scope | Recovery | Run status |
|-------|-------|---------|------------|
| Lock not acquired | Entire task | Graceful exit | N/A (no run created) |
| Project archived | Rule | Skip rule | No run created |
| Rule inactive | Rule | Skip rule | No run created |
| Invalid schedule_config | Rule | Skip; log error | error |
| RecipientResolver exception | Rule | Skip; log error | error |
| IssueResolver exception | Recipient | Skip recipient | partial_failure / failed |
| SMTP exception | Recipient | Record failure; continue | partial_failure / failed |
| DB exception recording run | Rule | Log; continue other rules | best-effort |
| Unhandled exception | Task | Let rake propagate | (no records) |
