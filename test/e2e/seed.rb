# Plugin data for the end-to-end scenarios, run by .codex/start_server.sh after
# the generic seed. Idempotent.
#
#   viewer   member of e2e-project with "E2E digest viewer": view_issues and
#            view_digest_rules, not manage_digest_rules
#   digester member of e2e-project with "E2E digest manager": view_issues and
#            both plugin permissions, no other settings permission
#   a private issue in e2e-project that the reporter may not see
#   a public saved query in e2e-project for the query filter
password = ENV.fetch('RMP_USER_PASSWORD', ENV.fetch('RMP_ADMIN_PASSWORD', 'Redmine7Test!'))
admin = User.find_by!(login: 'admin')
User.current = admin
project = Project.find_by!(identifier: 'e2e-project')
manager = User.find_by!(login: 'manager')

viewer = User.find_by(login: 'viewer') ||
         User.new(login: 'viewer', firstname: 'Viewer', lastname: 'E2E', mail: 'viewer@example.net')
viewer.password = viewer.password_confirmation = password
viewer.must_change_passwd = false
viewer.status = User::STATUS_ACTIVE
viewer.save!(validate: false)

role = Role.find_by(name: 'E2E digest viewer') || Role.new(name: 'E2E digest viewer')
role.permissions = [:view_issues, :view_digest_rules]
role.issues_visibility = 'default'
role.save!
Member.create!(principal: viewer, project: project, roles: [role]) unless Member.where(user_id: viewer.id, project_id: project.id).exists?

digester = User.find_by(login: 'digester') ||
           User.new(login: 'digester', firstname: 'Digester', lastname: 'E2E', mail: 'digester@example.net')
digester.password = digester.password_confirmation = password
digester.must_change_passwd = false
digester.status = User::STATUS_ACTIVE
digester.save!(validate: false)

manager_role = Role.find_by(name: 'E2E digest manager') || Role.new(name: 'E2E digest manager')
manager_role.permissions = [:view_issues, :view_digest_rules, :manage_digest_rules]
manager_role.issues_visibility = 'default'
manager_role.save!
unless Member.where(user_id: digester.id, project_id: project.id).exists?
  Member.create!(principal: digester, project: project, roles: [manager_role])
end

unless Issue.where(project_id: project.id, subject: 'E2E private issue in public project').exists?
  issue = Issue.new(project: project, tracker: project.trackers.first, author: admin,
                    subject: 'E2E private issue in public project', is_private: true,
                    priority: IssuePriority.default || IssuePriority.first, assigned_to: manager)
  issue.status = issue.tracker.default_status
  issue.save!
end

unless IssueQuery.where(project_id: project.id, name: 'E2E open issues query').exists?
  query = IssueQuery.new(project: project, name: 'E2E open issues query', user: admin,
                         visibility: Query::VISIBILITY_PUBLIC)
  query.add_filter('status_id', 'o', [''])
  query.save!
end

puts "Plugin seed: viewer, digester, #{Issue.where(project_id: project.id).count} issues in e2e-project, " \
     "query #{IssueQuery.find_by(name: 'E2E open issues query')&.id}"
