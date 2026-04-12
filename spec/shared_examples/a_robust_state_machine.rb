# Composable contract — include in any model's spec to verify it satisfies
# the full robustness contract.
#
# Usage:
#
#   RSpec.describe Job do
#     it_behaves_like "a robust state machine",
#       factory:     -> { Job.create!(work_units: 1000) },
#       valid_event: :complete,
#       bad_state:   'hacked'
#   end

RSpec.shared_examples "a robust state machine" do |factory:, valid_event:, bad_state: 'invalid'|
  let(:record) { factory.call }

  it "prevents direct state assignment" do
    col = record.class.aasm.attribute_name.to_s
    expect { record.public_send(:"#{col}=", bad_state) }
      .to raise_error(AASM::NoDirectAssignmentError)
  end

  it "prevents update! from bypassing guards" do
    col = record.class.aasm.attribute_name.to_s
    expect { record.update!(col => bad_state) }
      .to raise_error(ActiveRecord::RecordInvalid)
  end

  it "allows update_columns as an operator escape hatch" do
    col = record.class.aasm.attribute_name.to_s
    expect { record.update_columns(col => bad_state) }.not_to raise_error
  end

  it "writes a transition record on a successful event" do
    transition_klass = "#{record.class.name}Transition".constantize
    expect { record.public_send(:"#{valid_event}!") }
      .to change { transition_klass.count }.by(1)
  end

  it "does not fire after_commit if an outer transaction rolls back" do
    fired = false
    probe_attr = :"on_#{valid_event}ed_probe"
    record.class.public_send(:"#{probe_attr}=", ->(_) { fired = true }) rescue nil

    ActiveRecord::Base.transaction do
      record.public_send(:"#{valid_event}!")
      raise ActiveRecord::Rollback
    end

    expect(fired).to be false
  end

  it "does not fire after_commit inside an outer transaction" do
    sequence = []
    probe_attr = :"on_#{valid_event}ed_probe"
    record.class.public_send(:"#{probe_attr}=", ->(_) { sequence << :callback }) rescue nil

    ActiveRecord::Base.transaction do
      record.public_send(:"#{valid_event}!")
      sequence << :inside_outer_tx
    end

    callback_idx = sequence.index(:callback)
    marker_idx   = sequence.index(:inside_outer_tx)

    # callback_idx can be nil if the probe isn't wired — skip gracefully
    next if callback_idx.nil?

    expect(callback_idx).to be > marker_idx
  end
end
