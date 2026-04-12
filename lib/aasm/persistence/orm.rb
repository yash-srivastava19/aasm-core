module AASM
  module Persistence
    # This module adds transactional support for any database that supports it.
    # This includes rollback capability and rollback/commit callbacks.
    module ORM

      # Writes <tt>state</tt> to the state column and persists it to the database.
      # On success, writes an audit record to {Model}Transition (if the table
      # exists) inside the same transaction, so the state update and the audit
      # row are always atomic — both commit or both roll back.
      #
      #   foo = Foo.find(1)
      #   foo.aasm.current_state # => :opened
      #   foo.close!
      #   foo.aasm.current_state # => :closed
      #   Foo.find(1).aasm.current_state # => :closed
      #
      # NOTE: intended to be called from an event
      def aasm_write_state(state, name=:default)
        from_state = aasm(name).current_state   # capture before the write

        attribute_name = self.class.aasm(name).attribute_name
        old_value = aasm_read_attribute(attribute_name)
        aasm_write_state_attribute state, name

        success = if aasm_skipping_validations(name)
          aasm_update_column(attribute_name, aasm_raw_attribute_value(state, name))
        else
          aasm_save
        end

        if success
          aasm_write_transition_log(from_state, state)
        else
          aasm_rollback(name, old_value)
          aasm_raise_invalid_record if aasm_whiny_persistence(name)
        end

        success
      end

      # Writes <tt>state</tt> to the state field, but does not persist it to the database
      #
      #   foo = Foo.find(1)
      #   foo.aasm.current_state # => :opened
      #   foo.close
      #   foo.aasm.current_state # => :closed
      #   Foo.find(1).aasm.current_state # => :opened
      #   foo.save
      #   foo.aasm.current_state # => :closed
      #   Foo.find(1).aasm.current_state # => :closed
      #
      # NOTE: intended to be called from an event
      def aasm_write_state_without_persistence(state, name=:default)
        aasm_write_state_attribute(state, name)
      end

      private

      # Save the record and return true if it succeeded/false otherwise.
      def aasm_save
        raise("Define #aasm_save_without_error in the AASM Persistence class.")
      end

      def aasm_raise_invalid_record
        raise("Define #aasm_raise_invalid_record in the AASM Persistence class.")
      end

      # Update only the column without running validations.
      def aasm_update_column(attribute_name, value)
        raise("Define #aasm_update_column in the AASM Persistence class.")
      end

      def aasm_read_attribute(name)
        raise("Define #aasm_read_attribute the AASM Persistence class.")
      end

      def aasm_write_attribute(name, value)
        raise("Define #aasm_write_attribute in the AASM Persistence class.")
      end

      # Returns true or false if transaction completed successfully.
      def aasm_transaction(requires_new, requires_lock)
        raise("Define #aasm_transaction the AASM Persistence class.")
      end

      def aasm_supports_transactions?
        true
      end

      # Writes an immutable transition record to {Model}Transition when the
      # table exists.  Convention-based: no configuration required.
      #
      # Namespaced models (e.g. Billing::Invoice):
      #   - Tries Billing::InvoiceTransition first, then InvoiceTransition.
      #   - FK uses demodulized name: "invoice_id", not "billing_invoice_id".
      #
      # Called from aasm_write_state after a successful save, so it runs
      # inside the same database transaction as the state column update.
      def aasm_write_transition_log(from_state, to_state)
        klass = aasm_transition_log_class
        return unless klass

        klass.create!(
          "#{self.class.name.demodulize.underscore}_id" => id,
          from_state: from_state.to_s,
          to_state:   to_state.to_s,
          event:      Thread.current[:aasm_current_event].to_s
        )
      end

      # Resolve the {Model}Transition class, memoized at the class level.
      # Constant resolution only runs once per model class; subsequent calls
      # return the cached result (including nil for models without a transition
      # class).  Warns once on first resolution if the class is missing.
      def aasm_transition_log_class
        return self.class.instance_variable_get(:@_aasm_transition_log_class) \
          if self.class.instance_variable_defined?(:@_aasm_transition_log_class)

        klass = "#{self.class.name}Transition".safe_constantize ||
                "#{self.class.name.demodulize}Transition".safe_constantize
        self.class.instance_variable_set(:@_aasm_transition_log_class, klass)

        if klass.nil?
          Kernel.warn \
            "[AASM] #{self.class.name}: no transition class found " \
            "(tried #{self.class.name}Transition and " \
            "#{self.class.name.demodulize}Transition). " \
            "Audit logging is disabled for this model."
        end

        klass
      end

      def aasm_execute_after_commit
        yield
      end

      def aasm_write_state_attribute(state, name=:default)
        aasm_write_attribute(self.class.aasm(name).attribute_name, aasm_raw_attribute_value(state, name))
      end

      def aasm_raw_attribute_value(state, _name=:default)
        state.to_s
      end

      def aasm_rollback(name, old_value)
        aasm_write_attribute(self.class.aasm(name).attribute_name, old_value)
        false
      end

      def aasm_whiny_persistence(state_machine_name)
        AASM::StateMachineStore.fetch(self.class, true).machine(state_machine_name).config.whiny_persistence
      end

      def aasm_skipping_validations(state_machine_name)
        AASM::StateMachineStore.fetch(self.class, true).machine(state_machine_name).config.skip_validation_on_save
      end

      def use_transactions?(state_machine_name)
        AASM::StateMachineStore.fetch(self.class, true).machine(state_machine_name).config.use_transactions
      end

      def requires_new?(state_machine_name)
        AASM::StateMachineStore.fetch(self.class, true).machine(state_machine_name).config.requires_new_transaction
      end

      def requires_lock?(state_machine_name)
        AASM::StateMachineStore.fetch(self.class, true).machine(state_machine_name).config.requires_lock
      end

      # Returns true if event was fired successfully and transaction completed.
      def aasm_fire_event(state_machine_name, name, options, *args, &block)
        return super unless aasm_supports_transactions? && options[:persist]

        # Reload from DB before evaluating guards so they always see the
        # current row, not stale in-memory state.
        #
        # SIDE EFFECT: discards any unsaved in-memory attribute changes the
        # caller made before invoking the event.  Callers who need to mutate
        # attributes atomically with the transition should either:
        #   a) save! the record first, or
        #   b) perform the mutation inside an AASM before-hook.
        reload if persisted?

        event = self.class.aasm(state_machine_name).state_machine.events[name]
        event.fire_callbacks(:before_transaction, self, *args)
        event.fire_global_callbacks(:before_all_transactions, self, *args)

        begin
          success = if options[:persist] && use_transactions?(state_machine_name)
            aasm_transaction(requires_new?(state_machine_name), requires_lock?(state_machine_name)) do
              super
            end
          else
            super
          end

          if success && !(event.options.keys & [:after_commit, :after_all_commits]).empty?
            aasm_execute_after_commit do
              event.fire_callbacks(:after_commit, self, *args)
              event.fire_global_callbacks(:after_all_commits, self, *args)
            end
          end

          success
        ensure
          event.fire_callbacks(:after_transaction, self, *args)
          event.fire_global_callbacks(:after_all_transactions, self, *args)
        end
      end

    end # Transactional
  end # Persistence
end # AASM
