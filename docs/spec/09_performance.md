# Performance Specification — redmine_digest

## 1. Expected Query Patterns

The rake task execution path is the primary performance concern. There is no per-request
performance sensitivity (the UI is low-traffic and non-critical-path).

### 1.1 Rake task query sequence (per invocation)

1. Load all active rules with project + enabled_modules JOIN (one query, all rules).
2. Filter due rules in Ruby (ScheduleEvaluator, no DB hit).
3. For each due rule:
   a. Atomic `UPDATE` on the rule (`last_run_at`, one query per rule).
   b. Resolve base issue scope for candidate recipients (one query if assignee/watcher mode).
   c. Resolve recipients (one to three queries per mode).
   d. For each recipient:
      - Resolve visible issues (one query).
      - Generate email (no DB query; view rendering).
      - Send email (SMTP call; network I/O).
      - Record delivery (one INSERT).
   e. Update run record (one UPDATE).

---

## 2. N+1 Query Prevention

### 2.1 Rule loading

Load all rules with associations in one query:

```ruby
IssueDigestRule
  .includes(:project, :query)
  .joins(:project)
  .joins("JOIN enabled_modules ON enabled_modules.project_id = projects.id AND enabled_modules.name = 'issue_digest'")
  .where(active: true)
  .where("projects.status != ?", Project::STATUS_ARCHIVED)
```

Do NOT: `rule.project` inside a loop without eager loading.

### 2.2 Issue loading per recipient

When loading issues for a recipient, use `includes` to preload associations that will
be rendered in the email:

```ruby
IssueResolver.new(rule, user: user).resolve
  .includes(:tracker, :status, :priority, :assigned_to, :fixed_version, :category)
  .limit(max_issues_per_email)
```

This avoids N+1 when rendering the issue table (each row accesses tracker.name, status.name, etc.).

### 2.3 Recipient resolution: assignee mode

Do NOT: load all matching issues into memory, then extract assignees.

```ruby
# BAD: loads all issues
issues.map(&:assigned_to).uniq

# GOOD: single subquery
User.active
  .joins("JOIN issues ON issues.assigned_to_id = users.id")
  .where(issues: { project_id: rule.project_id })
  .where(base_issue_conditions)
  .distinct
```

### 2.4 Recipient resolution: watcher mode

```ruby
# GOOD: join through watchers
User.active
  .joins("JOIN watchers ON watchers.user_id = users.id")
  .joins("JOIN issues ON issues.id = watchers.watchable_id AND watchers.watchable_type = 'Issue'")
  .where(issues: { project_id: rule.project_id })
  .where(base_issue_conditions)
  .distinct
```

---

## 3. Batching Strategy for Large Projects

### 3.1 Recipient batching

If a project has a large number of potential recipients (e.g., 500+), process in batches:

```ruby
RecipientResolver.new(rule, ...).resolve.each_slice(DELIVERY_BATCH_SIZE) do |batch|
  batch.each do |user|
    # process
  end
end
```

`DELIVERY_BATCH_SIZE` = 50 (configurable constant; not exposed in UI for v1).

### 3.2 Issue scope: use relation, not array

Always pass `ActiveRecord::Relation` to the mailer and render it lazily:
- Use `.to_a` only at the point of rendering (in the view).
- Do not `.to_a` in the service before passing to the mailer.

### 3.3 Large number of rules

Expected scale: < 100 rules per Redmine instance (most instances: 5–20).
At 1000+ rules, the in-memory schedule evaluation would need DB-side scheduling logic.
For v1, document a soft limit: "Performance untested above 500 active rules."

---

## 4. Limits and Guardrails

### 4.1 Maximum issues per email (hard cap)

```ruby
MAX_ISSUES_PER_EMAIL = Setting.plugin_redmine_digest['max_issues_per_email'].to_i.clamp(1, 5000)
# Default: 500
```

Applied in `IssueResolver`:
```ruby
scope.limit(MAX_ISSUES_PER_EMAIL)
```

When the limit is hit, the total count is computed separately and passed to the mailer
for the "Showing X of Y" message. This requires a separate `.count` query before applying
the limit — accept this as a necessary trade-off.

### 4.2 Recipient limit

No hard cap on recipients, but document: "Digests with more than 200 recipients may
cause significant SMTP load. Use role-based or specific-user recipient modes for large teams."

### 4.3 Query timeout (PostgreSQL)

Wrap `IssueResolver#resolve.to_a` in a statement timeout (optional, configurable):

```ruby
# If database supports it
ActiveRecord::Base.connection.execute("SET LOCAL statement_timeout = 30000") # 30 seconds
issues = scope.to_a
```

For v1, document this as an operational recommendation, not a code requirement.

---

## 5. Index Recommendations

All recommended indexes are specified in `04_data_model.md`. Summary:

```sql
-- Primary rake task query
INDEX ON issue_digest_rules (active, project_id, last_run_at)

-- Run history queries
INDEX ON issue_digest_runs (issue_digest_rule_id, started_at DESC)

-- Delivery queries
INDEX ON issue_digest_deliveries (issue_digest_run_id)
INDEX ON issue_digest_deliveries (user_id)

-- Existing Redmine indexes (verify presence)
-- issues.project_id, issues.assigned_to_id, issues.status_id, issues.due_date
-- These are standard Redmine indexes; do not duplicate.
```

---

## 6. Memory Usage Concerns

### 6.1 Issue objects

Each `Issue` object with associations loaded takes approximately 1–5 KB of memory.
At 500 issues per email: ~2.5 MB per recipient per rule.
For 50 concurrent recipients: ~125 MB peak.

**Mitigation**: Issues are loaded once per recipient and garbage-collected after the
mailer template is rendered and the email is delivered. Do not accumulate all recipients'
issue arrays simultaneously; process sequentially (current design).

### 6.2 Rule loading

All active rules are loaded into memory at task start. For a typical instance (< 1000 rules),
this is a few MB at most. No batching needed.

### 6.3 Email rendering

ActionMailer generates the email in memory before calling `deliver_now`. For very large
digests (500 issues), the rendered email may be 300–500 KB. This is acceptable.

---

## 7. Sorting Stability

All issue queries must specify a deterministic ORDER BY to avoid inconsistent rendering:

```ruby
scope.order("#{Issue.table_name}.due_date ASC NULLS LAST, #{Issue.table_name}.id ASC")
```

For grouped queries, group-by column comes first:
```ruby
scope.order("#{group_by_column} ASC NULLS LAST, #{Issue.table_name}.due_date ASC NULLS LAST, #{Issue.table_name}.id ASC")
```

`NULLS LAST` is PostgreSQL/SQLite syntax. For MySQL compatibility:
```ruby
scope.order(Arel.sql("ISNULL(#{Issue.table_name}.due_date) ASC, #{Issue.table_name}.due_date ASC, #{Issue.table_name}.id ASC"))
```

**Cross-DB compatibility**: Use Arel for ORDER BY with NULL handling to avoid DB-specific syntax.
Alternatively, accept PostgreSQL-style syntax only and document MySQL as "community-supported."

---

## 8. Avoiding Duplicate Queries

### 8.1 Recipient resolution and base issue scope

The base issue scope (without per-recipient personalization) is computed once per rule
and passed to `RecipientResolver` for modes that need it (`assignees`, `authors`, `watchers`):

```ruby
# In DigestSender
base_scope = IssueResolver.new(rule, user: nil).base_scope_without_visibility
# Used only for recipient resolution, not for actual delivery
recipients = RecipientResolver.new(rule, issues_scope: base_scope).resolve
```

The per-recipient scope (`Issue.visible(user)`) is computed separately per recipient.

### 8.2 Count query optimization

If `send_empty = false` (default), the mailer is not called for recipients with zero
visible issues. The count can be determined by checking `issues.loaded? ? issues.size : issues.limit(1).any?`
to avoid a full `.count` query when we just need to know "any?".

---

## 9. Large Digest Handling

### 9.1 Pagination in email

Not supported in v1. The hard cap (500 issues by default) is the pagination proxy.
Recipients with many matching issues receive the first 500, sorted by due date + ID.

### 9.2 Async delivery (future)

For very large installations, consider `deliver_later` with a background job adapter.
This is explicitly out of scope for v1 but the architecture does not prevent it:
the `DigestSender` calls `.deliver_now`; changing to `.deliver_later` requires only
changing that one line and adding a job queue.

---

## 10. Performance Test Recommendations

The following are not automated tests but operational benchmarks to run before
production deployment:

| Scenario | Expected behavior |
|----------|-----------------|
| 100 active rules, 1000 issues each, 10 recipients | Task completes in < 5 minutes |
| 500 rules, all skipped (not due) | Task completes in < 5 seconds |
| One rule, 500 issues, 200 recipients | Task completes in < 30 seconds (SMTP latency dominates) |
| Concurrent rake runs | Second run exits in < 1 second (lock not acquired) |

These benchmarks should be documented for operators; they are not part of the automated
test suite.
