# Unhappy path: namespaced models produce broken FK and constant lookup.
#
# Bug 1 — Foreign key:
#   self.class.name.underscore + "_id"
#   "Billing::Invoice".underscore  →  "billing/invoice"  →  "billing/invoice_id"
#   The column does not exist.  The correct form is "invoice_id".
#
# Bug 2 — Constant lookup (minor, works for same-namespace classes but
#   silently misses top-level classes):
#   "#{self.class.name}Transition"  →  "Billing::InvoiceTransition"
#   This works IF the transition class is namespaced identically.
#   Fails silently if the dev defined top-level InvoiceTransition instead.
#
# Fix: use self.class.model_name.singular for the FK (Rails strips namespace),
# and fall back to demodulized constant name so both conventions work.

# ── Namespaced models defined inline ─────────────────────────────────────────

module Billing
  class InvoiceTransition < ActiveRecord::Base
    self.table_name = 'billing_invoice_transitions'
    belongs_to :invoice, class_name: 'Billing::Invoice'
  end

  class Invoice < ActiveRecord::Base
    self.table_name = 'billing_invoices'

    include AASM
    include AASM::Core

    aasm column: :status do
      state :draft,    initial: true
      state :approved
      state :rejected

      event :approve do
        transitions from: :draft, to: :approved
      end

      event :reject do
        transitions from: :draft, to: :rejected
      end
    end
  end
end

# ── Specs ─────────────────────────────────────────────────────────────────────

RSpec.describe "Unhappy path: namespaced models" do
  subject(:invoice) { Billing::Invoice.create!(amount_cents: 500) }

  before { Billing::InvoiceTransition.delete_all }

  # ── Bypass protection must still work under namespacing ─────────────────

  describe "bypass prevention" do
    it "raises on direct state assignment" do
      expect { invoice.status = 'approved' }
        .to raise_error(AASM::NoDirectAssignmentError)
    end

    it "raises on update_columns with the state column" do
      expect { invoice.update_columns(status: 'approved') }
        .to raise_error(RuntimeError, /cannot update state column/)
    end
  end

  # ── Transition logging must write to the right table with the right FK ───

  describe "audit trail" do
    it "creates a transition record on a successful event" do
      expect { invoice.approve! }
        .to change { Billing::InvoiceTransition.count }.by(1)
    end

    it "stores the correct foreign key (invoice_id, not billing/invoice_id)" do
      invoice.approve!

      t = Billing::InvoiceTransition.last
      expect(t.invoice_id).to eq(invoice.id),
        "FK is wrong — likely stored as nil because the column name was " \
        "derived from 'Billing::Invoice'.underscore → 'billing/invoice_id', " \
        "which doesn't exist. Fix: use model_name.singular."
    end

    it "records correct from_state, to_state, and event" do
      invoice.approve!

      t = Billing::InvoiceTransition.last
      expect(t.from_state).to eq('draft')
      expect(t.to_state).to  eq('approved')
      expect(t.event).to     eq('approve')
    end

    it "does not create a record when the transition is invalid" do
      invoice.approve!

      expect { invoice.approve! rescue nil }
        .not_to change { Billing::InvoiceTransition.count }
    end
  end

  # ── Guards must work ──────────────────────────────────────────────────────

  describe "transitions" do
    it "follows the full lifecycle" do
      invoice.approve!
      expect(invoice.status).to eq('approved')
    end

    it "raises on invalid transition" do
      invoice.approve!
      expect { invoice.reject! }.to raise_error(AASM::InvalidTransition)
    end
  end
end
