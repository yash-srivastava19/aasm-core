# Contract: aasm_transition_metadata hook enriches the audit log
#
# By default, the transition log records from_state, to_state, and event.
# aasm_transition_metadata is an overrideable hook that lets models attach
# arbitrary JSON context to each log entry — who triggered the transition,
# why, from which IP, with which idempotency key, etc.
#
# The hook is:
#   - optional (default returns {}, no metadata written)
#   - safe when the transition table has no metadata column (no error)
#   - called with (from_state, to_state, event_name) so models can vary
#     metadata by transition type
#
# The metadata column must be present in the transition table for the hook's
# output to be persisted.  The job_transitions table already has it.

# ── Inline model for the "no metadata column" fallback test ──────────────────
# Uses ops_requests / ops_request_transitions (no metadata column).
# Namespaced under Testing:: so the FK derivation (request_id) matches the
# existing table column.

module Testing
  class RequestTransition < ActiveRecord::Base
    self.table_name = 'ops_request_transitions'
  end

  class Request < ActiveRecord::Base
    self.table_name = 'ops_requests'
    include AASM
    aasm column: :status do
      state :open,     initial: true
      state :approved
      event :approve do
        transitions from: :open, to: :approved
      end
    end
  end
end

# ── Specs ─────────────────────────────────────────────────────────────────────

RSpec.describe "Contract: transition metadata hook" do
  # ── Default (no override) writes no metadata ─────────────────────────────

  describe "default behaviour" do
    subject(:job) { Job.create!(work_units: 1000) }

    it "transitions successfully without a metadata override" do
      expect { job.complete! }.not_to raise_error
    end

    it "writes the standard transition fields" do
      job.complete!
      t = JobTransition.last
      expect(t.from_state).to eq('pending')
      expect(t.to_state).to   eq('completed')
      expect(t.event).to      eq('complete')
    end

    it "leaves metadata as the column default (empty object) when hook returns {}" do
      job.complete!
      # Column default is '{}' — hook returned {} so nothing was overwritten
      expect(JobTransition.last.metadata).to eq('{}')
    end
  end

  # ── Override via singleton method writes JSON context ────────────────────

  describe "with aasm_transition_metadata overridden on the instance" do
    subject(:job) do
      j = Job.create!(work_units: 1000)
      j.define_singleton_method(:aasm_transition_metadata) do |from, to, evt|
        { actor: 'scheduler', reason: 'automated', transition: "#{from}→#{to}" }
      end
      j
    end

    it "persists the hook's return value as JSON in the metadata column" do
      job.complete!

      data = JSON.parse(JobTransition.last.metadata)
      expect(data['actor']).to      eq('scheduler')
      expect(data['reason']).to     eq('automated')
      expect(data['transition']).to eq('pending→completed')
    end

    it "receives the correct (from_state, to_state, event_name) arguments" do
      captured = []
      job.define_singleton_method(:aasm_transition_metadata) do |from, to, evt|
        captured << [from, to, evt]
        {}
      end

      job.complete!

      expect(captured).to eq([[:pending, :completed, :complete]])
    end

    it "is called for every transition with the right arguments" do
      payloads = []
      job.define_singleton_method(:aasm_transition_metadata) do |from, to, evt|
        payloads << "#{from}→#{to}:#{evt}"
        { transition: "#{from}→#{to}" }
      end

      job.complete!
      job.cancel!

      expect(payloads).to eq(['pending→completed:complete', 'completed→cancelled:cancel'])

      records = JobTransition.order(:created_at).last(2)
      transitions = records.map { |r| JSON.parse(r.metadata)['transition'] }
      expect(transitions).to eq(%w[pending→completed completed→cancelled])
    end
  end

  # ── Safe when metadata column is absent ──────────────────────────────────
  #
  # Teams that haven't added a metadata column to their transition table
  # must not see an error — the hook output is silently skipped.

  describe "graceful fallback when no metadata column exists" do
    before { Testing::RequestTransition.delete_all }

    subject(:request) { Testing::Request.create!(priority: 1) }

    it "skips the metadata write without raising" do
      expect { request.approve! }.not_to raise_error
    end

    it "still writes the standard transition fields" do
      request.approve!

      t = Testing::RequestTransition.last
      expect(t.from_state).to eq('open')
      expect(t.to_state).to   eq('approved')
    end

    it "does not error even when the override returns a non-empty hash" do
      request.define_singleton_method(:aasm_transition_metadata) do |from, to, evt|
        { actor: 'operator', note: 'manual approval' }
      end

      expect { request.approve! }.not_to raise_error
    end
  end
end
