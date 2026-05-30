# Changelog
## [Unreleased]
### Added
- **In-UI dry-run preview** — the digest rule page now has a "Preview (dry run)"
  button that runs the real send path in dry-run mode (no emails, no records
  written) and shows, per recipient, what *would* happen (would send N issues /
  would skip / would fail). Only issue counts are shown — never issue titles —
  so the preview can never reveal issues a user could not otherwise see. Gated
  by the *manage digest rules* permission.

### Changed (issue filtering)
- The single **"New or updated since last run"** option is split into two
  independent, cumulative checkboxes: **"Newly created since last run"** and
  **"Updated since last run"**. A rule can now narrow on creation, on update, or
  on both. Migration 009 backfills both flags to true for rules that had the old
  option enabled, so existing behaviour is preserved; run
  `rake redmine:plugins:migrate` after upgrading. The migration is reversible.
- The recipient form shows a small info icon next to the
  Assignees/Authors/Watchers modes explaining that recipients are derived from
  the matching issues and each recipient only sees their own relevant issues
  (unless also selected via a broad mode).

### Fixed (database portability)
- The plugin could not be installed on **MySQL**: the migrations created the
  foreign keys to Redmine's core tables (`projects`, `users`) as `bigint`, but
  Redmine's legacy primary keys are `int(11)`. MySQL rejects the type mismatch
  (errno 150); PostgreSQL tolerated it. Those four FK columns are now pinned to
  `:integer`. Plugin-internal foreign keys (which reference the plugin's own
  `bigint`-keyed tables) are unchanged. Added a MySQL CI workflow.
- Added migration 008 to converge installs created before the fix: it converts
  any still-`bigint` core foreign-key columns (`project_id`, `created_by_id`,
  `updated_by_id`, `user_id`) to `:integer`, matching a fresh install. It is a
  safe no-op where the columns are already integer, preserves existing foreign
  keys and indexes, and is data-safe (Redmine ids fit in a 32-bit integer).
  Run `rake redmine:plugins:migrate` after upgrading to apply it.

### Changed
- The "Include …" issue filters are now consistently **additive (OR)**: checking
  "Recently updated"/"Recently created" alongside a status filter now ADDS those
  issues instead of narrowing the result, matching the on-screen hint. Narrowing
  controls (New/updated since last run, saved query, personalization) still apply
  with AND on top.
- The Filters form is grouped into "Include issues matching any of these" and
  "Then narrow the matched issues" for clarity; sub-project scope moved next to
  the saved-query selector.
- "New since last run only" renamed to **"New or updated since last run"** with
  matching help text, since the filter already matched updated (not only created)
  issues. Behavior unchanged; copy now reflects it across all locales.
- Recipient form now states that recipient modes are combined (union) and adds a
  "Personalization" sub-group explaining that those filters narrow each
  recipient's list (and that the Assignees/Authors/Watchers modes self-narrow).
- The "When trigger falls on weekend" dropdown is disabled unless "Weekdays only"
  is enabled, and "Send even if no issues match" warns about the empty-digest
  fan-out when combined with a broad recipient mode and a personalization filter.

### Fixed
- Recipient resolution for the `assignees`/`authors`/`watchers` modes now runs
  against the rule's *filtered* matching issues instead of every issue in the
  project. Previously a rule such as "open issues, new since last run" resolved
  every historical assignee in the project as a recipient (regardless of the
  status/date/`only_since_last_run` filters), which could email the whole team.
- When a recipient is selected *because* they are an assignee/author/watcher of
  matching issues, their digest is now scoped to the issues backing that
  relationship (source-aware personalization). Recipients added via a broad mode
  (project members, role, specific user, email) still receive the full matching
  list. A recipient who qualifies via both keeps the broad (full-list) behavior.

## [1.0.0] — initial release

