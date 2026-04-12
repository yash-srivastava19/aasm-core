# Unhappy path: aasm_fire_event reloads the record before evaluating guards.
#
# This is necessary for the guard freshness guarantee — guards must see the
# current DB row, not stale in-memory data.  But it has a side effect that
# surprises developers: any in-memory attribute changes made BEFORE calling
# the event method are silently discarded.
#
#   payment.amount_cents = 999  # in-memory only
#   payment.pay!                # reload! amount_cents reverts to DB value
#   payment.amount_cents        # → original DB value, not 999
#
# This spec:
#   1. Proves the behaviour exists (so it is a KNOWN, documented trade-off)
#   2. Verifies it only affects bang events (non-bang skips reload)
#   3. Verifies non-state columns are also reloaded (full record reload)
#
# The correct approach for callers: persist attribute changes with save!
# BEFORE calling the event, or use a before-hook inside the AASM definition.

RSpec.describe "Unhappy path: reload side effect on bang events" do
  subject(:payment) { Payment.create!(amount_cents: 1000) }

  # ── The side effect ───────────────────────────────────────────────────────

  describe "bang event (pay!) reloads the record before guards run" do
    it "discards in-memory attribute changes made before the event call" do
      payment.instance_variable_set(:@amount_cents_before_pay, payment.amount_cents)

      # Set amount_cents in memory only — do NOT save to DB
      payment.write_attribute(:amount_cents, 5000)
      expect(payment.amount_cents).to eq(5000)  # in-memory: 5000

      payment.pay!

      # After pay!, the record was reloaded — DB value was still 1000
      expect(payment.amount_cents).to eq(1000),
        "In-memory amount_cents (5000) was silently discarded by the reload " \
        "in aasm_fire_event.  Callers must persist attributes before calling " \
        "a bang event, or mutate inside an AASM before-hook."
    end

    it "succeeds when guard-relevant attribute is saved to DB first" do
      payment.update_columns(amount_cents: 5000)

      # Now DB matches intent — reload does not discard anything meaningful
      expect { payment.pay! }.not_to raise_error
      expect(payment.status).to eq('paid')
    end
  end

  # ── Non-bang does NOT reload ──────────────────────────────────────────────

  describe "non-bang event (pay) does not reload" do
    it "preserves in-memory attributes on the non-bang path" do
      payment.write_attribute(:amount_cents, 5000)

      # Non-bang: no persist, so we skip the reload
      payment.pay   # returns true/false, does not persist

      # amount_cents still 5000 in memory — reload never happened
      expect(payment.amount_cents).to eq(5000)
    end
  end

  # ── Guard still enforces DB state, not in-memory state ───────────────────

  describe "guard freshness is maintained regardless of in-memory state" do
    it "uses the reloaded DB value for the guard, not the in-memory value" do
      # In memory: amount_cents = 1000 (chargeable)
      # DB: amount_cents = 0   (not chargeable)
      Payment.where(id: payment.id).update_all(amount_cents: 0)

      # Guard must read DB (0) not in-memory (1000) — should fail
      expect { payment.pay! }.to raise_error(AASM::InvalidTransition)
    end
  end
end
