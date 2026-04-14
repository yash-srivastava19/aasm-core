# Contract: skip_validation_on_save respects ActiveRecord optimistic locking
#
# When a model uses both skip_validation_on_save: true AND ActiveRecord's
# lock_version optimistic locking, the state transition must:
#
#   1. Include lock_version in the UPDATE's WHERE clause (compare-and-swap)
#   2. Increment lock_version in the DB on success
#   3. Update lock_version in memory so the object stays consistent
#   4. Raise ActiveRecord::StaleObjectError when the in-memory version doesn't
#      match the DB (concurrent write detected)
#
# Before this fix, aasm_update_column called update_all without any
# lock_version check.  Two concurrent callers could both succeed:
#
#   Thread A: reload → lock=0, guard passes, update_all(status=completed) ✓
#   Thread B: reload → lock=0, guard passes, update_all(status=completed) ✓  ← bug
#
# After this fix, only one succeeds; the other raises StaleObjectError.

# ── Model definitions (inline — don't pollute other specs) ───────────────────

class LockableJobTransition < ActiveRecord::Base
  belongs_to :lockable_job
end

class LockableJob < ActiveRecord::Base
  include AASM

  aasm column: :status, skip_validation_on_save: true do
    state :pending,   initial: true
    state :completed
    state :failed

    event :complete do
      transitions from: :pending, to: :completed, guard: :eligible?
    end

    event :fail do
      transitions from: :pending, to: :failed
    end
  end

  def eligible?
    work_units > 0
  end
end

# ── Specs ─────────────────────────────────────────────────────────────────────

RSpec.describe "Contract: optimistic locking with skip_validation_on_save" do
  before { LockableJobTransition.delete_all; LockableJob.delete_all }

  subject(:job) { LockableJob.create!(work_units: 1000) }

  # ── Happy path ──────────────────────────────────────────────────────────────

  describe "successful transition" do
    it "completes the transition normally" do
      expect { job.complete! }.not_to raise_error
      expect(job.reload.status).to eq('completed')
    end

    it "increments lock_version in the database" do
      expect { job.complete! }
        .to change { LockableJob.find(job.id).lock_version }.by(1)
    end

    it "updates lock_version in memory so the object stays consistent" do
      original = job.lock_version
      job.complete!
      expect(job.lock_version).to eq(original + 1)
    end

    it "writes a transition record" do
      expect { job.complete! }
        .to change { LockableJobTransition.count }.by(1)
    end
  end

  # ── Concurrency protection ──────────────────────────────────────────────────

  describe "stale lock_version" do
    it "raises StaleObjectError when in-memory lock_version is behind the DB" do
      # Simulate a concurrent write: DB version advanced without this object's
      # knowledge.  We test aasm_update_column directly to bypass the reload
      # at the top of aasm_fire_event, which would refresh the version.
      LockableJob.where(id: job.id).update_all(lock_version: 99)

      expect {
        job.send(:aasm_update_column, :status, 'completed')
      }.to raise_error(ActiveRecord::StaleObjectError)
    end

    it "does not write the state column when the lock is stale" do
      LockableJob.where(id: job.id).update_all(lock_version: 99)

      job.send(:aasm_update_column, :status, 'completed') rescue nil

      expect(LockableJob.find(job.id).status).to eq('pending')
    end

    it "does not modify the in-memory lock_version on a stale write attempt" do
      original_in_memory = job.lock_version   # 0
      LockableJob.where(id: job.id).update_all(lock_version: 99)

      job.send(:aasm_update_column, :status, 'completed') rescue nil

      expect(job.lock_version).to eq(original_in_memory)
    end
  end

  # ── Models WITHOUT lock_version are unaffected ──────────────────────────────

  describe "model without lock_version column" do
    it "still transitions successfully (falls back to plain update_all)" do
      plain_job = Job.create!(work_units: 1000)
      expect { plain_job.complete! }.not_to raise_error
      expect(plain_job.reload.status).to eq('completed')
    end
  end
end
