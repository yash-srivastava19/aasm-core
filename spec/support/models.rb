require 'aasm'

# ── Transition log ────────────────────────────────────────────────────────────
class PaymentTransition < ActiveRecord::Base
  belongs_to :payment
end

# ── Payment ───────────────────────────────────────────────────────────────────
class Payment < ActiveRecord::Base
  include AASM

  # Test probes — set in specs, cleared in before(:each)
  cattr_accessor :on_paid_probe
  cattr_accessor :before_pay_probe

  aasm column: :status do
    state :pending,  initial: true
    state :paid
    state :failed
    state :refunded

    event :pay do
      before { self.class.before_pay_probe&.call(self) }
      transitions from: :pending, to: :paid, guard: :chargeable?
      after_commit { self.class.on_paid_probe&.call(self) }
    end

    event :fail do
      transitions from: %i[pending paid], to: :failed
    end

    event :refund do
      transitions from: :paid, to: :refunded
    end
  end

  def chargeable?
    amount_cents > 0
  end
end
