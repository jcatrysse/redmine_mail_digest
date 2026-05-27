# redmine_digest

A Redmine plugin for scheduled issue digest emails.

`redmine_digest` lets project managers configure rules that send periodic email
summaries of project issues to configurable recipients on a configurable schedule.
Digests are sent through Redmine's standard mailer and triggered by a cron-driven
rake task.

---

## Features

- **8 schedule types** — daily, selected weekdays, weekly, monthly by date, monthly on
  last day, every N days, every N weeks, and manual (rake-only)
- **Flexible recipients** — all project members, members by role, assignees, authors,
  watchers, or specific users
- **Issue filters** — open, closed, overdue, due soon, recently updated, recently
  created, or based on an existing saved Redmine query
- **Per-recipient personalization** — each recipient sees only the issues they are
  permitted to view; private issues are excluded automatically
- **Grace window** — configurable tolerance for late cron runs; missed windows are
  cleanly skipped
- **Business-days-only option** — skip or shift Saturday/Sunday occurrences
  (Monday–Friday only; no holiday calendar)
- **Schedule key idempotency** — robust duplicate-send prevention using a per-window
  key; safe against concurrent cron invocations
- **Run history** — every execution is recorded with recipient counts, delivery
  outcomes, and error messages
- **Dry-run mode** — preview what would be sent without sending anything
- **HTML and plain-text emails** — multipart email consistent with Redmine's style
- Compatible with **Redmine 5.1** and **Redmine 6.1**

---

## Requirements

| Component | Version |
|-----------|---------|
| Redmine | 5.1.x or 6.1.x |
| Ruby | ≥ 3.0 (5.1) / ≥ 3.2, < 3.5 (6.1) |
| Rails | 7.0.x (5.1) / 7.2.x (6.1) |
| Database | PostgreSQL 14+, MySQL 8.0+, or SQLite 3.x |

No additional gems are required beyond those already included in Redmine.

---

## Installation

### 1. Clone or copy the plugin

```bash
cd /path/to/redmine/plugins
git clone https://github.com/jcatrysse/redmine_digest.git
```

### 2. Run database migrations

```bash
cd /path/to/redmine
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
```

### 3. Restart Redmine

```bash
# Passenger / Puma / whatever your app server uses
touch tmp/restart.txt
```

---

## Configuration

### Global admin settings

Navigate to **Administration → Plugins → redmine_digest → Configure**:

| Setting | Default | Description |
|---------|---------|-------------|
| Maximum issues per email | 500 | Hard cap applied to every digest; range 1–5000 |
| Run history retention (days) | 90 | Digest run records older than this are pruned by the cleanup task. Set to 0 to keep records indefinitely. |

### Enable the module per project

1. Open a project → **Settings → Modules**.
2. Check **Issue Digests** and save.
3. A **Digest Rules** entry appears in the project menu.

### Permissions

Assign roles in **Administration → Roles and Permissions → Issue Digest**:

| Permission | Recommended roles |
|-----------|-----------------|
| `manage_digest_rules` | Manager, Project Manager |
| `view_digest_rules` | Developer, Reporter (optional) |

---

## Creating a digest rule

1. Open a project with the Issue Digests module enabled.
2. Click **Digest Rules** in the project menu.
3. Click **New digest rule**.
4. Fill in:
   - **Name** — a descriptive label (e.g. "Daily open issues")
   - **Schedule** — choose a schedule type and configure its options
   - **Send time** and **Timezone**
   - **Grace window** — how late the cron can be and still send (default: 24 hours)
   - **Issue filters** — which issues to include
   - **Recipients** — who receives the email
5. Save. The rule is active and will be sent on the next matching cron run.

### Schedule types reference

| Type | Description | `schedule_config` |
|------|-------------|------------------|
| `daily` | Every day at send time | `{}` |
| `weekdays` | On selected days (e.g. Mon, Wed, Fri) | `{"days":[1,3,5]}` |
| `weekly` | Every week on a specific day | `{"day":1}` (1=Mon, 7=Sun) |
| `monthly_date` | On day N of each month (1–28) | `{"day":15}` |
| `monthly_last_day` | On the last calendar day of each month | `{}` |
| `interval_days` | Every N days, anchored to start date | `{"every":3}` |
| `interval_weeks` | Every N weeks, anchored to start date | `{"every":2}` |
| `manual` | Never automatic; use rake task only | `{}` |

**Which type should I use?**

| I want to send… | Use |
|-----------------|-----|
| A daily standup / end-of-day summary | `daily` |
| Monday, Wednesday, Friday only | `weekdays` with `{"days":[1,3,5]}` |
| Every Monday | `weekly` with `{"day":1}` |
| On the 1st of every month | `monthly_date` with `{"day":1}` |
| On the last day of every month | `monthly_last_day` |
| Every sprint (every 14 days) | `interval_days` with `{"every":14}` |
| Every two weeks on the same weekday | `interval_weeks` with `{"every":2}` |
| Only when I explicitly trigger it | `manual` |

> **Note**: Days 29–31 are not available for `monthly_date` to avoid February edge cases.
> Use `monthly_last_day` for end-of-month sends.

### Timezone, grace window, and scheduling guarantees

**Timezone** — each rule has its own IANA timezone (e.g. `Europe/Brussels`). The `Send time`
field is a wall-clock time in that timezone, not UTC. A rule set to 08:00 Brussels time fires
at 06:00 UTC in winter and 07:00 UTC in summer. Daylight saving transitions cause at most one
extra or missed send per year — documented as an accepted limitation.

**Grace window** — the number of hours after `send_time` during which the rule is still
considered due (default: 24 hours). This prevents a rule scheduled for 08:00 from sending at
23:55 if the server was overloaded. If the cron misses the grace window entirely, that window
is skipped and the next occurrence is awaited.

**Schedule key (idempotency)** — every scheduling window has a deterministic key
(e.g. `42:D:2026-05-27`). The rake task claims the key atomically before sending,
preventing duplicate emails even when cron runs overlap or the server restarts mid-execution.

**Catch-up behavior** — there is no automatic catch-up. If the cron job is down for three
days, those windows are permanently skipped. Operators can manually re-send via:

```bash
bundle exec rake redmine:issue_digest:send RULE_ID=42 MANUAL=1 RAILS_ENV=production
```

### Business days only

Enable **Weekdays only** on any rule (except `weekdays` and `manual`). When the
scheduled trigger date falls on a Saturday or Sunday, choose one of:

- **Skip** — that occurrence is skipped entirely
- **Use preceding Friday** — rule fires the Friday before
- **Use following Monday** — rule fires the Monday after

No holiday calendar is supported in this version.

### Interval anchoring

For `interval_days` and `interval_weeks`, the interval is counted from the rule's
**Start date** (if set) or the rule's **creation date** (if no start date). For
example, a rule set to "every 7 days" starting 2026-01-01 will fire on 2026-01-01,
2026-01-08, 2026-01-15, and so on — regardless of when the cron last ran.

---

## Rake task

### Standard cron invocation

```bash
bundle exec rake redmine:issue_digest:send RAILS_ENV=production
```

### All options

| Environment variable | Description |
|---------------------|-------------|
| `DRY_RUN=1` | Print what would be sent; no emails sent, no records written |
| `PROJECT_IDENTIFIER=my-project` | Limit to one project |
| `RULE_ID=42` | Limit to one rule |
| `VERBOSE=1` | Log rule names, recipient counts, and issue counts |
| `FORCE=1` | Ignore idempotency guard; re-send even if already sent in this window |
| `MANUAL=1` | Equivalent to `FORCE=1`; triggers `manual` schedule_type rules |

### Example commands

```bash
# Standard scheduled run
bundle exec rake redmine:issue_digest:send RAILS_ENV=production

# Dry-run: see what would be sent
bundle exec rake redmine:issue_digest:send DRY_RUN=1 RAILS_ENV=production

# Verbose dry-run for a specific project
bundle exec rake redmine:issue_digest:send DRY_RUN=1 VERBOSE=1 \
  PROJECT_IDENTIFIER=my-project RAILS_ENV=production

# Trigger a manual rule
bundle exec rake redmine:issue_digest:send RULE_ID=42 MANUAL=1 RAILS_ENV=production

# Prune old run history
bundle exec rake redmine:issue_digest:cleanup RAILS_ENV=production
```

### Recommended cron configuration

```cron
# Send digests every 15 minutes (recommended)
*/15 * * * * cd /path/to/redmine && bundle exec rake redmine:issue_digest:send \
  RAILS_ENV=production >> log/issue_digest.log 2>&1

# Alternatively, hourly (digest send times are rounded to the nearest hour by the grace window)
0 * * * * cd /path/to/redmine && bundle exec rake redmine:issue_digest:send \
  RAILS_ENV=production >> log/issue_digest.log 2>&1

# Daily cleanup at midnight
0 0 * * * cd /path/to/redmine && bundle exec rake redmine:issue_digest:cleanup \
  RAILS_ENV=production >> log/issue_digest.log 2>&1
```

> **Important**: If the cron job is interrupted, missed scheduling windows are
> permanently skipped — there is no automatic catch-up. Monitor cron job health
> with your preferred monitoring tool (e.g. Healthchecks.io, Nagios, etc.).

---

## Idempotency and concurrency

Each scheduling window is identified by a unique **schedule key** (e.g.
`42:D:2026-05-27` for a daily rule). The task claims a window atomically via a
database `UPDATE … WHERE last_schedule_key != ?`, preventing duplicate sends even
when multiple cron processes overlap. On PostgreSQL, an advisory lock provides an
additional layer of protection.

---

## Uninstallation

```bash
cd /path/to/redmine
bundle exec rake redmine:plugins:migrate NAME=redmine_digest VERSION=0 RAILS_ENV=production
rm -rf plugins/redmine_digest
```

---

## Development

### Running tests

```bash
# Clone Redmine alongside the plugin
git clone --depth 1 --branch 6.1-stable https://github.com/redmine/redmine.git
cd redmine
ln -s /path/to/redmine_digest plugins/redmine_digest

# Set up the test database
cp config/database.yml.example config/database.yml
# (edit database.yml for your local DB)
bundle install
bundle exec rake db:create db:migrate redmine:plugins:migrate RAILS_ENV=test

# Run the plugin's test suite
bundle exec rspec plugins/redmine_digest/spec
```

### CI

Two GitHub Actions workflows are provided:

- `.github/workflows/rspec-61.yml` — Redmine 6.1, Ruby 3.3, PostgreSQL 16
- `.github/workflows/rspec-51.yml` — Redmine 5.1, Ruby 3.2, PostgreSQL 16

Trigger them manually from the **Actions** tab.

---

## Contributing

1. Fork the repository.
2. Create a branch: `git checkout -b feature/your-feature`.
3. Write tests for your change.
4. Ensure the full test suite passes.
5. Open a pull request with a clear description.

Please follow Redmine's [coding standards](https://www.redmine.org/projects/redmine/wiki/Coding_Guidelines)
for Ruby and ERB code.

---

## License

This plugin is released under the [GNU General Public License v2](LICENSE).

Copyright © 2026 Jan Catrysse and contributors.
