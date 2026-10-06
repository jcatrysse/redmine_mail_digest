# digest-send: commands and output

Run 2026-10-06T19:59:27.686Z.

```
$ rake redmine:issue_digest:send DRY_RUN=1 MANUAL=1 RULE_ID=4 VERBOSE=1
[IssueDigest] Starting at 2026-10-06T19:58:13Z (dry_run=true, force=true)
[IssueDigest] Found 1 due rules
[IssueDigest] Processing rule #4: E2E send rule (project: e2e-project)
[DRY_RUN] Rule #4 (E2E send rule): 3 recipients
  [DRY_RUN] Would send 6 issues to user #8
  [DRY_RUN] Would send 7 issues to user #5
  [DRY_RUN] Would send 6 issues to user #6
[IssueDigest] Rule #4: DRY_RUN summary: 3 plans (3 recipients)
[IssueDigest] Finished at 2026-10-06T19:58:14Z (1 rules, 0 emails, 0 failures)

$ rake redmine:issue_digest:send MANUAL=1 RULE_ID=4 VERBOSE=1
[IssueDigest] Starting at 2026-10-06T19:58:21Z (dry_run=false, force=true)
[IssueDigest] Found 1 due rules
[IssueDigest] Processing rule #4: E2E send rule (project: e2e-project)
[IssueDigest] Rule #4: completed (success, sent=3, failed=0)
[IssueDigest] Finished at 2026-10-06T19:58:23Z (1 rules, 3 emails, 0 failures)

$ ls tmp/mails
manager@example.net
reporter@example.net
viewer@example.net

$ manager mail headers
To: manager@example.net
Subject: E2E digest 1791316686020 E2E project: 7 issues
MIME-Version: 1.0
Content-Type: multipart/alternative;
Auto-Submitted: auto-generated
X-Auto-Response-Suppress: All

$ rake redmine:issue_digest:send VERBOSE=1   # the cron entry
[IssueDigest] Starting at 2026-10-06T19:58:33Z (dry_run=false, force=false)
[IssueDigest] Found 1 due rules
[IssueDigest] Processing rule #5: E2E scheduled rule (project: e2e-project)
[IssueDigest] Finished at 2026-10-06T19:58:35Z (1 rules, 0 emails, 0 failures)

$ rake redmine:issue_digest:send VERBOSE=1   # again, same window
[IssueDigest] Starting at 2026-10-06T19:58:37Z (dry_run=false, force=false)
[IssueDigest] Found 0 due rules
[IssueDigest] Finished at 2026-10-06T19:58:37Z (0 rules, 0 emails, 0 failures)

$ rake redmine:issue_digest:send MANUAL=1 RULE_ID=4 VERBOSE=1   # rule disabled
[IssueDigest] Starting at 2026-10-06T19:58:45Z (dry_run=false, force=true)
[IssueDigest] Found 0 due rules
[IssueDigest] Finished at 2026-10-06T19:58:45Z (0 rules, 0 emails, 0 failures)

$ rake redmine:issue_digest:send MANUAL=1 RULE_ID=4   # max_issues_per_email = 2
(no output)

$ rake redmine:issue_digest:cleanup   # retention 90 days, one run of 200 days old
[IssueDigest] Cleanup: deleted 1 runs, 0 deliveries
runs of the rule: 3 -> 2
```
