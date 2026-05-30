# Product Requirements Specification — redmine_mail_digest

## 1. Problem Statement

Redmine provides per-event email notifications (issue created, issue updated, etc.),
but offers no way to receive a scheduled summary of issues matching certain criteria.
Project members frequently need to start their day or week with a curated view of
open, overdue, or recently-changed issues without visiting Redmine manually or
being overwhelmed by individual per-event emails.

No built-in Redmine feature and no widely-maintained plugin fills this gap for
Redmine 5.1 / 6.x.

---

## 2. Goals

- Allow project managers to configure one or more named digest rules per project.
- Support flexible schedules: daily, weekly, specific weekdays, monthly.
- Allow issue filtering by status, recency, overdue state, and existing saved queries.
- Allow recipient configuration: members by role, assignees, authors, watchers,
  or specific named users.
- Send digests via the standard Redmine mailer, respecting all existing user and
  issue visibility settings.
- Provide a rake task suitable for cron execution.
- Record run history and failures in the database.
- Remain maintainable, testable, and consistent with Redmine plugin conventions.

---

## 3. Non-Goals (v1)

The following are confirmed out of scope for v1 and will not be implemented:

- **Custom cron expressions** (e.g. `0 9 * * 1,3,5`). Only discrete schedule types
  (daily, weekdays, weekly, monthly) are supported. *(OQ-03: resolved)*
- **External (non-Redmine-user) email addresses** as recipients. All recipients must
  be active Redmine users with a valid email. The global settings page includes a
  placeholder toggle for future use; it is inert in v1. *(OQ-01: resolved)*
- **Per-user digest opt-out preferences**. Recipients are controlled entirely by
  project managers; individual users cannot opt out in v1. *(OQ-02: resolved)*
- **REST API** for digest rules. UI-only management. *(OQ-10: resolved)*
- **Copy/clone digest rules** across projects. *(OQ-07: resolved)*
- **Automatic SMTP retry** on delivery failure. Failures are logged and recorded;
  no retry on the same or subsequent run. *(OQ-09: resolved)*
- Push notifications, SMS, or non-email delivery.
- Real-time digest triggering (only scheduled/cron execution).
- Integration with Sidekiq, DelayedJob, or other background job frameworks.
- Digest rules that span multiple projects.

---

## 4. Target Users

### 4.1 Personas

**Alice — Administrator**
- Manages the Redmine instance.
- Installs the plugin, runs migrations, schedules the cron job.
- May configure global plugin settings (max issues per email, data retention).
- Wants confidence that digests do not leak private issue data.

**Bob — Project Manager**
- Manages one or more projects.
- Creates and edits digest rules for their projects.
- Wants a morning email listing overdue issues and issues due this week.
- Wants team members to receive a weekly summary of open issues assigned to them.

**Carol — Developer (normal user)**
- Member of one or more projects.
- Receives digest emails configured by Bob.
- Does not manage digest rules.
- Wants the digest to only show issues she is allowed to see.

**Dave — Read-only Viewer**
- Project member with Reporter role.
- May be included in digests but cannot configure them.

---

## 5. Main Use Cases

### UC-01: Create a digest rule
- Bob navigates to Project → Settings → Digests.
- Bob clicks "New digest rule".
- Bob fills in name, schedule, recipients, issue filters.
- Bob saves the rule. The rule is active from the next scheduled run.

### UC-02: Edit a digest rule
- Bob navigates to Project → Settings → Digests.
- Bob clicks "Edit" on an existing rule.
- Bob changes the schedule or filters.
- Bob saves. The next run uses the updated configuration.

### UC-03: Disable a digest rule
- Bob clicks "Disable" on an existing rule.
- The rule is retained but not executed until re-enabled.

### UC-04: Delete a digest rule
- Bob clicks "Delete" and confirms.
- The rule and its run history are removed.

### UC-05: Receive a digest email
- Carol receives a daily email at 08:00 listing her open assigned issues.
- Each issue is a clickable link to Redmine.
- Issues she cannot see are excluded.

### UC-06: Run digests from cron
- Alice schedules `bundle exec rake redmine:issue_digest:send RAILS_ENV=production`
  to run every 15 minutes.
- The task finds due rules, sends digests, records run history.

### UC-07: Inspect run history
- Bob navigates to Project → Settings → Digests → [rule name] → Run history.
- Bob sees a table of past runs: date, status, recipients, emails sent.

### UC-08: Handle a failed delivery
- A delivery fails due to SMTP error.
- The failure is recorded in `issue_digest_deliveries`.
- The run is marked as `partial_failure`.
- The next scheduled run proceeds normally; no automatic retry.

### UC-09: Dry-run mode
- Alice runs `DRY_RUN=1 bundle exec rake redmine:issue_digest:send`.
- The task prints what would be sent without actually sending emails or updating run history.

### UC-10: Filter by existing query
- Bob selects an existing saved IssueQuery from a dropdown.
- The digest filters issues using that query's saved filters.
- Additional digest-level filters (open, overdue, etc.) are combined with the query's filters.

---

## 6. Example Digest Configurations

### Example A: Daily standup digest
- Name: "Daily open issues"
- Schedule: Daily at 08:00
- Recipients: All project members with role Developer or Manager
- Filters: Open issues only
- Group by: Assignee

### Example B: Weekly overdue summary
- Name: "Weekly overdue"
- Schedule: Weekly on Monday at 07:00
- Recipients: Project manager (specific user)
- Filters: Overdue issues (due date < today, status open)
- Group by: Priority

### Example C: Personal assigned digest
- Name: "My issues today"
- Schedule: Daily at 09:00
- Recipients: Assigned users (each user sees only their own assigned issues)
- Filters: Open issues; assigned to recipient

### Example D: Monthly project health
- Name: "Monthly health report"
- Schedule: Monthly on 1st at 06:00
- Recipients: All project members
- Filters: Open issues + issues closed in last 30 days
- Group by: Tracker

### Example E: Query-based digest
- Name: "Critical issues"
- Schedule: Daily at 08:00
- Recipients: Specific users [Alice, Bob]
- Filters: Based on saved query "P1 bugs"
- Group by: None

---

## 7. Expected User Flows

### 7.1 Project manager creates a digest rule

```
Project Settings → Digests tab (appears only if module enabled)
  → [New digest rule] button
    → Form: name, enabled, schedule, recipients, filters, grouping, email customization
      → [Save] → redirect to digest rules list, success flash
```

### 7.2 Cron execution (automated)

```
Cron triggers rake task every N minutes
  → Task acquires lock
    → Queries issue_digest_rules where active=true and due
      → For each rule:
          → Resolve recipients
          → For each recipient:
              → Resolve visible issues
              → Generate email
              → Send via Mailer
              → Record delivery
          → Record run
  → Release lock
```

### 7.3 User receives digest

```
Email arrives with subject "[ProjectName] Daily open issues — 2026-05-27"
  → Body: intro text, issue table grouped by assignee
    → Each issue: #ID, Tracker, Subject (linked), Status, Priority, Assignee, Due date
  → Footer: "Sent by Redmine digest. Manage digest settings: [link]"
```

---

## 8. Permission Model

| Permission | Holder | Description |
|------------|--------|-------------|
| `manage_digest_rules` | Project Manager / configurable role | Create, edit, disable, delete digest rules |
| `view_digest_rules` | Project Member (read-only) | View list of digest rules and run history |
| (none needed) | Recipient | Receives emails, no Redmine action required |

- The **digest module** must be enabled per-project (project module toggle in Project Settings → Modules).
- Only users with `manage_digest_rules` in the project can create/edit/delete rules.
- Users with `view_digest_rules` can see the rule list and history.
- The rake task runs as a system process and bypasses per-request authorization;
  issue visibility is still enforced per recipient at query time.

---

## 9. User Stories

| ID | Story |
|----|-------|
| US-01 | As a project manager, I can create a digest rule for my project. |
| US-02 | As a project manager, I can schedule a digest daily, weekly, on selected weekdays, or monthly. |
| US-03 | As a project manager, I can select which users or roles receive the digest. |
| US-04 | As a project manager, I can select which issue states are included (open, closed, overdue, due soon, recently updated, recently created). |
| US-05 | As a project manager, I can base the digest on an existing saved Redmine query. |
| US-06 | As an assigned user, I can receive a personalized digest of issues assigned to me. |
| US-07 | As a watcher, I can be included as a digest recipient via "watchers" recipient mode. |
| US-08 | As an administrator, I can run the digest task from cron without manual intervention. |
| US-09 | As an administrator, I can inspect run history and failures in the project settings UI. |
| US-10 | As a user without the manage_digest_rules permission, I cannot create or edit digest rules. |
| US-11 | As a recipient, I only see issues I am permitted to view in Redmine. |
| US-12 | As a project manager, I can set a start date and end date for a digest rule. |
| US-13 | As a project manager, I can preview the list of issues that would be included in the next digest. |
| US-14 | As an administrator, I can run a dry-run to verify what would be sent without sending emails. |
| US-15 | As a project manager, I can disable a rule without deleting it. |

---

## 10. Acceptance Criteria

### AC-01: Digest rule creation
- A project manager can create a rule with all required fields.
- The rule appears in the project's digest list after saving.
- The rule is executed on the next scheduled rake run.

### AC-02: Schedule accuracy
- A daily rule at 08:00 UTC is due if the rake task runs at or after 08:00 UTC on any day.
- A weekly rule on Monday at 08:00 UTC is due only on Mondays at or after 08:00 UTC.
- A monthly rule on the 1st at 06:00 UTC is due only on the 1st of each month.
- `last_run_at` is updated after each run; the same rule is not re-sent within the same window.

### AC-03: Recipient resolution
- "All project members" sends to all active members of the project.
- "By role" sends only to members holding the specified role(s).
- "Assigned users" sends to each user assigned to at least one matching issue.
- "Watchers" sends to each watcher of at least one matching issue.
- Locked, inactive, or anonymous users are excluded from all recipient lists.
- Users with no matching visible issues receive no email (unless `send_empty` is enabled).

### AC-04: Issue filtering
- "Open issues" = issues where status.is_closed = false.
- "Closed issues" = issues where status.is_closed = true.
- "Overdue" = open issues where due_date < today.
- "Due soon" = open issues where due_date is within N days.
- "Recently updated" = issues where updated_on >= N days ago.
- "Recently created" = issues where created_on >= N days ago.
- All filters are combined with AND logic.
- A saved query filter further restricts the result set.

### AC-05: Issue visibility
- The plugin uses `Issue.visible(user)` to scope issues per recipient.
- Private issues are excluded for users who cannot view them.
- Issues in sub-projects are included only if the query or rule includes sub-projects.

### AC-06: Run history
- Each rake run creates one `issue_digest_runs` record per rule executed.
- Each email attempt creates one `issue_digest_deliveries` record.
- Failures are recorded with error_message.
- The UI displays the last N runs for each rule.

### AC-07: No duplicate sends
- A rule is not executed again within the same scheduling window.
- The locking mechanism prevents concurrent rake runs from processing the same rule.

### AC-08: Dry-run mode
- `DRY_RUN=1` outputs rule names, recipient counts, and issue counts without sending.
- No run history is created in dry-run mode.
- No emails are sent in dry-run mode.

---

## 11. Error Cases

| Error | Expected behavior |
|-------|------------------|
| No matching issues | Skip email (or send empty digest if `send_empty=true`) |
| No matching recipients | Skip rule, log warning |
| SMTP delivery failure | Record failure in `issue_digest_deliveries.error_message`; continue |
| Saved query deleted | Block delivery for that rule; log warning and record the warning on the run |
| Saved query not visible/unusable to system | Block delivery for that rule; log warning and record the warning on the run |
| Project archived | Skip all rules for that project |
| Project closed (not archived) | Run normally |
| Rule end date passed | Rule is inactive; skip |
| Rule start date not reached | Rule is inactive; skip |
| Invalid schedule_config JSON | Log error; skip rule; mark as error |
| User removed from project mid-run | Excluded from recipient resolution |
| Locked/inactive user | Excluded from recipient list |
| Concurrent rake runs | DB advisory lock prevents double execution |
| Rule disabled during run window | Skip rule |
| Email address blank for user | Skip that recipient |

---

## 12. Empty States

| Context | Display |
|---------|---------|
| No digest rules in project | "No digest rules configured. [New digest rule]" |
| Digest module not enabled | Module settings tab shows but form is disabled (module guards access) |
| No runs yet | Run history shows "No runs recorded yet." |
| No issues matching filters | Email is not sent (default). If `send_empty=true`: send email with "No issues matched." |
| No recipients resolved | Log warning; no emails sent |

---

## 13. Backward Compatibility Considerations

- **Redmine 5.1**: Plugin must function on Rails 7.0.x, Ruby ≥ 3.0.
  - Avoid Rails 7.2-only APIs.
  - Test against both Redmine 5.1 and 6.1 in CI.
  - JSON column type may not be available in all DB versions for 5.1; serialize to TEXT if needed.
- **Redmine 6.1**: Primary target. Rails 7.2, Ruby 3.2–3.4, Propshaft, Importmap.
- **Database**: PostgreSQL (primary), MySQL 8.0+, SQLite 3.x. No raw PostgreSQL-only SQL in core logic.
- **Plugin compatibility**: No known conflict with other common plugins; avoid monkey-patching core classes.

---

## 14. Operational Requirements

- The plugin must be installable by placing the directory under `plugins/` and running
  `bundle exec rake redmine:plugins:migrate`.
- The cron job must be documented with example crontab entries.
- The plugin must not break Redmine startup if the cron job is not configured.
- The plugin must log clearly to Rails.logger; no silent failures.
- The plugin must not introduce gems that conflict with Redmine's existing Gemfile.
- Data retention for run history is configurable via global admin settings (default: 90 days).
