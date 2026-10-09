// "Open issues starting soon" and "Only unassigned issues": a rule that mails
// one specific user the unassigned open issues starting in the next 7 days.
// The form (the days field follows its checkbox), the rule page summary, the
// dry-run preview, a manual send and the mail it writes (Start date column,
// only the right issues), the refusal of "only unassigned" with the
// "Assigned users" mode and with "Only assigned to recipient", and the form
// refused to a member without the plugin's permissions.
import { e2e } from '../../.codex/e2e/lib.mjs';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const P = 'e2e-project';
const R = process.env.REDMINE_DIR;
const MAILS = path.join(R, 'tmp', 'mails');
const NAME = `E2E starting soon unassigned ${Date.now()}`;
const t = await e2e('starting-soon-unassigned');
const env = { ...process.env, RAILS_ENV: 'production' };
const runner = (code) => execFileSync('bundle', ['exec', 'rails', 'runner', '-e', 'production', code],
  { cwd: R, encoding: 'utf8', env }).trim();
const rake = (task, vars = {}) => execFileSync('bundle', ['exec', 'rake', task],
  { cwd: R, encoding: 'utf8', env: { ...env, ...vars } }).trim();
const log = [];
const record = (cmd, out) => { log.push(`$ ${cmd}\n${out}`); console.log(`$ ${cmd}\n${out}`); };
const errors = () => t.page.locator('#errorExplanation li').allTextContents();

function part(raw, type) {
  const at = raw.indexOf(`Content-Type: ${type}`);
  if (at < 0) return '';
  const head = raw.slice(at, at + 300);
  const m = raw.slice(at).match(/\r?\n\r?\n([^]*?)\r?\n--/);
  if (!m) return '';
  let body = m[1];
  if (/Content-Transfer-Encoding: quoted-printable/i.test(head)) {
    body = Buffer.from(body.replace(/=\r?\n/g, '').replace(/=([0-9A-F]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16))), 'latin1').toString('utf8');
  } else if (/Content-Transfer-Encoding: base64/i.test(head)) {
    body = Buffer.from(body.replace(/\s+/g, ''), 'base64').toString('utf8');
  }
  return body;
}

// Issues in e2e-project, start dates relative to today (re-set on every run).
const issues = JSON.parse(runner(`
  p = Project.find_by!(identifier: '${P}')
  admin = User.find_by!(login: 'admin')
  User.current = admin
  manager = User.find_by!(login: 'manager')
  group = Group.find_by(lastname: 'E2E group') || Group.create!(lastname: 'E2E group')
  closed = IssueStatus.where(is_closed: true).first
  today = Date.current
  spec = {
    'today'      => [0,  nil,   false],
    'in3'        => [3,  nil,   false],
    'day7'       => [7,  nil,   false],
    'day8'       => [8,  nil,   false],
    'nostart'    => [nil, nil,  false],
    'assigned'   => [3,  manager, false],
    'group'      => [3,  group, false],
    'closed'     => [3,  nil,   true]
  }
  out = {}
  spec.each do |key, (days, assignee, is_closed)|
    subject = "E2E SSU #{key}"
    i = Issue.find_by(project_id: p.id, subject: subject) ||
        Issue.new(project: p, tracker: p.trackers.first, author: admin, subject: subject,
                  priority: IssuePriority.default || IssuePriority.first)
    i.status ||= i.tracker.default_status
    i.save! if i.new_record?
    i = Issue.find(i.id) # a just-created record does not keep update_columns here
    i.update_columns(start_date: days && today + days, due_date: days && today + days + 10,
                     assigned_to_id: assignee&.id,
                     status_id: is_closed ? closed.id : i.tracker.default_status.id)
    out[key] = i.id
  end
  print out.to_json`));
record('issues (subject E2E SSU <key> => id)', JSON.stringify(issues));
const viewerId = runner(`print User.find_by!(login: 'viewer').id`);

// 1. the form, as the manager
await t.login('manager');
await t.go(`/projects/${P}/digest_rules/new`);
const daysField = '#issue_digest_rule_starting_soon_days';
if (await t.page.inputValue(daysField) !== '7') t.problems.push(`new form: starting soon days ${await t.page.inputValue(daysField)}, expected 7`);
if (!(await t.page.isDisabled(daysField))) t.problems.push('new form: days field enabled while the option is off');
await t.page.fill('#issue_digest_rule_name', NAME);
await t.page.selectOption('#issue_digest_rule_schedule_type', 'manual');
await t.page.uncheck('#issue_digest_rule_include_open');
await t.page.check('#issue_digest_rule_include_starting_soon');
if (await t.page.isDisabled(daysField)) t.problems.push('form: days field still disabled after ticking the option');
await t.page.uncheck('input[name="issue_digest_rule[recipient_modes][]"][value=project_members]');
await t.page.selectOption('#digest-users-select', `user:${viewerId}`);
await t.page.check('#issue_digest_rule_filter_unassigned');
await t.page.locator('#issue_digest_rule_include_starting_soon').scrollIntoViewIfNeeded();
await t.shot('form', 'New rule: "Open issues starting soon" ticked with 7 days (field enabled by its checkbox), open issues off, schedule manual');
await t.page.locator('#issue_digest_rule_filter_unassigned').scrollIntoViewIfNeeded();
await t.shot('form-recipient', 'Same form: recipient one specific user (Viewer E2E), "Only unassigned issues" ticked with its hint', { full: false });
await t.page.click('#digest_rule_form input[type=submit]');
await t.settle();
t.check('create');
if (!(await t.page.locator('#flash_notice').count())) t.problems.push(`create: not saved: ${(await errors()).join(' | ')}`);
const ruleId = runner(`print IssueDigestRule.find_by!(name: '${NAME}').id`);
const stored = runner(`r = IssueDigestRule.find(${ruleId}); print [r.include_starting_soon, r.starting_soon_days, r.filter_unassigned, r.include_open, r.recipient_modes].inspect`);
record('stored rule', stored);
if (stored !== `[true, 7, true, false, ["user:${viewerId}"]]`) t.problems.push(`stored rule: ${stored}`);

// 2. the rule page summary and the dry-run preview
await t.go(`/projects/${P}/digest_rules/${ruleId}`);
const box = await t.page.locator('.box').first().textContent();
if (!/Starting soon within 7 days/.test(box)) t.problems.push('show: no "Starting soon within 7 days" in the filters');
if (!/Only unassigned issues/.test(box)) t.problems.push('show: no "Only unassigned issues" in the summary');
await t.page.click('.contextual a.icon-test');
await t.page.waitForSelector('#digest-preview .box', { timeout: 10000 }).catch(() => t.problems.push('no preview shown'));
t.check('preview');
const rows = await t.page.locator('#digest-preview tbody tr').allTextContents();
const previewText = rows.map(r => r.replace(/\s+/g, ' ').trim()).join('; ');
if (rows.length !== 1 || !/Viewer/.test(rows[0]) || !/Would send 3 issue/.test(rows[0])) t.problems.push(`preview: ${previewText}`);
await t.shot('show-preview', `Rule page: filters "Starting soon within 7 days", personalization "Only unassigned issues", recipient Viewer E2E; dry run: ${previewText}`);

// 3. the manual send and the mail
fs.rmSync(MAILS, { recursive: true, force: true });
fs.mkdirSync(MAILS, { recursive: true });
const out = rake('redmine:issue_digest:send', { MANUAL: '1', RULE_ID: ruleId, VERBOSE: '1' });
record(`rake redmine:issue_digest:send MANUAL=1 RULE_ID=${ruleId} VERBOSE=1`, out);
const files = fs.readdirSync(MAILS).sort();
record('ls tmp/mails', files.join('\n'));
if (files.join(',') !== 'viewer@example.net') t.problems.push(`mails written for: ${files.join(', ')}, expected only viewer@example.net`);
const raw = files.includes('viewer@example.net') ? fs.readFileSync(path.join(MAILS, 'viewer@example.net'), 'utf8') : '';
const html = part(raw, 'text/html');
const text = part(raw, 'text/plain');
for (const k of ['today', 'in3', 'day7']) {
  if (!html.includes(`E2E SSU ${k}<`)) t.problems.push(`mail: issue "${k}" missing`);
}
for (const k of ['day8', 'nostart', 'assigned', 'group', 'closed']) {
  if (html.includes(`E2E SSU ${k}<`)) t.problems.push(`mail: issue "${k}" should not be in it`);
}
if (!/<th>Start date<\/th>\s*<th>Due date<\/th>/.test(html)) t.problems.push('mail: no "Start date" column before "Due date"');
const startLines = (text.match(/Start: \S+ {2}Due: /g) || []).length;
if (startLines !== 3) t.problems.push(`text part: ${startLines} "Start: ... Due:" lines, expected 3`);
record('text part, issue lines', text.split(/\r?\n/).filter(l => /^#\d+|Start:/.test(l)).join('\n'));
await t.page.setContent(html);
await t.shot('mail', 'The mail to Viewer E2E as a mail client shows it: only the unassigned open issues starting today, in 3 and in 7 days, with the Start date column');

// 4. refusals: "only unassigned" with the "Assigned users" mode, and with "Only assigned to recipient"
await t.go(`/projects/${P}/digest_rules/${ruleId}/edit`);
await t.page.check('input[name="issue_digest_rule[recipient_modes][]"][value=assignees]');
await t.page.click('#digest_rule_form input[type=submit]');
await t.settle();
t.check('refuse assignees');
let errs = await errors();
if (!errs.some(e => /Only unassigned issues cannot be combined/.test(e))) t.problems.push(`assignees + unassigned not refused: ${errs.join(' | ')}`);
await t.page.locator('#errorExplanation').scrollIntoViewIfNeeded();
await t.shot('refused-assignees', `Refused: "Only unassigned issues" with the "Assigned users" recipient mode: ${errs.join(' | ')}`, { full: false });

await t.go(`/projects/${P}/digest_rules/${ruleId}/edit`);
await t.page.check('#issue_digest_rule_filter_assigned_to_recipient');
await t.page.click('#digest_rule_form input[type=submit]');
await t.settle();
t.check('refuse assigned to recipient');
errs = await errors();
if (!errs.some(e => /Only unassigned issues cannot be combined/.test(e))) t.problems.push(`assigned-to-recipient + unassigned not refused: ${errs.join(' | ')}`);
await t.shot('refused-assigned-to-recipient', `Refused: "Only unassigned issues" with "Only assigned to recipient": ${errs.join(' | ')}`, { full: false });
const after = runner(`r = IssueDigestRule.find(${ruleId}); print [r.recipient_modes, r.filter_assigned_to_recipient].inspect`);
if (after !== `[["user:${viewerId}"], false]`) t.problems.push(`refused edits changed the rule: ${after}`);

// 5. the Dutch form: the new labels translated
runner(`u = User.find_by!(login: 'manager'); u.update_column(:language, 'nl')`);
try {
  await t.login('manager');
  await t.go(`/projects/${P}/digest_rules/${ruleId}/edit`);
  const labels = await t.page.locator('label[for=issue_digest_rule_include_starting_soon], label[for=issue_digest_rule_filter_unassigned]').allTextContents();
  if (!labels.some(l => /binnenkort starten/.test(l)) || !labels.some(l => /niet-toegewezen/.test(l))) t.problems.push(`nl labels: ${labels.join(' | ')}`);
  await t.page.locator('#issue_digest_rule_include_starting_soon').scrollIntoViewIfNeeded();
  await t.shot('form-nl', `The edit form in Dutch: ${labels.map(l => l.trim()).join(', ')}`, { full: false });
} finally {
  runner(`u = User.find_by!(login: 'manager'); u.update_column(:language, '')`);
}

// 6. without the plugin's permissions the form is refused
await t.login('reporter');
await t.go(`/projects/${P}/digest_rules/new`, { status: 403 });
await t.shot('reporter-refused', 'reporter (no plugin permissions): the new rule form is refused (403)');

runner(`IssueDigestRule.where(id: ${ruleId}).update_all(active: false)`);
fs.writeFileSync(path.join(process.env.RMP_E2E_OUT || 'docs/e2e', 'starting-soon-unassigned-commands.md'),
  `# starting-soon-unassigned: commands and output\n\nRun ${new Date().toISOString()}.\n\n\`\`\`\n${log.join('\n\n')}\n\`\`\`\n`);
await t.done();
