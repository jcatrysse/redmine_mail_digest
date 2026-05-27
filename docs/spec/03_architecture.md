# Technical Architecture Specification — redmine_digest

## 1. Plugin Identity

| Field | Value |
|-------|-------|
| Plugin name | `redmine_digest` |
| Module name (Ruby) | `IssueDigest` |
| Project module name | `:issue_digest` |
| Plugin directory | `plugins/redmine_digest/` |
| Redmine project module key | `issue_digest` |
| DB table prefix | `issue_digest_` |

---

## 2. Plugin Directory Structure

```
plugins/redmine_digest/
├── init.rb
├── Gemfile
├── app/
│   ├── controllers/
│   │   └── issue_digest_rules_controller.rb   # flat (non-namespaced)
│   ├── helpers/
│   │   └── issue_digest/
│   │       └── digest_rules_helper.rb
│   ├── mailers/
│   │   └── issue_digest_mailer.rb
│   ├── models/
│   │   ├── issue_digest_rule.rb
│   │   ├── issue_digest_run.rb
│   │   └── issue_digest_delivery.rb
│   ├── services/
│   │   └── issue_digest/
│   │       ├── schedule_evaluator.rb
│   │       ├── recipient_resolver.rb
│   │       ├── issue_resolver.rb
│   │       ├── digest_sender.rb
│   │       ├── run_recorder.rb
│   │       ├── query_adapter.rb
│   │       └── lock_manager.rb
│   └── views/
│       ├── issue_digest_rules/
│       │   ├── index.html.erb
│       │   ├── new.html.erb
│       │   ├── edit.html.erb
│       │   ├── show.html.erb
│       │   ├── _form.html.erb
│       │   ├── _rule_row.html.erb
│       │   └── _run_history.html.erb
│       ├── projects/
│       │   └── settings/
│       │       └── _digest_rules.html.erb     # settings tab partial
│       ├── settings/
│       │   └── _issue_digest_settings.html.erb
│       └── issue_digest_mailer/
│           ├── digest_email.html.erb
│           ├── digest_email.text.erb
│           └── _issue_row.html.erb
├── config/
│   ├── routes.rb
│   └── locales/
│       ├── en.yml
│       └── (additional locales as contributed)
├── db/
│   └── migrate/
│       ├── 001_create_issue_digest_rules.rb
│       ├── 002_create_issue_digest_runs.rb
│       ├── 003_create_issue_digest_deliveries.rb
│       └── 004_change_grace_window_hours_default.rb
├── lib/
│   ├── redmine_digest/
│   │   ├── version.rb
│   │   └── projects_helper_patch.rb           # adds settings tab
│   └── tasks/
│       └── issue_digest.rake
└── spec/
    ├── spec_helper.rb
    ├── rails_helper.rb
    ├── factories/
    ├── helpers/
    │   └── projects_helper_patch_spec.rb
    ├── models/
    ├── controllers/
    │   └── issue_digest_rules_controller_spec.rb
    ├── services/
    ├── mailers/
    ├── integration/
    │   └── digest_flow_spec.rb
    ├── security/
    │   └── security_checklist_spec.rb
    └── tasks/
        └── issue_digest_rake_spec.rb
```

---

## 3. init.rb Responsibilities

```ruby
# plugins/redmine_digest/init.rb

require_relative 'lib/redmine_digest/version'
require_relative 'lib/redmine_digest/projects_helper_patch'

Redmine::Plugin.register :redmine_digest do
  name        'Redmine Digest'
  author      'redmine_digest contributors'
  description 'Scheduled issue digest emails for Redmine projects'
  version     IssueDigest::VERSION
  url         'https://github.com/jcatrysse/redmine_digest'
  author_url  'https://github.com/jcatrysse'

  requires_redmine version_or_higher: '5.1.0'

  settings default: {
             'max_issues_per_email'       => 500,
             'run_history_retention_days' => 90,
             'allow_external_recipients'  => false
           },
           partial: 'settings/issue_digest_settings'

  project_module :issue_digest do
    permission :view_digest_rules,
               { 'issue_digest_rules' => [:index, :show] },
               read: true
    permission :manage_digest_rules,
               { 'issue_digest_rules' => [:new, :create, :edit, :update, :destroy, :enable, :disable] }
  end
end

# Apply the ProjectsHelper patch directly — NOT inside Rails.application.config.to_prepare.
#
# Redmine's PluginLoader runs every plugin's init.rb from within its own
# to_prepare callback (see lib/redmine/plugin_loader.rb).  Nesting a second
# to_prepare here would only schedule the patch for the next cycle, which
# never fires in production (cache_classes = true) or in tests.
#
# Applying the include directly is safe: at this point Rails is fully
# initialised and Zeitwerk can autoload ProjectsHelper on first reference.
unless ProjectsHelper.included_modules.include?(IssueDigest::ProjectsHelperPatch)
  ProjectsHelper.include(IssueDigest::ProjectsHelperPatch)
end
```

**Notes**:
- `requires_redmine` enforces minimum version compatibility.
- `settings` registers global admin settings. The partial lives at
  `app/views/settings/_issue_digest_settings.html.erb`.
- `project_module :issue_digest` gates all access behind module activation.
- No sidebar menu entry; access is exclusively through the Project Settings tab
  (added via `IssueDigest::ProjectsHelperPatch`).
- The `to_prepare` double-nesting anti-pattern is deliberately avoided — see the
  comment in `init.rb` and `lib/redmine_digest/projects_helper_patch.rb`.

---

## 4. Autoloading (Zeitwerk)

Redmine 6.1 uses Zeitwerk for autoloading via Rails 7.2. Plugins loaded via
`require` in `init.rb` are not automatically Zeitwerk-managed unless registered.

**Convention**: All files under `app/` are automatically eager-loaded by Redmine's
plugin loading mechanism (Redmine adds each plugin's `app/` subdirectories to
`ActiveSupport::Dependencies.autoload_paths`).

File naming rules:
- `app/models/issue_digest_rule.rb` → class `IssueDigestRule`
- `app/controllers/issue_digest/digest_rules_controller.rb` → class `IssueDigest::DigestRulesController`
- `app/services/issue_digest/schedule_evaluator.rb` → class `IssueDigest::ScheduleEvaluator`
- `app/mailers/issue_digest_mailer.rb` → class `IssueDigestMailer`

**Note**: Redmine 5.1 uses Rails 7.0 which also uses Zeitwerk. Same conventions apply.

---

## 5. Routes

```ruby
# plugins/redmine_digest/config/routes.rb

RedmineApp::Application.routes.draw do
  resources :projects, only: [] do
    resources :issue_digest_rules,
              controller: 'issue_digest_rules',
              path: 'digest_rules' do
      member do
        post :enable
        post :disable
      end
    end
  end
end
```

Resulting routes:

| Method | Path | Action |
|--------|------|--------|
| GET | `/projects/:project_id/digest_rules` | `index` |
| GET | `/projects/:project_id/digest_rules/new` | `new` |
| POST | `/projects/:project_id/digest_rules` | `create` |
| GET | `/projects/:project_id/digest_rules/:id` | `show` |
| GET | `/projects/:project_id/digest_rules/:id/edit` | `edit` |
| PATCH/PUT | `/projects/:project_id/digest_rules/:id` | `update` |
| DELETE | `/projects/:project_id/digest_rules/:id` | `destroy` |
| POST | `/projects/:project_id/digest_rules/:id/enable` | `enable` |
| POST | `/projects/:project_id/digest_rules/:id/disable` | `disable` |

---

## 6. Controllers

### 6.1 `IssueDigestRulesController`

Flat (non-namespaced) class, inherits from `ApplicationController`.

**Filters**:
- `before_action :find_project` — loads `@project` from `params[:project_id]`.
- `before_action :authorize` — checks `manage_digest_rules` or `view_digest_rules` per action.
- `before_action :find_rule, only: [:show, :edit, :update, :destroy, :enable, :disable]`.

**Actions** — all redirects on success go to the Project Settings `digest_rules` tab:

| Action | Permission | Success redirect |
|--------|-----------|-----------------|
| `index` | `view_digest_rules` | — (renders) |
| `show` | `view_digest_rules` | — (renders) |
| `new` | `manage_digest_rules` | — (renders) |
| `create` | `manage_digest_rules` | `settings_project_path(project, tab: 'digest_rules')` |
| `edit` | `manage_digest_rules` | — (renders) |
| `update` | `manage_digest_rules` | `settings_project_path(project, tab: 'digest_rules')` |
| `destroy` | `manage_digest_rules` | `settings_project_path(project, tab: 'digest_rules')` |
| `enable` | `manage_digest_rules` | `settings_project_path(project, tab: 'digest_rules')` |
| `disable` | `manage_digest_rules` | `settings_project_path(project, tab: 'digest_rules')` |

**`default_timezone_iana`**: The form pre-selects the timezone from Redmine's
global `Setting.default_timezone` (an ActiveSupport timezone name), converted
to an IANA identifier via `ActiveSupport::TimeZone[name]&.tzinfo.name`. Falls
back to `'UTC'` on any error.

**Strong parameters**:
```ruby
def digest_rule_params
  params.require(:issue_digest_rule).permit(
    :name, :active, :schedule_type,
    :start_on, :end_on, :send_time, :timezone,
    :query_id, :include_subprojects,
    :include_open, :include_closed, :include_overdue,
    :include_due_soon, :due_soon_days,
    :include_recently_updated, :recently_updated_days,
    :include_recently_created, :recently_created_days,
    :filter_assigned_to_recipient, :filter_watched_by_recipient,
    :filter_authored_by_recipient,
    :group_by, :send_empty,
    :email_subject, :email_intro,
    schedule_config: {}, # nested JSON fields submitted as form params
    recipient_modes: []  # array of strings
  )
end
```

---

## 7. Models

### 7.1 `IssueDigestRule`

- `belongs_to :project`
- `belongs_to :query, class_name: 'IssueQuery', optional: true`
- `belongs_to :created_by, class_name: 'User'`
- `belongs_to :updated_by, class_name: 'User', optional: true`
- `has_many :issue_digest_runs, dependent: :destroy`
- `validates :name, presence: true, length: { maximum: 255 }`
- `validates :schedule_type, inclusion: { in: %w[daily weekdays weekly monthly] }`
- `validates :send_time, presence: true`
- `validates :recipient_modes, presence: true` (must have at least one)
- `validate :schedule_config_valid`
- `validate :end_on_after_start_on`
- `serialize :schedule_config, coder: JSON`
- `serialize :recipient_modes, coder: JSON`
- `scope :active_for_project, ->(project) { where(project: project, active: true) }`
- `scope :due_now, ->` (delegates to ScheduleEvaluator; used in rake task)

**Instance methods**:
- `active?` — returns `active && within_date_range?`
- `within_date_range?` — checks `start_on` and `end_on` against `Date.current`
- `status_label` — returns `:active`, `:disabled`, `:expired`, or `:pending`
- `last_run` — returns latest `IssueDigestRun`

### 7.2 `IssueDigestRun`

- `belongs_to :issue_digest_rule`
- `has_many :issue_digest_deliveries, dependent: :destroy`
- `validates :status, inclusion: { in: %w[running success partial_failure failed error skipped] }`
- `enum :trigger, { scheduled: 'scheduled', manual: 'manual', dry_run: 'dry_run' }`

### 7.3 `IssueDigestDelivery`

- `belongs_to :issue_digest_run`
- `belongs_to :user, optional: true`
- `validates :status, inclusion: { in: %w[sent failed skipped] }`

---

## 8. Services

### 8.1 `IssueDigest::ScheduleEvaluator`

**Responsibility**: Determine if a rule is due at a given moment.

**Interface**:
```ruby
IssueDigest::ScheduleEvaluator.new(rule, time: Time.current).due? # => Boolean
```

**Input**: `IssueDigestRule` instance, optional `time:` (defaults to `Time.current`)  
**Output**: `true` / `false`  
**Failure**: Returns `false` on invalid config; logs an error.  
**Dependencies**: None (pure logic).

---

### 8.2 `IssueDigest::RecipientResolver`

**Responsibility**: Resolve a list of active, valid `User` objects for a rule.

**Interface**:
```ruby
IssueDigest::RecipientResolver.new(rule, issues_scope: scope).resolve # => [User, ...]
```

**Input**: `IssueDigestRule`, optional precomputed `issues_scope` (for assignee/watcher resolution)  
**Output**: `Array<User>` (unique, active, with valid email, with view_issues permission)  
**Failure**: Returns `[]` on exception; logs error.  
**Side effects**: None.

---

### 8.3 `IssueDigest::IssueResolver`

**Responsibility**: Build the issue scope for a rule and a specific user.

**Interface**:
```ruby
IssueDigest::IssueResolver.new(rule, user: user).resolve # => ActiveRecord::Relation<Issue>
```

**Input**: `IssueDigestRule`, `user:` (the recipient)  
**Output**: `ActiveRecord::Relation<Issue>` (not yet executed)  
**Failure**: Returns `Issue.none` on exception; logs error.  
**Dependencies**: `IssueDigest::QueryAdapter`

---

### 8.4 `IssueDigest::QueryAdapter`

**Responsibility**: Safely load and apply a saved `IssueQuery`'s filters to a scope.

**Interface**:
```ruby
IssueDigest::QueryAdapter.new(rule).apply_to(scope) # => ActiveRecord::Relation or original scope
```

**Input**: `IssueDigestRule` (to extract `query_id`), `ActiveRecord::Relation`  
**Output**: `ActiveRecord::Relation` with query WHERE clause applied (or unchanged on failure)  
**Failure**: Logs a warning and returns the original scope if query is missing or invalid.

---

### 8.5 `IssueDigest::DigestSender`

**Responsibility**: Orchestrate recipient resolution, issue resolution, email generation,
and delivery for one rule.

**Interface**:
```ruby
IssueDigest::DigestSender.new(rule, dry_run: false).send # => IssueDigestRun
```

**Input**: `IssueDigestRule`, `dry_run:` boolean  
**Output**: `IssueDigestRun` record (created and persisted, or a value object in dry_run mode)  
**Failure**: Rescues delivery errors per recipient; records them; continues.  
**Side effects**: Creates DB records, sends emails.

---

### 8.6 `IssueDigest::RunRecorder`

**Responsibility**: Create, update, and finalize `IssueDigestRun` and `IssueDigestDelivery` records.

**Interface**:
```ruby
recorder = IssueDigest::RunRecorder.new(rule, trigger: :scheduled)
recorder.start                        # creates IssueDigestRun with status: running
recorder.record_delivery(user, status, issues_count:, error_message: nil)
recorder.finish(status)               # updates run with final status, counts, timestamps
```

**Input**: `IssueDigestRule`, trigger type, recipient/delivery data  
**Output**: `IssueDigestRun` record  
**Failure**: Logs error; does not crash the sender.

---

### 8.7 `IssueDigest::LockManager`

**Responsibility**: Prevent concurrent rake task executions from processing the same rules.

**Recommendation**: Use PostgreSQL advisory locks for PostgreSQL databases.  
**Fallback**: File-based lock (`Tempfile`) for MySQL and SQLite.

**Interface**:
```ruby
IssueDigest::LockManager.with_lock do
  # process rules
end
# Returns false immediately without executing block if lock is not acquired
```

**Input**: Block  
**Output**: Result of block, or `false` if lock was not acquired  
**Failure**: Logs a warning if lock is not acquired; does not raise.

---

## 9. Mailer

### `IssueDigestMailer`

Inherits from `ActionMailer::Base` (like Redmine's `Mailer` class convention, but kept
separate to avoid conflicts with Redmine's own notification system).

**Actions**:
- `digest_email(rule, user, issues, grouped_issues)` — generates and delivers digest email.

**Details**: See `07_mailer_spec.md`.

---

## 10. Helpers

### `IssueDigest::DigestRulesHelper`

- `digest_rule_status_badge(rule)` — returns an HTML badge (span with CSS class) for rule status.
- `schedule_description(rule)` — human-readable schedule string (e.g. "Daily at 08:00 UTC").
- `recipient_modes_description(rule)` — human-readable recipient list.
- `format_run_status(run)` — badge for run status.
- `available_timezones` — returns sorted list of IANA timezone strings for select.
- `available_queries_for_project(project)` — public IssueQuery records for the project.

---

## 11. Views

### 11.1 Project Settings Tab

The plugin adds a "Digest Rules" tab to the standard Redmine Project Settings page
(the same page that shows Members, Versions, Issue categories, etc.).

**Implementation**: `lib/redmine_digest/projects_helper_patch.rb` patches
`ProjectsHelper#project_settings_tabs` using the `alias_method` chain pattern
(`_with_/_without_` style, compatible with other Redmine plugins). The module is
included directly in `init.rb` (not inside `to_prepare`) because `init.rb` already
runs inside Redmine's own `to_prepare` callback — see the comment in `init.rb`.

The tab is only added when:
1. The `issue_digest` module is enabled on the project.
2. `User.current.allowed_to?(:view_digest_rules, @project)` returns true.

The tab partial lives at `app/views/projects/settings/_digest_rules.html.erb` and
renders the rules list with Name, Schedule, Recipients, Status, Last Run, and
action buttons. Navigation from the settings tab is the primary (and only) UI
entry point; there is no sidebar menu entry.

### 11.2 Views List

| View file | Purpose |
|-----------|---------|
| `digest_rules/index.html.erb` | List all rules for project |
| `digest_rules/new.html.erb` | New rule form shell |
| `digest_rules/edit.html.erb` | Edit form shell |
| `digest_rules/show.html.erb` | Rule detail + run history |
| `digest_rules/_form.html.erb` | Shared form partial |
| `digest_rules/_rule_row.html.erb` | Table row for index page |
| `digest_rules/_run_history.html.erb` | Run history table |
| `issue_digest_mailer/digest_email.html.erb` | HTML email body |
| `issue_digest_mailer/digest_email.text.erb` | Plain text email body |
| `issue_digest_mailer/_issue_row.html.erb` | Single issue row in email |
| `settings/_issue_digest_settings.html.erb` | Global admin settings partial |

---

## 12. I18n Files

```
config/locales/en.yml
```

All locale keys are namespaced under `redmine_digest` or use Redmine's `label_*` /
`button_*` / `notice_*` / `error_*` conventions where appropriate.

See `06_ui_spec.md` for complete English key list.

---

## 13. Rake Tasks

```
lib/tasks/issue_digest.rake
```

Namespace: `redmine:issue_digest`

Tasks:
- `send` — main delivery task
- `cleanup` — prune old run records (delegates to retention policy)

See `05_scheduler.md` for full specification.

---

## 14. Redmine Integration Points

| Integration point | How used |
|------------------|---------|
| `Redmine::Plugin.register` | Plugin registration, metadata, settings |
| `project_module` | Module toggle per project |
| `permission` | Authorization gates |
| `:project_menu` | Optional sidebar menu entry |
| `ApplicationController` | Base class for plugin controllers |
| `Issue.visible(user)` | Issue visibility scoping |
| `IssueQuery` | Saved query filter integration |
| `Project` model | Association with rules |
| `User` model | Recipient resolution, email delivery |
| `Member` / `MemberRole` | Role-based recipient modes |
| `Watcher` | Watcher recipient mode |
| `ActionMailer::Base` | Email delivery |
| `Rails.logger` | Logging |
| `Setting.plugin_redmine_digest` | Global plugin settings |
| Redmine `layouts/base` | Controller rendering within Redmine layout |
| Redmine I18n / locale YAML | All UI strings |

---

## 15. Redmine Version Compatibility Notes

### Redmine 6.1 (Rails 7.2, Ruby 3.2–3.4)
- Zeitwerk autoloading: follow strict file/class naming.
- Propshaft replaces Sprockets: no `asset_path` or Sprockets-specific helpers.
- Importmap: no npm/webpack needed. Keep JS minimal or use Stimulus.
- `serialize` with `coder:` syntax: compatible.
- JSON columns: PostgreSQL native; TEXT+JSON for others.

### Redmine 5.1 (Rails 7.0, Ruby ≥ 3.0)
- Zeitwerk: same rules apply.
- Sprockets still present in 5.1? Verify in CI. Use Propshaft-compatible patterns to be safe.
- `enum` syntax: Rails 7.0 uses `enum :field, hash` (positional args deprecated). Use keyword syntax.
- `serialize coder:` syntax: Rails 7.0 compatible.

### Common compatibility rules
- No `Kernel.system`, `eval`, `constantize` on user input.
- No raw SQL with string interpolation; use Arel or `?` placeholders.
- Do not use `send` on user-supplied strings.
