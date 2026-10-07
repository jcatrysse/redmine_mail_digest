# digest-send: commands and output

Run 2026-10-07T16:06:25.899Z.

```
$ rake redmine:issue_digest:send DRY_RUN=1 MANUAL=1 RULE_ID=4 VERBOSE=1
[IssueDigest] Starting at 2026-10-07T16:05:06Z (dry_run=true, force=true)
[IssueDigest] Found 1 due rules
[IssueDigest] Processing rule #4: E2E send rule (project: e2e-project)
[DRY_RUN] Rule #4 (E2E send rule): 4 recipients
  [DRY_RUN] Would send 11 issues to user #5
  [DRY_RUN] Would send 10 issues to user #6
  [DRY_RUN] Would send 10 issues to user #8
  [DRY_RUN] Would send 10 issues to user #9
[IssueDigest] Rule #4: DRY_RUN summary: 4 plans (4 recipients)
[IssueDigest] Finished at 2026-10-07T16:05:07Z (1 rules, 0 emails, 0 failures)

$ rake redmine:issue_digest:send MANUAL=1 RULE_ID=4 VERBOSE=1
[IssueDigest] Starting at 2026-10-07T16:05:15Z (dry_run=false, force=true)
[IssueDigest] Found 1 due rules
[IssueDigest] Processing rule #4: E2E send rule (project: e2e-project)
[IssueDigest] Rule #4: completed (success, sent=4, failed=0)
[IssueDigest] Finished at 2026-10-07T16:05:16Z (1 rules, 4 emails, 0 failures)

$ ls tmp/mails
digester@example.net
manager@example.net
reporter@example.net
viewer@example.net

$ manager mail headers
To: manager@example.net
Subject: E2E digest 1791389098434 E2E project: 11 issues
MIME-Version: 1.0
Content-Type: multipart/alternative;
Auto-Submitted: auto-generated
X-Auto-Response-Suppress: All

$ rake redmine:issue_digest:send VERBOSE=1   # the cron entry
[IssueDigest] Starting at 2026-10-07T16:05:28Z (dry_run=false, force=false)
[IssueDigest] Found 2 due rules
[IssueDigest] Processing rule #1: E2E access rule (project: e2e-project)
[IssueDigest] Rule #1: completed (success, sent=4, failed=0)
[IssueDigest] Processing rule #5: E2E scheduled rule (project: e2e-project)
[IssueDigest] Rule #5: completed (success, sent=1, failed=0)
[IssueDigest] Finished at 2026-10-07T16:05:29Z (2 rules, 5 emails, 0 failures)

$ rake redmine:issue_digest:send VERBOSE=1   # again, same window
[IssueDigest] Starting at 2026-10-07T16:05:32Z (dry_run=false, force=false)
[IssueDigest] Found 0 due rules
[IssueDigest] Finished at 2026-10-07T16:05:32Z (0 rules, 0 emails, 0 failures)

$ rake redmine:issue_digest:send MANUAL=1 RULE_ID=4 VERBOSE=1   # rule disabled
[IssueDigest] Starting at 2026-10-07T16:05:41Z (dry_run=false, force=true)
[IssueDigest] Found 0 due rules
[IssueDigest] Finished at 2026-10-07T16:05:41Z (0 rules, 0 emails, 0 failures)

$ rake redmine:issue_digest:send MANUAL=1 RULE_ID=4   # max_issues_per_email = 2
(no output)

$ rake redmine:issue_digest:cleanup   # retention 90 days, one run of 200 days old
[IssueDigest] Cleanup: deleted 1 runs, 0 deliveries
runs of the rule: 3 -> 2
```
