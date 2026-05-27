# Security and Permissions Specification — redmine_digest

## 1. Permission Model

### 1.1 Registered permissions

```ruby
project_module :issue_digest do
  permission :view_digest_rules,
             { 'issue_digest/digest_rules' => [:index, :show] },
             :read => true

  permission :manage_digest_rules,
             { 'issue_digest/digest_rules' => [:new, :create, :edit, :update,
                                               :destroy, :enable, :disable] }
end
```

### 1.2 Permission assignment recommendations

| Role | Recommended permissions |
|------|------------------------|
| Manager / Project Manager | `manage_digest_rules` + `view_digest_rules` |
| Developer | `view_digest_rules` |
| Reporter | `view_digest_rules` (optional; PM decides) |
| Non-member | No access |

These are recommendations; actual assignment is per-project by the project manager.

### 1.3 Global admin access

Global plugin settings (`/settings/plugin/redmine_digest`) are protected by Redmine's
standard admin-only gate. Only users with `admin = true` can access this page. No
plugin-specific code is needed; Redmine enforces this for all `/settings/plugin/*` routes.

---

## 2. Controller Authorization

### 2.1 `before_action :authorize`

Every controller action must be guarded by Redmine's `authorize` filter.
This filter checks the current user's permissions against the current project and action.

```ruby
class IssueDigest::DigestRulesController < ApplicationController
  before_action :find_project
  before_action :authorize

  # ...

  private

  def find_project
    @project = Project.find(params[:project_id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end
end
```

The `authorize` filter is provided by Redmine's `ApplicationController`. It:
1. Loads the current user from the session.
2. Checks `User.current.allowed_to?(action, @project)`.
3. Returns 403 if not authorized.

### 2.2 Resource ownership check

When loading a specific rule, verify it belongs to the current project:

```ruby
def find_rule
  @rule = @project.issue_digest_rules.find(params[:id])
rescue ActiveRecord::RecordNotFound
  render_404
end
```

Using `@project.issue_digest_rules.find(...)` (scoped to project) prevents horizontal
privilege escalation (user of project A accessing a rule from project B via ID guessing).

---

## 3. Issue Visibility Enforcement

**This is the most critical security requirement.**

Every issue shown in a digest email must be visible to the specific recipient.

### 3.1 Enforcement mechanism

`IssueResolver` operates in two modes depending on whether a `user:` argument is supplied:

**Per-recipient delivery path** (`user:` provided — `DigestSender` calls `resolve` per recipient):

```ruby
Issue.visible(user).where(project: rule.project)
```

`Issue.visible(user)` is Redmine's built-in scope that accounts for:
- Project visibility (public vs. private projects)
- User membership in the project
- Issue-level private flag (private issues only visible to author, assignees, managers)
- Issue visibility setting at the project level (all members, non-members, etc.)

**Candidate-scope / recipient-discovery path** (`user: nil` — `RecipientResolver` calls
`base_scope` to find assignees, authors, or watchers without knowing the recipients yet):

```ruby
Issue.joins(:project)
     .where("projects.status != ?", Project::STATUS_ARCHIVED)
     .where(project_id: rule.project_id)
```

This path intentionally omits `Issue.visible`, because in a rake context `User.current`
is `AnonymousUser`, which has no visibility into private projects. Calling
`Issue.visible` here would return zero issues on any private project, causing
`assignees`, `authors`, and `watchers` modes to silently produce 0 recipients.

**The security guarantee is maintained**: every issue list sent to a real recipient is
built using `IssueResolver.new(rule, user: recipient).resolve`, which always uses
`Issue.visible(recipient)`. The candidate scope is used only to discover which users
should receive a digest; those users then each see only the issues they are permitted
to view.

### 3.2 No bypass allowed

- The mailer must NOT be called with a pre-fetched list of issues that bypasses `visible(user)`.
- The `DigestSender` must call `IssueResolver.new(rule, user: recipient).resolve` for
  each individual recipient, not compute a shared issue list and send it to all recipients.
- The `base_scope` (nil-user path) must never be passed directly to the mailer or used as
  the final issue list. It is used only for recipient discovery.
- If the performance cost of per-recipient issue resolution is too high, optimize using
  `include` / `preload` within the `Issue.visible(user)` scope — do not bypass it.

### 3.3 Query filter security

When applying a saved `IssueQuery`'s filters:

- The query's WHERE clause (its `statement`) is applied in addition to `Issue.visible(user)`.
- The IssueQuery's own visibility rules (PUBLIC/PRIVATE/ROLES) are checked before applying.
- A query marked as private (not belonging to this project, not public) must not be applied.
- The query's filters are extracted via `query.statement` which is generated by Redmine's
  own `Query` class; it uses parameterized SQL internally and is safe from injection.

**However**: the `QueryAdapter` must not call `eval`, `constantize`, or `send` on any
part of the query configuration. Access only the `statement` method and the `base_scope`.

---

## 4. Project Module Gate

If the `issue_digest` project module is not enabled for a project, all controller actions
return 403. This is enforced by `authorize` checking module activation.

An administrator or project manager can disable the module at any time. Existing rules
remain in the database but are not accessible via the UI until the module is re-enabled.
The rake task still executes rules for projects with the module disabled?

**Ruling**: No. The rake task should also check that the project module is enabled before
executing a rule. Add to the rule selection query:

```ruby
# Only projects with the issue_digest module enabled
scope = scope.joins(:enabled_modules)
             .where(enabled_modules: { name: 'issue_digest' })
```

This prevents execution of rules for projects that disabled the module.

---

## 5. CSRF Protection

Controller actions that modify state (create, update, destroy, enable, disable) use
standard Rails CSRF protection via `ApplicationController`'s `protect_from_forgery`.
No additional configuration needed; all POST/PATCH/DELETE requests from the UI include
the CSRF token via Redmine's standard form helpers.

The rake task does not go through the web request pipeline and therefore has no CSRF surface.

---

## 6. Strong Parameters

All form submissions are filtered through strong parameters in the controller.
See `03_architecture.md` section 6.1 for the `digest_rule_params` method.

**Rules**:
- Never use `params.require(:issue_digest_rule).permit!` (permits all).
- Never use `rule.update(params[:issue_digest_rule])` without filtering.
- The `schedule_config` is submitted as a nested hash (form fields) and permitted as
  `schedule_config: {}`. This allows arbitrary nested keys; however, the model validates
  the structure via `schedule_config_valid` before saving.
- The `recipient_modes` is submitted as an array and permitted as `recipient_modes: []`.
  The model validates that each element matches the allowed format (allowlist).

---

## 7. SQL Injection Prevention

### 7.1 Issue scope construction

All WHERE conditions use ActiveRecord query interface, not string interpolation:

```ruby
# CORRECT
scope.where(status: { is_closed: false })
scope.where("#{Issue.table_name}.due_date < ?", Date.current)
scope.where("#{Issue.table_name}.updated_on >= ?", recently_updated_days.days.ago)

# NEVER
scope.where("updated_on >= '#{params[:date]}'")  # SQL injection risk
```

### 7.2 `query.statement` usage

`IssueQuery#statement` returns a safe SQL fragment generated by Redmine's query system.
However, validate that `query` is a genuine `IssueQuery` instance (not a user-controlled
object) before calling `statement`. Use `query.is_a?(IssueQuery)` check.

### 7.3 Dynamic column names

Do not allow user input to determine SQL column names. Group-by values must be validated
against a strict allowlist:

```ruby
VALID_GROUP_BY = %w[none assignee priority tracker status version category].freeze

validates :group_by, inclusion: { in: VALID_GROUP_BY }
```

The group-by field name used in the query must be mapped from this allowlist to actual
column names in application code:

```ruby
GROUP_BY_COLUMNS = {
  'assignee'  => "#{Issue.table_name}.assigned_to_id",
  'priority'  => "#{Issue.table_name}.priority_id",
  'tracker'   => "#{Issue.table_name}.tracker_id",
  'status'    => "#{Issue.table_name}.status_id",
  'version'   => "#{Issue.table_name}.fixed_version_id",
  'category'  => "#{Issue.table_name}.category_id",
}.freeze
```

---

## 8. Avoiding Unsafe Dynamic Dispatch

Never use `constantize`, `send`, or `eval` on user-supplied strings:

```ruby
# NEVER (arbitrary code execution risk)
rule.schedule_type.constantize.new(rule)
"IssueDigest::#{params[:strategy]}".constantize.call

# CORRECT (explicit mapping)
SCHEDULE_EVALUATORS = {
  'daily'    => IssueDigest::Schedules::Daily,
  'weekdays' => IssueDigest::Schedules::Weekdays,
  'weekly'   => IssueDigest::Schedules::Weekly,
  'monthly'  => IssueDigest::Schedules::Monthly,
}.freeze

evaluator_class = SCHEDULE_EVALUATORS.fetch(rule.schedule_type) do
  raise ArgumentError, "Unknown schedule_type: #{rule.schedule_type}"
end
```

---

## 9. Recipient Mode Validation

`recipient_modes` is a JSON array of strings. Each string must be validated against
an allowlist pattern before use:

```ruby
VALID_RECIPIENT_MODE_PATTERNS = [
  /\Aproject_members\z/,
  /\Arole:\d+\z/,
  /\Auser:\d+\z/,
  /\Aassignees\z/,
  /\Aauthors\z/,
  /\Awatchers\z/,
].freeze

def validate_recipient_modes
  return if recipient_modes.blank?
  recipient_modes.each do |mode|
    unless VALID_RECIPIENT_MODE_PATTERNS.any? { |p| p.match?(mode) }
      errors.add(:recipient_modes, :invalid_mode, value: mode.truncate(50))
    end
  end
end
```

The `RecipientResolver` performs this validation again before acting on a mode.

---

## 10. Email Subject Template Security

The `email_subject` field supports a limited set of tokens (`{project}`, `{date}`, etc.).
These are substituted using safe string replacement:

```ruby
def render_subject(template, rule, date)
  template
    .gsub('{project}',    ERB::Util.html_escape(rule.project.name))
    .gsub('{rule_name}',  ERB::Util.html_escape(rule.name))
    .gsub('{date}',       date.strftime('%Y-%m-%d'))
    .gsub('{issues_count}', issues_count.to_s)
end
```

HTML escaping in the subject is not strictly needed (subjects are plain text), but
`ERB::Util.html_escape` prevents any accidental XSS if subject is later rendered in HTML.

Never use `ERB.new(template).result(binding)` with user-supplied templates.

---

## 11. Logging Security (No PII in Logs)

The following data must NEVER appear in log output:
- User email addresses
- Issue subjects or bodies
- User real names
- Project names (debatable; log project identifiers or IDs instead)

The following are acceptable in logs:
- User IDs (integer)
- Rule IDs (integer)
- Run IDs (integer)
- Issue counts (integer)
- Exception class names and truncated messages (max 200 chars, truncated to avoid leaking data)

---

## 12. External Email Addresses (Confirmed Out of Scope for v1)

**Confirmed decision (OQ-01)**: External (non-Redmine-user) email addresses are **not**
supported as recipients in v1. The global admin settings page includes an
`allow_external_recipients` toggle, but it is inert in v1 — setting it to `true` has
no effect. The `RecipientResolver` must hard-reject any non-User recipient regardless
of this setting in v1.

**Implementation requirement**: The `RecipientResolver` must assert that every
resolved recipient is an instance of the Redmine `User` model. No delivery to a
bare email string is permitted.

**Rationale for deferral**:
- Would bypass Redmine's issue visibility system (no User record = no permission check).
- Requires GDPR/spam compliance analysis (unsubscribe mechanism, legal basis).
- Adds significant complexity to recipient resolution.

**Stub for future implementation** (not to be built in v1):
When `allow_external_recipients` is eventually activated:
- Each external address must be explicitly added by a user with `manage_digest_rules`.
- Only non-private issue fields may appear in emails to external addresses.
- All external deliveries logged at INFO level with address hash, not plaintext.
- A mandatory unsubscribe link must appear in every email to an external address.

---

## 13. Private Issue Data

If a rule includes personalization filter `filter_assigned_to_recipient = false` and the
project has private issues, the `Issue.visible(user)` scope excludes private issues the
user cannot see. This is automatic and requires no additional code.

**Verify**: The `Issue.visible` scope in Redmine 5.1 and 6.1 must correctly handle:
- Private issues on public projects (visible only to assignee, author, watchers, managers).
- Issues in private projects (visible only to members).

This has been confirmed via Redmine's own test suite. The plugin must not override or
re-implement this logic.

---

## 14. Archived/Closed Project Access

- Archived projects (`status = STATUS_ARCHIVED`): excluded from rake task processing and
  from UI access (Redmine's `require_projects_not_archived` filter).
- Closed projects (`status = STATUS_CLOSED`): included; rules execute normally.

---

## 15. Security Review Checklist

| Check | Status | Notes |
|-------|--------|-------|
| All controller actions require `authorize` | Required | Per action, not skippable |
| Resource scoped to `@project` | Required | Prevents IDOR |
| Strong parameters on all form submissions | Required | No `permit!` |
| `Issue.visible(user)` always applied per recipient delivery | Required | Core privacy guarantee; nil-user candidate scope is for recipient discovery only, not for final issue lists |
| No SQL string interpolation with user input | Required | Use `?` placeholders |
| No `constantize`/`eval`/`send` on user data | Required | Use explicit mapping |
| Recipient modes validated against allowlist | Required | Before use in SQL |
| Email subject template uses safe substitution | Required | No ERB eval |
| No PII in Rails.logger output | Required | IDs only |
| Advisory lock prevents double execution | Required | DB advisory lock (PG) + file lock fallback; confirmed OQ-04 |
| Query visibility checked before applying | Required | PUBLIC or project-scoped |
| CSRF tokens on all state-mutating requests | Required | Rails default |
| Project module enabled check in rake task | Required | Via JOIN on enabled_modules |
| External email addresses hard-blocked in v1 | Required | RecipientResolver must reject non-User recipients; confirmed OQ-01 |
| No automatic SMTP retry | Required | Log failures; no re-send logic; confirmed OQ-09 |
