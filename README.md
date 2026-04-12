# aasm-we

A hard fork of [aasm](https://github.com/aasm/aasm) (forked at 5.5.2) that fixes four correctness problems that matter when your state machine guards real money, orders, or compliance workflows.

Drop-in replacement — same DSL, same API. No behaviour changes unless you were relying on the bugs.

---

## The four bugs this fork fixes

### 1. Before-hooks fire before guards (side-effect hazard)

**Vanilla aasm** runs `before` callbacks first, then checks guards. If the guard fails, the `before` hook already ran.

```ruby
event :charge do
  before { FeeCalculator.deduct!(self) }   # runs even on guard failure
  transitions from: :pending, to: :charged, guard: :sufficient_funds?
end
```

In vanilla aasm, `charge!` on an underfunded account deducts a fee and then raises `InvalidTransition`. The money is gone.

**This fork** evaluates guards first. If the guard fails, no callbacks run at all. The before-hook is never reached.

---

### 2. Guards read stale in-memory state (race condition)

**Vanilla aasm** evaluates guards against whatever is in the Ruby object, which may be seconds or minutes old. Two concurrent requests can both pass the guard on the same record.

```
Thread A: loads order, amount_cents=1000, guard passes
Thread B: loads order, amount_cents=1000, guard passes
Thread A: charges, sets amount_cents=0, saves
Thread B: charges on stale data — double charge
```

**This fork** reloads the record from the DB before evaluating guards on bang events (`pay!`). Guards always see committed state.

> **Side effect:** `pay!` discards unsaved in-memory attribute changes made before the call. Save first, or make the change inside a `before` hook.

---

### 3. State column can be bypassed (silent corruption)

**Vanilla aasm** with default settings lets you write the state column directly, skipping guards, callbacks, and audit logging:

```ruby
payment.status = 'paid'          # no guards, no callbacks, no log
payment.update!(status: 'paid')  # same — routes through the setter
```

**This fork** enables `no_direct_assignment` by default. Both vectors above raise `AASM::NoDirectAssignmentError`.

`update_columns` is intentionally left unrestricted — it is an explicit, low-level operator escape hatch for production incident recovery (see [Escape hatches](#escape-hatches)).

---

### 4. `after_commit` fires inside a savepoint (fires on rollback)

**Vanilla aasm** fires `after_commit` at SAVEPOINT release, not at the outermost `COMMIT`. If the outer transaction rolls back — a common pattern with nested transactions or `transaction { ... rollback! }` — the callback already ran.

```ruby
event :ship do
  after_commit { ShippingAPI.notify(self) }  # fires on SAVEPOINT release
end

ActiveRecord::Base.transaction do
  order.ship!          # after_commit fires here (inside the outer transaction)
  raise "oh no"        # outer transaction rolls back — but the notification is gone
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

Define a `PaymentTransition` model:

```ruby
class PaymentTransition < ApplicationRecord
  belongs_to :payment
end
```

With this migration:

```ruby
create_table :payment_transitions do |t|
  t.integer :payment_id, null: false
  t.string  :from_state, null: false
  t.string  :to_state,   null: false
  t.string  :event,      null: false
  t.timestamps
  t.index :payment_id
end
```

That is all. No configuration. The fork detects `PaymentTransition` by convention and writes to it automatically.

If the transition class does not exist, the fork logs one `warn` per model class and continues — no error, no silent failure.

### Namespaced models

`Billing::Invoice` tries `Billing::InvoiceTransition` first, then `InvoiceTransition`. The foreign key is `invoice_id` (demodulized), not `billing_invoice_id`.

---

## Escape hatches

### Emergency state correction from the console

Sometimes the state machine is the problem: a bug left records in an impossible state and you need to fix them without triggering broken callbacks. Use `update_columns`:

```ruby
# Rails console — production incident recovery
Payment.where(id: bad_ids).update_all(status: 'pending')
payment.update_columns(status: 'pending')
```

This bypasses all AASM machinery by design. The setter override only protects against accidental code-level assignment, not deliberate operator intervention.

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

## Why state machine bugs cause enterprise-level incidents

State machines in production systems are not just code organization — they are the enforcement boundary for business rules. When they break, the failures compound:

### The double-charge problem

Guard race conditions directly produce double charges. The guard passes on stale data in two concurrent threads; both transitions commit. This is not hypothetical — it is one of the most common sources of financial reconciliation bugs in Rails apps at scale. Every payment processor, booking system, and subscription service has hit this.

**Resources:**
- [Race Conditions on Rails](https://blog.appsignal.com/2022/01/12/how-to-deal-with-race-conditions-in-ruby-on-rails.html) — AppSignal
- [Pessimistic Locking in ActiveRecord](https://api.rubyonrails.org/classes/ActiveRecord/Locking/Pessimistic.html) — Rails docs
- [Stripe's approach to idempotency](https://stripe.com/blog/idempotency) — how Stripe prevents double charges at the API layer; the problem this addresses starts at the state machine layer

### The phantom notification problem

`after_commit` firing inside a savepoint means webhook calls, emails, and downstream API requests go out for transactions that ultimately roll back. The canonical incident: an order confirmation email is sent, the payment transaction rolls back, the customer has a confirmation for an order that doesn't exist.

**Resources:**
- [after_commit_everywhere README](https://github.com/Envek/after_commit_everywhere) — explains the SAVEPOINT problem concisely
- [Rails `after_commit` and nested transactions](https://guides.rubyonrails.org/active_record_callbacks.html#transaction-callbacks) — Rails docs on the behaviour
- [The problem with after_commit in Rails](https://www.honeybadger.io/blog/rails-callbacks/) — Honeybadger engineering

### The audit gap problem

State changes without a corresponding audit row create compliance failures. In financial services, healthcare, and legal tech, every state transition is a business event that regulators may require you to prove happened in a specific sequence. An audit table that can get out of sync with the state column (because the writes aren't atomic) is not a real audit trail.

**Resources:**
- [Event Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html) — Fowler; the audit trail pattern taken to its logical conclusion
- [Database Internals, Chapter 5](https://www.oreilly.com/library/view/database-internals/9781492040330/) — Petrov; transaction isolation levels and what "atomic" actually means at the DB layer
- [ACID compliance in practice](https://www.cockroachlabs.com/blog/acid-rain/) — CockroachDB blog; a readable explanation of what breaks when ACID guarantees are violated

### The silent bypass problem

Direct state column writes that skip the state machine produce records in states that are technically impossible by the machine's definition. Downstream code that trusts the state column — billing jobs, reporting queries, compliance checks — then runs against invalid data. The failure is not at the point of the bad write; it surfaces later, in a different system, in a way that is hard to trace back.

**Resources:**
- [Designing Data-Intensive Applications, Chapter 7](https://dataintensive.net/) — Kleppmann; transactions, isolation, and what "the database is the source of truth" actually requires
- [The dangers of implicit state](https://thoughtbot.com/blog/state-machines-and-the-open-closed-principle) — thoughtbot; state machines as a design boundary

---

## Further reading

| Topic | Resource |
|---|---|
| State machine theory | [Designing State Machines](https://statecharts.dev/) — XState docs; good mental model for anyone building state machines |
| Rails transaction safety | [How Rails handles transactions](https://api.rubyonrails.org/classes/ActiveRecord/Transactions/ClassMethods.html) |
| Locking strategies | [Optimistic vs Pessimistic Locking](https://www.martinfowler.com/eaaCatalog/optimisticOfflineLock.html) — Fowler |
| Financial correctness | [Double-entry bookkeeping](https://en.wikipedia.org/wiki/Double-entry_bookkeeping) — the 500-year-old solution to the same problem |
| Distributed systems | [Designing Distributed Systems](https://www.oreilly.com/library/view/designing-distributed-systems/9781491983638/) — Burns; Chapter 3 covers coordination patterns relevant to multi-service state |

---

## Forked from

[aasm/aasm](https://github.com/aasm/aasm) at tag `v5.5.2`. This fork is not affiliated with or endorsed by the original project.
