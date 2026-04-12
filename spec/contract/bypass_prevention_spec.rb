# Contract: the state column cannot be written outside AASM's machinery
#
# Three bypass vectors exist in vanilla AASM:
#
#   1. payment.status = 'paid'          — direct attribute assignment
#   2. payment.update!(status: 'paid')  — goes through validations but not AASM guards
#   3. payment.update_columns(...)      — skips everything: validations, callbacks, AASM
#
# AASM's built-in `no_direct_assignment: true` only blocks vector 1.
# Vectors 2 and 3 remain open.  This spec defines what the correct contract is.

RSpec.describe "Contract: bypass prevention" do
  subject(:payment) { Payment.create!(amount_cents: 1000) }

  # ── Vector 1: direct attribute assignment ─────────────────────────────────
  # AASM handles this with no_direct_assignment: true.
  # The gem must enable it by default — opt-out, not opt-in.

  describe "direct assignment" do
    it "raises when the state column is assigned directly" do
      expect { payment.status = 'paid' }
        .to raise_error(AASM::NoDirectAssignmentError)
    end

    it "raises even for a valid state value" do
      expect { payment.status = 'pending' }
        .to raise_error(AASM::NoDirectAssignmentError)
    end

    it "does not change the record's state" do
      # NOTE: `obj.attr = val rescue nil` is a Ruby parsing quirk — rescue
      # applies to val, not to the setter call.  Use begin/rescue explicitly.
      begin
        payment.status = 'paid'
      rescue AASM::NoDirectAssignmentError
        nil
      end
      expect(payment.reload.status).to eq('pending')
    end
  end

  # ── Vector 2: update! ──────────────────────────────────────────────────────
  # Goes through AR validations.  A model-level validator must reject this.

  describe "update! with state column" do
    it "raises because update! routes through the setter" do
      expect { payment.update!(status: 'paid') }
        .to raise_error(AASM::NoDirectAssignmentError)
    end

    it "does not persist the change" do
      payment.update!(status: 'paid') rescue nil
      expect(payment.reload.status).to eq('pending')
    end
  end

  # ── Vector 3: update_columns ──────────────────────────────────────────────
  # Skips validations AND callbacks — the most dangerous path.
  # Closing this without a DB-level trigger requires overriding update_columns.
  # The gem must do this.

  describe "update_columns with state column" do
    it "raises an error rather than silently writing state" do
      expect { payment.update_columns(status: 'paid') }
        .to raise_error(RuntimeError, /cannot update state column/)
    end

    it "does not persist the change" do
      payment.update_columns(status: 'paid') rescue nil
      expect(payment.reload.status).to eq('pending')
    end
  end

  # ── Legitimate path ────────────────────────────────────────────────────────

  describe "legitimate transitions" do
    it "succeeds through the event method" do
      expect { payment.pay! }.not_to raise_error
      expect(payment.status).to eq('paid')
    end

    it "can query the current state freely" do
      expect(payment.pending?).to be true
      expect(payment.paid?).to be false
    end
  end
end
