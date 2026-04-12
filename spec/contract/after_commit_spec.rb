# Contract: after_commit fires after the REAL outermost transaction commit
#
# Vanilla AASM simulates after_commit by firing immediately after its own
# internal transaction {} block closes — which is only a SAVEPOINT when
# nested inside an outer transaction.  This means:
#
#   - after_commit runs while the outer transaction is still open
#   - if the outer transaction rolls back, the callback already fired
#   - external side-effects (jobs, ledger writes) happen on uncommitted data
#
# This spec defines the correct contract.  Run it against vanilla AASM and
# watch it fail.  That is the proof the bug exists.

RSpec.describe "Contract: after_commit" do
  subject(:payment) { Payment.create!(amount_cents: 1000) }

  # ── Basic firing ────────────────────────────────────────────────────────────

  describe "fires after a successful transition" do
    it "calls the after_commit block" do
      fired = false
      Payment.on_paid_probe = ->(_) { fired = true }

      payment.pay!

      expect(fired).to be true
    end

    it "fires exactly once per transition" do
      count = 0
      Payment.on_paid_probe = ->(_) { count += 1 }

      payment.pay!

      expect(count).to eq(1)
    end
  end

  # ── Must NOT fire on failure ─────────────────────────────────────────────

  describe "does NOT fire when the transition cannot proceed" do
    it "is silent when the event is invalid for the current state" do
      fired = false
      Payment.on_paid_probe = ->(_) { fired = true }

      payment.fail!
      expect { payment.pay! }.to raise_error(AASM::InvalidTransition)

      expect(fired).to be false
    end

    it "is silent when a guard fails" do
      payment.update_columns(amount_cents: 0)
      fired = false
      Payment.on_paid_probe = ->(_) { fired = true }

      expect { payment.pay! }.to raise_error(AASM::InvalidTransition)

      expect(fired).to be false
    end

    it "is silent and rolls back when the before hook raises" do
      Payment.before_pay_probe = ->(_) { raise "fee engine down" }
      fired = false
      Payment.on_paid_probe = ->(_) { fired = true }

      expect { payment.pay! }.to raise_error("fee engine down")

      expect(fired).to be false
      expect(payment.reload.status).to eq("pending")
    end
  end

  # ── THE CRITICAL CONTRACT ────────────────────────────────────────────────
  #
  # This is the test vanilla AASM fails.
  # It proves that after_commit is not truly after commit.

  describe "nested transaction correctness" do
    it "does NOT fire while still inside an outer transaction" do
      sequence = []
      Payment.on_paid_probe = ->(_) { sequence << :callback }

      ActiveRecord::Base.transaction do
        payment.pay!
        sequence << :still_inside_outer_tx
      end
      sequence << :after_outer_tx

      # Correct order:  [:still_inside_outer_tx, :callback, :after_outer_tx]
      #                 or [:still_inside_outer_tx, :after_outer_tx, :callback]
      #
      # Broken order:   [:callback, :still_inside_outer_tx, :after_outer_tx]
      #                 ← vanilla AASM does this

      expect(sequence.index(:callback)).to be > sequence.index(:still_inside_outer_tx),
        "after_commit fired INSIDE the outer transaction.\n" \
        "Sequence: #{sequence.inspect}\n" \
        "This is the vanilla AASM bug: it fires at SAVEPOINT release, " \
        "not at the outermost transaction commit."
    end

    it "does NOT fire if the outer transaction rolls back" do
      payment  # create the record BEFORE the outer transaction so rollback
               # only undoes the pay! state change, not the record itself
      fired = false
      Payment.on_paid_probe = ->(_) { fired = true }

      ActiveRecord::Base.transaction do
        payment.pay!
        raise ActiveRecord::Rollback
      end

      expect(fired).to be false
      expect(payment.reload.status).to eq("pending")
    end

    it "fires once the outer transaction commits, even with multiple nesting levels" do
      sequence = []
      Payment.on_paid_probe = ->(_) { sequence << :callback }

      ActiveRecord::Base.transaction do          # level 1
        ActiveRecord::Base.transaction do        # level 2 (savepoint)
          payment.pay!
        end
        sequence << :exited_level_2
      end                                        # real commit here
      sequence << :exited_level_1

      expect(sequence.index(:callback)).to be > sequence.index(:exited_level_2),
        "Callback fired before level-1 (outermost) transaction committed.\n" \
        "Sequence: #{sequence.inspect}"
    end
  end
end
