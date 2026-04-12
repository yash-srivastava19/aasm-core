# Contract: every state change produces an immutable transition record
#
# Borrowed from Statesman's core insight: the transition LOG is the source of
# truth, not just the status column.  Every successful transition writes one
# row to job_transitions in the SAME database transaction as the state column
# update.  They are atomic — you never get one without the other.
#
# This gives you:
#   - a full audit trail for free (no extra effort from the developer)
#   - proof that a rollback undoes both the state change and the log entry
#   - a queryable history for compliance, debugging, and support

RSpec.describe "Contract: audit trail" do
  subject(:job) { Job.create!(work_units: 1000) }

  # ── A record is written on every successful transition ───────────────────

  describe "transition record creation" do
    it "creates one JobTransition per successful event" do
      expect { job.complete! }
        .to change { JobTransition.count }.by(1)
    end

    it "records the correct from_state, to_state, and event name" do
      job.complete!
      t = JobTransition.last

      expect(t.from_state).to eq('pending')
      expect(t.to_state).to  eq('completed')
      expect(t.event).to     eq('complete')
    end

    it "records a timestamp" do
      freeze = Time.now
      job.complete!

      expect(JobTransition.last.created_at).to be_within(2).of(freeze)
    end

    it "records the parent FK so history is queryable per record" do
      job.complete!
      expect(JobTransition.last.job_id).to eq(job.id)
    end
  end

  # ── Atomicity: log entry and state column live or die together ───────────

  describe "atomicity with the state column" do
    it "does NOT write a transition record when a guard fails" do
      job.update_columns(work_units: 0)   # bypass for setup only

      expect { job.complete! rescue nil }
        .not_to change { JobTransition.count }
    end

    it "does NOT write a transition record when the transition is invalid" do
      job.fail!   # move to :failed first

      expect { job.complete! rescue nil }
        .not_to change { JobTransition.count }
    end

    it "does NOT write a transition record when the before hook raises" do
      Job.before_complete_probe = ->(_) { raise "upstream dependency unavailable" }

      expect { job.complete! rescue nil }
        .not_to change { JobTransition.count }

      expect(job.reload.status).to eq('pending')
    end

    it "rolls back the transition record if the outer transaction rolls back" do
      job  # create the record BEFORE the outer transaction
      ActiveRecord::Base.transaction do
        job.complete!
        expect(JobTransition.count).to eq(1)   # written inside the tx
        raise ActiveRecord::Rollback
      end

      # Both the state column AND the log entry must be rolled back
      expect(JobTransition.count).to eq(0)
      expect(job.reload.status).to eq('pending')
    end
  end

  # ── History across multiple transitions ──────────────────────────────────

  describe "full lifecycle history" do
    it "appends one record per transition, in order" do
      job.complete!
      job.cancel!

      history = JobTransition
                  .where(job_id: job.id)
                  .order(:created_at)

      expect(history.map(&:to_state)).to eq(%w[completed cancelled])
    end

    it "never updates or deletes existing records — append only" do
      job.complete!
      first_id = JobTransition.last.id

      job.cancel!

      # The original record must be untouched
      expect(JobTransition.find(first_id).to_state).to eq('completed')
      expect(JobTransition.count).to eq(2)
    end
  end
end
