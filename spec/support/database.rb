require 'active_record'

ActiveRecord::Base.establish_connection(
  adapter:  'sqlite3',
  database: ':memory:'
)

ActiveRecord::Base.logger = nil

ActiveRecord::Schema.define do
  create_table :payments, force: true do |t|
    t.string  :status,       null: false, default: 'pending'
    t.integer :amount_cents, null: false, default: 0
    t.timestamps
  end

  create_table :payment_transitions, force: true do |t|
    t.string  :from_state
    t.string  :to_state,   null: false
    t.string  :event
    t.text    :metadata,   default: '{}'
    t.integer :payment_id, null: false
    t.timestamps
  end

  add_index :payment_transitions, :payment_id

  # Namespaced model tables — used by spec/unhappy/namespaced_model_spec.rb
  create_table :billing_invoices, force: true do |t|
    t.string  :status,       null: false, default: 'draft'
    t.integer :amount_cents, null: false, default: 0
    t.timestamps
  end

  create_table :billing_invoice_transitions, force: true do |t|
    t.string  :from_state
    t.string  :to_state,    null: false
    t.string  :event
    t.integer :invoice_id,  null: false
    t.timestamps
  end

  add_index :billing_invoice_transitions, :invoice_id
end
