# Before: the branch GEOxyz runs today (`main` @ `e734469`) on Redmine 5.1.13

Same scenarios as `docs/e2e/`, run with `RMP_E2E_OUT=docs/e2e/before` against
Redmine 5.1-stable (Ruby 3.2.6, PostgreSQL 16, production mode), to compare
where behaviour or layout changed. `rule_lifecycle.mjs` stops at "disable":
on `main` the enable/disable/delete buttons are `<input>` elements, the
scenario looks for the `<button>` the branch renders, so the later pictures
and its `.md` are missing.

What the pictures show (looked at, 2026-10-06):

- `access-tab-manager.png`: 5.1 draws the icons with CSS; the branch on 5.1
  (`docs/e2e/redmine51/access-tab-manager.png`) looks the same.
- `rule-lifecycle-new-form.png`: the timezone select preselects
  "(UTC-12:00) International Date Line West" (Redmine default time zone unset).
- `rule-lifecycle-invalid.png`: "Translation missing" for the end date and the
  time window errors.
- `rule-lifecycle-created.png`: the rule created as "weekly on Wednesday" is
  listed as "Weekly on Monday at 07:30 Etc/GMT+12": both bugs are in the
  version GEOxyz runs today, see "After the upgrade" in the migration plan.
