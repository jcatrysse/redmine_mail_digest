// Plugin settings (Administration > Plugins > Configure): shown and saved by an
// administrator, refused to everybody else. The external-recipients switch
// decides whether the rule form offers the e-mail address field.
import { e2e } from '../../.codex/e2e/lib.mjs';

const t = await e2e('settings');
const SETTINGS = '/settings/plugin/redmine_mail_digest';

await t.login('admin');
await t.go(SETTINGS);
await t.shot('form', 'The plugin settings: max issues per e-mail, run history retention, e-mail address lookup');

await t.page.fill('#settings_max_issues_per_email', '250');
await t.page.fill('#settings_run_history_retention_days', '30');
await t.page.check('#settings_allow_external_recipients');
await t.page.click('#settings input[type=submit], form input[name=commit]');
await t.settle();
t.check('save settings');
if (!(await t.page.locator('#flash_notice').count())) t.problems.push('save settings: no success notice');
if (await t.page.inputValue('#settings_max_issues_per_email') !== '250') t.problems.push('save settings: max issues not kept');
if (!(await t.page.isChecked('#settings_allow_external_recipients'))) t.problems.push('save settings: e-mail lookup not kept');
await t.shot('saved', 'Saved: notice shown, the new values are kept');

await t.go('/projects/e2e-project/digest_rules/new');
if (!(await t.page.locator('#issue_digest_rule_recipient_email_addresses').count())) {
  t.problems.push('with e-mail lookup on, the rule form has no e-mail address field');
}
await t.page.locator('#issue_digest_rule_recipient_email_addresses').scrollIntoViewIfNeeded();
await t.shot('email-field-on', 'With the e-mail address lookup on, the rule form offers the address field', { full: false });

// back to the defaults, then the field is gone
await t.go(SETTINGS);
await t.page.fill('#settings_max_issues_per_email', '500');
await t.page.fill('#settings_run_history_retention_days', '90');
await t.page.uncheck('#settings_allow_external_recipients');
await t.page.click('#settings input[type=submit], form input[name=commit]');
await t.settle();
t.check('restore settings');
await t.go('/projects/e2e-project/digest_rules/new');
if (await t.page.locator('#issue_digest_rule_recipient_email_addresses').count()) {
  t.problems.push('with e-mail lookup off, the rule form still has the e-mail address field');
}

for (const user of ['manager', 'reporter']) {
  await t.login(user);
  await t.go(SETTINGS, { status: 403 });
}
await t.shot('refused', 'A non-administrator (reporter) is refused the plugin settings (403)');

await t.anonymous();
await t.go(SETTINGS);
if (!/\/login/.test(t.page.url())) t.problems.push(`anonymous: not sent to the login page (${t.page.url()})`);
await t.shot('anonymous', 'Anonymous is sent to the login page');

await t.done();
