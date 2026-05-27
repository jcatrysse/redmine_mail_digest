# Installing `redmine_digest`

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
git clone https://github.com/jcatrysse/redmine_digest.git
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

## Upgrading

```bash
cd /path/to/redmine/plugins/redmine_digest
git pull
cd ../..
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
touch tmp/restart.txt
```

## Uninstalling

```bash
cd /path/to/redmine
bundle exec rake redmine:plugins:migrate NAME=redmine_digest VERSION=0 \
  RAILS_ENV=production
rm -rf plugins/redmine_digest
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
