$LOAD_PATH.unshift File.join(__dir__, '..', 'lib')
require 'aasm'

require_relative 'support/database'
require_relative 'support/models'

Dir[File.join(__dir__, 'shared_examples', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.before(:each) do
    JobTransition.delete_all
    Job.delete_all
    Job.on_completed_probe   = nil
    Job.before_complete_probe = nil
  end

  config.expect_with :rspec do |e|
    e.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.order = :random
end
