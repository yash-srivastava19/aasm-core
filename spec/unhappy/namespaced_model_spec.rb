# Unhappy path: namespaced models produce broken FK and constant lookup.
#
# Bug 1 — Foreign key:
#   self.class.name.underscore + "_id"
#   "Ops::Request".underscore  →  "ops/request"  →  "ops/request_id"
#   The column does not exist.  The correct form is "request_id".
#
# Bug 2 — Constant lookup (minor, works for same-namespace classes but
#   silently misses top-level classes):
#   "#{self.class.name}Transition"  →  "Ops::RequestTransition"
#   This works IF the transition class is namespaced identically.
#   Fails silently if the dev defined top-level RequestTransition instead.
#
# Fix: use self.class.name.demodulize.underscore for the FK (strips namespace),
# and fall back to demodulized constant name so both conventions work.

# ── Namespaced models defined inline ─────────────────────────────────────────

module Ops
  class RequestTransition < ActiveRecord::Base
    self.table_name = 'ops_request_transitions'
    belongs_to :request, class_name: 'Ops::Request'
  end

  class Request < ActiveRecord::Base
    self.table_name = 'ops_requests'

    include AASM

    aasm column: :status do
      state :open,     initial: true
      state :approved
      state :rejected

      event :approve do
        transitions from: :open, to: :approved
      end

      event :reject do
        transitions from: :open, to: :rejected
      end
    end
  end
end

# ── Specs ─────────────────────────────────────────────────────────────────────

RSpec.describe "Unhappy path: namespaced models" do
  subject(:request) { Ops::Request.create!(priority: 1) }

  before { Ops::RequestTransition.delete_all }

  # ── Bypass protection must still work under namespacing ─────────────────

  describe "bypass prevention" do
    it "raises on direct state assignment" do
      expect { request.status = 'approved' }
        .to raise_error(AASM::NoDirectAssignmentError)
    end

    it "allows update_columns as an escape hatch (does not raise)" do
      expect { request.update_columns(status: 'approved') }.not_to raise_error
      expect(request.reload.status).to eq('approved')
    end
  end

  # ── Transition logging must write to the right table with the right FK ───

  describe "audit trail" do
    it "creates a transition record on a successful event" do
      expect { request.approve! }
        .to change { Ops::RequestTransition.count }.by(1)
    end

    it "stores the correct foreign key (request_id, not ops/request_id)" do
      request.approve!

      t = Ops::RequestTransition.last
      expect(t.request_id).to eq(request.id),
        "FK is wrong — likely stored as nil because the column name was " \
        "derived from 'Ops::Request'.underscore → 'ops/request_id', " \
        "which doesn't exist. Fix: use demodulize.underscore."
    end

    it "records correct from_state, to_state, and event" do
      request.approve!

      t = Ops::RequestTransition.last
      expect(t.from_state).to eq('open')
      expect(t.to_state).to  eq('approved')
      expect(t.event).to     eq('approve')
    end

    it "does not create a record when the transition is invalid" do
      request.approve!

      expect { request.approve! rescue nil }
        .not_to change { Ops::RequestTransition.count }
    end
  end

  # ── Guards must work ──────────────────────────────────────────────────────

  describe "transitions" do
    it "follows the full lifecycle" do
      request.approve!
      expect(request.status).to eq('approved')
    end

    it "raises on invalid transition" do
      request.approve!
      expect { request.reject! }.to raise_error(AASM::InvalidTransition)
    end
  end
end
