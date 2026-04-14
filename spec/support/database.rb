require 'active_record'

ActiveRecord::Base.establish_connection(
  adapter:  'sqlite3',
  database: ':memory:'
)

ActiveRecord::Base.logger = nil

ActiveRecord::Schema.define do
  create_table :jobs, force: true do |t|
    t.string  :status,     null: false, default: 'pending'
    t.integer :work_units, null: false, default: 0
    t.timestamps
  end

  create_table :job_transitions, force: true do |t|
    t.string  :from_state
    t.string  :to_state,  null: false
    t.string  :event
    t.text    :metadata,  default: '{}'
    t.integer :job_id,    null: false
    t.timestamps
  end

  add_index :job_transitions, :job_id

  # Namespaced model tables — used by spec/unhappy/namespaced_model_spec.rb
  create_table :ops_requests, force: true do |t|
    t.string  :status,   null: false, default: 'open'
    t.integer :priority, null: false, default: 0
    t.timestamps
  end

  create_table :ops_request_transitions, force: true do |t|
    t.string  :from_state
    t.string  :to_state,   null: false
    t.string  :event
    t.integer :request_id, null: false
    t.timestamps
  end

  add_index :ops_request_transitions, :request_id

  # Optimistic-locking model — used by spec/contract/optimistic_locking_spec.rb
  create_table :lockable_jobs, force: true do |t|
    t.string  :status,       null: false, default: 'pending'
    t.integer :work_units,   null: false, default: 0
    t.integer :lock_version, null: false, default: 0
    t.timestamps
  end

  create_table :lockable_job_transitions, force: true do |t|
    t.string  :from_state
    t.string  :to_state,         null: false
    t.string  :event
    t.integer :lockable_job_id,  null: false
    t.timestamps
  end

  add_index :lockable_job_transitions, :lockable_job_id
end
