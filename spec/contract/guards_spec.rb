# Contract: guards
#
# Guards are pure boolean functions.  They decide whether a transition is
# PERMITTED, not what happens as a result.  Two contracts matter here:
#
#   1. A failing guard prevents the transition and leaves state untouched.
#   2. Guards run on FRESH, LOCKED data from the database — not on whatever
#      happens to be in the Ruby object's memory at the time of the call.
#
# Contract 2 is the one vanilla AASM gets wrong under concurrency.  Without a
# pessimistic lock (FOR UPDATE NOWAIT), two concurrent callers can both load
# the record, both pass the guard on their stale in-memory copy, and both
# attempt to write the same transition.  Only one state wins in the DB, but
# both callers believe they succeeded.
#
# The fix: reload the record under a lock before evaluating guards.

RSpec.describe "Contract: guards" do
  # ── Failing guard ──────────────────────────────────────────────────────────

  describe "when a guard returns false" do
    subject(:job) { Job.create!(work_units: 0) }   # not eligible

    it "raises AASM::InvalidTransition on the bang method" do
      expect { job.complete! }.to raise_error(AASM::InvalidTransition)
    end

    it "returns false (not raises) on the non-bang method" do
      expect(job.complete).to be false
    end

    it "leaves the state column unchanged" do
      job.complete rescue nil
      expect(job.reload.status).to eq('pending')
    end

    it "does not run the before hook" do
      before_ran = false
      Job.before_complete_probe = ->(_) { before_ran = true }

      job.complete rescue nil

      expect(before_ran).to be false
    end

    it "does not fire after_commit" do
      fired = false
      Job.on_completed_probe = ->(_) { fired = true }

      job.complete rescue nil

      expect(fired).to be false
    end
  end

  # ── Passing guard ──────────────────────────────────────────────────────────

  describe "when a guard returns true" do
    subject(:job) { Job.create!(work_units: 1000) }

    it "allows the transition" do
      expect { job.complete! }.not_to raise_error
      expect(job.status).to eq('completed')
    end
  end

  # ── THE CRITICAL CONTRACT: guards must see fresh DB state ─────────────────
  #
  # Scenario: a record is loaded into memory with stale data.
  # The DB is then updated directly (simulating another process).
  # The guard must read from the DB, not from stale in-memory data.
  #
  # Note: SQLite does not support FOR UPDATE row locking.  True concurrent
  # isolation (preventing TOCTOU races between the reload and the write)
  # requires PostgreSQL with requires_lock: 'FOR UPDATE NOWAIT' in the aasm
  # config.  This spec tests the freshness guarantee only.

  describe "guards run on fresh database state (not stale in-memory)" do
    subject(:job) { Job.create!(work_units: 0) }   # stale: not eligible

    it "reloads the record before evaluating guards" do
      # Update the DB behind the in-memory object's back
      Job.where(id: job.id).update_all(work_units: 1000)

      # In memory: work_units is still 0 — guard would fail on stale data
      expect(job.work_units).to eq(0)

      # Correct behavior: reload before guards → reads 1000 → passes
      expect { job.complete! }.not_to raise_error,
        "Guard evaluated stale in-memory data instead of reloading from DB."
    end

    it "reflects the current DB state in guard evaluation, not the object's memory" do
      Job.where(id: job.id).update_all(work_units: 1000)

      # bang method — triggers reload + persist
      job.complete!

      expect(job.reload.status).to eq('completed')
    end
  end

  # ── Guard does not produce side effects ────────────────────────────────────
  #
  # can_transition_to? calls guards without performing a transition.
  # Guards must be safe to call multiple times with no observable effect.

  describe "guards are idempotent (no side effects)" do
    subject(:job) { Job.create!(work_units: 1000) }

    it "can be checked via may_complete? without changing state" do
      expect(job.may_complete?).to be true
      expect(job.reload.status).to eq('pending')
    end

    it "can be called multiple times without consequence" do
      3.times { job.may_complete? }
      expect(job.reload.status).to eq('pending')
    end
  end
end
