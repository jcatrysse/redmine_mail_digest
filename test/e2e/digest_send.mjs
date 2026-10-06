// Sending digests, the plugin's core function, against the running instance:
// the rake task cron runs (redmine:issue_digest:send in its modes, and
// :cleanup), the mails it writes (recipients, per-recipient visibility,
// headers, the HTML as a mail client shows it), the run history on the rule
// page, the scheduled-window idempotency, the issue cap from the plugin
// settings and the cleanup of old runs.
import { e2e } from '../../.codex/e2e/lib.mjs';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const P = 'e2e-project';
const R = process.env.REDMINE_DIR;
const MAILS = path.join(R, 'tmp', 'mails');
const t = await e2e('digest-send');
const env = { ...process.env, RAILS_ENV: 'production' };
const runner = (code) => execFileSync('bundle', ['exec', 'rails', 'runner', '-e', 'production', code],
  { cwd: R, encoding: 'utf8', env }).trim();
const rake = (task, vars = {}) => execFileSync('bundle', ['exec', 'rake', task],
  { cwd: R, encoding: 'utf8', env: { ...env, ...vars } }).trim();
const log = [];
const record = (cmd, out) => { log.push(`$ ${cmd}\n${out}`); console.log(`$ ${cmd}\n${out}`); };

// Mails written by :file delivery, one file per address, messages appended.
function readMails() {
  if (!fs.existsSync(MAILS)) return {};
  const out = {};
  for (const f of fs.readdirSync(MAILS)) {
    const raw = fs.readFileSync(path.join(MAILS, f), 'utf8');
    out[f] = raw.split(/\r?\n(?=Date: )/).filter(m => m.includes('Subject:'));
  }
  return out;
}
function htmlPart(raw) {
  const m = raw.match(/Content-Type: text\/html[^]*?\r?\n\r?\n([^]*?)\r?\n--/);
  if (!m) return '';
  let body = m[1];
  if (/Content-Transfer-Encoding: quoted-printable/i.test(raw.slice(raw.indexOf('text/html'), raw.indexOf('text/html') + 200))) {
    body = Buffer.from(body.replace(/=\r?\n/g, '').replace(/=([0-9A-F]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16))), 'latin1').toString('utf8');
  } else if (/Content-Transfer-Encoding: base64/i.test(raw.slice(raw.indexOf('text/html'), raw.indexOf('text/html') + 200))) {
    body = Buffer.from(body.replace(/\s+/g, ''), 'base64').toString('utf8');
  }
  return body;
}
const decodeSubject = (raw) => {
  const s = (raw.match(/^Subject: (.*(?:\r?\n[ \t].*)*)/m) || [])[1] || '';
  return s.replace(/\r?\n[ \t]/g, '').replace(/=\?UTF-8\?([QB])\?(.*?)\?=/gi, (_, enc, txt) =>
    enc.toUpperCase() === 'B' ? Buffer.from(txt, 'base64').toString('utf8')
      : Buffer.from(txt.replace(/_/g, ' ').replace(/=([0-9A-F]{2})/g, (__, h) => String.fromCharCode(parseInt(h, 16))), 'latin1').toString('utf8'));
};

fs.rmSync(MAILS, { recursive: true, force: true });
fs.mkdirSync(MAILS, { recursive: true });
const stamp = Date.now();

// A manual rule for all project members, open issues, a subject we can find.
const ruleId = runner(`
  p = Project.find_by!(identifier: '${P}')
  r = IssueDigestRule.find_or_initialize_by(project_id: p.id, name: 'E2E send rule')
  r.assign_attributes(active: true, schedule_type: 'manual', send_time: nil, timezone: 'Etc/UTC',
                      grace_window_hours: 24, non_business_day_behavior: 'skip', schedule_config: {},
                      recipient_modes: ['project_members'], include_open: true, group_by: 'status',
                      email_subject: 'E2E digest ${stamp} {project}: {issues_count} issues',
                      email_intro: 'Your *weekly* overview.', send_empty: false,
                      created_by: User.find_by!(login: 'admin'))
  r.save!
  r.issue_digest_runs.destroy_all
  print r.id`);

// 1. dry run: prints the plan, writes nothing
let out = rake('redmine:issue_digest:send', { DRY_RUN: '1', MANUAL: '1', RULE_ID: ruleId, VERBOSE: '1' });
record(`rake redmine:issue_digest:send DRY_RUN=1 MANUAL=1 RULE_ID=${ruleId} VERBOSE=1`, out);
if (!/DRY_RUN summary: \d+ plans/.test(out)) t.problems.push('dry run: no summary printed');
if (Object.keys(readMails()).length) t.problems.push('dry run: mails were written');
if (runner(`print IssueDigestRun.where(issue_digest_rule_id: ${ruleId}).count`) !== '0') t.problems.push('dry run: a run was recorded');

// 2. manual run: one mail per member, each with the issues that member may see
out = rake('redmine:issue_digest:send', { MANUAL: '1', RULE_ID: ruleId, VERBOSE: '1' });
record(`rake redmine:issue_digest:send MANUAL=1 RULE_ID=${ruleId} VERBOSE=1`, out);
const mails = readMails();
const got = Object.keys(mails).sort();
record('ls tmp/mails', got.join('\n'));
for (const who of ['manager', 'reporter', 'viewer']) {
  if (!got.includes(`${who}@example.net`)) t.problems.push(`manual run: no digest for ${who}`);
}
for (const who of ['outsider', 'admin']) {
  if (got.some(f => f.startsWith(who))) t.problems.push(`manual run: a digest went to ${who}, who is no member`);
}
const managerMail = (mails['manager@example.net'] || []).at(-1) || '';
const reporterMail = (mails['reporter@example.net'] || []).at(-1) || '';
const PRIVATE = 'E2E private issue in public project';
if (!htmlPart(managerMail).includes(PRIVATE)) t.problems.push('manager (sees all issues): private issue missing from the digest');
if (htmlPart(reporterMail).includes(PRIVATE) || reporterMail.includes(PRIVATE)) t.problems.push('reporter: the private issue leaked into the digest');
// 'E2E private issue' is the issue of the other project, e2e-private
if (/>E2E private issue</.test(htmlPart(managerMail))) t.problems.push('manager: an issue of another project is in the digest');
for (const [h, v] of [['Auto-Submitted', 'auto-generated'], ['X-Auto-Response-Suppress', 'All']]) {
  if (!new RegExp(`^${h}: ${v}`, 'm').test(managerMail)) t.problems.push(`mail header ${h}: ${v} missing`);
}
if (!/multipart\/alternative/.test(managerMail)) t.problems.push('mail: not multipart/alternative');
const subject = decodeSubject(managerMail);
if (!subject.startsWith(`E2E digest ${stamp} E2E project:`)) t.problems.push(`mail subject: "${subject}"`);
record('manager mail headers', managerMail.split(/\r?\n\r?\n/)[0].split(/\r?\n/)
  .filter(l => /^(To|Subject|Auto-Submitted|X-Auto-Response-Suppress|MIME-Version|Content-Type):/.test(l)).join('\n'));

await t.login('manager');
await t.page.setContent(htmlPart(managerMail));
await t.shot('mail-manager', `The manager's digest as a mail client renders it, subject "${subject}": grouped by status, the private issue included`);
await t.page.setContent(htmlPart(reporterMail));
await t.shot('mail-reporter', "The reporter's digest of the same run: the private issue is not in it");

await t.go(`/projects/${P}/digest_rules/${ruleId}`);
const runRows = await t.page.locator('table.list tbody tr').count();
if (runRows < 1) t.problems.push('rule page: the manual run is not in the run history');
await t.shot('run-history', 'The rule page lists the manual run: trigger, status, recipients, mails sent');

// 3. scheduled run: a daily rule due now goes out once per window
const schedId = runner(`
  p = Project.find_by!(identifier: '${P}')
  r = IssueDigestRule.find_or_initialize_by(project_id: p.id, name: 'E2E scheduled rule')
  r.assign_attributes(active: true, schedule_type: 'daily', send_time: (Time.now.utc - 3600).strftime('%H:%M'),
                      timezone: 'Etc/UTC', grace_window_hours: 24, non_business_day_behavior: 'skip',
                      schedule_config: {}, recipient_modes: ['user:' + User.find_by!(login: 'viewer').id.to_s],
                      include_open: true, group_by: 'none', email_subject: 'E2E scheduled ${stamp}',
                      last_schedule_key: nil, created_by: User.find_by!(login: 'admin'))
  r.save!
  print r.id`);
const countSched = () => (readMails()['viewer@example.net'] || []).filter(m => decodeSubject(m).startsWith(`E2E scheduled ${stamp}`)).length;
out = rake('redmine:issue_digest:send', { VERBOSE: '1' });
record('rake redmine:issue_digest:send VERBOSE=1   # the cron entry', out);
if (countSched() !== 1) t.problems.push(`scheduled run: ${countSched()} mails to viewer, expected 1`);
out = rake('redmine:issue_digest:send', { VERBOSE: '1' });
record('rake redmine:issue_digest:send VERBOSE=1   # again, same window', out);
if (countSched() !== 1) t.problems.push(`scheduled run repeated: ${countSched()} mails to viewer, the window was sent twice`);
if (!/Found 0 due rules|already claimed/.test(out) && !/\(0 rules/.test(out)) {
  // the manual rule is never due and the daily one is claimed: nothing processed
  if (!/0 rules, 0 emails/.test(out)) t.problems.push('scheduled run repeated: something was processed again');
}

// 4. a disabled rule is not sent, not even manually
runner(`IssueDigestRule.find(${ruleId}).update!(active: false)`);
const before = Object.values(readMails()).flat().length;
out = rake('redmine:issue_digest:send', { MANUAL: '1', RULE_ID: ruleId, VERBOSE: '1' });
record(`rake redmine:issue_digest:send MANUAL=1 RULE_ID=${ruleId} VERBOSE=1   # rule disabled`, out);
if (Object.values(readMails()).flat().length !== before) t.problems.push('disabled rule: mails were sent');
runner(`IssueDigestRule.find(${ruleId}).update!(active: true)`);

// 5. the cap from the plugin settings: max 2 issues per mail
runner(`Setting.plugin_redmine_mail_digest = Setting.plugin_redmine_mail_digest.merge('max_issues_per_email' => 2)`);
try {
  fs.rmSync(path.join(MAILS, 'manager@example.net'), { force: true });
  out = rake('redmine:issue_digest:send', { MANUAL: '1', RULE_ID: ruleId });
  record(`rake redmine:issue_digest:send MANUAL=1 RULE_ID=${ruleId}   # max_issues_per_email = 2`, out || '(no output)');
  const capped = htmlPart((readMails()['manager@example.net'] || []).at(-1) || '');
  const rows = (capped.match(/\/issues\/\d+">#\d+</g) || []).length;
  if (rows !== 2) t.problems.push(`cap 2: the manager's digest lists ${rows} issues`);
  await t.page.setContent(capped);
  await t.shot('mail-capped', `With "Maximum issues per email" set to 2 the digest lists ${rows} issues`);
} finally {
  runner(`Setting.plugin_redmine_mail_digest = Setting.plugin_redmine_mail_digest.merge('max_issues_per_email' => 500)`);
}

// 6. cleanup: runs older than the retention go, recent ones stay
runner(`
  r = IssueDigestRule.find(${ruleId})
  IssueDigestRun.create!(issue_digest_rule: r, trigger: 'manual', status: 'success',
                         started_at: 200.days.ago, finished_at: 200.days.ago)`);
const runsBefore = runner(`print IssueDigestRun.where(issue_digest_rule_id: ${ruleId}).count`);
out = rake('redmine:issue_digest:cleanup');
const runsAfter = runner(`print IssueDigestRun.where(issue_digest_rule_id: ${ruleId}).count`);
record('rake redmine:issue_digest:cleanup   # retention 90 days, one run of 200 days old', `${out || '(no output)'}\nruns of the rule: ${runsBefore} -> ${runsAfter}`);
if (Number(runsAfter) !== Number(runsBefore) - 1) t.problems.push(`cleanup: runs ${runsBefore} -> ${runsAfter}, expected one less`);

runner(`IssueDigestRule.where(id: ${schedId}).update_all(active: false)`);
fs.writeFileSync(path.join(process.env.RMP_E2E_OUT || 'docs/e2e', 'digest-send-commands.md'),
  `# digest-send: commands and output\n\nRun ${new Date().toISOString()}.\n\n\`\`\`\n${log.join('\n\n')}\n\`\`\`\n`);
await t.done();
