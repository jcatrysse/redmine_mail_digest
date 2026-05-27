# UI and UX Specification — redmine_digest

## 1. Design Philosophy

The UI must feel native to Redmine. Specifically:

- Use `<table class="list">` for list pages (same as Redmine's issue lists).
- Use Redmine's flash helpers: `flash[:notice]` for success, `flash[:error]` for errors.
- Use Redmine's form conventions (labels above or beside fields, matching existing project settings forms).
- Use Redmine's `submit_tag`, `link_to`, `button_to` helpers.
- No custom JavaScript frameworks. Progressive enhancement via Stimulus only if needed.
- The Digests tab appears in the **Project Settings** page only when the `issue_digest`
  module is enabled for the project.
- Access via `/projects/:identifier/digest_rules`.

---

## 2. Project Module Activation

- An admin or project manager must enable the "Issue Digests" module under
  **Project Settings → Modules** (standard Redmine module toggle).
- Once enabled, a "Digest Rules" tab appears in the **Project Settings** page
  (same row as Members, Versions, Issue categories, etc.).
- There is no sidebar menu entry; the settings tab is the sole UI entry point.
- If the module is disabled, the controller returns 403 for all actions.

---

## 3. Page: Digest Rules Index

**URL**: `GET /projects/:project_id/digest_rules`  
**Permission**: `view_digest_rules`  
**Layout**: Standard Redmine project layout (`layouts/base`, with project context)

### Header

```
[Project Name] > Digest Rules

                                  [+ New digest rule]   (visible only with manage_digest_rules)
```

### Table columns

| Column | Notes |
|--------|-------|
| Name | Linked to show page |
| Schedule | Human-readable (from `schedule_description(rule)`) |
| Recipients | Human-readable (from `recipient_modes_description(rule)`) |
| Status | Badge: Active / Disabled / Expired / Pending |
| Last run | Formatted datetime + status badge (Success / Failed / Skipped) |
| Actions | Edit / Disable (or Enable) / Delete — visible only with `manage_digest_rules` |

### Empty state

When no rules exist:
```
No digest rules have been configured for this project.
[+ New digest rule]       ← link (if manage_digest_rules)
```

### Status badges (CSS classes matching Redmine conventions)

| Status | Badge text | CSS hint |
|--------|-----------|---------|
| Active | "Active" | `class="badge badge-success"` (green) |
| Disabled | "Disabled" | `class="badge badge-inactive"` (grey) |
| Expired | "Expired" | `class="badge badge-error"` (red) |
| Pending | "Pending" | `class="badge badge-warning"` (yellow) |

---

## 4. Page: New / Edit Digest Rule

**URL**: `GET /projects/:project_id/digest_rules/new`  
**URL**: `GET /projects/:project_id/digest_rules/:id/edit`  
**Permission**: `manage_digest_rules`  
**Layout**: Standard Redmine project layout

### Form structure (fieldsets)

---

#### Fieldset 1: Basic information

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| Name | text input | Yes | max 255 chars |
| Active | checkbox | No | default: checked |

---

#### Fieldset 2: Schedule

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| Schedule type | select | Yes | See options below |
| Send time | time input | Conditional | Required for all types except `manual` |
| Timezone | select | Conditional | Required when send time is set; default: server timezone |
| Start date | date input | No | If blank: active immediately; anchor for interval types |
| End date | date input | No | If blank: no expiry |
| Grace window | integer input | No | Hours after send time during which the rule is still due; default: 24; range 0–48 |

**Schedule type options** (select list):

| Value | Label |
|-------|-------|
| `daily` | Every day |
| `weekdays` | Selected days of the week |
| `weekly` | Weekly on a specific day |
| `monthly_date` | Monthly on day number |
| `monthly_last_day` | Monthly on the last day |
| `interval_days` | Every N days |
| `interval_weeks` | Every N weeks |
| `manual` | Manual only (rake task) |

**Dynamic sub-fields** (show/hide with Stimulus or inline `<script>`):

| Visible when | Field | Type | Notes |
|-------------|-------|------|-------|
| `weekdays` | Day checkboxes | checkboxes | Mon / Tue / Wed / Thu / Fri / Sat / Sun |
| `weekly` | Day of week | select | Monday – Sunday |
| `monthly_date` | Day of month | select | 1 – 28 |
| `monthly_last_day` | *(no extra fields)* | — | Last day is computed automatically |
| `interval_days` | Every N days | integer | Min 1, max 365 |
| `interval_weeks` | Every N weeks | integer | Min 1, max 52 |
| `manual` | *(no send time or timezone)* | — | Both send_time and timezone hidden/disabled |

**Business days section** (shown for all types except `weekdays` and `manual`):

| Field | Type | Notes |
|-------|------|-------|
| Weekdays only | checkbox | If checked: skip or shift Sat/Sun executions |
| When trigger falls on weekend | select | Skip / Use preceding Friday / Use following Monday; visible only when "Weekdays only" is checked |

**Help text for grace window**:
> "If the cron job runs late, the digest is still sent as long as the delay is within this window. After the window expires, that occurrence is skipped. Default: 24 hours (1 day). Set to 0 for strict on-time delivery only. Maximum: 48 hours."

**Help text for manual schedule**:
> "This rule will never run automatically. Trigger it explicitly with: `bundle exec rake redmine:issue_digest:send RULE_ID=#{rule.id} MANUAL=1 RAILS_ENV=production`"

**Implementation note**: Use a `data-schedule-type` attribute on the form and a
Stimulus controller (or minimal inline `<script>`) to show/hide sub-fields when the
select changes. The controller only needs to toggle CSS `display` — no AJAX required.

---

#### Fieldset 3: Issue filters

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| Based on saved query | select (optional) | No | Shows public queries for this project + "None" |
| Include open issues | checkbox | No | default: checked |
| Include closed issues | checkbox | No | default: unchecked |
| Include overdue issues | checkbox | No | default: unchecked |
| Include due soon | checkbox | No | Shows "within N days" input when checked |
| Due soon days | integer input | Conditional | Visible when "Include due soon" is checked; default: 7 |
| Include recently updated | checkbox | No | Shows "within N days" input when checked |
| Recently updated days | integer input | Conditional | default: 7 |
| Include recently created | checkbox | No | Shows "within N days" input when checked |
| Recently created days | integer input | Conditional | default: 7 |
| Include sub-projects | checkbox | No | default: unchecked |

**Help text below filters**:
> "Filters are combined with AND logic. The saved query filter is applied on top of
> the selected filters. If no filters are checked, all issues in the project are included."

---

#### Fieldset 4: Recipients

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| Recipient modes | checkboxes (multi-select) | Yes (at least 1) | See mode list below |

**Recipient mode checkboxes**:

```
[ ] All project members
[ ] Members with role: [role select — shown when this is checked]
[ ] Assigned users (users assigned to matching issues)
[ ] Issue authors
[ ] Issue watchers
[ ] Specific users: [user multi-select or token input]
```

**Per-recipient personalization** (shown only if relevant modes are selected):

```
[ ] Only show issues assigned to the recipient
[ ] Only show issues watched by the recipient
[ ] Only show issues authored by the recipient
```

**Help text**:
> "Each recipient receives a personalized email containing only the issues they are
> permitted to see. Recipients with no matching visible issues will not receive an email."

---

#### Fieldset 5: Email format

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| Group issues by | select | No | None / Assignee / Priority / Tracker / Status / Version / Category |
| Send even if no issues match | checkbox | No | default: unchecked |
| Custom email subject | text input | No | If blank: auto-generated; supports `{project}` and `{date}` tokens |
| Custom intro text | formatted-text area (wiki toolbar + preview) | No | Appears at top of email body; max 2000 chars. Rendered with Redmine's text formatter (`textilizable`) on the rule's show page **and** in the delivered HTML email, so the form preview matches the result. |

---

#### Form actions

```
[Save]   [Cancel]
```

- On success: redirect to the Project Settings `digest_rules` tab with `flash[:notice] = t(:notice_issue_digest_rule_saved)`.
  All other mutating actions (update, destroy, enable, disable) also redirect to the settings tab.
- On failure: re-render form with inline validation errors (Redmine's standard `errorExplanation` div).

---

## 5. Page: Show Digest Rule

**URL**: `GET /projects/:project_id/digest_rules/:id`  
**Permission**: `view_digest_rules`

**Navigation**: Accessible by clicking the rule name in the Project Settings
`digest_rules` tab. The settings tab also has an explicit "Run History" button
in the actions column, and a "Last Run" column showing the most recent run date
and status badge.

### Sections

1. **Rule details** — readonly display of all configured fields:
   - Schedule description (human-readable, from `schedule_description(rule)`)
   - Recipients (from `recipient_modes_description(rule)`)
   - **Filters** — comma-separated list of active issue filter labels; shows
     `"None (all project issues included)"` when no filters are active
     (from `filter_summary(rule)`)
   - **Personalization** — comma-separated list of active per-recipient flags
     (`filter_assigned_to_recipient`, `filter_watched_by_recipient`,
     `filter_authored_by_recipient`); row is **hidden entirely** when no flags are set
     (from `personalization_summary(rule)`)
   - Saved query name (if `query_id` is set)
   - Date bounds (`start_on` / `end_on`, if set)
   - Group-by
   - Last success timestamp (if present)
   - Email intro text (if present)
2. **Actions** — Edit / Disable (or Enable) / Delete (conditional on `manage_digest_rules`).
3. **Run history** — last 20 runs (table).

### Run history table columns

| Column | Notes |
|--------|-------|
| Started at | Formatted datetime |
| Finished at | Formatted datetime (or "—" if running) |
| Trigger | Scheduled / Manual / Dry run |
| Status | Badge (Success / Partial failure / Failed / Error / Skipped) |
| Recipients | Count |
| Emails sent | Count |
| Failures | Count |
| Details | Link to expanded delivery list (show individual deliveries) |

---

## 6. Confirmation Dialogs

### Delete confirmation

Uses Redmine's standard approach: `link_to ..., method: :delete, data: { confirm: t(:text_are_you_sure) }`.

The confirmation dialog text:
> "Are you sure you want to delete the digest rule '{{name}}'?
> All run history for this rule will also be deleted. This action cannot be undone."

---

## 7. Enable / Disable Behavior

- The Project Settings tab (and the show page) shows "Disable" for active rules
  and "Enable" for disabled rules.
- These are POST actions (not GET) to prevent browser prefetching.
- After toggle: redirect to the Project Settings `digest_rules` tab with a flash notice.

---

## 8. Global Admin Settings Page

**URL**: `/settings/plugin/redmine_digest`  
**Access**: Redmine administrators only (Redmine enforces this for plugin settings).  
**Backing store**: `Setting.plugin_redmine_digest` hash (standard Redmine plugin settings).

### Fields

| Setting key | UI label | Type | Default | Notes |
|-------------|----------|------|---------|-------|
| `max_issues_per_email` | Maximum issues per email | integer | 500 | Global hard cap; range 1–5000 |
| `run_history_retention_days` | Run history retention (days) | integer | 90 | 0 = keep forever; applied by cleanup task |
| `allow_external_recipients` | Allow external email recipients | checkbox | unchecked | **Reserved for future use — has no effect in v1.** Field is present but disabled/greyed out with a note: "External recipients are not supported in this version." |

### init.rb default values

```ruby
settings :default => {
  'max_issues_per_email'         => 500,
  'run_history_retention_days'   => 90,
  'allow_external_recipients'    => false
}, :partial => 'settings/issue_digest_settings'
```

### I18n keys for global settings

```yaml
redmine_digest:
  settings:
    max_issues_per_email: "Maximum issues per email"
    run_history_retention_days: "Run history retention (days)"
    allow_external_recipients: "Allow external email recipients"
    allow_external_recipients_note: "External recipients are not supported in this version."
    hint_max_issues_per_email: "Hard cap applied to every digest email. Range: 1–5000."
    hint_retention_days: "Digest run records older than this many days are removed by the cleanup task. Set to 0 to keep records indefinitely."
```

---

## 9. Validation Messages

### Field-level errors (inline, below field)

| Validation | Message key |
|-----------|------------|
| Name blank | `error_name_blank` |
| Name too long | `error_name_too_long` |
| No schedule type selected | `error_schedule_type_blank` |
| Send time blank | `error_send_time_blank` |
| Invalid timezone | `error_timezone_invalid` |
| No recipient modes selected | `error_recipient_modes_blank` |
| End date before start date | `error_end_before_start` |
| Due soon days out of range | `error_due_soon_days_range` |

---

## 10. Help Text and Tooltips

- Each fieldset has a `<p class="description">` below it with explanatory text.
- Timezone field: "Select the timezone used to interpret the send time. Defaults to UTC."
- Query field: "Selecting a saved query restricts issues to those matching the query's saved filters. The query must be public or belong to this project."
- Personalization filters: "When enabled, each recipient sees only issues matching the selected criteria for their user account."

---

## 11. Accessibility

- All form inputs have associated `<label>` elements (for: attribute).
- Use `fieldset` + `legend` for grouped checkboxes (weekdays, recipient modes).
- Error summary rendered as `<div id="errorExplanation">` (Redmine convention).
- Flash messages rendered in Redmine's standard `#flash-notifications` container.
- Table headers use `<th scope="col">`.
- Status badges use ARIA: `<span class="badge" aria-label="Status: Active">Active</span>`.

---

## 12. I18n Keys (English Locale)

### Menu and page titles

```yaml
  label_issue_digest: "Digest Rules"
  label_issue_digest_rule: "Digest Rule"
  label_issue_digest_rules: "Digest Rules"
  label_new_issue_digest_rule: "New Digest Rule"
  label_edit_issue_digest_rule: "Edit Digest Rule"
  label_run_history: "Run History"
  label_run_history_last: "Last Run"
  label_run_history_started_at: "Started at"
  label_run_history_finished_at: "Finished at"
  label_run_history_trigger: "Trigger"
  label_run_history_status: "Status"
  label_run_history_recipients: "Recipients"
  label_run_history_emails_sent: "Sent"
  label_run_history_emails_failed: "Failures"
  label_issue_digest_settings: "Issue Digest Settings"
  label_filters: "Filters"
```

### Form field labels

```yaml
  field_name: "Name"
  field_active: "Active"
  field_schedule_type: "Schedule"
  field_send_time: "Send time"
  field_timezone: "Timezone"
  field_start_on: "Start date"
  field_end_on: "End date"
  field_query_id: "Based on saved query"
  field_include_subprojects: "Include sub-project issues"
  field_include_open: "Include open issues"
  field_include_closed: "Include closed issues"
  field_include_overdue: "Include overdue issues"
  field_include_due_soon: "Include issues due soon"
  field_due_soon_days: "Due soon within (days)"
  field_include_recently_updated: "Include recently updated issues"
  field_recently_updated_days: "Updated within (days)"
  field_include_recently_created: "Include recently created issues"
  field_recently_created_days: "Created within (days)"
  field_filter_assigned_to_recipient: "Only assigned to recipient"
  field_filter_watched_by_recipient: "Only watched by recipient"
  field_filter_authored_by_recipient: "Only authored by recipient"
  field_recipient_modes: "Recipients"
  field_group_by: "Group issues by"
  field_send_empty: "Send even if no issues match"
  field_email_subject: "Email subject (optional)"
  field_email_intro: "Email intro text (optional)"
```

### Schedule types

```yaml
  schedule_type_daily: "Every day"
  schedule_type_weekdays: "Selected days of the week"
  schedule_type_weekly: "Weekly on a specific day"
  schedule_type_monthly_date: "Monthly on day number"
  schedule_type_monthly_last_day: "Monthly on the last day"
  schedule_type_interval_days: "Every N days"
  schedule_type_interval_weeks: "Every N weeks"
  schedule_type_manual: "Manual only (rake task)"
  field_grace_window_hours: "Grace window (hours)"
  field_business_days_only: "Weekdays only (Mon-Fri)"
  field_non_business_day_behavior: "When trigger falls on weekend"
  non_business_day_skip: "Skip that occurrence"
  non_business_day_previous_weekday: "Use preceding Friday"
  non_business_day_next_weekday: "Use following Monday"
  field_interval_every_days: "Every N days"
  field_interval_every_weeks: "Every N weeks"
  hint_grace_window: "If the cron job runs late, the digest is still sent within this window. After the window expires, that occurrence is skipped. Default: 24 hours. Range: 0–48."
  hint_manual_schedule: "This rule never runs automatically. Trigger it with: rake redmine:issue_digest:send RULE_ID=%{id} MANUAL=1"
  hint_interval_anchor: "The interval is counted from the Start date (or rule creation date if no start date is set)."
```

### Recipient modes

```yaml
  recipient_mode_project_members: "All project members"
  recipient_mode_role: "Members with role:"
  recipient_mode_assignees: "Assigned users (of matching issues)"
  recipient_mode_authors: "Issue authors"
  recipient_mode_watchers: "Issue watchers"
  recipient_mode_users: "Specific users:"
```

### Group-by options

```yaml
  group_by_none: "No grouping"
  group_by_assignee: "Assignee"
  group_by_priority: "Priority"
  group_by_tracker: "Tracker"
  group_by_status: "Status"
  group_by_version: "Target version"
  group_by_category: "Category"
```

### Status labels

```yaml
  status_active: "Active"
  status_disabled: "Disabled"
  status_expired: "Expired"
  status_pending: "Pending"
```

### Run status labels

```yaml
  run_status_running: "Running"
  run_status_success: "Success"
  run_status_partial_failure: "Partial failure"
  run_status_failed: "Failed"
  run_status_error: "Error"
  run_status_skipped: "Skipped (no recipients)"
```

### Notices and errors

```yaml
  notice_issue_digest_rule_saved: "Digest rule was successfully saved."
  notice_issue_digest_rule_deleted: "Digest rule was deleted."
  notice_issue_digest_rule_enabled: "Digest rule was enabled."
  notice_issue_digest_rule_disabled: "Digest rule was disabled."
  error_issue_digest_rule_not_saved: "Digest rule could not be saved."
  error_name_blank: "Name can't be blank."
  error_schedule_type_blank: "Schedule type can't be blank."
  error_recipient_modes_blank: "At least one recipient mode must be selected."
  error_end_before_start: "End date must be after start date."
```

### Empty states

```yaml
  text_no_digest_rules: "No digest rules have been configured for this project."
  text_no_runs_yet: "No runs recorded yet."
  text_digest_rule_delete_confirm: "Are you sure you want to delete the digest rule '%{name}'? All run history will also be deleted."
```

### Help texts

```yaml
  hint_schedule: "The digest will be sent at the specified time, on the scheduled days."
  hint_timezone: "Select the timezone used to interpret the send time."
  hint_query: "Restricts issues to those matching the saved query's filters. The query must be public or belong to this project."
  hint_filters: "Filters are combined. Unchecked filters are ignored. If no filters are selected, all project issues are included."
  hint_recipients: "Each recipient receives a personalized email with only the issues they are permitted to see."
  hint_send_empty: "If checked, an email is sent even when no issues match the configured filters."
  hint_email_subject: "Supports tokens: {project}, {date}, {rule_name}. Leave blank to use the default subject."
  hint_max_issues: "Note: the digest will include at most %{max} issues per email (configured globally)."
```

---

## 13. Notes for Additional Locales

- Contributors should create `config/locales/<locale>.yml` following the same key structure.
- The plugin must not crash if a locale file is missing; fall back to English.
- Submit locale files via pull requests. Do not include machine-translated strings without review.
