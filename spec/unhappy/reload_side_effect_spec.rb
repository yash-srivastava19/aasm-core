# Unhappy path: aasm_fire_event reloads the record before evaluating guards.
#
# This is necessary for the guard freshness guarantee — guards must see the
# current DB row, not stale in-memory data.  But it has a side effect that
# surprises developers: any in-memory attribute changes made BEFORE calling
# the event method are silently discarded.
#
#   job.work_units = 999  # in-memory only
#   job.complete!         # reload! work_units reverts to DB value
#   job.work_units        # → original DB value, not 999
#
# This spec:
#   1. Proves the behaviour exists (so it is a KNOWN, documented trade-off)
#   2. Verifies it only affects bang events (non-bang skips reload)
#   3. Verifies non-state columns are also reloaded (full record reload)
#
# The correct approach for callers: persist attribute changes with save!
# BEFORE calling the event, or use a before-hook inside the AASM definition.

RSpec.describe "Unhappy path: reload side effect on bang events" do
  subject(:job) { Job.create!(work_units: 1000) }

  # ── The side effect ───────────────────────────────────────────────────────

  describe "bang event (complete!) reloads the record before guards run" do
    it "discards in-memory attribute changes made before the event call" do
      job.instance_variable_set(:@work_units_before_complete, job.work_units)

      # Set work_units in memory only — do NOT save to DB
      job.write_attribute(:work_units, 5000)
      expect(job.work_units).to eq(5000)  # in-memory: 5000

      job.complete!

      # After complete!, the record was reloaded — DB value was still 1000
      expect(job.work_units).to eq(1000),
        "In-memory work_units (5000) was silently discarded by the reload " \
        "in aasm_fire_event.  Callers must persist attributes before calling " \
        "a bang event, or mutate inside an AASM before-hook."
    end

    it "succeeds when guard-relevant attribute is saved to DB first" do
      job.update_columns(work_units: 5000)

      # Now DB matches intent — reload does not discard anything meaningful
      expect { job.complete! }.not_to raise_error
      expect(job.status).to eq('completed')
    end
  end

  # ── Non-bang does NOT reload ──────────────────────────────────────────────

  describe "non-bang event (complete) does not reload" do
    it "preserves in-memory attributes on the non-bang path" do
      job.write_attribute(:work_units, 5000)

      # Non-bang: no persist, so we skip the reload
      job.complete   # returns true/false, does not persist

      # work_units still 5000 in memory — reload never happened
      expect(job.work_units).to eq(5000)
    end
  end

  # ── Guard still enforces DB state, not in-memory state ───────────────────

  describe "guard freshness is maintained regardless of in-memory state" do
    it "uses the reloaded DB value for the guard, not the in-memory value" do
      # In memory: work_units = 1000 (eligible)
      # DB: work_units = 0   (not eligible)
      Job.where(id: job.id).update_all(work_units: 0)

      # Guard must read DB (0) not in-memory (1000) — should fail
      expect { job.complete! }.to raise_error(AASM::InvalidTransition)
    end
  end
end
