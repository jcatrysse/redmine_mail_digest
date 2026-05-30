# Data Model Specification — redmine_mail_digest

## 1. Overview

Three tables are introduced. All table names are prefixed with `issue_digest_`.
All timestamps are UTC. All migrations follow Redmine's existing migration convention
(inheriting from `ActiveRecord::Migration[7.2]` for Redmine 6.1, `[7.0]` for 5.1 —
use the appropriate version in each CI environment).

**Cross-DB compatibility rules**:
- No PostgreSQL-only column types in migration DDL (e.g., do not use `jsonb`).
- Use `:text` for JSON fields; apply `serialize :field, coder: JSON` in the model.
- Rationale: MySQL 8 and SQLite3 do not support `jsonb`; `json` type support varies.
- Exception: if the plugin is PostgreSQL-only, `jsonb` can be used and is preferable
  for indexing — mark this as an open question (OQ-DB-01).
- **Recommendation**: Use `:text` for broadest compatibility in v1.

---

## 2. Table: `issue_digest_rules`

### Purpose
Stores one digest rule per row. A project can have multiple rules.

### Schema

```sql
CREATE TABLE issue_digest_rules (
  id                         INTEGER      NOT NULL PRIMARY KEY,
  project_id                 INTEGER      NOT NULL,
  name                       VARCHAR(255) NOT NULL,
  active                     BOOLEAN      NOT NULL DEFAULT TRUE,
  schedule_type              VARCHAR(30)  NOT NULL,
  schedule_config            TEXT         NOT NULL DEFAULT '{}',
  start_on                   DATE,
  end_on                     DATE,
  send_time                  TIME         NOT NULL,
  timezone                   VARCHAR(64)  NOT NULL DEFAULT 'UTC',
  grace_window_hours         INTEGER      NOT NULL DEFAULT 4,
  last_schedule_key          VARCHAR(100),
  business_days_only         BOOLEAN      NOT NULL DEFAULT FALSE,
  non_business_day_behavior  VARCHAR(20)  NOT NULL DEFAULT 'skip',
  query_id                   INTEGER,
  include_subprojects        BOOLEAN      NOT NULL DEFAULT FALSE,
  include_open               BOOLEAN      NOT NULL DEFAULT TRUE,
  include_closed             BOOLEAN      NOT NULL DEFAULT FALSE,
  include_overdue            BOOLEAN      NOT NULL DEFAULT FALSE,
  include_due_soon           BOOLEAN      NOT NULL DEFAULT FALSE,
  due_soon_days              INTEGER      NOT NULL DEFAULT 7,
  include_recently_updated   BOOLEAN      NOT NULL DEFAULT FALSE,
  recently_updated_days      INTEGER      NOT NULL DEFAULT 7,
  include_recently_created   BOOLEAN      NOT NULL DEFAULT FALSE,
  recently_created_days      INTEGER      NOT NULL DEFAULT 7,
  since_last_run_created     BOOLEAN      NOT NULL DEFAULT FALSE,
  since_last_run_updated     BOOLEAN      NOT NULL DEFAULT FALSE,
  filter_assigned_to_recipient BOOLEAN    NOT NULL DEFAULT FALSE,
  filter_watched_by_recipient  BOOLEAN    NOT NULL DEFAULT FALSE,
  filter_authored_by_recipient BOOLEAN    NOT NULL DEFAULT FALSE,
  recipient_modes            TEXT         NOT NULL DEFAULT '[]',
  group_by                   VARCHAR(20)  NOT NULL DEFAULT 'none',
  send_empty                 BOOLEAN      NOT NULL DEFAULT FALSE,
  email_subject              VARCHAR(255),
  email_intro                TEXT,
  last_run_at                DATETIME,
  last_success_at            DATETIME,
  created_by_id              INTEGER      NOT NULL,
  updated_by_id              INTEGER,
  created_at                 DATETIME     NOT NULL,
  updated_at                 DATETIME     NOT NULL
);
```

### Field Specifications

| Column | Type | Nullable | Default | Validation | Purpose |
|--------|------|----------|---------|------------|---------|
| `id` | int, PK | NO | auto | — | Primary key |
| `project_id` | int, FK | NO | — | must exist in `projects` | Links rule to project |
| `name` | varchar(255) | NO | — | length 1–255 | Human-readable rule name |
| `active` | boolean | NO | true | — | Soft enable/disable toggle |
| `schedule_type` | varchar(30) | NO | — | in: daily, weekdays, weekly, monthly_date, monthly_last_day, interval_days, interval_weeks, manual | Determines schedule logic |
| `schedule_config` | text (JSON) | NO | `'{}'` | valid JSON; schema per type (see functional spec §2.3) | Type-specific schedule parameters |
| `start_on` | date | YES | NULL | end_on > start_on if both present | Rule inactive before this date; also serves as anchor for interval types |
| `end_on` | date | YES | NULL | > start_on if both present | Rule inactive after this date |
| `send_time` | time | NO | — | HH:MM:SS | Wall-clock time in `timezone`; not stored in UTC |
| `timezone` | varchar(64) | NO | `'UTC'` | valid IANA tz string | Timezone for send_time interpretation and schedule evaluation |
| `grace_window_hours` | int | NO | 4 | 0–23 | Hours after send_time within which the rule is still considered due |
| `last_schedule_key` | varchar(100) | YES | NULL | — | Most recently claimed scheduling window key; primary idempotency guard |
| `business_days_only` | boolean | NO | false | — | When true, skip or shift executions that fall on Sat/Sun |
| `non_business_day_behavior` | varchar(20) | NO | `'skip'` | in: skip, previous_weekday, next_weekday | What to do when trigger date is Sat/Sun and business_days_only is true |
| `query_id` | int, FK | YES | NULL | must exist in `queries` if set | Saved IssueQuery to apply filters from |
| `include_subprojects` | boolean | NO | false | — | Include issues from sub-projects |
| `include_open` | boolean | NO | true | — | Include open issues |
| `include_closed` | boolean | NO | false | — | Include closed issues |
| `include_overdue` | boolean | NO | false | — | Include overdue open issues |
| `include_due_soon` | boolean | NO | false | — | Include issues due within N days |
| `due_soon_days` | int | NO | 7 | 1–365 | "Due soon" window in days |
| `include_recently_updated` | boolean | NO | false | — | Include recently updated issues |
| `recently_updated_days` | int | NO | 7 | 1–365 | "Recently updated" window in days |
| `include_recently_created` | boolean | NO | false | — | Include recently created issues |
| `recently_created_days` | int | NO | 7 | 1–365 | "Recently created" window in days |
| `since_last_run_created` | boolean | NO | false | — | Narrow to issues **created** after the last successful run |
| `since_last_run_updated` | boolean | NO | false | — | Narrow to issues **updated** after the last successful run |
| `filter_assigned_to_recipient` | boolean | NO | false | — | Per-recipient: only show assigned-to-recipient issues |
| `filter_watched_by_recipient` | boolean | NO | false | — | Per-recipient: only show issues watched by recipient |
| `filter_authored_by_recipient` | boolean | NO | false | — | Per-recipient: only show issues authored by recipient |
| `recipient_modes` | text (JSON array) | NO | `'[]'` | valid JSON array; non-empty | JSON array of recipient mode strings |
| `group_by` | varchar(20) | NO | `'none'` | in: none, assignee, priority, tracker, status, version, category | Email grouping field |
| `send_empty` | boolean | NO | false | — | Send email even if no matching issues |
| `email_subject` | varchar(255) | YES | NULL | max 255 | Custom email subject template (nil = auto-generated) |
| `email_intro` | text | YES | NULL | max 2000 chars | Custom intro text for email body |
| `last_run_at` | datetime | YES | NULL | — | Timestamp of most recent rake run (success or failure) |
| `last_success_at` | datetime | YES | NULL | — | Timestamp of most recent successful run |
| `created_by_id` | int, FK | NO | — | must exist in `users` | User who created the rule |
| `updated_by_id` | int, FK | YES | NULL | must exist in `users` if set | User who last updated the rule |
| `created_at` | datetime | NO | — | — | Rails standard timestamp |
| `updated_at` | datetime | NO | — | — | Rails standard timestamp |

### Indexes

```sql
CREATE INDEX idx_issue_digest_rules_project_id ON issue_digest_rules (project_id);
CREATE INDEX idx_issue_digest_rules_active ON issue_digest_rules (active);
CREATE INDEX idx_issue_digest_rules_query_id ON issue_digest_rules (query_id);
CREATE INDEX idx_issue_digest_rules_last_run_at ON issue_digest_rules (last_run_at);
CREATE INDEX idx_issue_digest_rules_schedule_key ON issue_digest_rules (last_schedule_key);
```

Composite index for the rake task query:
```sql
CREATE INDEX idx_issue_digest_rules_due ON issue_digest_rules (active, project_id, last_run_at);
```

### Associations

```ruby
belongs_to :project
belongs_to :query, class_name: 'IssueQuery', foreign_key: :query_id, optional: true
belongs_to :created_by, class_name: 'User', foreign_key: :created_by_id
belongs_to :updated_by, class_name: 'User', foreign_key: :updated_by_id, optional: true
has_many :issue_digest_runs, dependent: :destroy
```

### Dependent behavior

- Deleting a `Project` does NOT automatically cascade to `issue_digest_rules` unless a
  foreign key constraint is in place. **Recommendation**: add `ON DELETE CASCADE` to the
  `project_id` FK, OR handle cleanup in a Rails `before_destroy` callback on the `Project`
  model via a hook. Since we cannot modify `Project`, use a Redmine hook:
  `Redmine::Hook.add_listener` for the project destroy event.
  
  **Alternative**: Leave orphan rules; the rake task skips rules for non-existent projects.
  Query: `issue_digest_rules JOIN projects ON projects.id = issue_digest_rules.project_id`.

  **Recommended approach**: FK with `ON DELETE CASCADE` in migration (add `foreign_key: true`
  to `add_reference` call). Rails/ActiveRecord will manage this if the DB supports it.

- Deleting a `Query` (IssueQuery) does not cascade. The `query_id` becomes a dangling
  reference. The rake task handles this via `find_by` returning nil (EC-04 in functional spec).

### `schedule_config` JSON Schema

```json
// daily
{}

// weekdays
{ "days": [1, 2, 3, 4, 5] }
// ISO day numbers: 1=Monday, 7=Sunday

// weekly
{ "day": 1 }
// 1=Monday, 7=Sunday

// monthly
{ "day": 1 }
// 1–28
```

### `recipient_modes` JSON Schema

```json
["project_members", "role:3", "user:42", "assignees", "authors", "watchers"]
```

Each element is a string. Format:
- `"project_members"` — all active project members
- `"role:<id>"` — members with this role ID
- `"user:<id>"` — specific user ID
- `"assignees"` — assigned users of matching issues
- `"authors"` — authors of matching issues
- `"watchers"` — watchers of matching issues

---

## 3. Table: `issue_digest_runs`

### Purpose
Records one execution event per rule per rake task invocation.

### Schema

```sql
CREATE TABLE issue_digest_runs (
  id                    INTEGER      NOT NULL PRIMARY KEY,
  issue_digest_rule_id  INTEGER      NOT NULL,
  started_at            DATETIME     NOT NULL,
  finished_at           DATETIME,
  status                VARCHAR(20)  NOT NULL DEFAULT 'running',
  trigger               VARCHAR(20)  NOT NULL DEFAULT 'scheduled',
  schedule_key          VARCHAR(100),
  recipients_count      INTEGER      NOT NULL DEFAULT 0,
  emails_sent_count     INTEGER      NOT NULL DEFAULT 0,
  emails_failed_count   INTEGER      NOT NULL DEFAULT 0,
  issues_count          INTEGER      NOT NULL DEFAULT 0,
  warning_message       TEXT,
  error_message         TEXT,
  created_at            DATETIME     NOT NULL,
  updated_at            DATETIME     NOT NULL
);
```

### Field Specifications

| Column | Type | Nullable | Default | Validation | Purpose |
|--------|------|----------|---------|------------|---------|
| `id` | int, PK | NO | auto | — | Primary key |
| `issue_digest_rule_id` | int, FK | NO | — | must exist | Links run to its rule |
| `started_at` | datetime | NO | — | — | When processing of this rule began |
| `finished_at` | datetime | YES | NULL | — | When processing finished (nil if still running) |
| `status` | varchar(20) | NO | `'running'` | in: running, success, partial_failure, failed, error, skipped | Final status of the run |
| `trigger` | varchar(20) | NO | `'scheduled'` | in: scheduled, manual, dry_run | What triggered this run |
| `schedule_key` | varchar(100) | YES | NULL | — | The schedule window key that was claimed for this run; matches `issue_digest_rules.last_schedule_key` at the time of the run |
| `recipients_count` | int | NO | 0 | >= 0 | Number of recipients resolved |
| `emails_sent_count` | int | NO | 0 | >= 0 | Number of emails successfully sent |
| `emails_failed_count` | int | NO | 0 | >= 0 | Number of delivery failures |
| `issues_count` | int | NO | 0 | >= 0 | Total unique issues found across all recipients |
| `warning_message` | text | YES | NULL | max 2000 chars | Non-fatal warnings (e.g., query not found) |
| `error_message` | text | YES | NULL | max 2000 chars | Fatal error message if status is error/failed |
| `created_at` | datetime | NO | — | — | Rails timestamp |
| `updated_at` | datetime | NO | — | — | Rails timestamp |

### Status value semantics

| Trigger | Meaning |
|---------|---------|
| `scheduled` | Normal cron-driven execution |
| `manual` | Invoked via `MANUAL=1` or `RULE_ID=X` |
| `dry_run` | `DRY_RUN=1`; no emails sent, no DB records |

### Run status semantics

| Status | Meaning |
|--------|---------|
| `running` | Currently executing (should not persist after process ends) |
| `success` | All deliveries succeeded |
| `partial_failure` | Some deliveries failed, some succeeded |
| `failed` | All deliveries failed |
| `error` | Execution-level error (rule resolution failed) |
| `skipped` | No recipients found; no emails sent |

### Indexes

```sql
CREATE INDEX idx_issue_digest_runs_rule_id ON issue_digest_runs (issue_digest_rule_id);
CREATE INDEX idx_issue_digest_runs_started_at ON issue_digest_runs (started_at);
CREATE INDEX idx_issue_digest_runs_status ON issue_digest_runs (status);
```

Composite for history queries:
```sql
CREATE INDEX idx_issue_digest_runs_rule_started ON issue_digest_runs (issue_digest_rule_id, started_at DESC);
```

### Associations

```ruby
belongs_to :issue_digest_rule
has_many :issue_digest_deliveries, dependent: :destroy
```

### Dependent behavior

- `dependent: :destroy` on `issue_digest_rule` → runs deleted when rule is deleted.
- `issue_digest_deliveries` → deleted when run is deleted.

---

## 4. Table: `issue_digest_deliveries`

### Purpose
Records one email delivery attempt per recipient per run.

### Schema

```sql
CREATE TABLE issue_digest_deliveries (
  id                    INTEGER      NOT NULL PRIMARY KEY,
  issue_digest_run_id   INTEGER      NOT NULL,
  user_id               INTEGER,
  email                 VARCHAR(255) NOT NULL,
  status                VARCHAR(20)  NOT NULL DEFAULT 'sent',
  issues_count          INTEGER      NOT NULL DEFAULT 0,
  sent_at               DATETIME,
  error_message         TEXT,
  created_at            DATETIME     NOT NULL,
  updated_at            DATETIME     NOT NULL
);
```

### Field Specifications

| Column | Type | Nullable | Default | Validation | Purpose |
|--------|------|----------|---------|------------|---------|
| `id` | int, PK | NO | auto | — | Primary key |
| `issue_digest_run_id` | int, FK | NO | — | must exist | Links delivery to its run |
| `user_id` | int, FK | YES | NULL | — | Redmine user; NULL reserved for future external recipient support (not used in v1) |
| `email` | varchar(255) | NO | — | valid format | Email address delivered to |
| `status` | varchar(20) | NO | `'sent'` | in: sent, failed, skipped | Delivery outcome |
| `issues_count` | int | NO | 0 | >= 0 | Issues included in this recipient's email |
| `sent_at` | datetime | YES | NULL | — | When email was dispatched (nil if failed/skipped) |
| `error_message` | text | YES | NULL | max 2000 chars | SMTP or other error message |
| `created_at` | datetime | NO | — | — | Rails timestamp |
| `updated_at` | datetime | NO | — | — | Rails timestamp |

### Status value semantics

| Status | Meaning |
|--------|---------|
| `sent` | Email delivered to SMTP relay (may still bounce) |
| `failed` | SMTP or generation error; see `error_message` |
| `skipped` | Recipient excluded (no visible issues, locked user, etc.) |

### Indexes

```sql
CREATE INDEX idx_issue_digest_deliveries_run_id ON issue_digest_deliveries (issue_digest_run_id);
CREATE INDEX idx_issue_digest_deliveries_user_id ON issue_digest_deliveries (user_id);
CREATE INDEX idx_issue_digest_deliveries_status ON issue_digest_deliveries (status);
```

### Associations

```ruby
belongs_to :issue_digest_run
belongs_to :user, optional: true
```

---

## 5. Serialization Strategy

### `schedule_config` and `recipient_modes`

**Primary approach**: Store as TEXT; serialize/deserialize using Ruby's `JSON` module:

```ruby
# In model
serialize :schedule_config, coder: JSON
serialize :recipient_modes, coder: JSON
```

This works on all three supported database backends (PostgreSQL, MySQL, SQLite3).

**Alternative for PostgreSQL-only deployments**: Use `jsonb` column type for indexed
querying. Not recommended for v1 given cross-DB compatibility goal.

**Validation**:
- Always validate parsed JSON matches expected schema before saving.
- Treat nil/empty as `{}` for `schedule_config` and `[]` for `recipient_modes`.

---

## 6. Data Retention Policy

Default: 90 days for `issue_digest_runs` and `issue_digest_deliveries`.

- Configurable via global plugin settings: `run_history_retention_days`.
- Cleanup task: `bundle exec rake redmine:issue_digest:cleanup RAILS_ENV=production`.
- The cleanup task deletes runs older than the retention window and their cascade-deleted deliveries.
- Rules themselves are never auto-deleted by retention policy.

---

## 7. Migration Strategy

### Migration naming convention

Follow Redmine plugin migration convention: files named `NNN_description.rb` with N
being a sequential integer (not a timestamp, since plugin migrations use integer versioning).

Example:
```
db/migrate/001_create_issue_digest_rules.rb
db/migrate/002_create_issue_digest_runs.rb
db/migrate/003_create_issue_digest_deliveries.rb
```

### Migration version

Use `ActiveRecord::Migration[7.2]` in the migration class. Redmine 5.1 compatibility:
Redmine's plugin migration runner uses the migration version specified in the file;
if `[7.2]` causes compatibility issues on Rails 7.0, the coding agent should detect
the Rails version and use `[7.0]` accordingly.

**Recommendation**: Use `ActiveRecord::Migration[#{Rails::VERSION::MAJOR}.#{Rails::VERSION::MINOR}]`
dynamically, or simply `ActiveRecord::Migration[7.0]` (which is forward-compatible to 7.2).

### Foreign keys

Add FK constraints in migrations using `add_foreign_key`:

```ruby
add_foreign_key :issue_digest_rules, :projects, on_delete: :cascade
add_foreign_key :issue_digest_rules, :users, column: :created_by_id
add_foreign_key :issue_digest_runs, :issue_digest_rules, on_delete: :cascade
add_foreign_key :issue_digest_deliveries, :issue_digest_runs, on_delete: :cascade
```

Note: `query_id` FK is intentionally omitted to handle deleted queries gracefully.

---

## 8. ER Diagram (Textual)

```
projects (Redmine core)
  ↓ 1:N
issue_digest_rules
  - project_id → projects.id (FK, cascade on delete)
  - query_id → queries.id (no FK, nullable, soft reference)
  - created_by_id → users.id (FK)
  - updated_by_id → users.id (FK, nullable)
  ↓ 1:N
issue_digest_runs
  - issue_digest_rule_id → issue_digest_rules.id (FK, cascade)
  ↓ 1:N
issue_digest_deliveries
  - issue_digest_run_id → issue_digest_runs.id (FK, cascade)
  - user_id → users.id (FK, nullable)
```

---

## 9. Resolved Technical Data Model Decisions

These were internal technical questions; decisions are now recorded as implementation requirements.

| ID | Decision |
|----|---------|
| OQ-DB-01 | **Use `:text` columns for `schedule_config` and `recipient_modes`** with `serialize :field, coder: JSON`. `jsonb` is not used in v1 for broadest DB compatibility (PostgreSQL, MySQL, SQLite3). |
| OQ-DB-02 | **Use `:time` column type for `send_time`** in the migration (`t.time :send_time`). Rails maps this correctly on PostgreSQL and MySQL. For SQLite3, ActiveRecord serializes `TIME` columns as strings; retrieve and parse via `TimeWithZone` in the model. |
| OQ-DB-03 | **Store `issues_count` per `issue_digest_delivery` row** (not only at the run level). Personalized digests produce different issue counts per recipient; per-delivery storage is required. |
| OQ-DB-04 | **Keep `warning_message` and `error_message` as separate columns** in `issue_digest_runs`. Warnings are non-fatal (e.g., deleted query) and may coexist with a `success` status. Merging them would obscure run health. |
