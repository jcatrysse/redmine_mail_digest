# access

Run 2026-10-06T19:58:05.456Z against http://127.0.0.1:3000.

| screenshot | user | URL | shows |
|---|---|---|---|
| ![](access-tab-manager.png) | manager | `/projects/e2e-project/settings/digest_rules` | manager: the Digest rules tab with New, Run history, Edit, Disable, Delete, each with its icon |
| ![](access-index-manager.png) | manager | `/projects/e2e-project/digest_rules` | manager: the rule list page with the New digest rule link |
| ![](access-index-viewer.png) | viewer | `/projects/e2e-project/digest_rules` | viewer (view only): the rule list with the Run history link, no New/Edit/Disable/Delete |
| ![](access-show-viewer.png) | viewer | `/projects/e2e-project/digest_rules/1` | viewer: the rule page without Preview, Edit, Disable or Delete |
| ![](access-new-refused-viewer.png) | viewer | `/projects/e2e-project/digest_rules/1/edit` | viewer: the new rule form is refused (403) |
| ![](access-index-refused-reporter.png) | reporter | `/projects/e2e-project/digest_rules` | reporter (no plugin permission): the rule list is refused (403) |
| ![](access-private-refused-outsider.png) | outsider | `/projects/e2e-private/digest_rules` | outsider: the rules of the private project are refused (403) |
| ![](access-anonymous.png) | anonymous | `/login?back_url=http%3A%2F%2F127.0.0.1%3A3000%2Fprojects%2Fe2e-project%2Fdigest_rules` | anonymous: sent to the login page |
| ![](access-other-project-404.png) | manager | `/projects/e2e-private/digest_rules/1` | manager: a rule of e2e-project opened under e2e-private is not found (404) |
| ![](access-module-off.png) | manager | `/projects/e2e-project/digest_rules` | module Issue digests switched off: the rule list is refused (403), also to the manager |
