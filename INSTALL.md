# Installing `redmine_mail_digest`

A step-by-step installation guide. See `README.md` for usage, configuration,
and operational guidance after install.

---

## Requirements

| Component | Required version |
|-----------|------------------|
| Redmine   | 5.1.x or 6.1.x |
| Ruby      | ≥ 3.0 (Redmine 5.1) / 3.2–3.4 (Redmine 6.1) |
| Rails     | 7.0.x or 7.2.x (provided by Redmine) |
| Database  | PostgreSQL 14+ recommended; MySQL 8+ or SQLite 3 also supported |
| Cron      | Standard system cron (or any equivalent scheduler) |

No additional Ruby gems are needed at runtime. The plugin's `Gemfile`
adds `rspec-rails` and `factory_bot_rails` only in the `:test` group.

---

## 1. Install the plugin

From the Redmine installation root:

```bash
cd plugins
git clone https://github.com/jcatrysse/redmine_mail_digest.git
```

## 2. Run migrations

```bash
cd ..   # back to the Redmine root
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
```

This creates three tables: `issue_digest_rules`, `issue_digest_runs`,
`issue_digest_deliveries`.

## 3. Restart Redmine

```bash
touch tmp/restart.txt   # Passenger
# or restart Puma/Unicorn/your app server as appropriate
```

## 4. Enable the project module

For each project that should be allowed to send digests:

1. Go to **Project Settings → Modules**.
2. Check **Issue Digests** and save.

## 5. Assign permissions

Go to **Administration → Roles and Permissions → Issue Digest** and assign:

| Permission              | Recommended roles    |
|-------------------------|----------------------|
| `manage_digest_rules`   | Manager              |
| `view_digest_rules`     | Developer, Reporter  |

## 6. Configure the cron job

Add to your system crontab (run `crontab -e` as the Redmine user):

```cron
# Send digests every 15 minutes — recommended for minute-level granularity
*/15 * * * * cd /path/to/redmine && bundle exec rake redmine:issue_digest:send \
  RAILS_ENV=production >> log/issue_digest.log 2>&1

# Daily cleanup of run history at 00:00
0 0 * * * cd /path/to/redmine && bundle exec rake redmine:issue_digest:cleanup \
  RAILS_ENV=production >> log/issue_digest.log 2>&1
```

Alternative cron strategies:

```cron
# Hourly (simpler; only useful if send_time values are on the hour)
0 * * * * cd /path/to/redmine && bundle exec rake redmine:issue_digest:send \
  RAILS_ENV=production >> log/issue_digest.log 2>&1
```

```cron
# With RVM (adjust path)
*/15 * * * * cd /path/to/redmine && \
  /usr/local/rvm/bin/rvm default do bundle exec rake redmine:issue_digest:send \
  RAILS_ENV=production >> log/issue_digest.log 2>&1
```

> **Important**: missed scheduling windows are **not** caught up automatically.
> Monitor cron health (Healthchecks.io, Nagios, etc.); a stalled cron silently
> drops digest sends.

## 7. Verify

```bash
bundle exec rake redmine:issue_digest:send DRY_RUN=1 VERBOSE=1 \
  RAILS_ENV=production
```

This prints what would be sent for any due rules without actually sending or
recording anything. If you see `Found 0 due rules`, that just means nothing
is due right now — create a rule from the project UI and try again.

---

## Migrating from `redmine_digest` (existing installations)

This plugin was previously registered under the identifier `redmine_digest`.
If you already run that earlier version, follow the steps below to switch to
`redmine_mail_digest` **without losing any data**.

Why this is safe: the database tables (`issue_digest_rules`,
`issue_digest_runs`, `issue_digest_deliveries`) are named after the plugin's
internal `issue_digest` namespace, **not** after the plugin identifier. The
rename therefore touches only two pieces of Redmine bookkeeping:

1. the plugin settings row (`settings.name = 'plugin_redmine_digest'`), and
2. the plugin migration markers in `schema_migrations`
   (`<n>-redmine_digest`), which Redmine writes as `<version>-<plugin_id>`.

Your rules, run history and deliveries are left completely untouched.

> ⚠️ **Do NOT** uninstall the old plugin with
> `rake redmine:plugins:migrate NAME=redmine_digest VERSION=0`. That runs the
> `down` migrations and **drops the `issue_digest_*` tables**, deleting every
> rule and all run history. Use the in-place rename below instead.

### 1. Back up the database

```bash
# PostgreSQL example
pg_dump redmine_production > redmine_backup_$(date +%F).sql
```

### 2. Stop Redmine (or enter maintenance mode)

Stop the app server so no request or cron run touches the plugin mid-migration.

### 3. Rename the plugin directory

The directory name **must** equal the new identifier. Redmine validates this at
boot: a plugin registered as `redmine_mail_digest` from a directory named
`redmine_digest` raises `Redmine::PluginNotFound` and the whole instance fails
to start. Rename the directory so it matches:

```bash
cd /path/to/redmine/plugins
# If you track the plugin with git and renamed the remote repository:
mv redmine_digest redmine_mail_digest
cd redmine_mail_digest && git pull   # pull the renamed release
# (Alternatively: rm -rf redmine_digest && git clone <repo> redmine_mail_digest)
```

### 4. Rename the database bookkeeping

Run **inside a transaction** against your Redmine database. Pick the snippet for
your adapter; both statements are required.

**PostgreSQL / MySQL / MariaDB:**

```sql
BEGIN;

-- Preserve the configured global plugin settings.
UPDATE settings
   SET name = 'plugin_redmine_mail_digest'
 WHERE name = 'plugin_redmine_digest';

-- Re-point the plugin migration markers so Redmine knows migrations 1..7
-- have already run and does not try to re-create existing tables.
UPDATE schema_migrations
   SET version = REPLACE(version, '-redmine_digest', '-redmine_mail_digest')
 WHERE version LIKE '%-redmine_digest';

COMMIT;
```

**SQLite:** the same two `UPDATE` statements work (wrap in
`BEGIN;` / `COMMIT;`).

### 5. Confirm migrations are settled

```bash
cd /path/to/redmine
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
```

This must report **no pending migrations** for `redmine_mail_digest`. If it
tries to run `001_create_issue_digest_rules` (or fails with "table already
exists"), step 4 did not match — recheck the `schema_migrations` rows:

```sql
SELECT version FROM schema_migrations WHERE version LIKE '%digest%';
-- expect: 1-redmine_mail_digest … 7-redmine_mail_digest (no *-redmine_digest left)
```

### 6. Restart and verify

```bash
touch tmp/restart.txt
```

Then confirm:

- **Administration → Plugins** lists **Redmine Mail Digest** (no duplicate, no
  old entry).
- **Administration → Plugins → Configure** still shows your previous settings
  (max issues per email, retention days, external-recipient option).
- A project's **Digest Rules** list still contains your existing rules and run
  history.
- A dry run sees your rules:
  `bundle exec rake redmine:issue_digest:send DRY_RUN=1 VERBOSE=1 RAILS_ENV=production`

> Note: this plugin ships no public assets, so there is nothing to clean up
> under `public/plugin_assets/`. If you previously generated any, you may
> remove the stale `public/plugin_assets/redmine_digest` directory.

---

## Upgrading

```bash
cd /path/to/redmine/plugins/redmine_mail_digest
git pull
cd ../..
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
touch tmp/restart.txt
```

## Uninstalling

```bash
cd /path/to/redmine
bundle exec rake redmine:plugins:migrate NAME=redmine_mail_digest VERSION=0 \
  RAILS_ENV=production
rm -rf plugins/redmine_mail_digest
touch tmp/restart.txt
```

This drops the three plugin tables; existing digest rules and run history are
permanently deleted.

---

## Troubleshooting

### `Could not acquire lock`

A previous run is still in progress, or a stale advisory lock is held. Wait
one cron cycle. The lock is released automatically when the rake task
finishes or its process exits.

### `Module is not enabled`

Enable **Issue Digests** under the project's **Settings → Modules**. The
rake task ignores rules belonging to projects with the module disabled.

### No emails arrive

1. Run with `DRY_RUN=1 VERBOSE=1` to confirm the rule is being matched.
2. Check Redmine's mailer configuration (`config/configuration.yml`).
3. Check the project recipients have email addresses and `view_issues`
   permission on the project.
4. Inspect the run history: project menu → **Digest Rules** → click the
   rule → **Run History** section.

### Wrong send time / timezone

The `send_time` field is a wall-clock time in the rule's `timezone`. A rule
set to 08:00 in `Europe/Brussels` fires at 06:00 UTC in winter and 07:00
UTC in summer.
