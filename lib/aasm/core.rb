require 'after_commit_everywhere'   # AASM detects this and uses it for after_commit
require 'aasm'

require_relative 'core/version'
require_relative 'core/bypass_guard'
require_relative 'core/guard_order'
require_relative 'core/transition_logger'

module AASM
  # Drop-in extension for AASM that makes it safe for business-critical flows.
  #
  # Usage (one line per model):
  #
  #   class Payment < ApplicationRecord
  #     include AASM
  #     include AASM::Core          # ← this line
  #
  #     aasm column: :status do
  #       ...                       # existing AASM syntax unchanged
  #     end
  #   end
  #
  # What it does (all automatic, zero configuration):
  #
  #   1. after_commit — fires after the REAL outermost transaction, not inside it
  #   2. Guard ordering — guards run before before-hooks (not after)
  #   3. Bypass prevention — direct state writes raise immediately
  #   4. Audit trail — writes to {Model}Transition if the table exists
  #
  module Core
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      # Intercept the aasm macro so we can apply our setup after the block runs.
      def aasm(*args, &block)
        super.tap { _aasm_core_configure! if block_given? }
      end

      # Public: returns all state column names for this model (across all machines).
      def aasm_core_state_columns
        AASM::StateMachineStore.fetch(self, true).machine_names.map do |name|
          AASM::StateMachineStore.fetch(self, true).machine(name).config.column.to_s
        end
      end

      private

      def _aasm_core_configure!
        _aasm_core_install_no_direct_assignment!
        _aasm_core_install_behaviours!
      end

      # Override each state column setter to raise immediately on direct write.
      # This covers: payment.status = 'paid' and payment.update!(status: 'paid')
      def _aasm_core_install_no_direct_assignment!
        aasm_core_state_columns.each do |col|
          define_method(:"#{col}=") do |_|
            raise AASM::NoDirectAssignmentError,
              "#{col} cannot be assigned directly — use state machine events"
          end
        end
      end

      # Mix in the three behaviour modules (idempotent — safe to call multiple
      # times if the model defines multiple state machines).
      def _aasm_core_install_behaviours!
        include BypassGuard       unless include?(BypassGuard)
        include GuardOrder        unless include?(GuardOrder)
        include TransitionLogger  unless include?(TransitionLogger)
      end
    end
  end
end
