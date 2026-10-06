// A digest rule from start to end as the manager: the new rule form (defaults,
// the schedule fields that follow the schedule type), refused invalid input,
// create, show, edit, disable, enable, a cancelled and a confirmed delete.
import { e2e } from '../../.codex/e2e/lib.mjs';

const P = 'e2e-project';
const NAME = `E2E lifecycle ${Date.now()}`;
const t = await e2e('rule-lifecycle');
const row = () => t.page.locator('#digest-rules-settings tr', { hasText: NAME });
const notice = async (step) => {
  if (!(await t.page.locator('#flash_notice').count())) t.problems.push(`${step}: no success notice`);
};

await t.login('manager');
await t.go(`/projects/${P}/settings/digest_rules`);
await t.page.click('#digest-rules-settings a.icon-add');
await t.settle();
t.check('open new form');
const tz = await t.page.inputValue('#issue_digest_rule_timezone');
if (tz !== 'Etc/UTC') t.problems.push(`new form: timezone preselected ${tz}, expected Etc/UTC`);
await t.shot('new-form', 'New rule form: daily, 08:00, timezone UTC preselected (Redmine default time zone unset), all project members');

// schedule type drives the visible fields
await t.page.selectOption('#issue_digest_rule_schedule_type', 'interval_hours');
if (await t.page.isVisible('#issue_digest_rule_send_time')) t.problems.push('interval_hours: send time still visible');
if (!(await t.page.isVisible('#issue_digest_rule_schedule_config_every_subdaily'))) t.problems.push('interval_hours: no "every" field');
await t.page.locator('#issue_digest_rule_schedule_type').scrollIntoViewIfNeeded();
await t.shot('form-every-n-hours', 'Schedule "every N hours": interval, time window and days shown, send time hidden', { full: false });

// invalid: no name, no recipients, end before start, bad time window
await t.page.fill('#issue_digest_rule_schedule_config_from', '25:99');
await t.page.fill('#issue_digest_rule_schedule_config_to', '18:00');
await t.page.fill('#issue_digest_rule_start_on', '2026-12-31');
await t.page.fill('#issue_digest_rule_end_on', '2026-01-01');
await t.page.uncheck('input[name="issue_digest_rule[recipient_modes][]"][value=project_members]');
await t.page.click('#digest_rule_form input[type=submit]');
await t.settle();
t.check('submit invalid', { requests: [] });
const errors = await t.page.locator('#errorExplanation li').allTextContents();
if (errors.length < 3) t.problems.push(`invalid submit: only ${errors.length} error(s): ${errors.join(' | ')}`);
await t.shot('invalid', `Invalid input is refused and explained: ${errors.length} errors (name, recipients, end date, time window)`);

// valid: weekly on Wednesday 07:30
await t.page.fill('#issue_digest_rule_name', NAME);
await t.page.selectOption('#issue_digest_rule_schedule_type', 'weekly');
await t.page.selectOption('#issue_digest_rule_schedule_config_day_weekly', '3');
await t.page.fill('#issue_digest_rule_send_time', '07:30');
await t.page.fill('#issue_digest_rule_start_on', '');
await t.page.fill('#issue_digest_rule_end_on', '');
await t.page.check('input[name="issue_digest_rule[recipient_modes][]"][value=project_members]');
await t.page.check('#issue_digest_rule_include_overdue');
await t.page.fill('#issue_digest_rule_email_subject', 'Weekly {project}: {issues_count} issues');
await t.page.fill('#issue_digest_rule_email_intro', 'Hello *team*, the weekly list.');
await t.page.click('#digest_rule_form input[type=submit]');
await t.settle();
t.check('create');
await notice('create');
if (!(await row().count())) t.problems.push('create: the rule is not listed in the settings tab');
const desc = (await row().locator('td').nth(1).textContent() || '').trim();
if (!/Wednesday/.test(desc) || !/07:30/.test(desc)) t.problems.push(`create: schedule shown as "${desc}"`);
await t.shot('created', `Saved: notice, the rule is listed as "${desc}"`);

await row().locator('a', { hasText: NAME }).click();
await t.settle();
t.check('show');
if (!(await t.page.locator('.wiki em, .wiki strong', { hasText: 'team' }).count())) t.problems.push('show: the intro is not formatted');
await t.shot('show', 'The rule page: schedule, recipients, filters, formatted intro, empty run history');
const showUrl = new URL(t.page.url()).pathname;

await t.page.click('.contextual a.icon-edit');
await t.settle();
t.check('open edit');
const sendTime = await t.page.inputValue('#issue_digest_rule_send_time');
if (!sendTime.startsWith('07:30')) t.problems.push(`edit: send time not kept (${sendTime})`);
await t.page.selectOption('#issue_digest_rule_schedule_type', 'weekdays');
for (const d of ['1', '5']) {
  await t.page.check(`.schedule-config[data-show-for=weekdays] input[value="${d}"]`);
}
await t.shot('edit', 'Edit form: switched to selected weekdays, Monday and Friday');
await t.page.click('#digest_rule_form input[type=submit]');
await t.settle();
t.check('update');
await notice('update');
const desc2 = (await row().locator('td').nth(1).textContent() || '').trim();
if (!/Monday/.test(desc2) || !/Friday/.test(desc2)) t.problems.push(`update: schedule shown as "${desc2}"`);
await t.shot('updated', `Updated: the rule now reads "${desc2}"`);

// invalid edit is refused and the stored rule is unchanged
await t.go(`${showUrl}/edit`);
await t.page.fill('#issue_digest_rule_name', '');
await t.page.click('#digest_rule_form input[type=submit]');
await t.settle();
t.check('invalid update');
if (!(await t.page.locator('#errorExplanation').count())) t.problems.push('invalid update: no error shown');
await t.shot('invalid-update', 'An edit with an empty name is refused; the rule keeps its name');

await t.go(`/projects/${P}/settings/digest_rules`);
await row().locator('button.icon-lock').click();
await t.settle();
t.check('disable');
await notice('disable');
if (!(await row().locator('button.icon-unlock').count())) t.problems.push('disable: no Enable button afterwards');
await t.shot('disabled', 'Disabled: notice, status inactive, the button now reads Enable');
await row().locator('button.icon-unlock').click();
await t.settle();
t.check('enable');
await notice('enable');
if (!(await row().locator('button.icon-lock').count())) t.problems.push('enable: no Disable button afterwards');

// delete: cancel first, then confirm
t.page.once('dialog', d => d.dismiss());
await row().locator('button.icon-del').click();
await t.settle();
if (!(await row().count())) t.problems.push('delete cancelled: the rule is gone anyway');
t.page.once('dialog', d => d.accept());
await row().locator('button.icon-del').click();
await t.settle();
t.check('delete');
await notice('delete');
if (await row().count()) t.problems.push('delete: the rule is still listed');
await t.shot('deleted', 'Deleted after confirming (a cancelled confirmation kept it): notice, the rule is gone');
await t.go(showUrl, { status: 404 });

await t.done();
