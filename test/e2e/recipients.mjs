// Recipient modes as they reach the mailbox: a role, a specific user, issue
// assignees (who see only their own issues), and e-mail addresses when the
// plugin setting allows them (only registered users with access get mail).
import { e2e } from '../../.codex/e2e/lib.mjs';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const P = 'e2e-project';
const R = process.env.REDMINE_DIR;
const MAILS = path.join(R, 'tmp', 'mails');
const t = await e2e('recipients');
const env = { ...process.env, RAILS_ENV: 'production' };
const runner = (code) => execFileSync('bundle', ['exec', 'rails', 'runner', '-e', 'production', code],
  { cwd: R, encoding: 'utf8', env }).trim();
const send = (id) => execFileSync('bundle', ['exec', 'rake', 'redmine:issue_digest:send'],
  { cwd: R, encoding: 'utf8', env: { ...env, MANUAL: '1', RULE_ID: id, VERBOSE: '1' } }).trim();
const inbox = () => (fs.existsSync(MAILS) ? fs.readdirSync(MAILS).sort() : []);
const clear = () => { fs.rmSync(MAILS, { recursive: true, force: true }); fs.mkdirSync(MAILS, { recursive: true }); };
const lines = [];

await t.login('manager');

// assignees: each assignee gets only the issues assigned to them
await t.go(`/projects/${P}/digest_rules/new`);
await t.page.fill('#issue_digest_rule_name', `E2E assignees ${Date.now()}`);
await t.page.selectOption('#issue_digest_rule_schedule_type', 'manual');
await t.page.uncheck('input[name="issue_digest_rule[recipient_modes][]"][value=project_members]');
await t.page.check('input[name="issue_digest_rule[recipient_modes][]"][value=assignees]');
await t.page.locator('input[value=assignees]').scrollIntoViewIfNeeded();
await t.shot('form-assignees', 'Recipients: issue assignees only', { full: false });
await t.page.click('#digest_rule_form input[type=submit]');
await t.settle();
t.check('create assignees rule');
const assigneesId = runner(`print IssueDigestRule.where("name LIKE 'E2E assignees %'").order(:id).last.id`);
clear();
lines.push(send(assigneesId));
let got = inbox();
lines.push(`mails: ${got.join(', ')}`);
if (got.join() !== 'manager@example.net,reporter@example.net') t.problems.push(`assignees: mails to ${got.join(', ')}, expected manager and reporter`);
const reporterMail = fs.readFileSync(path.join(MAILS, 'reporter@example.net'), 'utf8');
if (!reporterMail.includes('E2E subtask') || reporterMail.includes('E2E assigned issue')) t.problems.push("assignees: the reporter's digest is not limited to the reporter's issue");

// role + specific user
const viewerRole = runner(`print Role.find_by!(name: 'E2E digest viewer').id`);
await t.go(`/projects/${P}/digest_rules/${assigneesId}/edit`);
await t.page.uncheck('input[value=assignees]');
await t.page.check(`input[name="issue_digest_rule[recipient_modes][]"][value="role:${viewerRole}"]`);
await t.page.selectOption('#digest-users-select', { label: 'Reporter E2E' });
await t.page.locator('#digest-users-select').scrollIntoViewIfNeeded();
await t.shot('form-role-user', 'Recipients: role "E2E digest viewer" and the specific user Reporter E2E', { full: false });
await t.page.click('#digest_rule_form input[type=submit]');
await t.settle();
t.check('update to role and user');
clear();
lines.push(send(assigneesId));
got = inbox();
lines.push(`mails: ${got.join(', ')}`);
if (got.join() !== 'reporter@example.net,viewer@example.net') t.problems.push(`role + user: mails to ${got.join(', ')}, expected reporter and viewer`);

// e-mail addresses, allowed by the setting: they resolve to registered users
// who may view the project's issues. e2e-project is public and the Non member
// role has view_issues, so the outsider qualifies too; the unknown address
// gets nothing.
runner(`Setting.plugin_redmine_mail_digest = Setting.plugin_redmine_mail_digest.merge('allow_external_recipients' => '1')`);
try {
  await t.go(`/projects/${P}/digest_rules/${assigneesId}/edit`);
  await t.page.uncheck(`input[value="role:${viewerRole}"]`);
  await t.page.selectOption('#digest-users-select', '');
  await t.page.fill('#issue_digest_rule_recipient_email_addresses', 'viewer@example.net\noutsider@example.net\nnobody@example.org');
  await t.page.locator('#issue_digest_rule_recipient_email_addresses').scrollIntoViewIfNeeded();
  await t.shot('form-emails', 'Recipients by e-mail address: a member, a non-member and an unknown address', { full: false });
  await t.page.click('#digest_rule_form input[type=submit]');
  await t.settle();
  t.check('update to e-mail addresses');
  clear();
  lines.push(send(assigneesId));
  got = inbox();
  lines.push(`mails: ${got.join(', ')}`);
  if (got.join() !== 'outsider@example.net,viewer@example.net') t.problems.push(`e-mail addresses: mails to ${got.join(', ')}, expected outsider and viewer`);
  await t.go(`/projects/${P}/digest_rules/${assigneesId}`);
  await t.shot('show-emails', 'The rule lists the addresses; viewer and outsider (public project) received the digest, the unknown address nothing');
} finally {
  runner(`Setting.plugin_redmine_mail_digest = Setting.plugin_redmine_mail_digest.merge('allow_external_recipients' => '0')`);
}

// with the setting off again the stored addresses are still resolved at send
// time (the setting only governs the form): current behaviour, an open
// question in the plan
clear();
lines.push(send(assigneesId));
got = inbox();
lines.push(`setting off -> mails: ${got.join(', ') || 'none'}`);
if (got.join() !== 'outsider@example.net,viewer@example.net') t.problems.push(`e-mail addresses with the setting off: mails to ${got.join(', ')}`);

runner(`IssueDigestRule.where(id: ${assigneesId}).update_all(active: false)`);
fs.writeFileSync(path.join(process.env.RMP_E2E_OUT || 'docs/e2e', 'recipients-commands.md'),
  `# recipients: rake output\n\n\`\`\`\n${lines.join('\n\n')}\n\`\`\`\n`);
console.log(lines.join('\n'));
await t.done();
