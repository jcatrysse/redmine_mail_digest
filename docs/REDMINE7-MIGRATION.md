# Redmine 7 migration: redmine_mail_digest

Start a Claude Code (or Codex) session on this repository, branch `redmine70-migration`, with:

> Read CLAUDE.md and docs/REDMINE7-MIGRATION.md, then carry out the Redmine 7 migration of this
> plugin as described there, on branch redmine70-migration. That includes the plugin's tests on
> PostgreSQL and MariaDB, every function exercised end to end on a real running Redmine in a
> browser (with and without permissions, failure paths included) with screenshots you looked at,
> and an OpenAI review of the diff when OPENAI_API_KEY is set. Report to me in Dutch at the end.

This file is the plan and the memory of that work. Update it as you go: verdicts, results,
what is left. Written 2026-10-06 from a measured analysis (report at the bottom).

## Status

| | |
|---|---|
| Plugin id | `redmine_mail_digest` |
| GEOxyz runs today | `main` |
| Upstream | geen (eigen plugin) |
| Runs on Redmine 7 as is | JA (boots, specs green), but with visible defects; fixed on this branch |
| Upstream sync | GEEN UPSTREAM |
| After sync | n.v.t. |
| Complexity (1 trivial .. 5 rewrite) | 1 |
| Measured on | Redmine 7.0.1 (`7.0-stable-GEOxyz` @ `8067e23`), Rails 8.1.3.1, Ruby 3.3.6, PostgreSQL 16.15 and MariaDB 10.11.14; also Redmine 5.1.13 (`5.1-stable`), Rails 6.1.7.10, Ruby 3.2.6 |
| Migration session | done 2026-10-06; work list complete; Jan's decisions on the open questions built the same day |
| Branch head | see `git log`; this file updated with the last commit |

## Feature 2026-10-09: "Open issues starting soon" and "Only unassigned issues"

Requested by Jan on 2026-10-09, built on this branch (`34fc40c`, e2e `3070e0a`) and cherry-picked
to `main` (see below). Jan's decisions: dedicated rule options (not the saved-query route);
"unassigned" is `assigned_to_id IS NULL` (an issue assigned to a group is assigned, as in
Redmine's "Assignee: none"); the mail shows a Start date column for every rule.

Choices made in this session (Jan was not watching), with the reason:
- "Only unassigned issues" sits under Personalization next to the `filter_*_recipient` flags,
  as asked, with its own hint, because its neighbours' hint ("their own issues") does not fit it.
  It narrows the candidate scope too, so the authors/watchers modes stay consistent with it.
- The refusal is a model validation on `filter_unassigned` with an `activerecord.errors.messages`
  code, like the other own error codes on this branch, so it reaches the form and every locale.
- Date semantics follow `due_soon_condition` exactly (`Date.current`, both ends inclusive).
- The text part gets "Start: <date>" before "Due:", labels hard-coded like the existing ones.
- Migration 011 (`include_starting_soon`, `starting_soon_days`, `filter_unassigned`), with
  defaults that keep every existing rule unchanged.

| Check | Result |
|---|---|
| rspec, Redmine 7.0-stable-GEOxyz, PostgreSQL 16 | 571 examples, 0 failures (533 before + 38 new); without the change 20 of the new examples fail, the others guard defaults, "ignored when off" and the migration |
| migration 011 down and up | spec `spec/migrations/add_starting_soon_and_unassigned_spec.rb`; on the e2e database `redmine:plugins:migrate` ran 011 |
| e2e, production mode | 9 scripts (smoke, core, 7 plugin scenarios), 68 screenshots, 0 problems; new scenario `test/e2e/starting_soon_unassigned.mjs`, 8 screenshots looked at, in `docs/e2e/starting-soon-unassigned*` |
| rubocop on the changed files | 3 offenses before and after, all pre-existing |
| OpenAI review (`gpt-5`) of `bc766ca..3070e0a` | no findings (`docs/reviews/openai-2026-10-09-3070e0a.md`) |

Not updated: the design documents under `docs/spec/` (data model, UI spec) still describe the
rule without the two options.

## Result (2026-10-07, head `b5de1c5` and later)

| Check | PostgreSQL 16, Redmine 7.0-stable-GEOxyz |
|---|---|
| rspec, plugin alone | 533 examples, 0 failures |
| rspec, with 8 other GEOxyz plugins (ai_summary, custom_workflows, depending_custom_fields, issue_view_columns, itil_priority, project_workflows, reporter_dashboards, wiki_extensions; their `redmine70-migration` branches, wiki_extensions `main`) | 533 examples, 0 failures |
| Project > Settings, Digest Rules tab, issue list, issue page with those plugins | 200 for admin, manager, digester |
| e2e with those plugins | 8 scripts, 60 screenshots, 0 problems |

## Result (2026-10-06, head `0fe3802`; history)

| Check | PostgreSQL 16 | MariaDB 10.11 | Redmine 5.1.13 (PostgreSQL) |
|---|---|---|---|
| rspec, test DB by `db:migrate` | 531 examples, 0 failures | 531 examples, 0 failures | 531 examples, 0 failures, 3 pending (sprite-icon examples skip on 5.1) |
| rspec, schema-only test DB (`db:schema:load`) | 518 examples, 0 failures at `676c93f` (was 20 failures) | 518 examples, 0 failures at `676c93f` | - |
| plugin migrations down to 0 and up again | 10 reverted, 10 migrated, then 518/0 | 10 reverted, 10 migrated, then 518/0 | - |
| production boot + eager load | OK (puma, `Rails.application.eager_load!`) | OK | OK |
| e2e (`./.codex/e2e.sh`, production mode) | 8 scripts (smoke, core, 6 plugin scenarios), 60 screenshots, 0 problems | 8 scripts, 60 screenshots, 0 problems | 8 scripts, 60 screenshots, 0 problems at `0d6ae0d` (`docs/e2e/redmine51`) |
| together with `redmine_wiki_extensions` 1.3.0 (main) | rspec and e2e above ran with it installed | - | - |
| OpenAI review (`gpt-5`) | 3 rounds: `c370138` no findings; `0d6ae0d` 1 finding, fixed; `dbf1efe` 3 findings, 1 fixed, 2 rejected with measurement; `0fe3802` no findings (`docs/reviews/`) | | |

Screenshots: `docs/e2e/*.png` (PostgreSQL, committed and looked at), `docs/e2e/redmine51/`
(the branch on 5.1), `docs/e2e/before/` (`main` on 5.1, see its README), `docs/e2e/baseline/`
(smoke and core on Redmine 7 before any change). The MariaDB run's pictures were looked at, not
committed (same pages).

## Already on this branch

| Commit | What | Test that fails without it |
|---|---|---|
| `d155a6f` | Specs create the builtin groups and Non member `view_issues` (work list 1) | the suite on a schema-only test DB: 20 failures before |
| `70ff82b` | `Auto-Submitted: auto-generated`, `X-Auto-Response-Suppress: All` on digest mails (work list 2, header part) | `spec/mailers` "marks the mail as auto-generated" |
| `ce3ee43` | Action icons through `sprite_icon` on 6+/7, CSS icons kept on 5.1; enable/disable/delete as `<button>` (block form of `button_to`) so the SVG fits (work list 3) | controller specs "draws the action icons as SVG sprites", helper spec |
| `d328d23` | New rule form preselected "(UTC-12:00) International Date Line West" when Redmine's default time zone is unset (found in e2e; also on 5.1) | controller spec "preselects UTC" |
| `4f8893d` | Plugin settings: duplicate id on the e-mail lookup checkbox, label did nothing (found in e2e) | `spec/views/issue_digest_settings_spec.rb` |
| `373d73a` | Models inherit from `ApplicationRecord` where it exists: on Redmine 6/7 form labels and error messages ignored the plugin's `field_*` translations (Redmine 6 moved that lookup off `ActiveRecord::Base`) | `spec/models/attribute_names_spec.rb` |
| `eb5b4b1` | The rule's own error codes had no translation ("Translation missing" in the form), all 11 locales (found in e2e; also on 5.1) | `spec/models/issue_digest_rule_error_messages_spec.rb` (66 examples) |
| `b096951` | Rule form submitted the hidden schedule blocks too: weekly-on-Wednesday saved as Monday, every 3 days as 1 (found in e2e; also on 5.1) | `test/e2e/rule_lifecycle.mjs`, controller spec "clears the schedule config" |
| `bb2476c`, `0b5c973` | e2e scenarios and screenshots | - |
| `c370138` | README (Redmine 7, how users reach the rules), manual workflow `rspec-70.yml` | - |
| `ae10d0d` | Jan's decision on question 2: project menu entry "Digest Rules" for `view_digest_rules`; `manage_digest_rules` also grants `projects#settings` (as core's `manage_categories`), so a save no longer ends on a 403 for a role without another settings permission; back link to the list for view-only users | `spec/plugin/registration_spec.rb` (5 of 6 fail without), controller spec for the back link, `access.mjs` (viewer, digester) |
| `1bf128c` | Jan's decision on question 3: with the e-mail address lookup off, stored addresses are not mailed and are marked "not sent" (11 locales) | `recipient_resolver_spec` "ignores stored addresses", helper spec, `recipients.mjs` |
| `dbf1efe` | OpenAI finding: keep a stored schedule config when a type with fields is sent without any | controller spec "keeps the stored config" |
| `0fe3802` | OpenAI finding: preview scenario saves its rules with validations | - |

## Baseline (2026-10-06, before any change, branch head `ecd779b`)

Redmine 7.0.1 `7.0-stable-GEOxyz` @ `8067e23`, Rails 8.1.3.1, Ruby 3.3.6.

| Database | Test DB built with | rspec |
|---|---|---|
| PostgreSQL 16.15 | `db:migrate` + `redmine:plugins:migrate` | 440 examples, 0 failures |
| MariaDB 10.11.14 | `db:migrate` + `redmine:plugins:migrate` | 440 examples, 0 failures |
| PostgreSQL 16.15 | `db:schema:load` (schema only, no builtin groups/roles) | 440 examples, 20 failures (as in the analysis) |

Browser baseline (production mode, PostgreSQL): smoke 15 screenshots, core 6, 0 problems
(`docs/e2e/baseline`). Visible on the pictures already: action links without icons.

## Inventory of functions

| Function | How a user reaches it | Scenario | Screenshots |
|---|---|---|---|
| Plugin settings (max issues per mail, retention, e-mail address lookup) | Administration > Plugins > Configure | `settings.mjs` | `settings-form`, `-saved`, `-email-field-on`, `-refused` (non-admin 403), `-anonymous` (login) |
| Project module + permissions `view_digest_rules` / `manage_digest_rules` | project Settings > Modules; Roles | `access.mjs` | `access-tab-manager`, `-tab-digester` (only the plugin permissions: settings page with just this tab), `-index-manager`, `-index-viewer`, `-show-viewer`, `-new-refused-viewer`, `-index-refused-reporter`, `-private-refused-outsider`, `-anonymous`, `-other-project-404`, `-module-off` |
| Digest Rules tab in the project settings | Settings > Digest Rules | `access.mjs`, `rule_lifecycle.mjs` | `access-tab-manager`, `rule-lifecycle-created` |
| Rule list, project menu entry "Digest Rules" | project menu (with `view_digest_rules`) | `access.mjs` | `access-index-viewer` (reached through the menu), `access-index-manager` |
| New rule / create, schedule fields per type, invalid input | New Digest Rule | `rule_lifecycle.mjs` | `rule-lifecycle-new-form`, `-form-every-n-hours`, `-invalid`, `-created` |
| Show rule (details, formatted intro, run history) | rule name | `rule_lifecycle.mjs`, `digest_send.mjs` | `rule-lifecycle-show`, `digest-send-run-history` |
| Edit / update, invalid update | Edit | `rule_lifecycle.mjs` | `rule-lifecycle-edit`, `-updated`, `-invalid-update` |
| Disable / enable | Disable / Enable buttons | `rule_lifecycle.mjs`, `access.mjs` (forged POST as viewer: 403) | `rule-lifecycle-disabled` |
| Delete (confirm cancelled, then accepted) | Delete | `rule_lifecycle.mjs` | `rule-lifecycle-deleted` |
| Preview (dry run), saved query filter, deleted saved query | Preview (dry run) on the rule page | `preview.mjs` | `preview-counts`, `-query-and`, `-query-deleted`, `-viewer` (forged POST 403) |
| Recipient modes: assignees, role, specific user, e-mail addresses (and the lookup switched off) | rule form, Recipients | `recipients.mjs` | `recipients-form-assignees`, `-form-role-user`, `-form-emails`, `-show-emails`, `-show-emails-off`; output in `recipients-commands.md` |
| Sending: `rake redmine:issue_digest:send` dry run, manual, scheduled (cron), idempotent window, disabled rule, issue cap; mail content, headers, per-recipient visibility | cron / operator | `digest_send.mjs` | `digest-send-mail-manager`, `-mail-reporter` (private issue absent), `-mail-capped`, `-run-history`; commands and output in `digest-send-commands.md` |
| Cleanup: `rake redmine:issue_digest:cleanup` | cron | `digest_send.mjs` | `digest-send-commands.md` (one run of 200 days deleted, 3 -> 2) |
| Include "Open issues starting soon", narrow to "Only unassigned issues" (2026-10-09); Start date column in every mail | rule form, Filters and Personalization | `starting_soon_unassigned.mjs` | `starting-soon-unassigned-form`, `-form-recipient`, `-show-preview`, `-mail`, `-refused-assignees`, `-refused-assigned-to-recipient`, `-form-nl`, `-reporter-refused`; commands in `starting-soon-unassigned-commands.md` |
| Webhooks (Redmine 7) | - | not applicable, see work list 5 | - |

## Work list for the migration session

In this order: things that break, security, the GEOxyz changes, the open items, then the checks.

**Open items from the analysis** (Dutch; where they conflict with a decision or a priority item above, those win)

1. Make specs create builtin groups and a Non member role with view_issues themselves.
   **Done** in `d155a6f`.
2. Product decision: honour mail_notification=none / add Auto-Submitted header (digest bypasses Redmine Mailer).
   **Header done** in `70ff82b` (no behaviour lost; same headers as Redmine's Mailer).
   **mail_notification not changed**: OQ-02 in `docs/spec/` decided that the digest ignores it
   (the PM controls recipients). Kept; see "Open questions for Jan".
3. Icons icon-* -> sprite_icon (cosmetic). **Done** in `ce3ee43`, 5.1 keeps the CSS icons
   (checked in `docs/e2e/redmine51`).

Found while testing end to end (fixed, each with a test; all except the labels were also wrong on 5.1):

- 3a. Timezone default "International Date Line West" (`d328d23`).
- 3b. Duplicate id on the settings checkbox (`4f8893d`).
- 3c. Untranslated labels and messages on Redmine 6/7 (`373d73a`, a Redmine 6+ regression).
- 3d. "Translation missing" for the rule's own errors (`eb5b4b1`).
- 3e. Hidden schedule blocks submitted: wrong weekday, day of month and interval saved (`b096951`).

Not fixed (recorded, no change made):

- 3f. The rule list's "No runs recorded yet." uses `.nodata`, which Redmine draws as a full flash
  box, so it overflows the table cell (same on 5.1, see `docs/e2e/before/access-tab-manager.png`).
  Cosmetic; a one-class change in `_rule_row.html.erb` when wanted.
- 3g. The rule page warning for a deleted saved query says "The query filter will be skipped
  until the rule is updated", but the send is blocked ("digest delivery was blocked",
  `preview-query-deleted.png`). Text fix in 11 locales when wanted.
- 3h. The fallback emoticon path in `IssueDigestMailer#configure_third_party_url_helpers`
  (`/plugin_assets/...`, not the Propshaft `/assets/plugin_assets/...`) is only used when
  redmine_wiki_extensions has no `wiki_extensions_emoticon` route; GEOxyz's
  `jcatrysse/redmine_wiki_extensions` main (1.3.0) has the route, so it is unreachable. Left as is.
- 3i. `require_relative 'lib/issue_digest/projects_helper_patch'` in `init.rb` on a Zeitwerk
  path: eager load OK in production on 7.0 and 5.1. Left as is.

**Checks**

4. Run the plugin's whole test suite on Redmine 7.0-stable-GEOxyz with PostgreSQL AND MariaDB, and once on 5.1-stable if the branch is meant to stay 5.1-compatible.
   **Done**, see "Result": 518/0 on both databases (migrated and schema-only), 518/0/3 pending on 5.1.13.
5. Check Redmine 7 webhooks against this plugin (see "Rules"), and note the result here even if nothing is needed.
   **Nothing needed**: the plugin does not patch `Issue`, its API views, visibility or any issue
   data; its only core patch is `ProjectsHelper#project_settings_tabs`. Webhook payloads are
   unaffected. Digest rules and runs have no webhook events and need none.
6. Verify every feature of the plugin by hand on a running Redmine 7 (screenshots).
   **Done**, see the inventory: every function as admin, manager, viewer (view only),
   reporter (no plugin permission), outsider and anonymous, with the failure paths.

## Decided by Jan

General decisions for every GEOxyz plugin, 2026-10-07 (`docs/DECISIONS-2026-10-07.md`):

- **Straight to Redmine 7, no 5.1.** Done in `b5de1c5`: the 5.1 code paths added during the
  migration are gone (models on `ApplicationRecord`, `sprite_icon` without fallback),
  `requires_redmine` 6.0.0, the 5.1 workflow removed. The 5.1 results below stay as history.
- **PostgreSQL only.** Rules above updated. The MariaDB runs below stay as history; no
  MariaDB-only problem was found.
- **deface without a version constraint.** Not applicable: the plugin does not use deface.
- **No `alias_method` on core methods other plugins patch.** `ProjectsHelper#project_settings_tabs`
  was an alias chain; at least seven other GEOxyz plugins wrap it (alias chains: ai_summary,
  depending_custom_fields, itil_priority; prepend on ProjectsHelper: wiki_extensions; controller
  helper: custom_workflows, issue_view_columns, project_workflows, reporter_dashboards).
  Measured on Redmine 7, production, this plugin plus a fixture plugin that prepends onto
  `ProjectsHelper` and loads first: alias chain (old) -> Project > Settings **500**; new -> 200.
  Built in `87d79f2` with `ProjectsController.helper`, not with `ProjectsHelper.prepend`: a
  prepend followed by a later plugin's alias chain fails too (`super: no superclass method`,
  measured with wiki_extensions' prepend and an alias fixture), while a module in the
  controller's helper chain is outside `ProjectsHelper.ancestors` and composes in any load
  order; the same pattern reporter_dashboards and custom_workflows use. With the eight GEOxyz
  plugins above installed: Project > Settings, the Digest Rules tab, the issue list and an issue
  answer 200 for admin, manager and digester.
- **GitHub Actions manual only.** All workflows are `workflow_dispatch`.

Answered 2026-10-06 ("1: advies volgen, 2 en 3 bouwen"):

1. **`mail_notification = none`** (and "only my watches"): digests still go to such users, as
   decided in OQ-02. Kept, no change.
2. **Users with only `view_digest_rules`** reach the rules through a project menu entry
   "Digest Rules". Built in `ae10d0d`, together with `projects#settings` for
   `manage_digest_rules` so the redirects after a save work for every manager role.
3. **E-mail address recipients with the lookup switched off** are no longer mailed; the rule
   pages mark them "not sent". Built in `1bf128c`. Addresses still reach only registered users
   who may see the project's issues, which for a public project includes non-members.

## Open questions for Jan

None.

## GEOxyz changes to review or re-apply

Own plugin: all of it is GEOxyz code, so there is nothing to re-apply. While migrating, hold the code you touch to the rules below; list larger quality problems you find in the work list instead of fixing them in passing.

## After the upgrade (production)

Actions the person doing the upgrade must take, or know about, for this plugin:

- Re-create the cron entries `redmine:issue_digest:send` and `:cleanup`
  (`cd <redmine> && RAILS_ENV=production bundle exec rake redmine:issue_digest:send`, every
  5-15 minutes; `:cleanup` daily).
- Migration 011 (2026-10-09 feature: starting soon, only unassigned) is new; it is also on
  `main`. Run `RAILS_ENV=production bundle exec rake redmine:plugins:migrate` once; existing
  rules keep their behaviour (defaults off, 7 days). Rollback:
  `rake redmine:plugins:migrate NAME=redmine_mail_digest VERSION=10`.
- Behaviour that changes for users: a "Digest Rules" entry in the project menu for roles with
  *view digest rules*; roles with *manage digest rules* can open the project settings (only the
  tabs their permissions allow); rules with e-mail address recipients stop mailing those
  addresses while "Allow email-address recipient lookup" is off in the plugin settings. Check
  that setting before the upgrade if rules use addresses.
- **Check the existing rules**: the form bugs fixed here exist in the version GEOxyz runs today
  (`docs/e2e/before/rule-lifecycle-created.png`). Rules created or saved through the form may
  carry a wrong timezone, weekday, day of month or interval. Find them with
  `RAILS_ENV=production bundle exec rails runner 'IssueDigestRule.order(:project_id, :name).each { |r| puts [r.id, r.project.identifier, r.name, r.schedule_type, r.schedule_config, r.timezone].inspect }'`
  and correct them in the form (now saved correctly); in particular `timezone == "Etc/GMT+12"`
  is almost certainly the default that should have been UTC or Europe/Brussels.

## How to test

This repo already has its own `.codex/` scripts (older variant). Read their headers and use them; check they accept `7.0-stable-GEOxyz` (clone from https://github.com/jcatrysse/redmine.git) and MariaDB. The shared variant from the other plugin repos may replace them if that is simpler.

Then the real Redmine and the browser checks (shared scripts, they use the checkout in `redmine/` or `REDMINE_DIR`):

```sh
./.codex/start_server.sh       # real Redmine (production mode) with this plugin, seeded users and projects
./.codex/e2e.sh                # browser: smoke over the plugin's pages, core issue flows, test/e2e/*.mjs
./.codex/openai_review.sh      # independent OpenAI review of the diff, only when OPENAI_API_KEY is set
```
Write one scenario per function in `test/e2e/<function>.mjs` (example at the top of
`.codex/e2e/lib.mjs`); screenshots and a table per scenario land in `docs/e2e/`. Users:
`admin`, `manager` (every permission), `reporter` (no plugin permissions), `outsider` (no
membership); password `Redmine7Test!`. Needs Node with Playwright and Chromium
(`npm install -g playwright && npx playwright install --with-deps chromium`).

The coordinator's harness (`plugin-check.sh` in the migration kit, kept outside this repo) adds a
browser smoke test of every page the plugin adds and runs all GEOxyz plugins together; the
results quoted in the analysis come from it.

## How the migration session works (same for every plugin)

1. **Start**: `git fetch && git checkout redmine70-migration && git pull`. Read this whole file,
   including the analysis report at the bottom. Do not reopen decisions recorded here.
2. **Baseline, before you change anything**:
   - the plugin's tests on Redmine 7.0-stable-GEOxyz with PostgreSQL and with MariaDB;
   - a real running Redmine with this plugin (`./.codex/start_server.sh`) and the browser run
     (`./.codex/e2e.sh`: smoke over every page the plugin adds, plus the core issue flows).
   Write the numbers here. Something already broken now is a finding, not your regression.
3. **Inventory of functions**: list every function of the plugin in this file, in a table
   "function | how a user reaches it | scenario | screenshot". Take them from the README,
   `init.rb` (permissions, menus, settings, project modules), routes, hooks and view
   overrides, macros, mail handling, API endpoints, rake tasks and cron jobs. This table is the
   coverage list for step 8; a function that is not in it will not be tested.
4. **GEOxyz changes**: go through the table above, one item at a time. Each kept or re-made change
   is its own commit with a test that proves it. Record the verdict in the table.
5. **Work list**: then the numbered list, in order. One concern per commit.
6. **Portability**: PostgreSQL is the database (Jan, 2026-10-07); keep SQL portable where that
   costs nothing. Migrations must be reversible and are run down and up on PostgreSQL.
7. **Together**: run with the other GEOxyz plugins installed (the migration kit's harness, or
   `RMP_EXTRA_PLUGINS`). A failure that only appears in combination is a finding to record here.
8. **End to end, visually, every function**: on the real Redmine from `start_server.sh`
   (production mode, the way GEOxyz runs it), write one scenario per function in
   `test/e2e/<function>.mjs` with `.codex/e2e/lib.mjs` and run them with `./.codex/e2e.sh`.
   - Each function as the users that matter: `admin`, `manager` (every permission, the
     plugin's included), `reporter` (member without the plugin's permissions), `outsider`
     (no membership, private project must stay invisible).
   - The failure paths too: setting off, permission absent, empty state, invalid input, the
     value that used to raise. A refusal that is shown is evidence as much as a success.
   - One screenshot per function and per path, with a caption saying what it proves. Open
     every screenshot and look at it: a picture nobody looked at proves nothing. Commit them
     in `docs/e2e/` and list them in the inventory table.
   - Functions without a page (mail in and out, REST API, rake tasks, cron, webhooks): exercise
     them against the same running instance (mails land in `redmine/tmp/mails`, `t.mails()`
     reads them; API through `t.page.request`) and record command and result.
   - Before pictures where behaviour or layout changes: the branch GEOxyz runs today, on
     Redmine 5.1, same scenarios, `RMP_E2E_OUT=docs/e2e/before`.
   - Run the whole e2e set once on MariaDB as well (`RMP_DB=mariadb`, then `start_server.sh --reset`).
9. **Independent review**: first your own, adversarial: re-read the whole diff as if someone
   else wrote it and you are paid to reject it. Then, **when `OPENAI_API_KEY` is set in the
   session**, `./.codex/openai_review.sh`: it sends the diff of this branch to an OpenAI model
   and writes `docs/reviews/openai-<date>-<sha>.md`. Every finding gets a `Resolution:` line
   there (fixed in <commit>, with a test, or why not). Fix, re-run the tests and the e2e set,
   and run the review again until it has nothing new that you accept. Without the key: write
   "OpenAI review: skipped, no OPENAI_API_KEY" in the report; never send code anywhere else.
10. **After the upgrade**: anything the production upgrade must do for this plugin (data fixes,
    settings, cron, files, removed features) goes into the section "After the upgrade".
11. **Finish**: update "Status", the inventory and the work list in this file, push
    `redmine70-migration`, and report: what changed, test numbers on both databases, e2e
    numbers (scenarios, screenshots, problems), the review result, what is left, what needs Jan.

### Stop and ask Jan when
- a GEOxyz change would be lost or behave differently for users;
- a new gem, a new setting with user impact, or a schema change not required by Redmine 7 seems needed;
- the change would send data to an external service (the OpenAI review of the code diff is the
  one exception Jan approved, and only when the key is present);
- upstream and GEOxyz disagree on behaviour and both are defensible.

## Rules

- **Target**: Redmine 7.0-stable-GEOxyz (https://github.com/jcatrysse/redmine), Rails 8.1, Ruby 3.3+.
  Core sources for comparison: branches `5.1-stable`, `6.1-stable`, `7.0-stable`, `7.0-stable-GEOxyz`.
- **Evidence**: never report a test, lint, browser check or review as passed without having seen
  it. Quote the summary lines; list the screenshots. "Should work" is not a result, and a green
  test suite is not proof that a feature works in the browser.
- **Tests**: never skip, delete or weaken a test. A test that encodes Redmine 5 markup or
  behaviour is updated to Redmine 7, with the reason in the commit. Every fix gets a test that
  fails without it.
- **Minimal diffs** in the plugin's own style. No reformatting, no unrelated refactoring.
  Something wrong elsewhere: write it down here, do not fix it in passing.
- **Security**: authorization on every action and entry point; `safe_attributes`, never
  `to_unsafe_hash` into `update`; no SQL built from params; no secrets in logs; no `html_safe` on
  user input.
- **Webhooks (new in Redmine 7)**: core sends issue payloads (core `issues/show.api.rsb`, rendered
  as the webhook owner) to webhook endpoints, past plugin hooks and controller patches. If the
  plugin hides, adds or changes issue data, make webhooks consistent with that or record why not.
- **Redmine 7 conventions**: SVG icons through `sprite_icon` (the `icon icon-*` CSS is gone),
  Propshaft assets under `assets/` (`/assets/plugin_assets/<id>/...`), the new header and user menu,
  `ContextMenus::*Controller`, Loofah-based text formatting, Chart.js as an ES module, sudo mode
  (on by default: `t.sudo()` in a scenario). The breaker list is in the migration kit's CHECKLIST.md.
- **Locales**: keep the locales the plugin ships in sync; translate a new key by matching the
  closest existing key in the same file, not from scratch; do not add new languages.
- **No 5.1** (Jan, 2026-10-07): GEOxyz goes straight to Redmine 7; nothing is backported or
  cherry-picked to the default branch or to what production runs today. No code paths that exist
  only for Redmine 5.1.
- **PostgreSQL only** (Jan, 2026-10-07): production runs PostgreSQL 16; tests and the e2e set run
  on PostgreSQL. Keep SQL portable where that costs nothing; a MariaDB-only problem is a note
  here, not a blocker.
- **Core methods other plugins patch** (Jan, 2026-10-07): never `alias_method`. Here the
  settings tab goes through `ProjectsController.helper`, see "Decided by Jan".
- **deface** (Jan, 2026-10-07): required without a version constraint; this plugin does not use it.
- **Git**: work on `redmine70-migration` only; never push to the default branch; never force-push
  a branch someone else uses. Descriptive commit messages (what and why). Push after every
  commit, together with the updated status in this file: a cloud session can stop at a usage
  limit, and work that is not pushed is lost with its container.
- **GitHub Actions**: manual only (`workflow_dispatch`). Do not add push, pull_request or schedule
  triggers.

## Definition of done

- All items of the work list are done or explicitly deferred with a reason, in this file.
- The plugin's tests are green on Redmine 7.0-stable-GEOxyz with PostgreSQL, alone and with the
  other GEOxyz plugins (numbers in this file); boot, production-like eager load, migrations up/down OK.
- Every function in the inventory exercised end to end on a real running Redmine, with and
  without permissions and on its failure paths; `./.codex/e2e.sh` green; screenshots looked at,
  committed in `docs/e2e/` and listed.
- Review done: your own, and the OpenAI review when the key is present, every finding resolved
  in `docs/reviews/`.
- No new failure when run together with the other GEOxyz plugins.
- "After the upgrade" lists every action production needs; "Status" is current.


## Analysis report (2026-10-06, Dutch)

# redmine_mail_digest
- Gebruikte branch: main @ e734469 (2026-05-31) - plugin id redmine_mail_digest, versie 1.0.0
- Upstream: geen (eigen plugin, jcatrysse/redmine_mail_digest is geen fork, 2 commits)
- Fork t.o.v. upstream: n.v.t.
- Andere relevante branches: geen (alleen main)
- Baseline: geen runtime-gems; test-gems rspec-rails, factory_bot_rails, rails-controller-testing; 10 migraties (001-010); rspec 18 spec-bestanden / 440 examples; eigen `IssueDigestMailer < ActionMailer::Base` (bewust niet Redmine's `Mailer`); rake `redmine:issue_digest:send` en `:cleanup` voor cron; `serialize ..., coder: JSON` (al Rails 7.1+-vorm).

## 1. Werkt out of the box op Redmine 7?   JA
Harness `redmine_mail_digest@origin/main` (results/1006-084844-s5-redmine_mail_digest_origin_main) en eindrun op redmine70-migration (= zelfde commit):
- OK bundle, boot, eager load, migraties dev+test, rollback 0 en terug
- FAIL rspec 440 examples, 20 failures - **geen R7-regressie, maar testdata**: de test-DB van de harness is schema-only (0 users, 0 rollen). 19 failures: `User#roles` -> `GroupNonMember.first.id` op nil (app/models/user.rb:655, identieke code in 5.1) omdat de ingebouwde groepen ontbreken; 1 failure (`spec/security/security_checklist_spec.rb:138`) verwacht `issue_tracking` in de SQL van `Issue.visible`, wat alleen gebeurt als de builtin rol "Non member" `view_issues` heeft. Gemeten: na `GroupAnonymous/GroupNonMember.load_instance` -> 440 examples, 1 failure; na ook `Role.non_member.permissions = [:view_issues]` -> **440 examples, 0 failures**. De plugin-CI draait `db:migrate` + default data op een echte DB en ziet dit dus niet.
- OK smoke 64/64 (4 plugin routes; INFO 404 op `/digest_rules/1` = geen record in de seed).
- Extra UI-check als admin met een echte regel (gemeten): index, new, show, edit, projectinstellingen-tab, `/settings/plugin/redmine_mail_digest` allemaal 200; `POST preview` (xhr) 200; `POST disable` 302 en regel inactief; 0 x HTTP 500.
- Cron-entrypoints (gemeten, `bundle exec rake`): `redmine:issue_digest:send DRY_RUN=1 MANUAL=1 VERBOSE=1` vindt de regel en plant 2 x 9 issues; `send` zonder FORCE: 0 due rules, rc 0; `cleanup` rc 0.

### Respecteert de digest de notificatie-instellingen van gebruikers?
Nee - en dat was op 5.1 ook al zo, **bewust**: `docs/spec/02_functional_specification.md` §22 en OQ-02 ("The plugin does not check `user.mail_notification`"; geen opt-out in v1). Gemeten op R7 met een `project_members`-regel: gebruiker met `mail_notification=none` en gebruiker met de nieuwe 7.0-optie `only_my_watches` (#37978) krijgen **allebei** de digest (run status success, 2/2 verzonden). Wat de plugin wel afdwingt: actieve gebruiker, mailadres aanwezig, `view_issues` op het project (of een subproject), issues gefilterd via `Issue.visible(user)` per ontvanger.
- #37978 voegt alleen `only_my_watches` toe aan `User::MAIL_NOTIFICATION_OPTIONS`; de plugin leest die lijst niet, dus geen breuk. Wie verwacht dat "only watched" ook digests beperkt: dat is een productkeuze, geen R7-probleem.
- #38513 (MIME-Version): opgelost in de mail-gem 2.9 die R7 meebrengt; de digest gebruikt dezelfde gem -> header komt als `MIME-Version: 1.0` (gemeten), multipart/alternative text+html.
- Omdat de digest niet via Redmine's `Mailer` gaat, krijgt hij ook niet: `Auto-Submitted: auto-generated`, `X-Redmine-*`/`List-Id`, emails_header/footer, de instelling "platte tekst mail". Niet nieuw in 7.0; wel relevant voor out-of-office-lussen (Auto-Submitted ontbreekt).

## 2. Upstream sync?   GEEN UPSTREAM

## 3. Werkt na sync op Redmine 7?   n.v.t.

## 4. Complexiteit en blokkers   score 1
- Blokkers: geen gevonden.
- Stille breuken:
  - Iconen: `app/views/issue_digest_rules/_rule_row.html.erb:18-36`, `show.html.erb:10-27`, `index.html.erb:5`, `projects/settings/_digest_rules.html.erb:6` gebruiken `class: 'icon icon-*'` -> links zonder icoon op R7 (#43206, cosmetisch). De multiselect-toggle in `app/helpers/issue_digest/digest_rules_helper.rb:157` doet het al goed (sprite_icon).
  - `app/mailers/issue_digest_mailer.rb:141` hardcoded `/plugin_assets/redmine_wiki_extensions/images/emoticons/...` als fallback voor wiki_extensions-emoticons in mails: onder Propshaft (6.0+) staan plugin-assets onder `/assets/plugin_assets/...`; alleen geraakt als redmine_wiki_extensions geen `wiki_extensions_emoticon_path`-route heeft.
  - `init.rb:3` `require_relative 'lib/issue_digest/projects_helper_patch'` op een Zeitwerk-autoload-pad: eager load slaagt (gemeten), dus geen blokker.
  - Specs zijn afhankelijk van seed-data in de test-DB (builtin groepen + Non member-rol met view_issues) i.p.v. die zelf aan te maken.
- Overlap met Redmine 7 core: geen. Core 7.0 heeft "notifications for watched objects only" (#37978) maar geen geplande digests.
- Open werk voor ansif:
  1. Specs robuust maken: in `spec/rails_helper.rb` (of per spec) `GroupAnonymous.load_instance`, `GroupNonMember.load_instance` en een Non member-rol met `view_issues` aanmaken, zodat de suite ook op een schema-only test-DB groen is.
  2. (product) Beslissen of `mail_notification = 'none'` een digest moet tegenhouden en of `Auto-Submitted: auto-generated` gezet moet worden.
  3. Iconen naar `sprite_icon` (cosmetisch).

## Branch redmine70-migration
- Basis: origin/main @ e734469 (geen wijzigingen nodig; branch lokaal aangemaakt, 0 commits)
- Commits: geen
- Eindresultaat harness (herhaald met de bijgewerkte harness van 09:25, results/1006-093003-s5-redmine_mail_digest_redmine70-migration; identiek aan de eerdere run 1006-091911, waar rspec al echt draaide via PATH): OK bundle, boot, eager load, migraties dev+test, rollback; FAIL rspec 440 examples, 20 failures (testdata, zie 1; 0 failures met builtin groepen + Non member view_issues); OK smoke 64/64.
- Rollback migraties: OK

## Cron/rake inventory (alle plugins)
Read-only gescand op de default branch van elke repo in /home/user/plugins (voor redmine_ai_summary: main-GEOxyz), plus alle remote branches op extra `.rake`-bestanden. "Cron" = taken die op de server periodiek moeten draaien; de rest is eenmalig/beheer/dev. Op de nieuwe server: cron als `cd <redmine> && RAILS_ENV=production bundle exec rake <task>` met de juiste Ruby in PATH (in deze container staan `rake`/`rspec` niet in PATH: rbenv zonder shims).

| Plugin | Taak | Soort | Opmerking |
|---|---|---|---|
| issue_recurring | `redmine:issue_recurring:renew_all` | **cron** (dagelijks of vaker) | Op R7 getest na fix (59879c4): werkt. Op origin/master crasht de plugin al bij het laden (enum). Rakefile laadt `config/environment` bij elke rake-aanroep. Dev-task `redmine:plugins:test:migration` kapot op Rails 8.1. |
| redmine_mail_digest | `redmine:issue_digest:send` | **cron** (frequent, bv. elke 5-15 min; de regels bepalen zelf wanneer ze due zijn, met lock) | Op R7 getest: OK |
| redmine_mail_digest | `redmine:issue_digest:cleanup` | **cron** (dagelijks) | Op R7 getest: OK |
| redmine_reporter_dashboards | `reporter_dashboards:schedules:run` | **cron** (dagelijks: "deliver every scheduled report that is due today", exit 1 bij fout) | + `schedules:status` voor monitoring; `documents:purge` (verlopen snapshots, periodiek); rest (migrate_from_reporter, export/import, lint_templates, gallery, drop_reference) eenmalig. Niet door mij getest op R7. |
| redmine_ai_triage | `redmine_ai_triage:cron` | **cron** ("the scheduled entry point: one reconciliation and one wake-up") | + `reconcile`, `health` (monitoring), `purge` (retentie, periodiek), `poll` (dev-loop), `wake`, `enqueue`, `kill_switch`, `demote`, rapporten. ActiveJob `RedmineAiTriage::WakeUpJob` + `AlertMailer` (deliver_later) -> vereist een echte ActiveJob-backend of inline. Niet door mij getest. |
| redmine_ldap_sync | `redmine:plugins:ldap_sync:sync_users`, `:sync_groups`, `:sync_all` (alias `redmine:plugins:redmine_ldap_sync:sync_users`) | **cron** (typisch nachtelijk) | Branches 1.2-stable/1.3-stable hebben nog een oude `lib/tasks/sync_users.rake`. `testing.rake` = dev. Niet door mij getest. |
| redmine_ai_summary | `GenerateSummaryJob` (ActiveJob, `perform_later` vanuit controller en Journal-callback) | **job-backend**, geen cron | Rake `redmine:create_test_data` en `redmine:set_admin_password` zijn dev-hulpjes (de eerste maakt een testproject `test-project` met issue aan, de tweede zet "wachtwoord moet gewijzigd worden" af voor de gebruiker `admin`) - **niet in cron, niet op productie draaien**. |
| bless-this-redmine-sso | `redmine:bless_this_sso:install/configure/enable_sso_only/disable_sso_only/status/test/reset/help` | beheer, eenmalig | Geen cron. |
| redmine_issue_templates | `redmine_issue_templates:apply_inhelit_template_to_child_projects`, `:unapply_...`; `:test`, `:spec` | beheer / dev | Geen cron. |
| redmine_project_workflows | (main: geen) | - | Alleen op `claude/dev`: `lib/tasks/redmine_project_workflows.rake` (backup/restore e.d.); geen cron. |
| redmine_custom_workflows | (geen rake) `CustomWorkflowMailer` met deliver_later | job-backend | Geen cron. |

Overige plugins (calendar_events_daily, custom_field_sql, redmine_depending_custom_fields, redmine_description_macros, redmine_drawio, redmine_editauthor, redmine_extended_api, redmine_impersonate, redmine_inline_edit_issues, redmine_issue_field_visibility, redmine_issue_todo_lists2, redmine_issue_view_columns, redmine_itil_priority, redmine_mermaid_macro, redmine_more_previews, redmine_parent_child_filters, redmine_paste_as_wiki_tables, redmine_plugin_computed_custom_field, redmine_stealth, redmine_subtask, redmine_tint_issues, redmine_view_issue_description, redmine_wiki_extensions, that_attachments_limit): geen `.rake`, geen ActiveJob-klassen, geen schedulers.

ActiveJob-backend: Redmine 7 zet in productie geen adapter (Rails-default `:async`, in-process; de admin-checklist waarschuwt daarvoor). Plugins die `perform_later`/`deliver_later` gebruiken (ai_summary `GenerateSummaryJob`, ai_triage `WakeUpJob` + `AlertMailer`, custom_workflows `CustomWorkflowMailer`; reporter_dashboards gebruikt bewust `deliver_now`) verliezen jobs bij een herstart met `:async`; zet een echte adapter of `:inline` in `config/additional_environment.rb`. Redmine's eigen `Mailer` gebruikt sinds 7.0 een eigen `Mailer::DeliveryJob`.

