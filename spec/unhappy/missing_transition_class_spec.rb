# Unhappy path: transition class is not defined.
#
# When {Model}Transition cannot be found via safe_constantize, audit logging
# is silently skipped — no rows written, no error, no warning.  A developer
# who typos the class name (PaymentLog vs PaymentTransition) gets no feedback
# and spends hours debugging an empty audit table.
#
# Contract: emit one Kernel.warn per model class (not per transition) so the
# problem is visible in development and CI logs without spamming production.

RSpec.describe "Unhappy path: missing transition class" do
  # Build a model that has NO corresponding transition class.
  # We use an anonymous subclass so it doesn't pollute other specs.
  let(:klass) do
    Class.new(ActiveRecord::Base) do
      self.table_name = 'payments'

      include AASM

      aasm column: :status do
        state :pending, initial: true
        state :paid

        event :pay do
          transitions from: :pending, to: :paid
        end
      end

      def self.name; 'OrphanPayment'; end
    end
  end

  subject(:record) { klass.create!(amount_cents: 1000) }

  it "emits a Kernel.warn when no transition class exists" do
    # OrphanPaymentTransition does not exist — safe_constantize returns nil
    expect(Kernel).to receive(:warn).with(/OrphanPayment.*transition class/i).at_least(:once)

    record.pay!
  end

  it "warns only once per model class, not once per transition" do
    warning_count = 0
    allow(Kernel).to receive(:warn) { |msg| warning_count += 1 if msg =~ /OrphanPayment/i }

    record.pay!
    klass.create!(amount_cents: 1000).tap do |r|
      r.pay! rescue nil
    end

    expect(warning_count).to eq(1), "Expected one warning for the class, got #{warning_count}"
  end

  it "still completes the transition successfully (warn, don't raise)" do
    allow(Kernel).to receive(:warn)
    expect { record.pay! }.not_to raise_error
    expect(record.reload.status).to eq('paid')
  end

  it "does not warn when the transition class IS defined (normal path)" do
    expect(Kernel).not_to receive(:warn).with(/transition class/i)

    # Payment has PaymentTransition defined — no warning expected
    Payment.create!(amount_cents: 1000).pay!
  end
end
