# Unhappy path: a before-hook fires a second AASM event on the same thread.
#
# This is real. A payment's before hook might call `order.ship!`, or a
# ledger's before hook might archive an old entry. The inner event runs
# inside the outer event's call stack — specifically BEFORE aasm_write_state
# runs for the outer event.
#
# The bug (guard_order.rb ensure):
#
#   Thread.current[:aasm_core_current_event] = :pay   # outer sets it
#   super                                              # inner event fires here
#     → inner sets it to :fail
#     → inner's ensure resets it to nil               # ← outer context wiped
#   aasm_write_state (outer) reads nil → logs event: ""
#
# The fix: save/restore instead of reset-to-nil in ensure.

RSpec.describe "Unhappy path: re-entrant events in callbacks" do
  let(:outer) { Payment.create!(amount_cents: 1000) }
  let(:inner) { Payment.create!(amount_cents: 1000) }

  after { Payment.before_pay_probe = nil }

  # ── Inner event succeeds ─────────────────────────────────────────────────

  describe "inner event fires inside the before hook of an outer event" do
    before do
      # :pay's before hook fires :fail on a different Payment record.
      # :fail has no guards, so it always succeeds immediately.
      # The inner event's ensure block runs before the outer's aasm_write_state.
      Payment.before_pay_probe = ->(_) { inner.fail! }
    end

    it "logs the correct event name ('pay') for the outer transition" do
      outer.pay!

      log = PaymentTransition.find_by(payment_id: outer.id)
      expect(log.event).to eq('pay'),
        "Outer event logged as #{log.event.inspect}.\n" \
        "The inner event's ensure reset :aasm_core_current_event to nil before\n" \
        "the outer aasm_write_state ran. Fix: save/restore, not reset."
    end

    it "logs the correct event name ('fail') for the inner transition" do
      outer.pay!

      log = PaymentTransition.find_by(payment_id: inner.id)
      expect(log.event).to eq('fail')
    end

    it "creates exactly one transition record per payment" do
      outer.pay!

      expect(PaymentTransition.where(payment_id: outer.id).count).to eq(1)
      expect(PaymentTransition.where(payment_id: inner.id).count).to eq(1)
    end
  end

  # ── Inner guard fails (ensure clears outer context even without setting it) ──
  #
  # Even when the inner event's guard fails, our method is entered, the ensure
  # runs, and it resets the thread-local to nil — wiping the outer event's name.

  describe "inner guard fails inside the before hook of an outer event" do
    before do
      unchargeable = Payment.create!(amount_cents: 0)
      Payment.before_pay_probe = ->(_) { unchargeable.pay rescue nil }
    end

    it "does not corrupt the outer event name when the inner guard fails" do
      outer.pay!

      log = PaymentTransition.find_by(payment_id: outer.id)
      expect(log.event).to eq('pay'),
        "Outer event logged as #{log.event.inspect}.\n" \
        "When the inner guard fails we early-return WITHOUT setting the\n" \
        "thread-local, but ensure still resets it to nil — clearing the\n" \
        "outer event's context. Fix: save before guard check, restore in ensure."
    end

    it "does not create a transition record for the failed inner attempt" do
      unchargeable = Payment.create!(amount_cents: 0)
      Payment.before_pay_probe = ->(_) { unchargeable.pay rescue nil }

      outer.pay!

      expect(PaymentTransition.where(payment_id: unchargeable.id).count).to eq(0)
    end
  end
end
