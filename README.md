# aasm-we

A hard fork of [aasm](https://github.com/aasm/aasm) (forked at 5.5.2) that fixes four correctness problems present in the upstream library. The same bugs affect any application using state machines to enforce business rules — whether you're running a job queue, a content moderation pipeline, a booking system, an e-commerce platform, or a SaaS approval workflow.

Drop-in replacement — same DSL, same API. No behaviour changes unless you were relying on the bugs.

---

## The four bugs this fork fixes

### 1. Before-hooks fire before guards (side-effect hazard)

**Vanilla aasm** runs `before` callbacks first, then checks guards. If the guard fails, the `before` hook already ran.

```ruby
event :submit do
  before { NotificationService.alert_reviewers(self) }  # runs even on guard failure
  transitions from: :draft, to: :under_review, guard: :has_content?
end
```

In vanilla aasm, `submit!` on an empty document alerts reviewers and then raises `InvalidTransition`. The notification is gone, reviewers are confused, the document is still in `:draft`.

**This fork** evaluates guards first. If the guard fails, no callbacks run at all. The before-hook is never reached.

---

### 2. Guards read stale in-memory state (race condition)

**Vanilla aasm** evaluates guards against whatever is in the Ruby object, which may be seconds or minutes old. Two concurrent requests can both pass the guard on the same record.

```
Thread A: loads job, capacity=10, guard passes
Thread B: loads job, capacity=10, guard passes
Thread A: claims a slot, sets capacity=9, saves
Thread B: claims on stale data — slot is over-committed
```

**This fork** reloads the record from the DB before evaluating guards on bang events (`complete!`). Guards always see committed state.

> **Side effect:** `complete!` discards unsaved in-memory attribute changes made before the call. Save first, or make the change inside a `before` hook.

---

### 3. State column can be bypassed (silent corruption)

**Vanilla aasm** with default settings lets you write the state column directly, skipping guards, callbacks, and audit logging:

```ruby
record.status = 'approved'          # no guards, no callbacks, no log
record.update!(status: 'approved')  # same — routes through the setter
```

**This fork** enables `no_direct_assignment` by default. Both vectors above raise `AASM::NoDirectAssignmentError`.

`update_columns` is intentionally left unrestricted — it is an explicit, low-level operator escape hatch for production incident recovery (see [Escape hatches](#escape-hatches)).

---

### 4. `after_commit` fires inside a savepoint (fires on rollback)

**Vanilla aasm** fires `after_commit` at SAVEPOINT release, not at the outermost `COMMIT`. If the outer transaction rolls back — a common pattern with nested transactions — the callback already ran.

```ruby
event :activate do
  after_commit { ExternalAPI.provision(self) }  # fires on SAVEPOINT release
end

ActiveRecord::Base.transaction do
  service.activate!    # after_commit fires here (inside the outer transaction)
  raise "rollback"     # outer transaction rolls back — but the API call is gone
end
```

**This fork** requires and uses [`after_commit_everywhere`](https://github.com/Envek/after_commit_everywhere), which correctly defers the callback until the real outermost commit.

---

## Installation

In your `Gemfile`, replace `gem 'aasm'` with:

```ruby
gem 'aasm-we'
```

No code changes needed. Same `include AASM`, same `aasm do ... end` DSL.

---

## Audit trail (transition logging)

Every successful persisted transition writes a row to `{Model}Transition` **inside the same transaction** as the state column update. Both commit together or both roll back.

### Convention

Define a `JobTransition` model:

```ruby
class JobTransition < ApplicationRecord
  belongs_to :job
end
```

With this migration:

```ruby
create_table :job_transitions do |t|
  t.integer :job_id,     null: false
  t.string  :from_state, null: false
  t.string  :to_state,   null: false
  t.string  :event,      null: false
  t.timestamps
  t.index :job_id
end
```

That is all. No configuration. The fork detects `JobTransition` by convention and writes to it automatically.

If the transition class does not exist, the fork logs one `warn` per model class and continues — no error, no silent failure.

### Namespaced models

`Ops::Request` tries `Ops::RequestTransition` first, then `RequestTransition`. The foreign key is `request_id` (demodulized), not `ops_request_id`.

---

## Escape hatches

### Emergency state correction from the console

Sometimes the state machine is the problem: a bug left records in an impossible state and you need to fix them without triggering broken callbacks. Use `update_columns`:

```ruby
# Rails console — production incident recovery
Job.where(id: stuck_ids).update_all(status: 'pending')
job.update_columns(status: 'pending')
```

This bypasses all AASM machinery by design. The setter override only protects against accidental code-level assignment, not deliberate operator intervention. A guardrail that prevents recovery is a trap.

### Seeding state in tests

If you need to create records in a specific state without going through events:

```ruby
# In tests or seeds — opt out per machine
aasm column: :status, no_direct_assignment: false do
  ...
end
```

---

## Configuration

All vanilla aasm options work unchanged. This fork adds one default change:

| Option | Vanilla aasm | aasm-we |
|---|---|---|
| `no_direct_assignment` | `false` | `true` |

Everything else (`whiny_transitions`, `use_transactions`, `requires_lock`, etc.) is identical.

---

## Why does this keep happening? Root cause analysis

These are not obscure edge cases. They appear in major open-source projects and production systems alike. The root causes explain why the upstream library didn't catch them — and why similar bugs are likely in any state machine library you pick up.

### 1. In-memory-first design

State machines were originally designed for in-process systems — embedded firmware, UI event loops, protocol parsers. In those contexts, "state" is a single-process concept and the guard `if (balance > 0)` reads a local variable. The correctness assumption is that the state machine *is* the canonical source of truth.

Rails models are wrappers over a shared database. Two instances of the same Ruby object can exist in different processes with different in-memory values for the same row. A state machine that reads its guard data from `self.balance` without reloading is applying a correctness model that is fundamentally wrong for a shared-database environment.

The upstream library acknowledged this with `requires_lock` configuration, but made it opt-in. The correct default is reload-then-lock.

### 2. Breaking-change aversion

`no_direct_assignment: false` was the original default. Changing it to `true` breaks apps that relied (usually accidentally) on direct assignment. The upstream project is conservative about defaults precisely because millions of apps depend on it. What is a correctness fix for new users is a breaking change for existing users.

This fork takes the position that the correct behaviour should be the default, and that opting *out* of protection is the deliberate act.

### 3. Opt-in safety vs opt-out safety

"Opt-in safety" means the safe behaviour requires configuration. Most developers use the defaults. Most apps are therefore running with the unsafe behaviour.

The before-hook ordering is the clearest example. The intuitive reading of:
```ruby
event :submit do
  before { send_notification }
  transitions from: :draft, to: :approved, guard: :ready?
end
```
is that the notification fires when the transition fires. But vanilla aasm separates "callbacks" from "guards" in its internal execution model, and runs callbacks before checking guards. The developer has to know to read the source to understand this.

### 4. Savepoint vs transaction confusion

ActiveRecord wraps every `save` in its own transaction. When you call `save` inside an explicit `transaction {}` block, the inner `save` becomes a SAVEPOINT. `after_commit` on a SAVEPOINT fires when the SAVEPOINT is released — not when the outer transaction commits.

The upstream library's `after_commit` simulation reads the documentation ("fires after commit") but implements the behaviour incorrectly ("fires after savepoint release"). This distinction is invisible in development — which has auto-commit semantics for each statement — and only surfaces in production code that wraps multiple operations in an explicit transaction.

The [`after_commit_everywhere`](https://github.com/Envek/after_commit_everywhere) gem exists specifically because this pattern is hard to get right from userland. Using it is the correct fix.

---

## Real incidents where these bugs caused production failures

The bugs fixed in this fork are not theoretical. Here are documented incidents in widely-deployed open-source projects:

| Project | Bug | Impact |
|---|---|---|
| **Drupal** ([#3181439](https://www.drupal.org/project/drupal/issues/3181439)) | Content Moderation module runs transition hooks before checking access guards | Published content visible to users before moderation approval; hooks fire on rejected transitions |
| **nopCommerce** ([CVE-2024-58248](https://nvd.nist.gov/vuln/detail/CVE-2024-58248)) | Gift card state guard evaluated against stale session state | Race condition allows gift card balance to be consumed more than once |
| **Spree Commerce** ([mass assignment era](https://guides.spreecommerce.org/security/)) | State column writable via mass assignment before `attr_accessible` enforcement | Order status overrideable via crafted POST parameters; fulfilled orders marked pending |
| **Rails** ([#52641](https://github.com/rails/rails/issues/52641)) | `after_commit` inside nested transactions fires at SAVEPOINT release | Callbacks run on data that is subsequently rolled back; duplicate emails, premature webhooks |

The pattern across all four: a state machine is used to enforce a business invariant, the library has an unsafe default, and the failure surfaces in a different system (a moderation queue, a billing reconciliation, an order fulfillment pipeline) days or weeks after the bad write.

---

## Further reading

| Topic | Resource |
|---|---|
| State machine theory | [Statecharts](https://statecharts.dev/) — good mental model; covers guard ordering and action timing |
| Rails transaction safety | [ActiveRecord Transactions](https://api.rubyonrails.org/classes/ActiveRecord/Transactions/ClassMethods.html) — official docs on savepoints and `after_commit` |
| The savepoint problem | [after_commit_everywhere](https://github.com/Envek/after_commit_everywhere) — explains the SAVEPOINT/COMMIT distinction concisely |
| Locking strategies | [Optimistic vs Pessimistic Locking](https://www.martinfowler.com/eaaCatalog/optimisticOfflineLock.html) — Fowler; relevant to guard freshness |
| Race conditions in Rails | [Race Conditions on Rails](https://blog.appsignal.com/2022/01/12/how-to-deal-with-race-conditions-in-ruby-on-rails.html) — AppSignal; practical examples |
| Distributed state | [Designing Distributed Systems](https://www.oreilly.com/library/view/designing-distributed-systems/9781491983638/) — Burns; Chapter 3 on coordination |

---

## Forked from

[aasm/aasm](https://github.com/aasm/aasm) at tag `v5.5.2`. This fork is not affiliated with or endorsed by the original project.
