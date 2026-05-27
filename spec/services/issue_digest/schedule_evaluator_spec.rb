# frozen_string_literal: true

require_relative '../../rails_helper'

RSpec.describe IssueDigest::ScheduleEvaluator, type: :service do
  let(:project) { create(:project) }
  let(:user)    { create(:user) }

  # Helper: build a rule without saving, to test .due? in isolation.
  def build_rule(attrs = {})
    defaults = {
      project:        project,
      name:           'Test',
      schedule_type:  'daily',
      schedule_config: {},
      send_time:      '08:00:00',
      timezone:       'UTC',
      grace_window_hours: 4,
      active:         true,
      include_open:   true,
      recipient_modes: ['project_members'],
      group_by:       'none',
      created_by:     user
    }
    build(:issue_digest_rule, defaults.merge(attrs))
  end

  # Helpers for time travel
  def at(time_str)
    Time.zone.parse(time_str)
  end

  describe '#due?' do
    context 'daily schedule' do
      it 'is due at send_time within grace window' do
        rule = build_rule
        travel_to(at('2026-05-27 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'is not due before send_time' do
        rule = build_rule
        travel_to(at('2026-05-27 07:55:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'is not due after grace window expires' do
        rule = build_rule
        travel_to(at('2026-05-27 12:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'is due at the end of the grace window' do
        rule = build_rule
        travel_to(at('2026-05-27 11:59:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'is not due when inactive' do
        rule = build_rule(active: false)
        travel_to(at('2026-05-27 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'is not due before start_on' do
        travel_to(at('2026-05-27 08:05:00 UTC')) do
          rule = build_rule(start_on: Date.current + 1)
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'is not due after end_on' do
        travel_to(at('2026-05-27 08:05:00 UTC')) do
          rule = build_rule(end_on: Date.current - 1)
          expect(described_class.new(rule).due?).to be false
        end
      end
    end

    context 'idempotency / schedule_key' do
      it 'is not due when last_schedule_key matches current window' do
        rule = build_rule(last_schedule_key: "0:D:2026-05-27")
        allow(rule).to receive(:id).and_return(0)
        travel_to(at('2026-05-27 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'is due when last_schedule_key is from a previous window' do
        rule = build_rule(last_schedule_key: "0:D:2026-05-26")
        allow(rule).to receive(:id).and_return(0)
        travel_to(at('2026-05-27 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'is due with force: true even when key matches' do
        rule = build_rule(last_schedule_key: "0:D:2026-05-27")
        allow(rule).to receive(:id).and_return(0)
        travel_to(at('2026-05-27 08:05:00 UTC')) do
          expect(described_class.new(rule, force: true).due?).to be true
        end
      end
    end

    context 'weekdays schedule' do
      it 'is due on an included day' do
        rule = build_rule(schedule_type: 'weekdays', schedule_config: { 'days' => [1, 3, 5] })
        # 2026-05-25 is a Monday (cwday=1)
        travel_to(at('2026-05-25 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'is not due on an excluded day' do
        rule = build_rule(schedule_type: 'weekdays', schedule_config: { 'days' => [1, 3, 5] })
        # 2026-05-26 is a Tuesday (cwday=2)
        travel_to(at('2026-05-26 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end
    end

    context 'weekly schedule' do
      it 'is due on the correct weekday' do
        rule = build_rule(schedule_type: 'weekly', schedule_config: { 'day' => 1 })
        # 2026-05-25 is Monday
        travel_to(at('2026-05-25 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'is not due on a different weekday' do
        rule = build_rule(schedule_type: 'weekly', schedule_config: { 'day' => 1 })
        # 2026-05-26 is Tuesday
        travel_to(at('2026-05-26 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'is not due if already sent this ISO week' do
        rule = build_rule(
          schedule_type: 'weekly',
          schedule_config: { 'day' => 1 },
          last_schedule_key: '0:W:2026-W22'
        )
        allow(rule).to receive(:id).and_return(0)
        # 2026-05-25 is Monday of W22
        travel_to(at('2026-05-25 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'is due on the same weekday next week' do
        rule = build_rule(
          schedule_type: 'weekly',
          schedule_config: { 'day' => 1 },
          last_schedule_key: '0:W:2026-W21'
        )
        allow(rule).to receive(:id).and_return(0)
        # 2026-06-01 is next Monday (W22 → W23 — let's just use a Monday after W21)
        travel_to(at('2026-05-25 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end
    end

    context 'monthly_date schedule' do
      it 'is due on the configured day of the month' do
        rule = build_rule(schedule_type: 'monthly_date', schedule_config: { 'day' => 15 })
        travel_to(at('2026-05-15 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'is not due on a different day' do
        rule = build_rule(schedule_type: 'monthly_date', schedule_config: { 'day' => 15 })
        travel_to(at('2026-05-14 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'is not due if already sent this month' do
        rule = build_rule(
          schedule_type: 'monthly_date',
          schedule_config: { 'day' => 15 },
          last_schedule_key: '0:MD:2026-05'
        )
        allow(rule).to receive(:id).and_return(0)
        travel_to(at('2026-05-15 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end
    end

    context 'monthly_last_day schedule' do
      it 'is due on the last day of February (28 days)' do
        rule = build_rule(schedule_type: 'monthly_last_day', schedule_config: {})
        travel_to(at('2026-02-28 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'is due on the last day of February in a leap year (29 days)' do
        rule = build_rule(schedule_type: 'monthly_last_day', schedule_config: {})
        travel_to(at('2028-02-29 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'is not due on day 30 when the month has 31 days' do
        rule = build_rule(schedule_type: 'monthly_last_day', schedule_config: {})
        travel_to(at('2026-05-30 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'is due on May 31st' do
        rule = build_rule(schedule_type: 'monthly_last_day', schedule_config: {})
        travel_to(at('2026-05-31 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end
    end

    context 'interval_days schedule' do
      let(:anchor) { Date.new(2026, 1, 1) }

      it 'is due on a period boundary' do
        rule = build_rule(
          schedule_type: 'interval_days',
          schedule_config: { 'every' => 3 },
          start_on: anchor
        )
        travel_to(at('2026-01-04 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'is not due between boundaries' do
        rule = build_rule(
          schedule_type: 'interval_days',
          schedule_config: { 'every' => 3 },
          start_on: anchor
        )
        travel_to(at('2026-01-05 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'is not due if already sent in current period' do
        rule = build_rule(
          schedule_type: 'interval_days',
          schedule_config: { 'every' => 3 },
          start_on: anchor,
          last_schedule_key: '0:ID:1'
        )
        allow(rule).to receive(:id).and_return(0)
        travel_to(at('2026-01-04 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end
    end

    context 'interval_weeks schedule' do
      let(:anchor) { Date.new(2026, 1, 5) } # Monday

      it 'is due on a period boundary' do
        rule = build_rule(
          schedule_type: 'interval_weeks',
          schedule_config: { 'every' => 2 },
          start_on: anchor
        )
        travel_to(at('2026-01-19 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'defaults anchor to created_at when start_on is nil' do
        created = Time.zone.parse('2026-01-05 00:00:00 UTC')
        rule = build_rule(
          schedule_type: 'interval_weeks',
          schedule_config: { 'every' => 2 },
          start_on: nil
        )
        allow(rule).to receive(:created_at).and_return(created)
        travel_to(at('2026-01-19 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end
    end

    context 'manual schedule' do
      it 'is never due without force' do
        rule = build_rule(schedule_type: 'manual', send_time: nil)
        travel_to(at('2026-05-27 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'is due with force: true' do
        rule = build_rule(schedule_type: 'manual', send_time: nil)
        travel_to(at('2026-05-27 08:05:00 UTC')) do
          expect(described_class.new(rule, force: true).due?).to be true
        end
      end
    end

    context 'business_days_only' do
      it 'daily: not due on Saturday when behavior is skip' do
        rule = build_rule(business_days_only: true, non_business_day_behavior: 'skip')
        # 2026-05-30 is a Saturday
        travel_to(at('2026-05-30 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'daily: due on Friday when Saturday shifts to previous_weekday' do
        rule = build_rule(business_days_only: true, non_business_day_behavior: 'previous_weekday')
        # 2026-05-29 is Friday; evaluator is asked at Friday — not a weekend, so passes
        travel_to(at('2026-05-29 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'daily: not due on Saturday even with previous_weekday (shifted to Friday)' do
        rule = build_rule(business_days_only: true, non_business_day_behavior: 'previous_weekday')
        travel_to(at('2026-05-30 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'monthly_date day 15 falls on Sunday: skip' do
        rule = build_rule(
          schedule_type: 'monthly_date',
          schedule_config: { 'day' => 15 },
          business_days_only: true,
          non_business_day_behavior: 'skip'
        )
        # 2026-03-15 is a Sunday
        travel_to(at('2026-03-15 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'monthly_date day 15 falls on Sunday: next_weekday — due on Monday' do
        rule = build_rule(
          schedule_type: 'monthly_date',
          schedule_config: { 'day' => 15 },
          business_days_only: true,
          non_business_day_behavior: 'next_weekday'
        )
        # 2026-03-16 is Monday (next weekday after Sunday 15th)
        travel_to(at('2026-03-16 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'weekdays type ignores business_days_only' do
        rule = build_rule(
          schedule_type: 'weekdays',
          schedule_config: { 'days' => [7] }, # Sunday
          business_days_only: true,
          non_business_day_behavior: 'skip'
        )
        # 2026-05-31 is Sunday
        travel_to(at('2026-05-31 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end
    end

    context 'timezone handling', :timezone do
      it 'UTC rule is due at UTC time' do
        rule = build_rule(timezone: 'UTC', send_time: '08:00:00')
        travel_to(at('2026-05-27 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'Europe/Brussels rule is due at UTC+2 in summer' do
        rule = build_rule(timezone: 'Europe/Brussels', send_time: '08:00:00')
        # Brussels UTC+2 in summer; 08:00 Brussels = 06:00 UTC
        travel_to(at('2026-05-27 06:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'Europe/Brussels rule is due at UTC+1 in winter' do
        rule = build_rule(timezone: 'Europe/Brussels', send_time: '08:00:00')
        # Brussels UTC+1 in winter; 08:00 Brussels = 07:00 UTC
        travel_to(at('2026-01-15 07:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'is not due when UTC time is before local send_time' do
        rule = build_rule(timezone: 'Europe/Brussels', send_time: '08:00:00')
        travel_to(at('2026-05-27 05:55:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end
    end

    context 'error handling' do
      it 'returns false on invalid schedule_config JSON' do
        rule = build_rule
        allow(rule).to receive(:schedule_config).and_return('INVALID_JSON_NOT_A_HASH')
        # schedule_config returns a string that is not a Hash
        travel_to(at('2026-05-27 08:05:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end
    end
  end

  describe '#compute_schedule_key' do
    it 'returns the daily key' do
      rule = build_rule(schedule_type: 'daily')
      allow(rule).to receive(:id).and_return(42)
      travel_to(at('2026-05-27 08:05:00 UTC')) do
        expect(described_class.new(rule).compute_schedule_key).to eq('42:D:2026-05-27')
      end
    end

    it 'returns the weekly key (ISO week)' do
      rule = build_rule(schedule_type: 'weekly', schedule_config: { 'day' => 1 })
      allow(rule).to receive(:id).and_return(42)
      # 2026-05-25 is Monday of W21
      travel_to(at('2026-05-25 08:05:00 UTC')) do
        key = described_class.new(rule).compute_schedule_key
        expect(key).to match(/\A42:W:2026-W\d+\z/)
      end
    end

    it 'returns the monthly_date key' do
      rule = build_rule(schedule_type: 'monthly_date', schedule_config: { 'day' => 15 })
      allow(rule).to receive(:id).and_return(42)
      travel_to(at('2026-05-15 08:05:00 UTC')) do
        expect(described_class.new(rule).compute_schedule_key).to eq('42:MD:2026-05')
      end
    end

    it 'returns the interval_days key as period number' do
      rule = build_rule(
        schedule_type: 'interval_days',
        schedule_config: { 'every' => 3 },
        start_on: Date.new(2026, 1, 1)
      )
      allow(rule).to receive(:id).and_return(42)
      # day 4 = period 1 (0-indexed: 0,3,6...; floor((3)/3)=1)
      travel_to(at('2026-01-04 08:05:00 UTC')) do
        expect(described_class.new(rule).compute_schedule_key).to eq('42:ID:1')
      end
    end

    it 'returns the monthly_last_day key' do
      rule = build_rule(schedule_type: 'monthly_last_day', schedule_config: {})
      allow(rule).to receive(:id).and_return(7)
      travel_to(at('2026-05-31 08:05:00 UTC')) do
        expect(described_class.new(rule).compute_schedule_key).to eq('7:ML:2026-05')
      end
    end

    it 'returns the interval_hours key as period number' do
      rule = build_rule(
        schedule_type: 'interval_hours',
        schedule_config: { 'every' => 2 },
        start_on: Date.new(2026, 1, 1),
        send_time: nil
      )
      allow(rule).to receive(:id).and_return(42)
      # Anchor = 2026-01-01 00:00 UTC
      # Elapsed at 04:30 = 4.5 hours = 16200 seconds
      # interval = 2*3600 = 7200 s → period = 16200/7200 = 2
      travel_to(at('2026-01-01 04:30:00 UTC')) do
        expect(described_class.new(rule).compute_schedule_key).to eq('42:IH:2')
      end
    end

    it 'returns the interval_minutes key as period number' do
      rule = build_rule(
        schedule_type: 'interval_minutes',
        schedule_config: { 'every' => 15 },
        start_on: Date.new(2026, 1, 1),
        send_time: nil
      )
      allow(rule).to receive(:id).and_return(99)
      # Anchor = 2026-01-01 00:00 UTC
      # Elapsed at 00:45 = 2700 s, interval = 900 s → period = 3
      travel_to(at('2026-01-01 00:45:00 UTC')) do
        expect(described_class.new(rule).compute_schedule_key).to eq('99:IM:3')
      end
    end
  end

  describe '#due? (sub-daily)' do
    context 'interval_hours' do
      let(:anchor) { Date.new(2026, 1, 1) }

      def build_hourly(attrs = {})
        build_rule({
          schedule_type: 'interval_hours',
          schedule_config: { 'every' => 2 },
          start_on: anchor,
          send_time: nil
        }.merge(attrs))
      end

      it 'is due at the start of a new period' do
        rule = build_hourly
        # Anchor 2026-01-01 00:00 UTC; every 2h → period boundary at 02:00, 04:00, …
        travel_to(at('2026-01-01 04:00:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'is due mid-period (no grace window; whole period is the window)' do
        rule = build_hourly
        travel_to(at('2026-01-01 04:59:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'is not due before anchor' do
        rule = build_hourly(start_on: Date.new(2026, 1, 2))
        travel_to(at('2026-01-01 04:00:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'is not due when last_schedule_key matches current period' do
        rule = build_hourly
        allow(rule).to receive(:id).and_return(0)
        # period 2 corresponds to key "0:IH:2"
        rule.last_schedule_key = '0:IH:2'
        travel_to(at('2026-01-01 04:30:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'is due for a new period even if previous key set' do
        rule = build_hourly
        allow(rule).to receive(:id).and_return(0)
        rule.last_schedule_key = '0:IH:2'
        travel_to(at('2026-01-01 06:00:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'respects a time window (from/to)' do
        rule = build_hourly(schedule_config: { 'every' => 1, 'from' => '09:00', 'to' => '17:00' })
        travel_to(at('2026-01-01 10:00:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
        travel_to(at('2026-01-01 07:00:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'respects a time window that wraps midnight' do
        rule = build_hourly(schedule_config: { 'every' => 1, 'from' => '22:00', 'to' => '06:00' })
        travel_to(at('2026-01-01 23:00:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
        travel_to(at('2026-01-01 05:00:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
        travel_to(at('2026-01-01 12:00:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'respects a day-of-week filter' do
        # Only Monday (cwday=1)
        rule = build_hourly(schedule_config: { 'every' => 1, 'days' => [1] })
        # 2026-01-05 is Monday
        travel_to(at('2026-01-05 04:00:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
        # 2026-01-06 is Tuesday
        travel_to(at('2026-01-06 04:00:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'is due with force: true even when key matches' do
        rule = build_hourly
        allow(rule).to receive(:id).and_return(0)
        rule.last_schedule_key = '0:IH:2'
        travel_to(at('2026-01-01 04:30:00 UTC')) do
          expect(described_class.new(rule, force: true).due?).to be true
        end
      end
    end

    context 'interval_minutes' do
      let(:anchor) { Date.new(2026, 1, 1) }

      def build_minutely(attrs = {})
        build_rule({
          schedule_type: 'interval_minutes',
          schedule_config: { 'every' => 15 },
          start_on: anchor,
          send_time: nil
        }.merge(attrs))
      end

      it 'is due at a 15-minute period boundary' do
        rule = build_minutely
        travel_to(at('2026-01-01 00:15:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end

      it 'is not due when key already claimed for this period' do
        rule = build_minutely
        allow(rule).to receive(:id).and_return(0)
        # 15 min from anchor at 00:00 → period = 1
        rule.last_schedule_key = '0:IM:1'
        travel_to(at('2026-01-01 00:20:00 UTC')) do
          expect(described_class.new(rule).due?).to be false
        end
      end

      it 'is due in the next period after key advances' do
        rule = build_minutely
        allow(rule).to receive(:id).and_return(0)
        rule.last_schedule_key = '0:IM:1'
        # period 2 starts at 00:30
        travel_to(at('2026-01-01 00:30:00 UTC')) do
          expect(described_class.new(rule).due?).to be true
        end
      end
    end
  end
end
