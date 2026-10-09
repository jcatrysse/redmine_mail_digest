# starting-soon-unassigned: commands and output

Run 2026-10-09T15:03:14.329Z.

```
$ issues (subject E2E SSU <key> => id)
{"today":8,"in3":9,"day7":10,"day8":11,"nostart":12,"assigned":13,"group":14,"closed":15}

$ stored rule
[true, 7, true, false, ["user:8"]]

$ rake redmine:issue_digest:send MANUAL=1 RULE_ID=1 VERBOSE=1
[IssueDigest] Starting at 2026-10-09T15:02:52Z (dry_run=false, force=true)
[IssueDigest] Found 1 due rules
[IssueDigest] Processing rule #1: E2E starting soon unassigned 1791558150171 (project: e2e-project)
[IssueDigest] Rule #1: completed (success, sent=1, failed=0)
[IssueDigest] Finished at 2026-10-09T15:02:53Z (1 rules, 1 emails, 0 failures)

$ ls tmp/mails
viewer@example.net

$ text part, issue lines
#8  [Bug]  E2E SSU today
      Start: 10/09/2026  Due: 10/19/2026  Updated: 2026-10-09
#9  [Bug]  E2E SSU in3
      Start: 10/12/2026  Due: 10/22/2026  Updated: 2026-10-09
#10  [Bug]  E2E SSU day7
      Start: 10/16/2026  Due: 10/26/2026  Updated: 2026-10-09
```
