# redmine_digest — Specification Index

**Plugin name:** `redmine_digest`  
**Spec version:** 1.1  
**Date:** 2026-05-27  
**Status:** Implementation-ready — all open questions resolved  
**Target Redmine versions:** 5.1-stable and 6.1-stable (primary)  
**Rails versions:** 7.0.x (Redmine 5.1) / 7.2.x (Redmine 6.1)  
**Ruby versions:** ≥ 3.0 (5.1) / ≥ 3.2, < 3.5 (6.1)  
**Test framework:** RSpec  
**Primary DB:** PostgreSQL; MySQL and SQLite3 also supported  

---

## Purpose

`redmine_digest` is a Redmine plugin that allows project managers to configure
scheduled email digests for their projects. A digest collects issues matching
configurable criteria and sends them to configurable recipients on a configurable
schedule. Digests are sent via the existing Redmine mailer infrastructure and
executed by a cron-driven rake task.

---

## Specification Documents

| # | File | Description |
|---|------|-------------|
| 01 | [01_product_requirements.md](01_product_requirements.md) | Problem statement, goals, user stories, acceptance criteria |
| 02 | [02_functional_specification.md](02_functional_specification.md) | Detailed behavior, edge cases, lifecycle rules |
| 03 | [03_architecture.md](03_architecture.md) | Plugin structure, components, services, Redmine integration |
| 04 | [04_data_model.md](04_data_model.md) | Database tables, columns, types, indexes, associations |
| 05 | [05_scheduler.md](05_scheduler.md) | Rake task, cron design, locking, idempotency, logging |
| 06 | [06_ui_spec.md](06_ui_spec.md) | Project settings UI, forms, pages, I18n keys |
| 07 | [07_mailer_spec.md](07_mailer_spec.md) | Email format, subject, HTML/text, personalization |
| 08 | [08_security.md](08_security.md) | Permissions, authorization, issue visibility, injection risks |
| 09 | [09_performance.md](09_performance.md) | Query patterns, N+1 avoidance, batching, index strategy |
| 10 | [10_test_plan.md](10_test_plan.md) | Unit, integration, mailer, rake, concurrency, timezone tests |
| 11 | [11_agent_plan.md](11_agent_plan.md) | Multi-agent work packages, dependencies, handoff notes |

---

## Key Assumptions

1. **Plugin-only deployment**: No changes to Redmine core files; all hooks via the
   Redmine plugin API.
2. **Cron-driven execution**: No background job framework (Sidekiq, DelayedJob) is
   added. Execution is via `bundle exec rake redmine:issue_digest:send`.
3. **RSpec test framework**: Consistent with CI configuration in `.github/workflows/`.
4. **PostgreSQL as primary target**: JSON column type used for `schedule_config`
   and `recipient_modes`; MySQL fallback uses TEXT with JSON serialization. SQLite3
   also supported.
5. **No external email relay (v1)**: Recipients must be Redmine users with valid email
   addresses. External (non-Redmine-user) addresses are explicitly out of scope for v1.
   The global admin settings page includes an `allow_external_recipients` toggle reserved
   for a future version; it has no effect in v1.
6. **Redmine IssueQuery reuse**: Existing saved queries are referenced by ID and
   applied as-is; the plugin does not re-implement query logic.
7. **Issue visibility is enforced per recipient**: Each recipient sees only the
   issues they are permitted to see; digests are personalized.
8. **No asset pipeline changes**: Minimal JavaScript; form behavior via standard
   HTML and Stimulus where needed.
9. **Roadie Rails**: HTML email CSS inlining is handled by Redmine's existing
   Roadie Rails integration.
10. **Zeitwerk autoloading**: All plugin classes follow Zeitwerk naming conventions
    (directory structure matches module nesting).

---

## Resolved Decisions (formerly Open Questions)

All open questions have been answered. The table below is closed; there are no
remaining open questions for v1.

| ID | Question | Decision |
|----|----------|----------|
| OQ-01 | Should digests support fixed external (non-Redmine-user) email addresses? | **No — out of scope for v1.** Global admin settings page includes a placeholder `allow_external_recipients` toggle (always false, inert in v1). |
| OQ-02 | Should per-user digest preferences allow users to opt out? | **No — not in v1.** Admin/PM controls the recipient list entirely. Per-user opt-out is a future enhancement. |
| OQ-03 | Should the plugin support custom cron expressions? | **No — discrete schedule types only in v1** (daily, weekdays, weekly, monthly). |
| OQ-04 | Should the plugin use a process-level file lock or a DB-level advisory lock? | **DB advisory lock (PostgreSQL `pg_try_advisory_xact_lock`), with file-based fallback for MySQL/SQLite3.** |
| OQ-05 | Should empty digests (no matching issues) be sent? | **Configurable per rule via `send_empty` boolean field; default: do not send.** |
| OQ-06 | Should there be a global admin configuration page? | **Yes.** Settings: max issues per email, allow external recipients (v1 placeholder), run history retention days. |
| OQ-07 | Should digest rules be copyable from project to project? | **Not in v1.** |
| OQ-08 | What is the data retention policy for run history? | **Configurable via global admin settings; default: 90 days.** |
| OQ-09 | Should digest delivery be retried on SMTP failure? | **No automatic retry.** Failures are logged and recorded; no retry in the same or subsequent run. |
| OQ-10 | Should the plugin expose a REST API for digest rules? | **Not in v1.** |

---

## Quality Gate Summary

| Gate | Status | Notes |
|------|--------|-------|
| G1 Requirements coverage | PASS | All requested features covered; OQ-01/OQ-03/OQ-07/OQ-10 explicitly deferred to v2 |
| G2 Redmine consistency | PASS | Follows plugin DSL, Hook API, IssueQuery, Mailer, permission patterns |
| G3 Implementation readiness | PASS | Each agent work package is self-contained |
| G4 Security | PASS | Issue visibility per-recipient; permission guards on all actions |
| G5 Testability | PASS | Concrete test cases in spec 10 |
| G6 Operational readiness | PASS | Rake task, locking, idempotency, logging all specified |
| G7 Multi-agent readiness | PASS | 8 work packages with clear dependencies |
