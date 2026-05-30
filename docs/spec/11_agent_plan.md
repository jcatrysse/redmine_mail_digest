# Multi-Agent Implementation Plan — redmine_mail_digest

## Overview

The implementation is divided into 8 work packages that can be executed by separate
coding agents. Each package has defined inputs, outputs, acceptance criteria, and
explicit dependencies.

**Execution order**: Agents 1 → 2 → [3, 4, 5 in parallel] → 6 → 7 → 8

---

## Integration Order

```
Agent 1: Data model + migrations (foundation)
  ↓
Agent 2: Core services (ScheduleEvaluator, RecipientResolver, IssueResolver, QueryAdapter, LockManager)
  ↓
Agent 3: Rake task + DigestSender + RunRecorder  [parallel with 4, 5]
Agent 4: Project settings UI (controller, views, helpers)  [parallel with 3, 5]
Agent 5: Mailer + email templates  [parallel with 3, 4]
  ↓
Agent 6: Permissions + security hardening (cross-cutting; reviews all agents' output)
  ↓
Agent 7: Test suite (comprehensive RSpec; all components)
  ↓
Agent 8: Documentation, init.rb finalization, CI validation
```

---

## Agent 1: Data Model and Migrations

### Scope
- Create the three database migration files.
- Create the three model files with associations, validations, scopes, and instance methods.
- Create FactoryBot factory files.
- Write model specs.

### Files to create

```
db/migrate/001_create_issue_digest_rules.rb
db/migrate/002_create_issue_digest_runs.rb
db/migrate/003_create_issue_digest_deliveries.rb
app/models/issue_digest_rule.rb
app/models/issue_digest_run.rb
app/models/issue_digest_delivery.rb
spec/factories/issue_digest_rules.rb
spec/factories/issue_digest_runs.rb
spec/factories/issue_digest_deliveries.rb
spec/models/issue_digest_rule_spec.rb
spec/models/issue_digest_run_spec.rb
spec/models/issue_digest_delivery_spec.rb
```

### Inputs from spec
- `04_data_model.md` — complete column definitions, types, indexes, associations
- `02_functional_specification.md` — validation rules, lifecycle behavior
- `03_architecture.md` — model methods required by services

### Expected outputs
- Three migrations that run cleanly via `bundle exec rake redmine:plugins:migrate`
- Three model classes with all validations, scopes, and instance methods listed in spec
- FactoryBot factories for all three models
- RSpec model tests covering all validations and associations (see `10_test_plan.md` section 3)

### Dependencies
- None; this is the foundation.

### Acceptance criteria
- `rake redmine:plugins:migrate` succeeds on fresh DB.
- All model tests pass.
- `IssueDigestRule.active.due_now` scope works (even if logic is stubbed).
- `IssueDigestRule#active?` correctly handles start_on/end_on.
- `IssueDigestRule#schedule_config` serializes/deserializes JSON correctly.

### Tests to add
- All model tests from `10_test_plan.md` section 3.

### Risks
- `serialize :field, coder: JSON` behaves differently on Rails 7.0 vs 7.2. Test both.
- `TIME` column type for `send_time` in SQLite3 may serialize as string. Handle in model.
- Foreign key `ON DELETE CASCADE` may fail on older MySQL. Add fallback or document requirement.

### Handoff notes
- Other agents depend on model classes being stable. Do NOT rename models or change
  serialization format after Agent 2 has started.
- The `IssueDigestRule#active?` method must return false when `start_on` is future or
  `end_on` is past. Agents 2 and 3 depend on this.

---

## Agent 2: Core Services

### Scope
- Implement the five core service objects.
- No UI, no rake task, no mailer.
- Each service has a clean interface as specified in `03_architecture.md`.

### Files to create

```
app/services/issue_digest/schedule_evaluator.rb
app/services/issue_digest/recipient_resolver.rb
app/services/issue_digest/issue_resolver.rb
app/services/issue_digest/query_adapter.rb
app/services/issue_digest/lock_manager.rb
spec/services/issue_digest/schedule_evaluator_spec.rb
spec/services/issue_digest/recipient_resolver_spec.rb
spec/services/issue_digest/issue_resolver_spec.rb
spec/services/issue_digest/lock_manager_spec.rb
```

### Inputs from spec
- `02_functional_specification.md` — sections 3, 6, 7, 8 (schedule, recipients, issues)
- `03_architecture.md` — section 8 (service interfaces)
- `05_scheduler.md` — section 4 (due-check algorithm)
- `08_security.md` — sections 3, 7 (Issue.visible, SQL safety)
- `09_performance.md` — sections 2, 3 (N+1 avoidance, index usage)

### Expected outputs
- Five service classes implementing the interfaces in section 8 of `03_architecture.md`.
- RSpec service tests (see `10_test_plan.md` section 4).

### Dependencies
- Agent 1 must be complete (models must exist).

### Acceptance criteria
- `IssueDigest::ScheduleEvaluator.new(rule).due?` returns correct values for all schedule types.
- `IssueDigest::RecipientResolver.new(rule).resolve` returns only active, permissioned users.
- `IssueDigest::IssueResolver.new(rule, user: user).resolve` always applies `Issue.visible(user)`.
- `IssueDigest::QueryAdapter.new(rule).apply_to(scope)` handles deleted/invisible queries safely.
- `IssueDigest::LockManager.with_lock {}` prevents concurrent execution.
- All service tests pass.

### Tests to add
- All service tests from `10_test_plan.md` section 4.

### Risks
- `IssueQuery#statement` is a Redmine internal API; verify it exists and works as expected in 5.1 and 6.1.
- The watcher recipient mode requires a JOIN through `watchers` table; confirm table name.
- `Issue.visible(user)` scope: verify it exists as a class-level scope in both versions.
- PostgreSQL advisory lock syntax: `pg_try_advisory_xact_lock` may not be available in all configs.

### Handoff notes
- `IssueResolver#base_scope_without_visibility` (without `Issue.visible`) is needed by the
  `RecipientResolver` to find candidate assignees/watchers. Export this as a public method.
- Do NOT load issues into memory in `RecipientResolver`; use subqueries.
- Service classes must be in the `IssueDigest::` module namespace.

---

## Agent 3: Rake Task, DigestSender, and RunRecorder

### Scope
- Implement the rake task.
- Implement `IssueDigest::DigestSender`.
- Implement `IssueDigest::RunRecorder`.

### Files to create

```
lib/tasks/issue_digest.rake
app/services/issue_digest/digest_sender.rb
app/services/issue_digest/run_recorder.rb
spec/tasks/issue_digest_rake_spec.rb
spec/services/issue_digest/digest_sender_spec.rb
```

### Inputs from spec
- `05_scheduler.md` — complete rake task specification
- `03_architecture.md` — service interfaces for DigestSender and RunRecorder
- `02_functional_specification.md` — section 11 (failure handling), section 5 (duplicate prevention)

### Expected outputs
- Working rake task with all ENV variable support.
- `DigestSender` that orchestrates the full delivery flow.
- `RunRecorder` that persists run/delivery records.
- Rake task tests.

### Dependencies
- Agent 1 (models) and Agent 2 (core services) must be complete.
- Agent 5 (mailer) must exist at least as a stub before integration testing.

### Acceptance criteria
- `bundle exec rake redmine:issue_digest:send RAILS_ENV=test` runs without error.
- `DRY_RUN=1` sends no emails and creates no DB records.
- `PROJECT_IDENTIFIER=x` limits processing to that project.
- `RULE_ID=n` limits to that rule.
- Double-execution is prevented (idempotency test passes).
- `cleanup` task prunes old records correctly.
- Rails.logger receives correct messages at correct levels.

### Tests to add
- All rake task tests from `10_test_plan.md` section 7.
- DigestSender unit tests (mock mailer, verify delivery records).

### Risks
- Rake task loading in test environment: ensure `rake` is loaded correctly in `rails_helper.rb`.
- PostgreSQL advisory lock requires an active PG connection; test environment uses PG (confirmed by CI).
- `last_run_at` atomic update: verify `update_all` returns the correct affected row count in all DB backends.

### Handoff notes
- The mailer action name is `IssueDigestMailer#digest_email`. Agent 3 calls `.deliver_now`
  and must rescue `StandardError`.
- The `DigestSender` group_issues method must return a Hash (group_name → issues array)
  for grouped modes, or nil for `group_by = 'none'`. The mailer spec depends on this structure.

---

## Agent 4: Project Settings UI

### Scope
- Implement the plugin's Rails controller and all views.
- Implement form helpers.
- Implement global admin settings partial.
- Register plugin in `init.rb`.
- Register routes.
- Add I18n locale file (`en.yml`).

### Files to create

```
init.rb
config/routes.rb
config/locales/en.yml
lib/redmine_mail_digest/version.rb
app/controllers/issue_digest/digest_rules_controller.rb
app/helpers/issue_digest/digest_rules_helper.rb
app/views/issue_digest/digest_rules/index.html.erb
app/views/issue_digest/digest_rules/new.html.erb
app/views/issue_digest/digest_rules/edit.html.erb
app/views/issue_digest/digest_rules/show.html.erb
app/views/issue_digest/digest_rules/_form.html.erb
app/views/issue_digest/digest_rules/_rule_row.html.erb
app/views/issue_digest/digest_rules/_run_history.html.erb
app/views/settings/_issue_digest_settings.html.erb
spec/controllers/issue_digest/digest_rules_controller_spec.rb
```

### Inputs from spec
- `06_ui_spec.md` — complete UI specification (forms, tables, validations, I18n keys)
- `03_architecture.md` — controller design, routes, strong params
- `08_security.md` — authorization, CSRF, strong parameters
- `01_product_requirements.md` — permission model

### Expected outputs
- All views rendered without errors.
- All controller actions with correct permission guards.
- Complete `en.yml` locale file.
- Complete `init.rb` with plugin registration.
- Controller specs passing.

### Dependencies
- Agent 1 (models) must be complete.
- No dependency on Agents 2, 3, or 5 for basic UI functionality.

### Acceptance criteria
- `GET /projects/p/digest_rules` renders correctly for users with `view_digest_rules`.
- `GET /projects/p/digest_rules/new` renders form for users with `manage_digest_rules`.
- Form submission creates a rule and redirects.
- 403 returned for unauthorized users on every action.
- 404 returned for rules from wrong project.
- `init.rb` registers plugin, module, permissions, and menu.

### Tests to add
- All controller tests from `10_test_plan.md` section 5.
- Permission tests from section 9.

### Risks
- Redmine 6.1 uses Propshaft (not Sprockets). Do not reference `asset_path` or `image_path`.
- Schedule type dynamic field show/hide may require Stimulus. If Stimulus is unavailable,
  use simple `style="display:none"` toggling with a `<script>` block. Keep minimal JS.
- The project settings tab integration: verify the correct Redmine hook or URL structure.
  Using the plugin's own controller (`/projects/:id/digest_rules`) is the safest approach.

### Handoff notes
- The `init.rb` must be reviewed by Agent 6 (security) before final commit.
- The `schedule_config` form fields are nested attributes. Use `fields_for` or individual
  named inputs that submit as `issue_digest_rule[schedule_config][day]`, etc.
- For `recipient_modes`, use checkbox inputs: `<input type="checkbox" name="issue_digest_rule[recipient_modes][]" value="project_members">`.

---

## Agent 5: Mailer and Email Templates

### Scope
- Implement `IssueDigestMailer`.
- Implement HTML and plain text email templates.
- Implement issue grouping logic (can be a private method or extracted helper).

### Files to create

```
app/mailers/issue_digest_mailer.rb
app/views/issue_digest_mailer/digest_email.html.erb
app/views/issue_digest_mailer/digest_email.text.erb
app/views/issue_digest_mailer/_issue_row.html.erb
spec/mailers/issue_digest_mailer_spec.rb
```

### Inputs from spec
- `07_mailer_spec.md` — complete mailer and email template specification
- `03_architecture.md` — mailer class design

### Expected outputs
- `IssueDigestMailer.digest_email(rule, user, issues, grouped_issues).deliver_now` works.
- HTML email renders correctly with issue table and group headers.
- Plain text email renders correctly.
- Mailer specs passing.

### Dependencies
- Agent 1 (models) must be complete so `IssueDigestRule` exists.
- No dependency on Agents 2, 3, or 4.

### Acceptance criteria
- Mailer action `digest_email` delivers to `user.mail`.
- Subject uses default or custom template.
- HTML email has correct structure (table, group headers, footer).
- Plain text email is readable.
- Empty issue list renders "No issues matched" if called (only when `send_empty=true`).
- Issue links use correct absolute URL format.
- Mailer specs all pass.

### Tests to add
- All mailer tests from `10_test_plan.md` section 6.

### Risks
- Roadie Rails CSS inlining: verify the `roadie-rails` gem is present in Redmine 6.1's Gemfile.
  If not, the HTML email will not have inlined CSS (degraded but not broken).
- `Setting.host_name` and `Setting.protocol` may return nil in test environment; stub them.
- Multipart email: both `html` and `text` formats must be specified in the `mail` call.

### Handoff notes
- Agent 3 (`DigestSender`) calls `IssueDigestMailer.digest_email(rule, user, issues, grouped_issues)`.
  The `grouped_issues` parameter is a `Hash<String, Array<Issue>>` or `nil`.
- The mailer must handle `grouped_issues: nil` gracefully (flat list rendering).

---

## Agent 6: Permissions and Security Review

### Scope
- Review all code from Agents 1–5 against `08_security.md`.
- Fix any identified security issues.
- Add any missing authorization checks.
- Validate strong parameters on all controllers.
- Verify `Issue.visible(user)` is applied in all code paths.
- Verify no raw SQL injection vectors.
- Add security-specific RSpec tests.

### Files to review and potentially modify

All files from Agents 1–5, plus:
```
spec/security/  (new directory for security-focused specs)
```

### Inputs from spec
- `08_security.md` — complete security checklist

### Expected outputs
- All items in `08_security.md` section 15 (Security Review Checklist) marked PASS.
- Any failing items resolved with code changes.
- Additional security specs.

### Dependencies
- Agents 1–5 must have complete implementations.

### Acceptance criteria
- IDOR test: requesting a rule from a different project returns 404.
- Visibility test: private issues are not included for unauthorized recipients.
- SQL injection test: malformed recipient_mode does not cause DB error.
- No `permit!` anywhere in controllers.
- `Issue.visible(user)` present in every code path that loads issues for delivery.

### Tests to add
- All security tests from `10_test_plan.md` section 10.

### Risks
- Security issues may require API changes to services (e.g., IssueResolver must accept user).
  These changes may break Agent 3's DigestSender. Coordinate via handoff notes.

### Handoff notes
- Document every change made and why in the commit message.
- Security changes that affect service interfaces must be communicated to Agent 7 (tests).

---

## Agent 7: Test Suite

### Scope
- Fill in any gaps in the test suite.
- Add all missing tests from `10_test_plan.md`.
- Add timezone/DST tests.
- Add concurrency/idempotency tests.
- Add integration tests.
- Ensure all existing tests pass.
- Set up `spec/spec_helper.rb` and `spec/rails_helper.rb` correctly.

### Files to create

```
spec/spec_helper.rb
spec/rails_helper.rb
spec/integration/digest_flow_spec.rb
spec/services/issue_digest/schedule_evaluator_spec.rb  (if not complete)
spec/services/issue_digest/recipient_resolver_spec.rb  (if not complete)
# ... any remaining gaps from 10_test_plan.md
```

### Inputs from spec
- `10_test_plan.md` — complete test case list
- All other spec documents for expected behavior

### Expected outputs
- Full RSpec test suite covering all components.
- All tests passing in both Redmine 5.1 and 6.1 CI environments.
- Coverage of all test categories in `10_test_plan.md`.

### Dependencies
- Agents 1–6 must be complete before comprehensive test runs.
- Agents 1–3 and 5 produce partial test files; Agent 7 fills remaining gaps.

### Acceptance criteria
- `bundle exec rspec plugins/redmine_mail_digest/spec` exits 0.
- No pending or skipped tests without documented reason.
- Timezone tests cover UTC, UTC+2 (summer), UTC+1 (winter), and DST boundary cases.
- Idempotency tests prove no double-sends under concurrent conditions.

### Tests to add
- Complete set per `10_test_plan.md`.

### Risks
- Redmine test infrastructure loading: `rails_helper.rb` must correctly boot Redmine's test environment.
  Reference existing Redmine plugin test setups (check CI workflow for precedent).
- FactoryBot and Redmine: Redmine uses fixtures, not factories. Confirm FactoryBot does not
  conflict with Redmine's `test_helper`. May need to load Redmine's fixtures and supplement with factories.
- Timezone tests require `ActiveSupport::TimeZone` to be available; verify in test env.

### Handoff notes
- The CI workflow (`rspec-61.yml`) shows how the plugin is loaded into Redmine for testing.
  The `rails_helper.rb` must mirror this setup locally.

---

## Agent 8: Documentation and Final Integration

### Scope
- Write the user-facing README.
- Write CHANGELOG.md.
- Write INSTALL.md with cron configuration examples.
- Finalize `init.rb` (version, URLs, description).
- Run `bundle exec rake redmine:plugins:migrate` and `bundle exec rspec` end-to-end.
- Validate that the plugin installs cleanly on a fresh Redmine 6.1 instance.
- Verify CI configuration in `.github/workflows/` is correct.

### Files to create/modify

```
README.md
CHANGELOG.md
INSTALL.md
lib/redmine_mail_digest/version.rb  (set to 1.0.0)
init.rb  (final review)
.github/workflows/rspec-61.yml  (verify is correct)
.github/workflows/rspec-51.yml  (verify is correct)
```

### Inputs from spec
- All spec documents.
- Output from Agents 1–7.

### Expected outputs
- Complete README with installation, configuration, cron setup, and usage instructions.
- INSTALL.md with step-by-step guide.
- Both CI workflows passing.
- Plugin version set to 1.0.0.

### Dependencies
- All other agents must be complete.

### Acceptance criteria
- Fresh Redmine 6.1 installation: install plugin → migrate → enable module → create rule →
  run rake task → email sent. End-to-end works.
- CI workflows pass on GitHub Actions.
- README is complete and accurate.

### Tests to add
- None (documentation only, plus validation of existing test suite).

### Risks
- Integration issues discovered at this stage require coordination with earlier agents.
- CI environment differences (different Ruby versions) may expose compatibility bugs.

### Handoff notes
- Version 1.0.0should be set only when all tests pass.
- DO NOT add the plugin to rubygems.org or any public index until security review is complete.

---

## Summary Dependency Graph

```
Agent 1 (Models)
    │
    ▼
Agent 2 (Core Services)
    │
    ├──────────────────────────────────────────────┐
    ▼                    ▼                         ▼
Agent 3 (Rake/Sender) Agent 4 (UI/Controller)  Agent 5 (Mailer)
    │                    │                         │
    └──────────────┬──────┘─────────────────────────┘
                  ▼
             Agent 6 (Security Review)
                  │
                  ▼
             Agent 7 (Test Suite)
                  │
                  ▼
             Agent 8 (Docs + Integration)
```

---

## File Ownership Table

| File | Owner Agent |
|------|------------|
| `db/migrate/*` | Agent 1 |
| `app/models/*` | Agent 1 |
| `spec/factories/*` | Agent 1 |
| `spec/models/*` | Agent 1 |
| `app/services/issue_digest/schedule_evaluator.rb` | Agent 2 |
| `app/services/issue_digest/recipient_resolver.rb` | Agent 2 |
| `app/services/issue_digest/issue_resolver.rb` | Agent 2 |
| `app/services/issue_digest/query_adapter.rb` | Agent 2 |
| `app/services/issue_digest/lock_manager.rb` | Agent 2 |
| `spec/services/*` | Agents 2+7 |
| `lib/tasks/issue_digest.rake` | Agent 3 |
| `app/services/issue_digest/digest_sender.rb` | Agent 3 |
| `app/services/issue_digest/run_recorder.rb` | Agent 3 |
| `spec/tasks/*` | Agent 3+7 |
| `init.rb` | Agent 4 |
| `config/routes.rb` | Agent 4 |
| `config/locales/en.yml` | Agent 4 |
| `app/controllers/*` | Agent 4 |
| `app/helpers/*` | Agent 4 |
| `app/views/issue_digest/digest_rules/*` | Agent 4 |
| `app/views/settings/*` | Agent 4 |
| `spec/controllers/*` | Agent 4+7 |
| `app/mailers/*` | Agent 5 |
| `app/views/issue_digest_mailer/*` | Agent 5 |
| `spec/mailers/*` | Agent 5+7 |
| Security review + fixes | Agent 6 |
| `spec/rails_helper.rb` | Agent 7 |
| `spec/integration/*` | Agent 7 |
| `README.md`, `INSTALL.md`, `CHANGELOG.md` | Agent 8 |
