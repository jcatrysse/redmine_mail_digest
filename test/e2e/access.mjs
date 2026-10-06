// Who reaches the digest rules: the "Digest rules" tab in the project settings
// and the rule pages, per user. manager has both plugin permissions, viewer only
// view_digest_rules, reporter none, outsider is no member; anonymous is not
// logged in. Also: the module switched off refuses everybody but the admin.
import { e2e } from '../../.codex/e2e/lib.mjs';
import { execFileSync } from 'node:child_process';

const P = 'e2e-project';
const t = await e2e('access');
const R = process.env.REDMINE_DIR;
const runner = (code) => execFileSync('bundle', ['exec', 'rails', 'runner', '-e', 'production', code],
  { cwd: R, encoding: 'utf8' }).trim();

// one rule to look at, made directly so this scenario does not depend on the form
const ruleId = runner(`
  p = Project.find_by!(identifier: '${P}')
  r = IssueDigestRule.find_or_initialize_by(project_id: p.id, name: 'E2E access rule')
  r.assign_attributes(active: true, schedule_type: 'daily', send_time: '08:00', timezone: 'Etc/UTC',
                      grace_window_hours: 24, non_business_day_behavior: 'skip',
                      recipient_modes: ['project_members'], include_open: true, group_by: 'none',
                      created_by: User.find_by!(login: 'admin'))
  r.save!
  print r.id`);

await t.login('manager');
await t.go(`/projects/${P}/settings/digest_rules`);
if (!(await t.page.locator('#tab-digest_rules').count())) t.problems.push('manager: no Digest rules tab');
// an icon is drawn either by an SVG sprite inside (Redmine 6+) or by the
// icon-* background image (Redmine 5.1)
for (const css of ['a.icon-add', 'a.icon-edit', '.icon-lock', '.icon-del']) {
  const drawn = await t.page.locator(`#digest-rules-settings ${css}`).first().evaluate(el =>
    !!el.querySelector('svg use') || getComputedStyle(el).backgroundImage !== 'none').catch(() => false);
  if (!drawn) t.problems.push(`manager, settings tab: ${css} has no icon`);
}
await t.shot('tab-manager', 'manager: the Digest rules tab with New, Run history, Edit, Disable, Delete, each with its icon');
await t.go(`/projects/${P}/digest_rules`);
await t.shot('index-manager', 'manager: the rule list page with the New digest rule link');

// viewer: view_digest_rules alone does not open the project settings (Redmine
// needs a settings permission), so the project menu entry leads to the list.
await t.login('viewer');
await t.go(`/projects/${P}/settings/digest_rules`, { status: 403 });
await t.go(`/projects/${P}`);
const menuEntry = t.page.locator('#main-menu a.issue-digest-rules');
if (!(await menuEntry.count())) t.problems.push('viewer: no Digest Rules entry in the project menu');
await menuEntry.click();
await t.settle();
t.check('viewer menu entry');
if (!new URL(t.page.url()).pathname.endsWith(`/projects/${P}/digest_rules`)) t.problems.push(`viewer: menu entry led to ${t.page.url()}`);
if (!(await t.page.locator('#main-menu a.issue-digest-rules.selected').count())) t.problems.push('viewer: menu entry not selected on the rule list');
if (await t.page.locator('a.icon-add, a.icon-edit, .icon-lock, .icon-del').count()) {
  t.problems.push('viewer: manage links shown without manage_digest_rules');
}
await t.shot('index-viewer', 'viewer (view only): "Digest Rules" in the project menu opens the rule list; Run history only, no New/Edit/Disable/Delete');
await t.go(`/projects/${P}/digest_rules/${ruleId}`);
if (await t.page.locator('a.icon-test, a.icon-edit').count()) t.problems.push('viewer: preview/edit shown on the rule page');
const back = await t.page.locator('p.back-url a').getAttribute('href');
if (back !== `/projects/${P}/digest_rules`) t.problems.push(`viewer: back link to ${back}`);
await t.shot('show-viewer', 'viewer: the rule page without Preview, Edit, Disable or Delete; the back link leads to the rule list');
await t.go(`/projects/${P}/digest_rules/new`, { status: 403 });
await t.go(`/projects/${P}/digest_rules/${ruleId}/edit`, { status: 403 });
await t.shot('new-refused-viewer', 'viewer: the new rule form is refused (403)');
// a POST without the permission: the CSRF token of the page, then fetch
const viewerPosts = await t.page.evaluate(async ({ P, ruleId }) => {
  const token = document.querySelector('meta[name=csrf-token]')?.content;
  const out = {};
  for (const action of ['disable', 'preview']) {
    const r = await fetch(`/projects/${P}/digest_rules/${ruleId}/${action}`, {
      method: 'POST', headers: { 'X-CSRF-Token': token, 'X-Requested-With': 'XMLHttpRequest' } });
    out[action] = r.status;
  }
  const d = await fetch(`/projects/${P}/digest_rules/${ruleId}`, {
    method: 'POST', headers: { 'X-CSRF-Token': token, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: '_method=delete' });
  out.delete = d.status;
  return out;
}, { P, ruleId });
t.check('viewer posts', { requests: ['403 fetch'] });
for (const [k, v] of Object.entries(viewerPosts)) if (v !== 403) t.problems.push(`viewer: POST ${k} returned ${v}, expected 403`);
if (runner(`print IssueDigestRule.find(${ruleId}).active`) !== 'true') t.problems.push('viewer: the rule was disabled');

// digester: both plugin permissions and no other settings permission. The
// settings page opens with only the Digest Rules tab, and a save lands there.
await t.login('digester');
await t.go(`/projects/${P}/settings/digest_rules`);
const tabs = await t.page.locator('.tabs a[id^=tab-]').allTextContents();
if (tabs.length !== 1 || !(await t.page.locator('#tab-digest_rules').count())) t.problems.push(`digester: settings tabs ${tabs.join(', ')}`);
await t.page.locator('#digest-rules-settings tr', { hasText: 'E2E access rule' }).locator('button.icon-lock').click();
await t.settle();
t.check('digester disable');
if (!new URL(t.page.url()).pathname.startsWith(`/projects/${P}/settings`) || !(await t.page.locator('#flash_notice').count())) {
  t.problems.push(`digester: disable did not land on the settings tab with a notice (${t.page.url()})`);
}
await t.shot('tab-digester', 'digester (manage_digest_rules, no other settings permission): the settings page shows only the Digest Rules tab, a disable lands back on it');
await t.page.locator('#digest-rules-settings tr', { hasText: 'E2E access rule' }).locator('button.icon-unlock').click();
await t.settle();
t.check('digester enable');

await t.login('reporter');
await t.go(`/projects/${P}`);
if (await t.page.locator('#main-menu a.issue-digest-rules').count()) t.problems.push('reporter: Digest Rules entry in the project menu');
await t.go(`/projects/${P}/settings`, { status: 403 });
await t.go(`/projects/${P}/digest_rules`, { status: 403 });
await t.shot('index-refused-reporter', 'reporter (no plugin permission): the rule list is refused (403)');
await t.go(`/projects/${P}/digest_rules/${ruleId}`, { status: 403 });

await t.login('outsider');
await t.go(`/projects/${P}/digest_rules`, { status: 403 });
await t.go('/projects/e2e-private/digest_rules', { status: 403 });
await t.shot('private-refused-outsider', 'outsider: the rules of the private project are refused (403)');

await t.anonymous();
await t.go(`/projects/${P}/digest_rules`);
if (!/\/login/.test(t.page.url())) t.problems.push(`anonymous: not sent to the login page (${t.page.url()})`);
await t.shot('anonymous', 'anonymous: sent to the login page');

// a rule id of another project is not found under this project
await t.login('manager');
await t.go(`/projects/e2e-private/digest_rules/${ruleId}`, { status: 404 });
await t.shot('other-project-404', 'manager: a rule of e2e-project opened under e2e-private is not found (404)');

// module switched off: the tab and the pages are gone, also for the manager
runner(`p = Project.find_by!(identifier: '${P}'); p.enabled_module_names = p.enabled_module_names - ['issue_digest']; p.save!`);
try {
  await t.go(`/projects/${P}/digest_rules`, { status: 403 });
  await t.shot('module-off', 'module Issue digests switched off: the rule list is refused (403), also to the manager');
  await t.go(`/projects/${P}/settings`);
  if (await t.page.locator('#tab-digest_rules').count()) t.problems.push('module off: the Digest rules tab is still shown');
} finally {
  runner(`p = Project.find_by!(identifier: '${P}'); p.enabled_module_names = (p.enabled_module_names + ['issue_digest']).uniq; p.save!`);
}

await t.done();
