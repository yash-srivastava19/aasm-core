module AASM
  module Core
    # Writes an immutable transition record to {Model}Transition on every
    # successful persisted state change.
    #
    # Convention: if a {Model}Transition constant is resolvable and a
    # corresponding table exists, logging is active automatically.
    # No configuration required.
    #
    # Namespaced models (e.g. Billing::Invoice):
    #   - Constant lookup tries Billing::InvoiceTransition first, then
    #     InvoiceTransition, so both namespaced and top-level transition
    #     classes are supported.
    #   - FK uses name.demodulize.underscore, producing "invoice_id"
    #     (not "billing/invoice_id" or "billing_invoice_id").
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
        klass = _aasm_core_transition_class
        return unless klass

        klass.create!(
          "#{self.class.name.demodulize.underscore}_id" => id,
          from_state:                               from_state.to_s,
          to_state:                                 to_state.to_s,
          event:                                    Thread.current[:aasm_core_current_event].to_s
        )
      end

      # Resolve the transition class for this model.
      #
      # Try the fully-qualified name first (Billing::InvoiceTransition), then
      # the demodulized name (InvoiceTransition), so developers can define the
      # transition class in either the same namespace or at the top level.
      def _aasm_core_transition_class
        "#{self.class.name}Transition".safe_constantize ||
          "#{self.class.name.demodulize}Transition".safe_constantize
      end
    end
  end
end
