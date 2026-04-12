# Contract: every state change produces an immutable transition record
#
# Borrowed from Statesman's core insight: the transition LOG is the source of
# truth, not just the status column.  Every successful transition writes one
# row to payment_transitions in the SAME database transaction as the state
# column update.  They are atomic — you never get one without the other.
#
# This gives you:
#   - a full audit trail for free (no extra effort from the developer)
#   - proof that a rollback undoes both the state change and the log entry
#   - a queryable history for compliance, debugging, and support

RSpec.describe "Contract: audit trail" do
  subject(:payment) { Payment.create!(amount_cents: 1000) }

  # ── A record is written on every successful transition ───────────────────

  describe "transition record creation" do
    it "creates one PaymentTransition per successful event" do
      expect { payment.pay! }
        .to change { PaymentTransition.count }.by(1)
    end

    it "records the correct from_state, to_state, and event name" do
      payment.pay!
      t = PaymentTransition.last

      expect(t.from_state).to eq('pending')
      expect(t.to_state).to  eq('paid')
      expect(t.event).to     eq('pay')
    end

    it "records a timestamp" do
      freeze = Time.now
      payment.pay!

      expect(PaymentTransition.last.created_at).to be_within(2).of(freeze)
    end

    it "records the parent FK so history is queryable per record" do
      payment.pay!
      expect(PaymentTransition.last.payment_id).to eq(payment.id)
    end
  end

  # ── Atomicity: log entry and state column live or die together ───────────

  describe "atomicity with the state column" do
    it "does NOT write a transition record when a guard fails" do
      payment.update_columns(amount_cents: 0)   # bypass for setup only

      expect { payment.pay! rescue nil }
        .not_to change { PaymentTransition.count }
    end

    it "does NOT write a transition record when the transition is invalid" do
      payment.fail!   # move to :failed first

      expect { payment.pay! rescue nil }
        .not_to change { PaymentTransition.count }
    end

    it "does NOT write a transition record when the before hook raises" do
      Payment.before_pay_probe = ->(_) { raise "payment gateway timeout" }

      expect { payment.pay! rescue nil }
        .not_to change { PaymentTransition.count }

      expect(payment.reload.status).to eq('pending')
    end

    it "rolls back the transition record if the outer transaction rolls back" do
      payment  # create the record BEFORE the outer transaction
      ActiveRecord::Base.transaction do
        payment.pay!
        expect(PaymentTransition.count).to eq(1)   # written inside the tx
        raise ActiveRecord::Rollback
      end

      # Both the state column AND the log entry must be rolled back
      expect(PaymentTransition.count).to eq(0)
      expect(payment.reload.status).to eq('pending')
    end
  end

  # ── History across multiple transitions ──────────────────────────────────

  describe "full lifecycle history" do
    it "appends one record per transition, in order" do
      payment.pay!
      payment.refund!

      history = PaymentTransition
                  .where(payment_id: payment.id)
                  .order(:created_at)

      expect(history.map(&:to_state)).to eq(%w[paid refunded])
    end

    it "never updates or deletes existing records — append only" do
      payment.pay!
      first_id = PaymentTransition.last.id

      payment.refund!

      # The original record must be untouched
      expect(PaymentTransition.find(first_id).to_state).to eq('paid')
      expect(PaymentTransition.count).to eq(2)
    end
  end
end
