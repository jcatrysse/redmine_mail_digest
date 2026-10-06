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
| Runs on Redmine 7 as is | JA |
| Upstream sync | GEEN UPSTREAM |
| After sync | n.v.t. |
| Complexity (1 trivial .. 5 rewrite) | 1 |
| Measured on | Redmine 7.0.1 (7.0-stable-GEOxyz + latest 7.0-stable), Rails 8.1.3.1, Ruby 3.3.6, PostgreSQL 16 and MariaDB 10.11 |
| Branch head when this file was written | `14ee9c2` |

## Already on this branch

- nothing: the branch equals the branch GEOxyz runs today.

## Work list for the migration session

In this order: things that break, security, the GEOxyz changes, the open items, then the checks.

**Open items from the analysis** (Dutch; where they conflict with a decision or a priority item above, those win)

1. Make specs create builtin groups and a Non member role with view_issues themselves
2. Product decision: honour mail_notification=none / add Auto-Submitted header (digest bypasses Redmine Mailer)
3. Icons icon-* -> sprite_icon (cosmetic)

**Checks**

4. Run the plugin's whole test suite on Redmine 7.0-stable-GEOxyz with PostgreSQL AND MariaDB, and once on 5.1-stable if the branch is meant to stay 5.1-compatible.
5. Check Redmine 7 webhooks against this plugin (see "Rules"), and note the result here even if nothing is needed.
6. Verify every feature of the plugin by hand on a running Redmine 7 (screenshots).

## GEOxyz changes to review or re-apply

Own plugin: all of it is GEOxyz code, so there is nothing to re-apply. While migrating, hold the code you touch to the rules below; list larger quality problems you find in the work list instead of fixing them in passing.

## After the upgrade (production)

Actions the person doing the upgrade must take, or know about, for this plugin:

- Re-create the cron entries `redmine:issue_digest:send` and `:cleanup`.

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
6. **Portability**: everything must run on Redmine's supported databases (PostgreSQL,
   MySQL/MariaDB; SQLite where the plugin already supports it). Migrations must be reversible and
   are run down and up on PostgreSQL and MariaDB.
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
- **5.1 compatibility**: prefer fixes that also run on Redmine 5.1 so they can be merged early;
  say so when a fix cannot.
- **Git**: work on `redmine70-migration` only; never push to the default branch; never force-push
  a branch someone else uses. Descriptive commit messages (what and why). Push after every
  commit, together with the updated status in this file: a cloud session can stop at a usage
  limit, and work that is not pushed is lost with its container.
- **GitHub Actions**: manual only (`workflow_dispatch`). Do not add push, pull_request or schedule
  triggers.

## Definition of done

- All items of the work list are done or explicitly deferred with a reason, in this file.
- The plugin's tests are green on Redmine 7.0-stable-GEOxyz with PostgreSQL and MariaDB
  (numbers in this file); boot, production-like eager load, migrations up/down OK.
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

