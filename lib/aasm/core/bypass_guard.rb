module AASM
  module Core
    # Closes the three bypass vectors that vanilla AASM leaves open:
    #
    #   payment.status = 'paid'            → raises NoDirectAssignmentError
    #   payment.update!(status: 'paid')    → raises NoDirectAssignmentError (via setter)
    #   payment.update_columns(status: ..) → raises RuntimeError
    #
    module BypassGuard
      def update_columns(attrs)
        blocked = attrs.keys.map(&:to_s) & self.class.aasm_core_state_columns
        if blocked.any?
          raise RuntimeError,
            "cannot update state column directly — use state machine events (#{blocked.join(', ')})"
        end
        super
      end
    end
  end
end
