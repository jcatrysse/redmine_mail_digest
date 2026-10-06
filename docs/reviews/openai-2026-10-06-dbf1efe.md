# OpenAI review dbf1efe

Model `gpt-5`, range `168a8ef1b4..dbf1efe`, 46 file(s), 2 request(s), 64557 tokens.

Add a `Resolution:` line under every finding: fixed in <commit>, or why not.

## Part 1 of 2

No findings.

Resolution: nothing to resolve.

## Part 2 of 2

Major, test/e2e/digest_send.mjs:70-86
The tests assume ActionMailer’s :file delivery writes one file per recipient named exactly after the email address (e.g. tmp/mails/manager@example.net) and append messages to that file. That is not how Rails’ built-in :file delivery works (it writes one file per message with a generated filename). If the test harness does not provide a custom file delivery that enforces this naming, the test will report false failures (e.g. “manual run: no digest for manager”) even when emails were delivered to the file store correctly.
Concrete failure: On a standard Redmine 7 configured with action_mailer.delivery_method = :file and file_settings[:location] = tmp/mails, the send rake task writes files like 20261006-123456-123456789.eml. The test then looks for “manager@example.net” in the directory listing and fails “manual run: no digest for manager”.
Fix: Don’t rely on filenames. Instead, parse all files under tmp/mails, split into messages, and inspect the To: header to determine recipients. For example, build a map { recipient_email => [raw_messages] } by reading all files and grouping by each message’s To header value. Apply the same approach in recipients.mjs.

Resolution: not changed, the premise is wrong. Rails' `:file` delivery is `Mail::FileDelivery`, which writes to `File.join(location, File.basename(to.to_s))` per recipient and appends; it does not write `.eml` files with generated names. Measured on this instance: `ls tmp/mails` after the manual run lists `manager@example.net`, `reporter@example.net`, `viewer@example.net` (`docs/e2e/digest-send-commands.md`), and the scenarios pass on PostgreSQL, MariaDB and Redmine 5.1.

Major, test/e2e/recipients.mjs:26-37 and usages at 56-65, 75-86, 96-105
Same underlying assumption as above: inbox() lists filenames and the tests compare them directly to recipient addresses (e.g. expecting “manager@example.net,reporter@example.net”). With Rails’ standard :file delivery this will be wrong and the assertions will fail even though the correct recipients were mailed.
Concrete failure: After sending a digest to Reporter and Viewer, tmp/mails contains random .eml filenames; the test expects exactly “reporter@example.net,viewer@example.net” and fails “role + user: mails to ..., expected reporter and viewer”.
Fix: Replace inbox() to return the set of recipients by parsing To: headers from all messages in all files under tmp/mails (same grouping approach as above). Update assertions to compare the extracted recipient set.

Resolution: not changed, same premise as above (one file per recipient address, appended), measured.

Minor, test/e2e/preview.mjs:18-27 (rule() helper), also at 34-41 and 47-60
The test creates rules with save!(validate: false), even for cases that are intended to represent valid user-created rules. This bypasses model validations and can hide regressions: preview scenarios would still run on invalid records that could not be created through the UI, so the end-to-end test stops reflecting real user flows.
Concrete failure: If a future change accidentally breaks a required attribute validation (e.g. recipient_modes cannot be blank), the UI will refuse to create new rules; however, these tests will still create the rules with validate: false and pass the preview checks, missing the regression.
Fix: Remove validate: false from rule creation and supply whatever minimal attributes are required for a valid record (the code already sets name, schedule, recipients, etc.). Let save! run validations so the E2E flow matches real behaviour.

Resolution: fixed in the next commit: the preview scenario saves its rules with validations; only the rule whose saved query is deleted afterwards is saved without (that state cannot be made valid, it is the failure path under test).
