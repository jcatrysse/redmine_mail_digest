# Test Plan — redmine_digest

## 1. Framework and Conventions

- **Framework**: RSpec (as confirmed by CI configuration in `.github/workflows/`).
- **Factories**: FactoryBot (standard for RSpec in Redmine plugins).
- **Database cleaner**: Database transactions (RSpec metadata `type: :model` etc.).
- **Mailer testing**: `ActionMailer::Base.deliveries` or `have_enqueued_mail`.
- **Time manipulation**: `travel_to` (ActiveSupport test helper).
- **Timezone manipulation**: `Time.use_zone`.
- **Mocking**: RSpec doubles (`instance_double`, `class_double`) for services.

**Note**: Redmine core uses MiniTest with fixtures. This plugin uses RSpec with FactoryBot,
which requires the plugin's own `spec/spec_helper.rb` and `spec/rails_helper.rb` that
load Redmine's `test_helper` equivalent. The CI workflow confirms this setup works.

---

## 2. Factory Definitions (Spec)

```ruby
# spec/factories/issue_digest_rules.rb
FactoryBot.define do
  factory :issue_digest_rule do
    association :project
    sequence(:name) { |n| "Digest Rule #{n}" }
    active { true }
    schedule_type { 'daily' }
    schedule_config { {} }
    send_time { '08:00:00' }
    timezone { 'UTC' }
    include_open { true }
    recipient_modes { ['project_members'] }
    group_by { 'none' }
    association :created_by, factory: :user

    trait :weekly do
      schedule_type { 'weekly' }
      schedule_config { { 'day' => 1 } }
    end

    trait :disabled do
      active { false }
    end

    trait :with_query do
      association :query, factory: :issue_query
    end
  end
end
```

---

## 3. Model Tests

### 3.1 `IssueDigestRule`

**File**: `spec/models/issue_digest_rule_spec.rb`

| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `valid with required fields` | Factory with all required fields | `rule.valid?` | `true` |
| `invalid without name` | Rule with name: nil | `rule.valid?` | `false`; `errors[:name]` present |
| `invalid without schedule_type` | Rule with schedule_type: nil | `rule.valid?` | `false` |
| `invalid without send_time` | Rule with send_time: nil | `rule.valid?` | `false` |
| `invalid without recipient_modes` | Rule with recipient_modes: [] | `rule.valid?` | `false`; `errors[:recipient_modes]` |
| `invalid with unknown schedule_type` | schedule_type: 'hourly' | `rule.valid?` | `false` |
| `valid with monthly_date schedule_type` | schedule_type: 'monthly_date', config: {day:15} | `rule.valid?` | `true` |
| `valid with monthly_last_day schedule_type` | schedule_type: 'monthly_last_day' | `rule.valid?` | `true` |
| `valid with interval_days schedule_type` | schedule_type: 'interval_days', config: {every:3} | `rule.valid?` | `true` |
| `valid with interval_weeks schedule_type` | schedule_type: 'interval_weeks', config: {every:2} | `rule.valid?` | `true` |
| `valid with manual schedule_type (no send_time required)` | schedule_type: 'manual', send_time: nil | `rule.valid?` | `true` |
| `invalid interval_days with every: 0` | config: {every:0} | `rule.valid?` | `false` |
| `invalid grace_window_hours: 24` | grace_window_hours: 24 | `rule.valid?` | `false` |
| `valid grace_window_hours: 0` | grace_window_hours: 0 | `rule.valid?` | `true` |
| `invalid non_business_day_behavior value` | non_business_day_behavior: 'holiday' | `rule.valid?` | `false` |
| `invalid when end_on before start_on` | start_on: tomorrow, end_on: today | `rule.valid?` | `false` |
| `valid when start_on == end_on` | start_on: today, end_on: today | `rule.valid?` | `true` |
| `active? returns true for active, in-range rule` | active: true, no start/end | `rule.active?` | `true` |
| `active? returns false when active is false` | active: false | `rule.active?` | `false` |
| `active? returns false when start_on is future` | start_on: tomorrow | `rule.active?` | `false` |
| `active? returns false when end_on is past` | end_on: yesterday | `rule.active?` | `false` |
| `status_label returns :active` | active, in-range | `rule.status_label` | `:active` |
| `status_label returns :disabled` | active: false | `rule.status_label` | `:disabled` |
| `status_label returns :expired` | active: true, end_on: yesterday | `rule.status_label` | `:expired` |
| `status_label returns :pending` | active: true, start_on: tomorrow | `rule.status_label` | `:pending` |
| `schedule_config serialized from hash` | schedule_config: {'days' => [1,3]} | `rule.save!; rule.reload.schedule_config` | `{'days' => [1, 3]}` |
| `recipient_modes serialized as JSON array` | recipient_modes: ['project_members'] | `rule.save!; rule.reload.recipient_modes` | `['project_members']` |
| `invalid recipient_mode rejected` | recipient_modes: ['bad_mode'] | `rule.valid?` | `false` |
| `role: mode accepted` | recipient_modes: ['role:3'] | `rule.valid?` | `true` |
| `user: mode accepted` | recipient_modes: ['user:42'] | `rule.valid?` | `true` |
| `belongs_to project` | rule with project | `rule.project` | instance of Project |
| `has_many issue_digest_runs` | rule with 3 runs | `rule.issue_digest_runs.count` | 3 |
| `cascade deletes runs on destroy` | rule with runs | `rule.destroy` | runs count 0 |

### 3.2 `IssueDigestRun`

**File**: `spec/models/issue_digest_run_spec.rb`

| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `valid with required fields` | Factory | `run.valid?` | `true` |
| `invalid without status` | status: nil | `run.valid?` | `false` |
| `invalid with unknown status` | status: 'unknown' | `run.valid?` | `false` |
| `belongs_to issue_digest_rule` | run with rule | `run.issue_digest_rule` | rule instance |
| `has_many deliveries` | run with 3 deliveries | `run.issue_digest_deliveries.count` | 3 |

### 3.3 `IssueDigestDelivery`

**File**: `spec/models/issue_digest_delivery_spec.rb`

| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `valid with sent status` | Factory, status: :sent | `delivery.valid?` | `true` |
| `invalid with unknown status` | status: 'bounced' | `delivery.valid?` | `false` |
| `email required` | email: nil | `delivery.valid?` | `false` |

---

## 4. Service Tests

### 4.1 `IssueDigest::ScheduleEvaluator`

**File**: `spec/services/issue_digest/schedule_evaluator_spec.rb`

| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
**Daily**
| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `due? for daily rule at send time` | daily, send_time: '08:00', grace: 4h, travel_to: today 08:05 UTC | `.due?` | `true` |
| `not due before send time` | send_time: '08:00', travel_to: 07:55 UTC | `.due?` | `false` |
| `not due after grace window expires` | send_time: '08:00', grace: 4h, travel_to: 12:05 UTC | `.due?` | `false` |
| `due at end of grace window` | send_time: '08:00', grace: 4h, travel_to: 11:59 UTC | `.due?` | `true` |
| `not due if inactive` | active: false | `.due?` | `false` |
| `not due before start_on` | start_on: tomorrow | `.due?` | `false` |
| `not due after end_on` | end_on: yesterday | `.due?` | `false` |

**Idempotency / schedule_key**
| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `not due if last_schedule_key matches current window` | last_schedule_key: '42:D:2026-05-27', travel_to: 2026-05-27 08:05 | `.due?` | `false` |
| `due if last_schedule_key is from previous window` | last_schedule_key: '42:D:2026-05-26' | `.due?` | `true` |
| `compute_schedule_key returns daily key` | daily, local_date: 2026-05-27 | `.compute_schedule_key` | `"#{id}:D:2026-05-27"` |
| `compute_schedule_key returns weekly key (ISO week)` | weekly, local_date: 2026-05-27 (W22) | `.compute_schedule_key` | `"#{id}:W:2026-W22"` |
| `compute_schedule_key returns monthly_date key` | monthly_date, local_date: 2026-05-15 | `.compute_schedule_key` | `"#{id}:MD:2026-05"` |
| `compute_schedule_key returns interval_days key` | interval_days every:3, anchor:2026-01-01, local_date:2026-01-04 | `.compute_schedule_key` | `"#{id}:ID:1"` |

**Weekdays**
| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `due for weekdays on included day` | days: [1,3,5], travel_to: Monday | `.due?` | `true` |
| `not due for weekdays on excluded day` | days: [1,3,5], travel_to: Tuesday | `.due?` | `false` |

**Weekly**
| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `due for weekly on correct weekday` | day: 1 (Monday), travel_to: Monday | `.due?` | `true` |
| `not due for weekly on wrong weekday` | day: 1 (Monday), travel_to: Tuesday | `.due?` | `false` |
| `not due for weekly if already sent this ISO week` | last_schedule_key: current week key | `.due?` | `false` |
| `due for weekly on same weekday next week` | last_schedule_key: last week key, travel_to: next Monday | `.due?` | `true` |

**monthly_date**
| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `due on configured day of month` | day:15, travel_to: 15th | `.due?` | `true` |
| `not due on different day` | day:15, travel_to: 14th | `.due?` | `false` |
| `not due if already sent this month` | last_schedule_key: current month key | `.due?` | `false` |

**monthly_last_day**
| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `due on last day of February (28 days)` | travel_to: 2026-02-28 | `.due?` | `true` |
| `due on last day of February (leap year, 29 days)` | travel_to: 2028-02-29 | `.due?` | `true` |
| `not due on 30th when month has 31 days` | travel_to: 2026-05-30 | `.due?` | `false` |
| `due on 31st in May` | travel_to: 2026-05-31 | `.due?` | `true` |

**interval_days / interval_weeks**
| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `interval_days: due on period boundary` | every:3, anchor:2026-01-01, travel_to:2026-01-04 | `.due?` | `true` |
| `interval_days: not due between boundaries` | every:3, anchor:2026-01-01, travel_to:2026-01-05 | `.due?` | `false` |
| `interval_days: not due if already sent in current period` | last_schedule_key: current period key | `.due?` | `false` |
| `interval_weeks: due on period boundary` | every:2, anchor:2026-01-05(Mon), travel_to:2026-01-19(Mon) | `.due?` | `true` |
| `interval_weeks: anchor defaults to created_at when start_on is nil` | start_on: nil, created_at: 2026-01-01 | period computed from created_at | correct |

**manual**
| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `manual rule is never due without FORCE/MANUAL` | schedule_type: manual | `.due?` | `false` |
| `manual rule is due with force: true` | schedule_type: manual, force: true | `.due?` | `true` |

**Business days only**
| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `daily rule: not due on Saturday with skip` | business_days_only: true, behavior: skip, travel_to: Saturday | `.due?` | `false` |
| `daily rule: due on Friday before Saturday with previous_weekday` | business_days_only: true, behavior: previous_weekday, canonical day is Sat → execution day is Fri | `.due?` on Friday | `true` |
| `daily rule: not due on Saturday when shifted to Friday` | same rule, travel_to: Saturday | `.due?` | `false` |
| `monthly_date day 15 falls on Sunday: skip` | day:15, business_days_only:true, behavior:skip, 15th is Sunday | `.due?` | `false` |
| `monthly_date day 15 falls on Sunday: next_weekday, due Monday` | behavior:next_weekday | `.due?` on Monday | `true` |
| `monthly_date shifted: schedule_key uses original month window` | shifted from Sun 15th to Mon 16th | `.compute_schedule_key` | key for month, not for day 16 |
| `weekdays type ignores business_days_only` | weekdays [7]=Sunday, business_days_only:true | `.due?` on Sunday | `true` (no interaction) |

**Timezone and DST**
| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `UTC rule at UTC time` | tz: UTC, send_time: 08:00, travel_to: 08:05 UTC | `.due?` | `true` |
| `Brussels rule: UTC+2 in summer` | tz: Europe/Brussels, send_time: 08:00, travel_to: 06:05 UTC | `.due?` | `true` |
| `Brussels rule: UTC+1 in winter` | tz: Europe/Brussels, send_time: 08:00, travel_to: 07:05 UTC | `.due?` | `true` |
| `last_schedule_key same day local time` | local date = run's local date | `.due?` | `false` |
| `last_schedule_key same UTC date but different local date` | send at local 23:50 yesterday | `.due?` today | `true` |
| `DST spring-forward: send_time in gap` | send_time: '02:30', TZ with 02:00→03:00 DST gap | `.due?` | `false` |
| `DST fall-back: second occurrence of 01:30` | ran at first 01:30 (key set), second 01:30 arrives | `.due?` | `false` |
| `returns false on invalid schedule_config` | schedule_config: 'INVALID_JSON' | `.due?` | `false` |

### 4.2 `IssueDigest::RecipientResolver`

**File**: `spec/services/issue_digest/recipient_resolver_spec.rb`

| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `project_members mode returns all active members` | project with 3 active members | `.resolve` | 3 users |
| `project_members excludes locked users` | 1 active + 1 locked member | `.resolve` | 1 user |
| `project_members excludes inactive users` | 1 active + 1 registered-not-active | `.resolve` | 1 user |
| `role: mode returns only members with that role` | 2 managers, 1 dev; mode: role:manager_id | `.resolve` | 2 users |
| `assignees mode returns users assigned to issues` | 2 issues assigned to user A, 1 to user B | `.resolve` | [A, B] |
| `watchers mode returns watchers of matching issues` | user A watches issue 1 | `.resolve` | [A] |
| `user: mode returns specific user` | mode: user:42, user 42 is active project member | `.resolve` | [user 42] |
| `user: mode excludes if user is not a project member` | mode: user:42, user 42 not a member | `.resolve` | [] |
| `user: mode excludes locked user` | mode: user:42, user 42 is locked | `.resolve` | [] |
| `multiple modes are unioned` | project_members (2) + user:42 (1 new user) | `.resolve` | 3 users |
| `deduplicates across modes` | user A in project_members + user:A | `.resolve` | [A] |
| `excludes users without view_issues permission` | user with no permissions | `.resolve` | [] |
| `returns empty array if no matching recipients` | empty project | `.resolve` | [] |

### 4.3 `IssueDigest::IssueResolver`

**File**: `spec/services/issue_digest/issue_resolver_spec.rb`

| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `returns open issues when include_open=true` | 3 open, 2 closed issues | `.resolve` | 3 issues |
| `returns closed issues when include_closed=true` | include_closed: true | `.resolve` | 2 issues |
| `returns overdue issues when include_overdue=true` | 1 overdue, 2 future-due | `.resolve` | 1 issue |
| `returns due-soon issues within window` | 1 due in 3 days, 1 due in 10 days, window=7 | `.resolve` | 1 issue |
| `returns recently updated issues` | 1 updated 3 days ago, 1 updated 10 days ago, window=7 | `.resolve` | 1 issue |
| `returns recently created issues` | 1 created 2 days ago, 1 created 10 days ago, window=7 | `.resolve` | 1 issue |
| `excludes issues from other projects` | rule for project A, issue in project B | `.resolve` | 0 issues |
| `respects Issue.visible(user)` | 1 private issue user cannot see | `.resolve` | excludes private issue |
| `applies filter_assigned_to_recipient` | 3 issues, 1 assigned to user | `.resolve` | 1 issue |
| `applies filter_watched_by_recipient` | 3 issues, user watches 1 | `.resolve` | 1 issue |
| `applies filter_authored_by_recipient` | 3 issues, user authored 1 | `.resolve` | 1 issue |
| `applies include_subprojects when enabled` | issue in sub-project | `.resolve` | includes it |
| `excludes sub-project issues when disabled` | include_subprojects: false | `.resolve` | excludes it |
| `respects max_issues_per_email limit` | 600 matching issues, limit: 500 | `.resolve.count` | 500 |
| `returns Issue.none on exception` | invalid rule config | `.resolve` | `Issue.none` equivalent |
| `sorts by due_date ASC NULLS LAST, id ASC` | mixed due dates | `.resolve` | correct order |

### 4.4 `IssueDigest::QueryAdapter`

**File**: `spec/services/issue_digest/issue_resolver_spec.rb` (or separate file)

| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `applies query filters to scope` | query with status filter | `.apply_to(scope)` | scope includes query's WHERE |
| `returns original scope if query_id is nil` | rule with no query | `.apply_to(scope)` | unchanged scope |
| `returns original scope if query not found` | query_id: 999 (doesn't exist) | `.apply_to(scope)` | unchanged scope + logs warning |
| `returns original scope if query is not visible` | private query, different user | `.apply_to(scope)` | unchanged scope + logs warning |
| `does not raise on deleted query` | query deleted after rule created | `.apply_to(scope)` | unchanged scope |

### 4.5 `IssueDigest::LockManager`

**File**: `spec/services/issue_digest/lock_manager_spec.rb`

| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `executes block when lock acquired` | no competing lock | `.with_lock { :executed }` | `:executed` |
| `returns false when lock not acquired (file lock)` | existing lock file held | `.with_lock { }` | `false` |
| `lock is released after block` | normal execution | after block | no lock file remains |
| `lock is released even after exception` | block raises | rescue; check lock | no lock file remains |

---

## 5. Controller Tests

### `IssueDigest::DigestRulesController`

**File**: `spec/controllers/issue_digest/digest_rules_controller_spec.rb`

| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `GET index with view permission` | user with view_digest_rules | GET /projects/p/digest_rules | 200, renders list |
| `GET index without permission` | user without permission | GET | 403 |
| `GET index with module disabled` | module not enabled | GET | 403 |
| `GET new with manage permission` | user with manage_digest_rules | GET /projects/p/digest_rules/new | 200, form |
| `GET new without manage permission` | user with only view | GET new | 403 |
| `POST create with valid params` | manage permission | POST valid attrs | redirect to index, rule created |
| `POST create with invalid params` | missing name | POST | 422, form with errors |
| `GET edit own rule` | manage permission | GET edit | 200, form |
| `GET edit rule from different project` | rule ID from project B | GET edit | 404 |
| `PATCH update with valid params` | manage permission | PATCH | redirect to show, updated |
| `PATCH update with invalid params` | manage permission, name: nil | PATCH | 422, errors |
| `DELETE destroy` | manage permission | DELETE | redirect to index, rule gone |
| `DELETE destroy rule from other project` | rule from project B | DELETE | 404 |
| `POST enable` | manage permission, disabled rule | POST enable | active=true, redirect |
| `POST disable` | manage permission, active rule | POST disable | active=false, redirect |
| `GET show with view permission` | view permission | GET show | 200, details |
| `GET show includes run history` | rule with 5 runs | GET show | response includes runs |
| `unauthenticated user` | not logged in | any action | redirect to login |

---

## 6. Mailer Tests

**File**: `spec/mailers/issue_digest_mailer_spec.rb`

| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `sends to recipient email` | user.mail = 'user@example.com' | `mailer.to` | `['user@example.com']` |
| `subject uses default template` | rule.email_subject = nil | `mailer.subject` | `"[My Project] Daily open issues — 2026-05-27"` |
| `subject uses custom template` | email_subject: '[{project}] digest' | `mailer.subject` | `"[My Project] digest"` |
| `from is Redmine mail_from setting` | Setting.mail_from = 'redmine@example.com' | `mailer.from` | `['redmine@example.com']` |
| `HTML part includes issue subject` | 1 issue with subject "Fix bug" | mailer.html_part.body | includes "Fix bug" |
| `HTML part includes issue link` | issue.id = 42 | HTML body | includes `/issues/42` |
| `text part includes issue subject` | 1 issue | text body | includes issue.subject |
| `empty issue list with send_empty` | issues: [], send_empty: true | HTML body | includes "No issues matched" |
| `grouped issues render group header` | 2 issues, group_by: :assignee, 2 assignees | HTML body | two group headers |
| `truncation notice shown when limited` | 501 issues, limit: 500 | HTML body | includes "Showing 500 of 501" |
| `renders in multipart (html + text)` | default | `mailer.parts.map(&:content_type)` | includes html and text |
| `subject tokens are escaped safely` | project.name: '<script>alert(1)</script>' | subject | escaped or stripped |
| `does not include issues from other projects` | issues from project B passed | (should not happen; resolver prevents this) | N/A — integration concern |
| `issue with nil assigned_to shows Unassigned` | assigned_to: nil | HTML body | "Unassigned" |
| `overdue issue has overdue CSS class` | due_date: yesterday | HTML body | `class="overdue"` |

---

## 7. Rake Task Tests

**File**: `spec/tasks/issue_digest_rake_spec.rb`

| Test name | Setup | Action | Expected |
|-----------|-------|--------|---------|
| `sends digest for due rule` | 1 due rule, 1 recipient, 1 issue | invoke task | 1 email sent, 1 run created |
| `skips non-due rule` | rule with future send_time | invoke task | 0 emails, 0 runs |
| `skips disabled rule` | active: false | invoke task | 0 emails |
| `skips archived project` | project.archive! | invoke task | 0 emails |
| `skips rule with module disabled` | module not enabled | invoke task | 0 emails |
| `dry_run does not send emails` | DRY_RUN=1 | invoke task | 0 emails, 0 DB records |
| `PROJECT_IDENTIFIER limits to one project` | 2 projects, 1 rule each | PROJECT_IDENTIFIER=p1 | 1 rule processed |
| `RULE_ID limits to one rule` | 3 due rules | RULE_ID=42 | only rule 42 processed |
| `records run in issue_digest_runs` | 1 due rule | invoke | 1 IssueDigestRun created |
| `records delivery in issue_digest_deliveries` | 1 recipient | invoke | 1 IssueDigestDelivery created |
| `delivery status is sent on success` | successful SMTP | invoke | delivery.status == 'sent' |
| `delivery status is failed on SMTP error` | SMTP stub raises | invoke | delivery.status == 'failed' |
| `run status is partial_failure if some fail` | 2 recipients, 1 SMTP failure | invoke | run.status == 'partial_failure' |
| `updates last_run_at on rule` | rule without last_run_at | invoke | rule.last_run_at is set |
| `does not re-send rule already sent today` | last_run_at: today | invoke | 0 new emails |
| `FORCE=1 re-sends despite last_run_at` | last_run_at: today | FORCE=1, invoke | sends again |
| `skips rule if no recipients` | 0 members | invoke | run.status == 'skipped' |
| `skips recipient if no visible issues` | recipient can see 0 issues | invoke | delivery.status == 'skipped' |
| `cleanup task deletes old runs` | 10 runs older than retention | invoke cleanup | 0 runs remain |
| `cleanup task keeps recent runs` | 10 runs within retention | invoke cleanup | 10 runs remain |

---

## 8. Integration Tests

**File**: `spec/integration/digest_flow_spec.rb`

| Test name | Description | Expected |
|-----------|-------------|---------|
| `end-to-end: create rule, invoke task, receive email` | Create rule via factory; invoke rake; check ActionMailer::Base.deliveries | 1 email delivered with correct content |
| `personalization: user sees only assigned issues` | filter_assigned_to_recipient, 2 assignees | each gets own email with own issues |
| `visibility: private issue excluded` | 1 private issue, user not assignee/author/watcher | email has 0 private issues |
| `query integration: applies saved query filters` | query with tracker filter, 2 trackers | only matching tracker issues in email |
| `deleted query: falls back to other filters` | query deleted before task run | email sent with other filters; warning logged |
| `multi-project: rules for different projects run independently` | 2 projects, 1 rule each | 2 separate runs, correct project isolation |

---

## 9. Permission Tests

**File**: `spec/controllers/issue_digest/digest_rules_controller_spec.rb`

| Test name | User role | Action | Expected |
|-----------|-----------|--------|---------|
| Manager can create rule | manager | POST create | 302 (success) |
| Developer cannot create rule | developer (no manage perm) | POST create | 403 |
| Manager can delete rule | manager | DELETE | 302 |
| Developer can view list | developer (view perm) | GET index | 200 |
| Non-member cannot view list | user not in project | GET index | 403 |
| Admin can view any project's rules | admin | GET index | 200 |

---

## 10. Security Tests

| Test name | Description | Expected |
|-----------|-------------|---------|
| `IDOR: cannot access rule from other project` | Rule ID from project B, logged in to project A | 404 |
| `SQL injection in recipient mode` | recipient_modes: ["'; DROP TABLE issues; --"] | validation error; no DB error |
| `XSS in email subject template` | email_subject with `<script>` | subject is escaped |
| `unsafe constantize blocked` | schedule_type: "Kernel" | model validation rejects |
| `private issue not sent to unauthorized user` | private issue visible to manager only | developer's email has 0 issues |
| `locked user excluded from recipients` | locked user is project member | 0 emails to locked user |
| `anonymous user never receives email` | anonymous "user" in watcher list | excluded from resolver |

---

## 11. Timezone and DST Tests

**File**: `spec/services/issue_digest/schedule_evaluator_spec.rb`

| Test name | Setup | Expected |
|-----------|-------|---------|
| `UTC rule at UTC time` | tz: UTC, send_time: 08:00, travel_to: 08:05 UTC | due |
| `Brussels rule: UTC+2 in summer` | tz: Europe/Brussels, send_time: 08:00, travel_to: 06:05 UTC | due |
| `Brussels rule: UTC+1 in winter` | tz: Europe/Brussels, send_time: 08:00, travel_to: 07:05 UTC | due |
| `Last run at same day (local time)` | local date = run date | not due |
| `Last run at same UTC date but different local date` | last_run_at: local 23:50 yesterday | due |
| `Monthly: last day of February` | day: 31, February | use last day of Feb |
| `DST spring-forward: time jumps 02:00→03:00` | send_time: 02:30 in spring-forward TZ | not due (time doesn't exist) |
| `DST fall-back: second occurrence of 01:30` | send_time: 01:30 in fall-back TZ, ran at first 01:30 | not due at second 01:30 |

---

## 12. Concurrency/Idempotency Tests

| Test name | Description | Expected |
|-----------|-------------|---------|
| `lock prevents double execution` | Two processes attempt to run simultaneously | One runs; other exits with `false` |
| `last_run_at prevents double send` | Two processes pass lock (race); first updates last_run_at | Second process sees updated_rows=0 and skips |
| `FORCE=1 overrides idempotency` | Rule already sent today; FORCE=1 | Sends again |
| `cleanup task is safe to run concurrently` | Two cleanup tasks run at once | No DB errors; correct records deleted |

---

## 13. Test Tagging Recommendations

Use RSpec metadata for organization:

```ruby
describe IssueDigest::ScheduleEvaluator, type: :service do
describe IssueDigest::DigestRulesController, type: :controller do
describe IssueDigestMailer, type: :mailer do
```

Slow tests (full integration with DB) tagged `:integration`.
Timezone/DST tests tagged `:timezone`.
Security tests tagged `:security`.

This allows selective runs:
```bash
bundle exec rspec spec --tag ~slow
bundle exec rspec spec --tag security
```
