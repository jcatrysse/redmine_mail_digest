# Decided by Jan, 2026-10-07

Jan Catrysse answered the open questions of this plugin on 2026-10-07, one at a time, with the
options, an explanation and the recommendation in front of him, in the coordinating session that
started the migration sessions (https://claude.ai/code/session_01GiSsYPm3bxvqrpZkdCxNoi).
This file records his answers as given; his free-text notes are quoted verbatim. The migration
session moves each into docs/REDMINE7-MIGRATION.md as decided and builds what it requires.

General decisions by Jan (2026-10-07), for every GEOxyz plugin:
- GEOxyz goes straight to Redmine 7: no backports to 5.1. Nothing is cherry-picked to the default branch or to the branch production runs today; `redmine70-migration` is what goes live with Redmine 7. Redmine 5.1 compatibility is no longer a requirement; drop that rule from the plan and do not add code paths that exist only for 5.1.
- GEOxyz does not use MariaDB or MySQL; production runs PostgreSQL 16. Run the tests and the e2e set on PostgreSQL only. Keep SQL portable where that costs nothing, but MariaDB runs are no longer required and a MariaDB-only problem is a note in the plan, not a blocker.
- A plugin that depends on deface requires it without a version constraint (change it when the Gemfile is touched anyway).
- A Redmine core method that other installed plugins also patch is patched with `prepend`, never with `alias_method`. Mixing both on one method recurses; that is what made Project > Settings return HTTP 500 with all GEOxyz plugins installed. Check this plugin: if it patches such a method with `alias_method`, switch it to `prepend` with a test, and confirm Project > Settings, the issue list and an issue page answer 200 with the other GEOxyz plugins installed (`RMP_EXTRA_PLUGINS`).
- GitHub Actions stay manual only (`workflow_dispatch`).

This plugin had no open questions; only the general decisions apply. What to do:
1. `git fetch && git checkout redmine70-migration && git pull`.
2. Record the general decisions in docs/REDMINE7-MIGRATION.md (date 2026-10-07) and update the plan's rules (no 5.1, PostgreSQL only).
3. The prepend rule: `ProjectsHelper#project_settings_tabs` is patched with `alias_method` in lib/issue_digest/projects_helper_patch.rb; at least four other GEOxyz plugins patch the same method. If another installed plugin patches the same method, switch to `prepend` with the same behaviour and a test that fails without it. If no other plugin touches it, say so in the plan and change nothing.
4. If you changed code: plugin tests green on PostgreSQL alone and with the other GEOxyz plugins, an e2e scenario for the affected function (screenshots looked at, committed), your own review and the OpenAI review when OPENAI_API_KEY is set.
5. Push `redmine70-migration` after every commit, and end with a short report in Dutch: what changed, test and e2e numbers, review result.
