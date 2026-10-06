// "Preview (dry run)" on the rule page: what a send would do per recipient,
// counts only, nothing sent or recorded. Also the saved-query filter and a
// rule whose saved query was deleted (warning, the preview says it would fail).
import { e2e } from '../../.codex/e2e/lib.mjs';
import { execFileSync } from 'node:child_process';

const P = 'e2e-project';
const t = await e2e('preview');
const R = process.env.REDMINE_DIR;
const runner = (code) => execFileSync('bundle', ['exec', 'rails', 'runner', '-e', 'production', code],
  { cwd: R, encoding: 'utf8' }).trim();
const rule = (name, extra, validate = true) => runner(`
  p = Project.find_by!(identifier: '${P}')
  r = IssueDigestRule.find_or_initialize_by(project_id: p.id, name: '${name}')
  r.assign_attributes(active: true, schedule_type: 'manual', send_time: nil, timezone: 'Etc/UTC',
                      grace_window_hours: 24, non_business_day_behavior: 'skip', schedule_config: {},
                      recipient_modes: ['project_members'], include_open: true, group_by: 'none',
                      query_id: nil, created_by: User.find_by!(login: 'admin'))
  ${extra || ''}
  r.save!(validate: ${validate})
  print r.id`);
const runs = (id) => runner(`print IssueDigestRun.where(issue_digest_rule_id: ${id}).count`);

async function preview(id) {
  await t.go(`/projects/${P}/digest_rules/${id}`);
  await t.page.click('.contextual a.icon-test');
  await t.page.waitForSelector('#digest-preview .box', { timeout: 10000 }).catch(() => t.problems.push(`rule ${id}: no preview shown`));
  t.check(`preview ${id}`);
  return t.page.locator('#digest-preview tbody tr').allTextContents();
}

const plainId = rule('E2E preview rule');
const runsBefore = runs(plainId);
await t.login('manager');
let rows = await preview(plainId);
if (rows.length !== 4) t.problems.push(`preview: ${rows.length} recipients, expected 4 (manager, reporter, viewer, digester)`);
if (!rows.every(r => /Would send \d+ issue/i.test(r))) t.problems.push(`preview rows: ${rows.join(' | ')}`);
if (await t.page.locator('#digest-preview').getByText('E2E private issue in public project').count()) t.problems.push('preview shows issue titles');
if (runs(plainId) !== runsBefore) t.problems.push('preview recorded a run');
await t.shot('counts', `Dry run per recipient, counts only: ${rows.map(r => r.replace(/\s+/g, ' ').trim()).join('; ')}`);

// saved query: a closed-issues-only rule with the public "open issues" query matches nothing
const queryId = runner(`print IssueQuery.find_by!(name: 'E2E open issues query').id`);
const qId = rule('E2E query rule', `r.query_id = ${queryId}; r.include_open = false; r.include_closed = true; r.send_empty = false`);
rows = await preview(qId);
if (!rows.every(r => /skip/i.test(r))) t.problems.push(`query filter: expected every recipient skipped, got ${rows.join(' | ')}`);
await t.shot('query-and', 'Closed issues AND the saved query "open issues": nothing matches, every recipient would be skipped (send empty is off)');

// the saved query is deleted: warning on the page, the preview says it would fail
const goneId = rule('E2E deleted query rule', `
  q = IssueQuery.new(project: p, name: 'E2E temporary query', user: User.find_by!(login: 'admin'), visibility: Query::VISIBILITY_PUBLIC)
  q.add_filter('status_id', 'o', ['']); q.save!
  r.query_id = q.id
  r.save!
  q.destroy`, false); // the rule points at a deleted query now: no longer valid, as in the field
await t.go(`/projects/${P}/digest_rules/${goneId}`);
if (!(await t.page.locator('.flash.warning').count())) t.problems.push('deleted query: no warning on the rule page');
rows = await preview(goneId);
if (!rows.length || !rows.every(r => /fail/i.test(r))) t.problems.push(`deleted query: expected "would fail", got ${rows.join(' | ')}`);
await t.shot('query-deleted', 'The saved query was deleted: a warning on the page and the dry run says every recipient would fail, nothing is sent');

// refusals: the viewer has no Preview button and a direct POST is refused
await t.login('viewer');
await t.go(`/projects/${P}/digest_rules/${plainId}`);
if (await t.page.locator('a.icon-test').count()) t.problems.push('viewer: Preview button shown');
const status = await t.page.evaluate(async (url) => {
  const token = document.querySelector('meta[name=csrf-token]')?.content;
  return (await fetch(url, { method: 'POST', headers: { 'X-CSRF-Token': token, 'X-Requested-With': 'XMLHttpRequest', Accept: 'text/javascript' } })).status;
}, `/projects/${P}/digest_rules/${plainId}/preview`);
t.check('viewer preview post', { requests: ['403 fetch'] });
if (status !== 403) t.problems.push(`viewer: POST preview returned ${status}`);
await t.shot('viewer', `viewer: no Preview button; a forged POST to preview is refused (${status})`);

runner(`IssueDigestRule.where(name: ['E2E query rule', 'E2E deleted query rule']).update_all(active: false)`);
await t.done();
