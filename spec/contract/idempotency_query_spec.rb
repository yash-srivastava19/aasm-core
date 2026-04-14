# Contract: aasm_has_transitioned_to? enables idempotent event handling
#
# Async job processors retry on failure.  Without idempotency, a retry
# after a partial failure (e.g. DB written, webhook failed) causes a
# double-execution of the same transition.
#
# aasm_has_transitioned_to? queries the transition log — committed DB state —
# so a processor can check "did we already do this?" before calling an event.
# This turns any AASM-backed model into an idempotency-safe processing target
# without a separate idempotency log table.
#
# Contract:
#   - Returns false before any transition has occurred
#   - Returns true after a successful transition reaches target_state
#   - Optionally filters by event name (multiple events → same state)
#   - Returns false (not error) when no transition class is defined

RSpec.describe "Contract: idempotency query" do
  subject(:job) { Job.create!(work_units: 1000) }

  # ── Basic behaviour ─────────────────────────────────────────────────────────

  describe "before any transition" do
    it "returns false for the initial state" do
      expect(job.aasm_has_transitioned_to?(:pending)).to be false
    end

    it "returns false for any state that has not been reached" do
      expect(job.aasm_has_transitioned_to?(:completed)).to be false
      expect(job.aasm_has_transitioned_to?(:failed)).to be false
    end
  end

  describe "after a successful transition" do
    before { job.complete! }

    it "returns true for the state that was reached" do
      expect(job.aasm_has_transitioned_to?(:completed)).to be true
    end

    it "returns false for states not yet reached" do
      expect(job.aasm_has_transitioned_to?(:failed)).to be false
      expect(job.aasm_has_transitioned_to?(:cancelled)).to be false
    end

    it "is queryable across multiple transitions" do
      job.cancel!

      expect(job.aasm_has_transitioned_to?(:completed)).to be true
      expect(job.aasm_has_transitioned_to?(:cancelled)).to be true
    end
  end

  # ── Event-name filter ────────────────────────────────────────────────────────

  describe "with event_name filter" do
    before { job.complete! }

    it "returns true when the state was reached via the given event" do
      expect(job.aasm_has_transitioned_to?(:completed, :complete)).to be true
    end

    it "returns false when the state was reached via a different event" do
      # :failed can be reached via :fail — not via :complete
      job2 = Job.create!(work_units: 1000)
      job2.fail!

      expect(job2.aasm_has_transitioned_to?(:failed, :complete)).to be false
      expect(job2.aasm_has_transitioned_to?(:failed, :fail)).to be true
    end
  end

  # ── Idempotency pattern ──────────────────────────────────────────────────────
  #
  # This is the primary use case: a retried job processor uses the query to
  # skip re-execution without a separate idempotency table.

  describe "idempotent processor pattern" do
    it "allows safe retry — second call sees the completed transition and returns early" do
      call_count = 0

      process = lambda do |j|
        return if j.aasm_has_transitioned_to?(:completed)
        j.complete!
        call_count += 1
      end

      process.call(job)   # first call — transitions and writes log
      process.call(job)   # second call (retry) — returns early

      expect(call_count).to eq(1)
      expect(JobTransition.where(job_id: job.id).count).to eq(1)
    end

    it "processes normally when the transition has not yet happened" do
      expect(job.aasm_has_transitioned_to?(:completed)).to be false
      job.complete!
      expect(job.aasm_has_transitioned_to?(:completed)).to be true
    end
  end

  # ── Missing transition class ─────────────────────────────────────────────────

  describe "when no transition class is defined" do
    let(:orphan_class) do
      Class.new(ActiveRecord::Base) do
        self.table_name = 'jobs'
        include AASM
        aasm column: :status do
          state :pending, initial: true
          state :completed
          event :complete do
            transitions from: :pending, to: :completed
          end
        end
        def self.name; 'OrphanJob'; end
      end
    end

    subject(:orphan) { orphan_class.create!(work_units: 1000) }

    it "returns false instead of raising" do
      allow(Kernel).to receive(:warn)  # suppress the missing-class warning
      expect(orphan.aasm_has_transitioned_to?(:completed)).to be false
    end
  end
end
