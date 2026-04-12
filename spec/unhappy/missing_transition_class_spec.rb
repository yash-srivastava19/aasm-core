# Unhappy path: transition class is not defined.
#
# When {Model}Transition cannot be found via safe_constantize, audit logging
# is silently skipped — no rows written, no error, no warning.  A developer
# who typos the class name (JobLog vs JobTransition) gets no feedback
# and spends hours debugging an empty audit table.
#
# Contract: emit one Kernel.warn per model class (not per transition) so the
# problem is visible in development and CI logs without spamming production.

RSpec.describe "Unhappy path: missing transition class" do
  # Build a model that has NO corresponding transition class.
  # We use an anonymous subclass so it doesn't pollute other specs.
  let(:klass) do
    Class.new(ActiveRecord::Base) do
      self.table_name = 'jobs'

      include AASM

      aasm column: :status do
        state :pending, initial: true
        state :completed

        event :complete do
          transitions from: :pending, to: :completed
        end
      end

      def self.name; 'OrphanJob'; end
    end
  end

  subject(:record) { klass.create!(work_units: 1000) }

  it "emits a Kernel.warn when no transition class exists" do
    # OrphanJobTransition does not exist — safe_constantize returns nil
    expect(Kernel).to receive(:warn).with(/OrphanJob.*transition class/i).at_least(:once)

    record.complete!
  end

  it "warns only once per model class, not once per transition" do
    warning_count = 0
    allow(Kernel).to receive(:warn) { |msg| warning_count += 1 if msg =~ /OrphanJob/i }

    record.complete!
    klass.create!(work_units: 1000).tap do |r|
      r.complete! rescue nil
    end

    expect(warning_count).to eq(1), "Expected one warning for the class, got #{warning_count}"
  end

  it "still completes the transition successfully (warn, don't raise)" do
    allow(Kernel).to receive(:warn)
    expect { record.complete! }.not_to raise_error
    expect(record.reload.status).to eq('completed')
  end

  it "does not warn when the transition class IS defined (normal path)" do
    expect(Kernel).not_to receive(:warn).with(/transition class/i)

    # Job has JobTransition defined — no warning expected
    Job.create!(work_units: 1000).complete!
  end
end
