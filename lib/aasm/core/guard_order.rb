module AASM
  module Core
    # Fixes AASM's callback ordering: by default, event-level `before` hooks
    # run BEFORE guards are checked.  For financial operations this is wrong —
    # a fee deduction should never happen if the guard is about to fail.
    #
    # Fix: pre-check guards in aasm_fire_event before AASM's base fires any
    # callbacks.  If guards fail we short-circuit cleanly:
    #
    #   event!  → guard fail → raises AASM::InvalidTransition (no before hooks)
    #   event   → guard fail → returns false                  (no before hooks)
    #
    # When guards pass we call super, which re-evaluates guards and executes
    # the full callback chain.  Guards run twice but must be pure by contract.
    #
    module GuardOrder
      def aasm_fire_event(state_machine_name, event_name, options, *args, &block)
        # Reload from the DB before evaluating guards so they always see the
        # current row, not whatever happens to be in Ruby's memory.
        # For production race-condition safety, pair with requires_lock: 'FOR UPDATE NOWAIT'
        # in the aasm config — that is the locking guarantee; this is the freshness guarantee.
        reload if persisted? && options[:persist]

        event     = self.class.aasm(state_machine_name).state_machine.events[event_name]
        old_state = aasm(state_machine_name).state_object_for_name(
                      aasm(state_machine_name).current_state)

        unless event.may_fire?(self, *args)
          if options[:persist]
            # Bang method — delegate to AASM's failure handler (respects whiny_transitions)
            return aasm_failed(state_machine_name, event_name, old_state, event.failed_callbacks)
          else
            # Non-bang method — always return false cleanly
            return false
          end
        end

        # Guards passed — mark we are inside a legitimate AASM transition
        # (BypassGuard reads this to allow aasm_write_attribute through)
        Thread.current[:aasm_core_transitioning]   = true
        Thread.current[:aasm_core_current_event]   = event_name

        super
      ensure
        Thread.current[:aasm_core_transitioning]   = false
        Thread.current[:aasm_core_current_event]   = nil
      end
    end
  end
end
