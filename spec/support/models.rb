require 'aasm'

# ── Transition log ────────────────────────────────────────────────────────────
class JobTransition < ActiveRecord::Base
  belongs_to :job
end

# ── Job ───────────────────────────────────────────────────────────────────────
class Job < ActiveRecord::Base
  include AASM

  # Test probes — set in specs, cleared in before(:each)
  cattr_accessor :on_completed_probe
  cattr_accessor :before_complete_probe

  aasm column: :status do
    state :pending,   initial: true
    state :completed
    state :failed
    state :cancelled

    event :complete do
      before { self.class.before_complete_probe&.call(self) }
      transitions from: :pending, to: :completed, guard: :eligible?
      after_commit { self.class.on_completed_probe&.call(self) }
    end

    event :fail do
      transitions from: %i[pending completed], to: :failed
    end

    event :cancel do
      transitions from: :completed, to: :cancelled
    end
  end

  def eligible?
    work_units > 0
  end
end
