# Contract: the state column cannot be written outside AASM's machinery
#
# Two bypass vectors are blocked in this fork:
#
#   1. job.status = 'completed'          — direct attribute assignment (blocked)
#   2. job.update!(status: 'completed')  — routes through setter (blocked)
#
# One vector is intentionally left open as an escape hatch:
#
#   3. job.update_columns(...)      — allowed
#
# Rationale for (3): update_columns is already a deliberate, explicit call
# that the caller uses knowing it skips validations and callbacks. Blocking it
# creates a painful situation in production incidents when an engineer needs to
# correct bad state from the console. The setter override (1) protects against
# accidental code-level assignment. update_columns is for intentional
# operator-level corrections.

RSpec.describe "Contract: bypass prevention" do
  subject(:job) { Job.create!(work_units: 1000) }

  # ── Vector 1: direct attribute assignment ─────────────────────────────────
  # AASM handles this with no_direct_assignment: true.
  # The gem enables it by default — opt-out, not opt-in.

  describe "direct assignment" do
    it "raises when the state column is assigned directly" do
      expect { job.status = 'completed' }
        .to raise_error(AASM::NoDirectAssignmentError)
    end

    it "raises even for a valid state value" do
      expect { job.status = 'pending' }
        .to raise_error(AASM::NoDirectAssignmentError)
    end

    it "does not change the record's state" do
      # NOTE: `obj.attr = val rescue nil` is a Ruby parsing quirk — rescue
      # applies to val, not to the setter call.  Use begin/rescue explicitly.
      begin
        job.status = 'completed'
      rescue AASM::NoDirectAssignmentError
        nil
      end
      expect(job.reload.status).to eq('pending')
    end
  end

  # ── Vector 2: update! ──────────────────────────────────────────────────────
  # Goes through AR validations and routes through the setter.

  describe "update! with state column" do
    it "raises because update! routes through the setter" do
      expect { job.update!(status: 'completed') }
        .to raise_error(AASM::NoDirectAssignmentError)
    end

    it "does not persist the change" do
      job.update!(status: 'completed') rescue nil
      expect(job.reload.status).to eq('pending')
    end
  end

  # ── Vector 3: update_columns — intentional escape hatch ──────────────────
  # Allowed by design. For production incident recovery from the console.

  describe "update_columns with state column" do
    it "succeeds — update_columns is an intentional operator escape hatch" do
      expect { job.update_columns(status: 'completed') }.not_to raise_error
    end

    it "persists the new state directly (bypasses AASM machinery by design)" do
      job.update_columns(status: 'completed')
      expect(job.reload.status).to eq('completed')
    end
  end

  # ── Legitimate path ────────────────────────────────────────────────────────

  describe "legitimate transitions" do
    it "succeeds through the event method" do
      expect { job.complete! }.not_to raise_error
      expect(job.status).to eq('completed')
    end

    it "can query the current state freely" do
      expect(job.pending?).to be true
      expect(job.completed?).to be false
    end
  end
end
