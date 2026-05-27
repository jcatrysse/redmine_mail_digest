# Functional Specification — redmine_digest

## 1. Digest Rule Lifecycle

```
States: draft (implicit, unsaved) → active → disabled → deleted
```

- A rule is **active** when `active = true` and `start_on` (if set) ≤ today ≤ `end_on` (if set).
- A rule is **disabled** when `active = false`. It is retained in the database.
- A rule is **expired** when `end_on < today`. It is treated as disabled; not automatically deleted.
- A rule is **pending** when `start_on > today`. It is treated as disabled.
- **Deletion** removes the rule and all associated `issue_digest_runs` and
  `issue_digest_deliveries` records (cascade).

### State transitions

| From | Event | To | Who |
|------|-------|----|-----|
| (new) | save with active=true | active | PM |
| active | edit active=false | disabled | PM |
| active | end_on passed | expired (auto) | system |
| active | start_on not yet reached | pending (auto) | system |
| disabled | edit active=true | active | PM |
| any | delete | (gone) | PM |

---

## 2. Schedule Definition

### 2.1 Schedule types

Eight `schedule_type` values are supported.

| `schedule_type` | Trigger pattern |
|-----------------|----------------|
| `daily` | Every day at `send_time` |
| `weekdays` | On selected days of the week; one or more checkboxes Mon–Sun |
| `weekly` | Every week on a single configured weekday at `send_time` |
| `monthly_date` | On day N of each month (1–28) at `send_time` |
| `monthly_last_day` | On the last calendar day of each month at `send_time` |
| `interval_days` | Every N days (e.g. every 3 days), anchored to `start_on` or rule creation date |
| `interval_weeks` | Every N weeks (e.g. every 2 weeks), anchored similarly |
| `manual` | Never triggered automatically; only via `RULE_ID=X MANUAL=1` rake invocation |

**`weekly` vs `weekdays`**: `weekly` = "every Monday" (single day). `weekdays` = "Mon, Wed, Fri every week" (multiple days). Implement both; they serve different needs.

**`monthly_date` cap**: Days 29–31 are not supported. Use `monthly_last_day` for end-of-month sends. Cap at 28 to avoid February edge cases.

**`manual`**: The rule has all configuration (recipients, filters, etc.) but the `ScheduleEvaluator` always returns `due? = false` for it. It is only executed when the operator explicitly invokes `RULE_ID=N MANUAL=1`.

### 2.2 `send_time` field

- Stored as `TIME` (DB column) representing wall-clock time in the rule's `timezone`.
- **Not** stored in UTC; it is a local-time anchor. UTC conversion happens at evaluation time.
- The rake task compares the current moment (in the rule's timezone) against `send_time`.
- Granularity: the rake task is expected to run at least every 15 minutes. The `grace_window_hours` field controls how long after `send_time` the rule remains due.

### 2.3 `schedule_config` JSON schema per type

```json
// daily
{}

// weekdays
{ "days": [1, 3, 5] }
// ISO weekday numbers: 1=Monday … 7=Sunday

// weekly
{ "day": 1 }
// 1=Monday … 7=Sunday

// monthly_date
{ "day": 15 }
// Integer 1–28

// monthly_last_day
{}
// No config required; last day is computed from current month

// interval_days
{ "every": 3 }
// Positive integer, min 1; anchor = rule.start_on or rule.created_at.to_date

// interval_weeks
{ "every": 2 }
// Positive integer, min 1

// manual
{}
```

### 2.4 Grace window

**Definition**: The time window after `send_time` during which the rule is still considered
due for that scheduling window. Controlled by `grace_window_hours` (integer, default: 4, range: 0–23).

```
rule is within grace window if:
  local_scheduled_datetime ≤ current_local_time ≤ local_scheduled_datetime + grace_window_hours
```

**Example**: `send_time = 08:00`, `grace_window_hours = 4`, `timezone = 'Europe/Brussels'`.
Rule is due between 08:00 and 12:00 local time. If the cron job runs at 12:30, the rule
is **not** due (missed). The next eligible window is tomorrow.

**`grace_window_hours = 0`**: The rule is due only within the cron resolution interval
(i.e., within ~15 minutes of `send_time`). Not recommended unless cron reliability is high.

**Rationale**: Without a grace window, any run of the rake task after `send_time` on the
correct day would trigger a send — a rule scheduled at 08:00 could send at 23:55 if the
server was overloaded. The grace window makes delivery time predictable and prevents
late-night catch-up sends.

### 2.5 Schedule key (idempotency key)

Each rule execution is identified by a **schedule_key**: a short deterministic string
encoding the rule ID and its scheduling window. If a run record already exists with this
key (and `status != 'error'`), the window is considered already processed.

Format: `"{rule_id}:{type_code}:{window_id}"`

| Schedule type | Type code | Window ID | Key example |
|--------------|-----------|-----------|-------------|
| `daily` | `D` | `YYYY-MM-DD` (local date) | `42:D:2026-05-27` |
| `weekdays` | `WD` | `YYYY-MM-DD` (local date) | `42:WD:2026-05-27` |
| `weekly` | `W` | `YYYY-Www` (ISO year-week) | `42:W:2026-W22` |
| `monthly_date` | `MD` | `YYYY-MM` | `42:MD:2026-05` |
| `monthly_last_day` | `ML` | `YYYY-MM` | `42:ML:2026-05` |
| `interval_days` | `ID` | decimal period number | `42:ID:45` |
| `interval_weeks` | `IW` | decimal period number | `42:IW:22` |
| `manual` | `M` | UTC timestamp of the rake invocation | `42:M:2026-05-27T09:00:00Z` |

**Period number** for interval types:
```ruby
anchor = rule.start_on || rule.created_at.to_date
period = ((local_date - anchor).to_i / schedule_config['every'].to_i).floor
```

The schedule_key is stored in:
- `issue_digest_rules.last_schedule_key` — the most recently claimed window (used for idempotency)
- `issue_digest_runs.schedule_key` — for audit trail and manual inspection

**Atomic claim** (replaces `last_run_at` window math):
```ruby
updated = IssueDigestRule
  .where(id: rule.id)
  .where("last_schedule_key IS NULL OR last_schedule_key != ?", schedule_key)
  .update_all(last_schedule_key: schedule_key, last_run_at: Time.current.utc)

next if updated == 0  # Window already claimed
```

`FORCE=1` or `MANUAL=1` bypasses this check (does not check `last_schedule_key`).
`FORCE=1` still updates `last_schedule_key` after processing to keep audit state consistent.

### 2.6 Business days only

`business_days_only` (boolean, default: `false`) combined with
`non_business_day_behavior` (enum, default: `'skip'`) modifies when a rule executes
if its scheduled trigger date falls on a Saturday or Sunday.

**Definition of "business day"**: Monday–Friday only. No holiday calendar in v1.

| `non_business_day_behavior` | Effect |
|----------------------------|--------|
| `skip` | That occurrence is skipped entirely; no email, no run record. |
| `previous_weekday` | The rule fires on the preceding Friday instead. |
| `next_weekday` | The rule fires on the following Monday instead. |

**Scope of `business_days_only`**:

| Schedule type | Interaction |
|--------------|-------------|
| `daily` | Sat/Sun occurrences affected by behavior setting. Equivalent to `weekdays [1,2,3,4,5]` with `skip`, but shift options are also available. |
| `weekdays` | No interaction. The PM explicitly chose the days; if they included Sat/Sun, it is intentional. |
| `weekly` | If configured weekday is Sat/Sun, applies behavior setting. |
| `monthly_date` | If day N falls on Sat/Sun in a given month, applies behavior setting. |
| `monthly_last_day` | If last day is Sat/Sun, applies behavior setting. |
| `interval_days` | If computed trigger date is Sat/Sun, applies behavior setting. |
| `interval_weeks` | If computed trigger date is Sat/Sun, applies behavior setting. |
| `manual` | Not applicable. |

**Schedule key when shifted**: The schedule_key is computed from the **original** window date
(not the shifted date). This ensures that a monthly rule shifted from Saturday to Friday
uses key `42:MD:2026-05` (not `42:D:2026-05-29`), giving exactly one send per window.

### 2.7 Catch-up behavior

**Decision**: No automatic catch-up in v1.

If the cron job was unavailable for three days:
- Only the **current window** is evaluated when the cron resumes.
- The missed windows are permanently skipped.
- No burst of catch-up emails is sent.

**Rationale**: Receiving three back-dated digest emails at once is a worse user experience
than missing them. Operators who need a catch-up can run `RULE_ID=X MANUAL=1` explicitly.

**Documentation requirement**: INSTALL.md and README.md must clearly state that if the
cron job is interrupted, digest windows will be missed without catch-up. Operators should
monitor the cron job's health.

---

## 3. Due-Check Algorithm

`IssueDigest::ScheduleEvaluator` determines whether a rule is due at the current moment.
Public interface: `due?` (boolean) and `compute_schedule_key` (string or nil).

### 3.1 Pre-conditions (fail fast, no DB/side effects)

```
Input: rule, current_time (UTC), force: false
Output: boolean

Step 1. If schedule_type == 'manual' AND force == false  → false
Step 2. If rule.active? == false                          → false
        (active? checks active flag and start_on/end_on)
Step 3. Parse schedule_config; on JSON::ParserError      → log error, return false
```

### 3.2 Timezone conversion

```ruby
tz         = rule.timezone.presence || 'UTC'
local_time = current_time.in_time_zone(tz)
local_date = local_time.to_date
```

### 3.3 Compute target trigger date

**Canonical date** per schedule type:

| Type | Canonical date condition |
|------|------------------------|
| `daily` | Always `local_date` |
| `weekdays` | `local_date.cwday` included in `config['days']` (ISO 1=Mon, 7=Sun) |
| `weekly` | `local_date.cwday == config['day']` |
| `monthly_date` | `local_date.day == config['day']` |
| `monthly_last_day` | `local_date == local_date.end_of_month` |
| `interval_days` | `((local_date - anchor).to_i % config['every'].to_i) == 0` |
| `interval_weeks` | `((local_date - anchor).to_i % (config['every'].to_i * 7)) == 0` |

Where `anchor = rule.start_on || rule.created_at.to_date`.

If canonical date condition is not met → `false`.

**Business day shift** (applied only when `rule.business_days_only? == true`):

```ruby
execution_date = if local_date.saturday? || local_date.sunday?
  case rule.non_business_day_behavior
  when 'skip'             then nil
  when 'previous_weekday' then local_date.prev_weekday
  when 'next_weekday'     then local_date.next_weekday
  end
else
  local_date
end

return false if execution_date.nil?           # 'skip' behavior
return false if execution_date != local_date  # today is not the execution date for this window
```

### 3.4 Grace window check

```ruby
send_time_today = local_date.in_time_zone(tz) + rule.send_time.seconds_since_midnight.seconds
window_open     = send_time_today
window_close    = send_time_today + rule.grace_window_hours.hours

return false if current_time < window_open    # too early
return false if current_time > window_close   # grace window expired; window missed
```

### 3.5 Schedule key idempotency check

```ruby
schedule_key = compute_schedule_key(rule, local_date, current_time)

return false if rule.last_schedule_key == schedule_key && !force
```

### 3.6 Return `true`

All checks passed. The caller then claims the window atomically:

```ruby
claimed = IssueDigestRule
  .where(id: rule.id)
  .where("last_schedule_key IS NULL OR last_schedule_key != ?", schedule_key)
  .update_all(last_schedule_key: schedule_key, last_run_at: Time.current.utc)

next if claimed == 0  # Another process beat us to this window
```

`FORCE=1` / `MANUAL=1` skips both step 3.5 and the atomic claim check.

---

## 4. Start and End Dates

- `start_on`: Optional date. If present, the rule is inactive before this date.
- `end_on`: Optional date. If present, the rule is inactive after this date.
- Expiry does not delete the rule; `active` remains `true` but the scheduler skips it.
- The UI shows a warning badge if `end_on` is in the past.

---

## 5. Duplicate Send Prevention

1. **DB advisory lock** (`IssueDigest::LockManager`): only one rake process executes at a time.
2. **Schedule key atomic claim**: each scheduling window is claimed once via `UPDATE … WHERE last_schedule_key != ?`. This is the primary idempotency guard and replaces the previous `last_run_at` window-date comparison.
3. **`last_run_at` still updated**: for display and debugging; updated alongside `last_schedule_key` in the same atomic `update_all`.

---

## 6. Recipient Resolution Rules

The `IssueDigest::RecipientResolver` service resolves the list of `User` objects
for a given rule and project.

### 6.1 Recipient modes

`recipient_modes` is a JSON array of mode strings. Multiple modes are unioned.

| Mode | Resolution |
|------|-----------|
| `project_members` | All active members of the project |
| `role:<role_id>` | Active members holding role `<role_id>` in the project |
| `assignees` | Distinct users assigned to at least one matching issue |
| `authors` | Distinct users who authored at least one matching issue |
| `watchers` | Distinct users watching at least one matching issue |
| `user:<user_id>` | Specific user by ID |

### 6.2 Exclusion rules (always applied)

- User must be active (`status = STATUS_ACTIVE`).
- User must have a valid, non-blank email address.
- User must have the `view_issues` permission in the project (checked via `User#allowed_to?`).
- User must not be anonymous.
- User must still be a member of the project (for role-based modes).

### 6.3 User removed from project mid-run

If a user was in the recipient list but is no longer a project member when the email is
about to be sent: skip that recipient and log a warning. Do not fail the entire rule.

---

## 7. Issue Filtering Rules

The `IssueDigest::IssueResolver` service applies filters and returns a scoped
`ActiveRecord::Relation` of `Issue` objects.

### 7.1 Base scope

Always starts with `Issue.visible(user).where(project: rule.project)`.

Sub-projects: included only if `include_subprojects = true` in the rule (default: false).
If true: `Issue.visible(user).where("#{Project.table_name}.lft >= ? AND #{Project.table_name}.rgt <= ?", project.lft, project.rgt)`

### 7.2 Filter application

All filters are combined with AND:

| Field | Filter condition |
|-------|-----------------|
| `include_open = true` | `status.is_closed = false` |
| `include_closed = true` | `status.is_closed = true` |
| `include_overdue = true` | `status.is_closed = false AND due_date IS NOT NULL AND due_date < CURRENT_DATE` |
| `include_due_soon = true` | `status.is_closed = false AND due_date IS NOT NULL AND due_date BETWEEN CURRENT_DATE AND CURRENT_DATE + due_soon_days` |
| `include_recently_updated = true` | `updated_on >= CURRENT_TIMESTAMP - recently_updated_days * INTERVAL '1 day'` |
| `include_recently_created = true` | `created_on >= CURRENT_TIMESTAMP - recently_created_days * INTERVAL '1 day'` |

**Open/closed combination**: If both `include_open` and `include_closed` are true, no
status filter is applied (all statuses included). If neither is true, the filter still
applies the query or other filters; the effective result may be empty.

**Overdue and due_soon**: These are subsets of open issues; they are OR-combined with
`include_open` if both are checked. Implementation: build an OR condition:
`(open_condition) OR (overdue_condition) OR (due_soon_condition)`.

### 7.3 Query integration

If `query_id` is set:
- Load the `IssueQuery` record.
- Check that the query is visible to the system user (global queries only, or queries
  belonging to the rule's project).
- Apply `query.base_scope` as an additional WHERE clause by intersecting the relation:
  `scope.merge(query.base_scope)` is not directly possible; instead extract the query's
  `statement` and append: `scope.where(query.statement)`.
- If the query has been deleted: log a warning and skip the query filter; continue with
  other filters. Record a warning in the run log.
- The query's column configuration and sort order are not applied; only the WHERE clause
  (filters) is used.

### 7.4 Recipient-personalized filtering

When the recipient mode includes `assignees` or the rule has `filter_assigned_to_recipient = true`:
- The issue scope is further filtered: `where(assigned_to_id: user.id)`.

When `filter_watched_by_recipient = true`:
- `where(id: user.watched_issue_ids)` (via Watcher join).

When `filter_authored_by_recipient = true`:
- `where(author_id: user.id)`.

These personalization flags are independent of recipient_modes.

---

## 8. Per-Recipient Personalization

Each recipient gets a separate email. The email content is generated per-recipient:

1. Issue scope is computed fresh for each recipient.
2. `Issue.visible(recipient)` is always applied.
3. Personalization filters (assigned_to, watched, authored) are applied if configured.
4. Each recipient sees only their own visible matching issues.
5. A recipient with zero visible matching issues: no email sent (unless `send_empty = true`).

---

## 9. Email Grouping Rules

The `group_by` field controls how issues are organized in the email body:

| `group_by` value | Grouping |
|-----------------|---------|
| `none` | Flat list |
| `assignee` | Group by assigned_to |
| `priority` | Group by priority |
| `tracker` | Group by tracker |
| `status` | Group by status |
| `version` | Group by fixed_version |
| `category` | Group by category |

Groups are sorted by the natural Redmine sort order for that field. Issues within a
group are sorted by `due_date ASC NULLS LAST, id ASC`.

---

## 10. Logging and Audit Rules

### 10.1 Rails logger

Every significant event is logged to `Rails.logger`:

| Level | Event |
|-------|-------|
| INFO | Rake task started/finished |
| INFO | Rule evaluated (due / skipped) |
| INFO | Recipients resolved (count) |
| INFO | Email sent to user |
| WARN | Rule skipped (expired, disabled, no recipients) |
| WARN | Query not found or not visible |
| WARN | Recipient excluded (locked, no permission, no email) |
| ERROR | Email delivery failed (with exception class and message, no PII beyond user ID) |
| ERROR | Rule configuration invalid |

**No sensitive data in logs**: issue subjects, user emails, and personal data are not
logged. User IDs are acceptable.

### 10.2 Database audit

- One `issue_digest_runs` record per rule per rake execution.
- One `issue_digest_deliveries` record per recipient per run.
- `error_message` stored for failures (truncated to 2000 characters).

---

## 11. Failure Handling

| Failure type | Behavior |
|-------------|---------|
| SMTP failure for one recipient | Log error; record delivery failure; continue to next recipient |
| SMTP failure for all recipients | Run recorded as `failed` |
| Some deliveries succeed, some fail | Run recorded as `partial_failure` |
| Exception in issue resolution | Log error; skip rule; record run as `error` |
| Exception in recipient resolution | Log error; skip rule; record run as `error` |
| Invalid schedule_config | Log error; skip rule; do not update `last_run_at` |
| DB error recording run | Log error; attempt to continue; surface in rake exit status |

---

## 12. Retry Behavior

**No automatic retry in v1.** A failed delivery is not retried on the next scheduled run;
the next run is a fresh execution based on the schedule window. Rationale: retrying
digest emails after a transient SMTP error may result in users receiving duplicate
digests when both the retry and the new scheduled run succeed.

Recommendation: ensure SMTP reliability at the infrastructure level (Redmine's standard
mailer settings). Operators can manually trigger a re-send via rake task with a
project/rule filter.

---

## 13. Timezone Handling

- Each rule has an optional `timezone` field (IANA timezone string, e.g. `"Europe/Brussels"`).
- Default: `'UTC'` if not set.
- All due-check logic converts current time to the rule's timezone before comparing
  `send_time` and determining the calendar day.
- `last_run_at` and `last_success_at` are stored in UTC (Rails default).
- The UI displays times in the project timezone (if set) or server timezone with a UTC note.

### 13.1 Daylight saving time

- Due-check compares wall-clock time in the rule's timezone.
- On DST transition days, the `send_time` is interpreted as local time:
  - If DST moves clocks forward (spring-forward): the send time may fall in the gap;
    the next eligible time after the gap is used. This may cause a send slightly late.
  - If DST moves clocks backward (fall-back): the send time occurs twice;
    the `last_run_at` check ensures only one send per calendar day in the rule's timezone.
- **Assumption**: This behavior is acceptable for v1. Document in user guide.

---

## 14. Locale Handling

- Email is sent in the **project's locale** if set, falling back to the **server default locale**.
- The recipient's personal locale preference (`User#language`) is not used in v1
  (all members of a project's digest get the same locale).
- Per-recipient locale (using `user.language` with `I18n.with_locale`) is a future
  enhancement; not in v1. *(OQ-02: per-user preferences deferred)*

---

## 15. Permissions and Visibility

- `manage_digest_rules`: can CRUD digest rules. Registered in project module.
- `view_digest_rules`: can view digest rules list and run history. Registered in project module.
- The **digest project module** must be enabled by a PM or admin in Project Settings → Modules.
- Controllers check `authorize` with `manage_digest_rules` or `view_digest_rules` as appropriate.
- The rake task bypasses request-level authorization but enforces `Issue.visible(user)` per recipient.

---

## 16. Interaction with Private Issues

- `Issue.visible(user)` automatically excludes private issues the user cannot see.
- No additional private-issue logic needed; trust Redmine's visibility scopes.
- **Assumption**: Redmine 5.1 and 6.1 both respect `Issue.visible(user)` for private project issues.

---

## 17. Interaction with Archived Projects

- The rake task queries `issue_digest_rules` joining `projects`.
- Archived projects (`projects.status = Project::STATUS_ARCHIVED`) are **excluded**.
- Rules for archived projects are not executed. They remain in the database.

---

## 18. Interaction with Closed Projects

- Closed projects (`projects.status = Project::STATUS_CLOSED`) are included.
- Issues in closed projects can still be queried and emailed (they may be relevant as history).
- **Assumption**: Closed ≠ archived in Redmine. Closed projects are still accessible.

---

## 19. Interaction with Disabled/Locked Users

- The `RecipientResolver` always calls `user.active?` before including a user.
- `User#active?` returns true only for `STATUS_ACTIVE`.
- Locked (`STATUS_LOCKED`) and registered-but-not-active users are excluded.
- Anonymous user is always excluded.

---

## 20. Interaction with Anonymous Users

- Anonymous users are never included as recipients. The `RecipientResolver` checks
  `user.is_a?(User) && !user.anonymous?`.

---

## 21. Interaction with Issue Visibility Settings

Redmine supports several issue visibility modes at the project level:
- All non-members can view: included if member mode allows.
- Members only: only project members see issues.
- Private: only assigned users, authors, and watchers.

The plugin uses `Issue.visible(user)` which already respects all of these. No custom
visibility logic is needed.

---

## 22. Interaction with Redmine Notification Settings

- The plugin does **not** check `user.mail_notification` before sending digests.
- Rationale: digest emails are a separate channel from event notifications. A user who
  set `mail_notification = 'none'` is still opted in to digests if the PM configured
  them as a recipient. *(Confirmed — OQ-02: per-user opt-out is not in v1.)*
- The plugin uses its own Mailer action and does not go through `Mailer.deliver_*`
  standard notification methods.

---

## 23. Edge Cases — Specified Behavior

### EC-01: No matching issues
- Default: skip email, do not send, do not record a delivery row.
- If `send_empty = true`: send email with "No issues matched this digest." body.
- Record delivery as `sent` with `issues_count = 0`.

### EC-02: No matching recipients
- Log `WARN: no recipients resolved for rule #{rule.id}`.
- Record run as `skipped` with `recipients_count = 0`.
- Do not send any emails.

### EC-03: Recipient has no permission to see some issues
- `Issue.visible(user)` excludes them automatically.
- The recipient receives fewer issues than expected; this is correct behavior.
- No error is raised.

### EC-04: Query deleted after digest creation
- Load: `IssueQuery.find_by(id: rule.query_id)` returns nil.
- Log `WARN: query #{rule.query_id} not found for rule #{rule.id}; skipping query filter`.
- Continue with remaining filters.
- Record a warning note in `issue_digest_runs.warning_message`.

### EC-05: Query visibility changes
- The query is loaded without user context in the rake task (system context).
- Check `query.visibility == Query::VISIBILITY_PUBLIC` or `query.project_id == rule.project_id`.
- If neither: skip query filter and log a warning.

### EC-06: User removed from project
- `RecipientResolver` re-queries membership at resolution time.
- User is excluded if no longer a member.

### EC-07: Project archived
- `issue_digest_rules` query JOINs `projects WHERE projects.status != #{Project::STATUS_ARCHIVED}`.
- Rule is not executed.

### EC-08: Digest disabled while due
- The rake task checks `rule.active?` including `start_on`/`end_on` check.
- If a race condition occurs (rule disabled between query and processing), the rule
  is skipped; no email sent.

### EC-09: Cron runs twice at the same time
- DB advisory lock (`IssueDigest::LockManager`) ensures one process wins.
- The losing process exits immediately with a log message.
- `last_run_at` is set atomically before sending, preventing double execution even
  without a lock (defense in depth).

### EC-10: Mail delivery failure
- `Mailer.issue_digest(rule, user, issues).deliver_now` is wrapped in `rescue => e`.
- Exception is caught, logged at ERROR level, and the delivery record is marked failed.
- The next recipient is still processed.

### EC-11: Large project with many issues
- `IssueResolver` uses `limit(max_issues_per_email)` where `max_issues_per_email`
  comes from global plugin settings (default: 500).
- If the limit is hit, the email body includes a note: "Showing 500 of N total matching issues."
- For recipient resolution of `assignees` or `watchers`, the query uses a subquery, not
  loading all issues into memory first.

### EC-12: Timezone boundary around midnight
- The due-check uses the rule's timezone. A rule set to 23:30 in UTC+2 is due at 21:30 UTC.
- If the rake task runs at 21:25 UTC, it is not yet due. At 21:30 UTC, it is due.
- The `last_run_at` check uses `to_date` in the rule's timezone to ensure only one send per day.

### EC-13: Daylight saving time changes
- Covered in section 13.1. Behavior: at most one extra or one missed send per DST day per year.
- Document as known limitation.

### EC-14: End date already passed
- `rule.active?` returns false. Rake task skips.
- The rule is not auto-disabled; `active` remains `true` but `end_on` gate prevents execution.
- UI shows "Expired" badge.

### EC-15: Invalid or incomplete digest configuration
- Missing `schedule_type`: validation error; rule cannot be saved.
- Invalid `schedule_config` JSON: `parse` rescues `JSON::ParserError`; rule is skipped and error is logged.
- No recipient modes set: validation error; rule cannot be saved.
- No issue filters selected: allowed (digest sends all issues in project matching base scope).
