module AASM
  module Core
    # Writes an immutable transition record to {Model}Transition on every
    # successful persisted state change.
    #
    # Convention: if a table named `{model_name}_transitions` exists and a
    # corresponding constant is defined, logging is active automatically.
    # No configuration required.
    #
    # The write happens inside AASM's own transaction (via aasm_write_state),
    # so the transition record and state column update are always atomic —
    # both commit or both roll back together.
    #
    module TransitionLogger
      def aasm_write_state(state, state_machine_name = :default)
        from_state = aasm(state_machine_name).current_state   # before super updates it

        result = super

        _aasm_core_log_transition(state_machine_name, from_state, state) if result
        result
      end

      private

      def _aasm_core_log_transition(state_machine_name, from_state, to_state)
        klass = "#{self.class.name}Transition".safe_constantize
        return unless klass

        klass.create!(
          "#{self.class.name.underscore}_id" => id,
          from_state:                           from_state.to_s,
          to_state:                             to_state.to_s,
          event:                                Thread.current[:aasm_core_current_event].to_s
        )
      end
    end
  end
end
