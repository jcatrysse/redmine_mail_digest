# starting-soon-unassigned: commands and output

Run 2026-10-09T14:50:47.157Z.

```
$ issues (subject E2E SSU <key> => id)
{"today":24,"in3":25,"day7":26,"day8":27,"nostart":28,"assigned":29,"group":30,"closed":31}

$ stored rule
[true, 7, true, false, ["user:8"]]

$ rake redmine:issue_digest:send MANUAL=1 RULE_ID=2 VERBOSE=1
[IssueDigest] Starting at 2026-10-09T14:50:19Z (dry_run=false, force=true)
[IssueDigest] Found 1 due rules
[IssueDigest] Processing rule #2: E2E starting soon unassigned 1791557393089 (project: e2e-project)
[IssueDigest] Rule #2: completed (success, sent=1, failed=0)
[IssueDigest] Finished at 2026-10-09T14:50:21Z (1 rules, 1 emails, 0 failures)

$ ls tmp/mails
viewer@example.net

$ text part, issue lines
#24  [Bug]  E2E SSU today
      Start: 10/09/2026  Due: 10/19/2026  Updated: 2026-10-09
#25  [Bug]  E2E SSU in3
      Start: 10/12/2026  Due: 10/22/2026  Updated: 2026-10-09
#26  [Bug]  E2E SSU day7
      Start: 10/16/2026  Due: 10/26/2026  Updated: 2026-10-09
```
