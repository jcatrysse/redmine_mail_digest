# frozen_string_literal: true

require_relative '../rails_helper'

RSpec.describe IssueDigestMailer, type: :mailer do
  # ------------------------------------------------------------------
  # Setup
  # ------------------------------------------------------------------
  let!(:project)   { create(:project, is_public: true, name: 'My Project', identifier: 'my-project') }
  let!(:user)      { create(:user, admin: true, mail: 'recipient@example.com') }
  let!(:open_st)   { create(:issue_status, name: "Open_#{SecureRandom.hex(4)}", is_closed: false) }
  let!(:tracker)   { t = create(:tracker, default_status: open_st); project.trackers << t; t }
  let!(:priority)  { create(:issue_priority, name: 'High', is_default: true) }
  let!(:role)      { Role.create!(name: "DigestMailerRole_#{SecureRandom.hex(4)}", permissions: [:view_issues]) }

  # Redmine validates that `assigned_to` is a member of the project (and that
  # the member has permission to be assigned issues). Tests that assign an
  # issue to a user must first call add_member for that user.
  def add_member(u, proj = project, r = role)
    Member.create!(principal: u, project: proj, roles: [r])
  end
  let(:rule) do
    create(:issue_digest_rule,
           project: project,
           name: 'Daily open issues',
           email_subject: nil,
           email_intro: nil,
           group_by: 'none',
           send_empty: true)
  end

  before do
    # Stub Setting.mail_from / host_name / protocol so we have deterministic values
    # in tests; preserve other Setting reads via and_call_original on unmatched names.
    allow(Setting).to receive(:mail_from).and_return('redmine@example.com')
    allow(Setting).to receive(:host_name).and_return('redmine.example.com')
    allow(Setting).to receive(:protocol).and_return('https')

    # Suppress noisy Redmine user/issue side effects (consistent with other specs).
    allow_any_instance_of(User).to receive(:deliver_security_notification)
    allow_any_instance_of(Issue).to receive(:add_auto_watcher)
  end

  def make_issue(attrs = {})
    create(:issue, { project: project, tracker: tracker, priority: priority,
                     status: open_st, author: user }.merge(attrs))
  end

  # Empty-issues + send_empty=false is NOT tested here because DigestSender
  # explicitly skips that case and never calls the mailer. See
  # app/services/issue_digest/digest_sender.rb #deliver_to.

  # ------------------------------------------------------------------
  # Envelope (to / from / subject)
  # ------------------------------------------------------------------
  describe 'envelope' do
    let(:issues) { [make_issue(subject: 'First issue')] }
    let(:mail)   { described_class.digest_email(rule, user, issues, nil) }

    it 'sends to the recipient user' do
      expect(mail.to).to eq([user.mail])
    end

    it 'sends from the configured Setting.mail_from' do
      expect(mail.from).to eq(['redmine@example.com'])
    end

    it 'uses the default subject template when email_subject is blank' do
      expect(mail.subject).to eq("[My Project] Daily open issues — #{Date.current.strftime('%Y-%m-%d')}")
    end
  end

  describe 'custom subject template' do
    let(:issues) { [make_issue, make_issue] }

    it 'substitutes {project}, {rule_name}, {date}, {issues_count} tokens' do
      rule.update!(email_subject: 'Digest {project} / {rule_name} on {date} ({issues_count})')
      mail = described_class.digest_email(rule, user, issues, nil)
      expect(mail.subject).to eq("Digest My Project / Daily open issues on #{Date.current.strftime('%Y-%m-%d')} (2)")
    end

    it 'does not evaluate ERB / format strings in the subject template (no dynamic eval)' do
      # Tokens that look like code must be treated as literal text.
      rule.update!(email_subject: '<%= 7*7 %> %{evil} {unknown_token}')
      mail = described_class.digest_email(rule, user, issues, nil)
      # The string is left untouched except for explicitly allowlisted tokens.
      expect(mail.subject).to include('<%= 7*7 %>')
      expect(mail.subject).to include('%{evil}')
      expect(mail.subject).to include('{unknown_token}')
    end

    it 'truncates very long subjects to 255 characters' do
      # The DB column is varchar(255) so we can't store an over-length template;
      # stub the accessor to simulate one (e.g. after token expansion).
      allow(rule).to receive(:email_subject).and_return('A' * 300)
      mail = described_class.digest_email(rule, user, issues, nil)
      expect(mail.subject.length).to eq(255)
    end
  end

  # ------------------------------------------------------------------
  # Multipart structure
  # ------------------------------------------------------------------
  describe 'multipart' do
    let(:issues) { [make_issue] }
    let(:mail)   { described_class.digest_email(rule, user, issues, nil) }

    it 'is multipart with both text/plain and text/html parts' do
      expect(mail).to be_multipart
      mime_types = mail.parts.map(&:mime_type)
      expect(mime_types).to include('text/plain')
      expect(mime_types).to include('text/html')
    end

    it 'is deliverable via deliver_now' do
      expect { mail.deliver_now }.not_to raise_error
    end
  end

  # ------------------------------------------------------------------
  # HTML body
  # ------------------------------------------------------------------
  describe 'HTML body' do
    let!(:assignee) do
      u = create(:user, firstname: 'Carol', lastname: 'Developer')
      add_member(u)
      u
    end
    let!(:issue) do
      make_issue(subject: 'Login fails after reset',
                 assigned_to: assignee,
                 due_date: 5.days.from_now.to_date)
    end
    let!(:unassigned_issue) do
      make_issue(subject: 'Orphan ticket')
    end
    let(:mail) { described_class.digest_email(rule, user, [issue, unassigned_issue], nil) }
    let(:html) { mail.html_part.body.to_s }

    it 'includes the issue id, subject, status, priority and assignee' do
      expect(html).to include("##{issue.id}")
      expect(html).to include('Login fails after reset')
      expect(html).to include(open_st.name)
      expect(html).to include('High')
      expect(html).to include('Carol Developer')
    end

    it 'includes a link to each issue using Setting.protocol/host_name' do
      expect(html).to include("https://redmine.example.com/issues/#{issue.id}")
    end

    it 'renders "Unassigned" when the issue has no assignee' do
      expect(html).to include('Unassigned')
    end

    it 'renders the formatted due date' do
      expect(html).to include(I18n.l(issue.due_date))
    end

    it 'renders the project heading' do
      expect(html).to include('My Project')
      expect(html).to include('Daily open issues')
    end

    it 'renders the manage-settings footer link' do
      expect(html).to include('https://redmine.example.com/projects/my-project/settings?tab=digest_rules')
      expect(html).to include('Manage digest settings')
    end
  end

  # ------------------------------------------------------------------
  # Text body
  # ------------------------------------------------------------------
  describe 'text body' do
    let!(:issue) { make_issue(subject: 'A text-mode issue') }
    let(:mail)   { described_class.digest_email(rule, user, [issue], nil) }
    let(:text)   { mail.text_part.body.to_s }

    it 'includes the issue id, subject and URL' do
      expect(text).to include("##{issue.id}")
      expect(text).to include('A text-mode issue')
      expect(text).to include("https://redmine.example.com/issues/#{issue.id}")
    end

    it 'includes the project and rule name header' do
      expect(text).to include('My Project')
      expect(text).to include('Daily open issues')
    end

    it 'includes the footer notice' do
      expect(text).to include('You received this digest because you are a member of My Project.')
    end
  end

  # ------------------------------------------------------------------
  # Empty digest (send_empty=true)
  # ------------------------------------------------------------------
  describe 'empty digest with send_empty=true' do
    let(:mail) { described_class.digest_email(rule, user, [], nil) }

    it 'renders the "No issues matched" message in HTML' do
      expect(mail.html_part.body.to_s).to include('No issues matched this digest.')
    end

    it 'renders the "No issues matched" message in text' do
      expect(mail.text_part.body.to_s).to include('No issues matched this digest.')
    end

    it 'still produces a deliverable multipart email' do
      expect(mail).to be_multipart
      expect { mail.deliver_now }.not_to raise_error
    end
  end

  # ------------------------------------------------------------------
  # Grouped layout
  # ------------------------------------------------------------------
  describe 'grouped layout' do
    let!(:carol) do
      u = create(:user, firstname: 'Carol', lastname: 'Developer')
      add_member(u)
      u
    end
    let!(:dave) do
      u = create(:user, firstname: 'Dave', lastname: 'Viewer')
      add_member(u)
      u
    end
    let!(:i1) { make_issue(subject: 'Login bug', assigned_to: carol) }
    let!(:i2) { make_issue(subject: 'CSV export', assigned_to: carol) }
    let!(:i3) { make_issue(subject: 'Report fails', assigned_to: dave) }
    let(:grouped) do
      {
        'Assignee: Carol Developer' => [i1, i2],
        'Assignee: Dave Viewer'     => [i3]
      }
    end
    let(:mail) { described_class.digest_email(rule, user, [i1, i2, i3], grouped) }

    it 'renders an <h3> header per group in HTML' do
      html = mail.html_part.body.to_s
      expect(html).to include('<h3>')
      expect(html).to include('Assignee: Carol Developer')
      expect(html).to include('Assignee: Dave Viewer')
    end

    it 'renders --- group markers in text' do
      text = mail.text_part.body.to_s
      expect(text).to include('--- Assignee: Carol Developer (2) ---')
      expect(text).to include('--- Assignee: Dave Viewer (1) ---')
    end
  end

  # ------------------------------------------------------------------
  # Overdue marker
  # ------------------------------------------------------------------
  describe 'overdue marker' do
    let!(:overdue) { make_issue(subject: 'Late item', due_date: 3.days.ago.to_date) }
    let!(:future)  { make_issue(subject: 'On time',   due_date: 3.days.from_now.to_date) }
    let(:mail) { described_class.digest_email(rule, user, [overdue, future], nil) }
    let(:html) { mail.html_part.body.to_s }

    it 'adds the overdue CSS class to a past-due date cell' do
      expect(html).to match(/class="overdue"[^>]*>#{Regexp.escape(I18n.l(overdue.due_date))}/)
    end

    it 'does not add the overdue CSS class to a future-due date cell' do
      future_str = I18n.l(future.due_date)
      expect(html).not_to match(/class="overdue"[^>]*>#{Regexp.escape(future_str)}/)
    end
  end

  # ------------------------------------------------------------------
  # Intro text
  # ------------------------------------------------------------------
  describe 'optional intro' do
    let!(:issue) { make_issue }
    let(:intro) { 'Good morning! Here is your daily summary of open issues.' }

    it 'renders the intro text in both parts when set' do
      rule.update!(email_intro: intro)
      mail = described_class.digest_email(rule, user, [issue], nil)
      expect(mail.html_part.body.to_s).to include('Good morning!')
      expect(mail.text_part.body.to_s).to include('Good morning!')
    end

    it 'omits the intro block when blank' do
      rule.update!(email_intro: nil)
      mail = described_class.digest_email(rule, user, [issue], nil)
      # The CSS rule .email-intro is always present in the <style> block; check
      # specifically that the wrapping <div class="email-intro"> is not emitted.
      expect(mail.html_part.body.to_s).not_to include('<div class="email-intro">')
    end
  end

  # ------------------------------------------------------------------
  # Intro is rendered with Redmine text formatting (regression)
  #
  # Previously the HTML part used simple_format, so wiki markup entered via the
  # form's toolbar/preview appeared literally in the delivered email — the
  # preview lied. The HTML part must now run the intro through `textilizable`,
  # consistent with the rule's show page and the form preview pane.
  # ------------------------------------------------------------------
  describe 'intro formatting' do
    let!(:issue) { make_issue }

    before do
      # Pin the formatter to textile so the assertion is deterministic across
      # Redmine 5.1 / 6.1 (both ship textile; common_mark only exists on 6.x).
      allow(Setting).to receive(:text_formatting).and_return('textile')
    end

    it 'renders the intro through Redmine formatting in the HTML part' do
      rule.update!(email_intro: 'Hello *world*')
      mail = described_class.digest_email(rule, user, [issue], nil)
      html = mail.html_part.body.to_s
      expect(html).to include('<strong>world</strong>')   # formatted, not literal
      expect(html).not_to include('Hello *world*')         # raw markup not leaked
    end

    it 'does not raise when the intro references an issue (route helper resolves)' do
      rule.update!(email_intro: "See ##{issue.id} for details")
      expect {
        described_class.digest_email(rule, user, [issue], nil).deliver_now
      }.not_to raise_error
    end
  end
end
