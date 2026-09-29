# provable-ruby

Prove that Ruby code keeps its rules for **every** input, not only for the inputs a test happens to try.

provable-ruby is a method plus a working template:

1. Write the business logic in **verifiable Ruby**. This is a small, strict subset of Ruby, and each of its lines maps to one Lean 4 line.
2. Copy that code into **Lean 4** by hand, line for line, and state its rules as theorems. Lean checks every proof.
3. Keep the model tied to the real code. A **conformance probe** runs Ruby and Lean on the same thousands of inputs and diffs the outputs. A **drift lock** fails when the Ruby changes. Every **counterexample** Lean finds is run again on the real Ruby.

```
$ bin/verify
== proofs
all theorems checked
== verifiable ruby
Ruby sources use only verifiable Ruby
== drift lock
Ruby sources match models.lock
== 01_money_split
CONFORMS 3792 rows
REPRODUCED remainder_last_is_not_fair: remainder_last(11, 4) = [2, 2, 2, 5]
== 02_order_flow
CONFORMS 14113 rows
REPRODUCED refund_not_always_possible: paid 100, status shipped, refunded 0 after cancel + refund
```

## Why

A test checks the cases you thought of. A proof checks all of them.

The order example below has a probe that tries 14,113 event sequences. Its proof covers every sequence: any length, any amounts, any order, any number of retries.

But Lean cannot read Ruby. So a proof is always about a *model* of the code, and a model can be wrong. Most of this project exists to keep the model honest:

| Risk | Guard |
|---|---|
| The model does not do what the Ruby does | **Conformance probe.** Lean prints `input => output` rows. Ruby reads the same inputs, runs the real code, and prints its own rows. `diff` must be empty. |
| The Ruby changes later and the model does not | **Drift lock.** `models.lock` holds a SHA-256 hash of each verified Ruby file. Any edit fails the check until someone checks the model again. |
| A counterexample is only a bug in the model | **Ruby repro.** Each refuted theorem's witness runs against the real Ruby too. |
| The model is too hard to write correctly | **Verifiable Ruby.** Each Ruby line has one obvious Lean line, so the copy is easy to write and easy to review. |

Why Lean 4? It is a programming language and a proof checker in one. The same `def` that the theorems are about also runs, and it prints the conformance rows. The model has no second copy that could drift.

## How it fits together

```
   Ruby core                    copy by hand, line for line                 Lean model
 (verifiable style)  ───────────────────────────────────────────────▶  + theorems about it
        ▲                                                                       │
        │   conformance: same inputs, same outputs (diff)                       │ lake build
        │   repro: every refuted theorem also fails in Ruby                     │ checks every proof
        │   drift lock: Ruby changed? check the model again                     │
        └─────────────────────────────── bin/verify ◀───────────────────────────┘
```

## Verdicts

Every rule gets exactly one verdict:

| Verdict | Meaning |
|---|---|
| **PROVEN** | A theorem says the rule holds for all inputs, and Lean checked the proof. |
| **REFUTED** | Lean checked a concrete counterexample, and the same input breaks the rule in Ruby too. |
| **ASSUMED** | A trust boundary that the model does not check. Each model lists them on its `Trust:` line. |
| **OPEN** | Not settled yet. It stays out of the Lean file. `sorry` is never allowed. |

A refuted rule is not always a bug. Sometimes it is a product question. Example 2 has one.

## Verifiable Ruby

This is plain Ruby 3.2+ with no gems. It is also the style that is easiest to read and test. `bin/check-style` rejects code that breaks these rules in every locked file. The rules:

1. **Pure core, thin shell.** The core never touches the database, the clock, randomness, the network, or globals. The shell loads data, calls the core, and saves the result. Only the core is verified.
2. **Values, not objects.** Use `Data.define` for records. Never mutate: `with` returns a new value.
3. **Closed choices as data.** Use symbols for statuses and one `Data` class for each kind of event. Branch with `case/in` and an explicit `else`.
4. **Integers only.** Money is in cents. Time is whole days or seconds. No `Float`.
5. **Visible failure.** Guard clauses at the top raise `ArgumentError`. Return `nil` only when it means "no result".
6. **Loops are folds.** Use `map`, `select`, `sum`, `reduce`, and `Array.new(n) { }`. No `while`, `loop`, `break`, `next`, or index mutation.
7. **No metaprogramming.** No `send`, `define_method`, `method_missing`, `instance_variable_set`, monkey patches, or callbacks. The code you read is the code that runs.
8. **Same names, same branches.** `remainder_last` in Ruby is `remainder_last` in Lean, with the same branches in the same order. Never clean up the logic in the model: if the Ruby has a bug, the model must have the same bug.

Each rule exists because it gives a one-to-one mapping to Lean:

| Ruby | Lean 4 |
|---|---|
| `Integer` | `Int` (or `Nat` when negatives cannot happen) |
| `Data.define(:a, :b)` | `structure` |
| `value.with(a: 1)` | `{ value with a := 1 }` |
| `:placed`, `:paid` symbols | `inductive Status` |
| One `Data` class per event kind | `inductive Event` with one constructor per class |
| `case [x, y] in [..] ... else` | `match x, y with ... \| _, _ =>` |
| `raise ArgumentError, msg` | `Except.error msg` |
| `nil` as "no result" | `Option` / `none` |
| `Array` | `List` |
| `Array.new(n) { \|i\| f(i) }` | `(List.range n).map f` |
| `list.reduce(x) { \|acc, e\| step(acc, e) }` | `list.foldl step x` |
| `module_function` method | `def` |

### A small example: from ordinary Rails code to a verifiable core

This code works, but it cannot be proven:

```ruby
class Invoice < ApplicationRecord
  def apply_late_fee!
    return if paid?

    days = (Date.today - due_on).to_i
    self.fee += days * 0.5 if days > 0
    self.fee = 50 if fee > 50
    save!
  end
end
```

It reads the clock, uses `Float` money, and mutates the record. It also hides a bug: each call adds the fee again, so a retried job charges twice.

Split it into a core and a shell:

```ruby
module LateFee
  module_function

  def fee(amount_due:, days_late:)
    return 0 unless amount_due.positive? && days_late.positive?

    [days_late * 50, 5_000].min
  end
end

class Invoice < ApplicationRecord
  def apply_late_fee!(today: Date.current)
    update!(fee_cents: LateFee.fee(amount_due: balance_cents, days_late: (today - due_on).to_i))
  end
end
```

The core is now one short, closed function with a direct Lean copy and three proofs:

```lean
def fee (amount_due days_late : Int) : Int :=
  if ¬ (amount_due > 0 ∧ days_late > 0) then 0 else
  min (days_late * 50) 5000

theorem fee_never_above_cap : fee amount_due days_late ≤ 5000 := by
  unfold fee; split <;> omega

theorem fee_never_negative : 0 ≤ fee amount_due days_late := by
  unfold fee; split <;> omega

theorem fee_zero_when_nothing_due (h : amount_due ≤ 0) : fee amount_due days_late = 0 := by
  unfold fee; split <;> omega
```

The fee now depends only on its inputs, so running the job twice sets the same fee twice. The shell (`update!`, the clock) stays **ASSUMED**.

## Example 1: split money into equal parts

`examples/01_money_split/` splits a number of cents into `parts` shares. It has two versions. The first is the one most people write first.

```ruby
module MoneySplit
  module_function

  def remainder_last(total, parts)
    raise ArgumentError, "parts must be positive" unless parts.positive?
    raise ArgumentError, "total must not be negative" if total.negative?

    base = total / parts
    Array.new(parts - 1, base) + [total - (base * (parts - 1))]
  end

  def even(total, parts)
    raise ArgumentError, "parts must be positive" unless parts.positive?
    raise ArgumentError, "total must not be negative" if total.negative?

    base, extra = total.divmod(parts)
    Array.new(parts) { |i| i < extra ? base + 1 : base }
  end
end
```

The Lean copy of `even` keeps the same guards and branches in the same order:

```lean
def even (total parts : Int) : Except String (List Int) :=
  if ¬ parts > 0 then .error "parts must be positive" else
  if total < 0 then .error "total must not be negative" else
  let base := total / parts
  let extra := total % parts
  .ok ((List.range parts.toNat).map fun (i : Nat) => if (i : Int) < extra then base + 1 else base)
```

The rules, in plain words first:

```lean
/-- No cent is lost and no cent is made up. -/
def SumsTo (total : Int) (xs : List Int) : Prop := xs.sum = total

/-- No part is more than one cent bigger than any other part. -/
def Fair (xs : List Int) : Prop := ∀ a ∈ xs, ∀ b ∈ xs, a ≤ b + 1
```

Verdicts:

```
PROVEN   even_sums_to_total             the parts always add up to the total
PROVEN   even_is_fair                   the parts differ by at most 1 cent
PROVEN   even_length                    there are exactly `parts` parts
PROVEN   even_parts_not_negative        no part is below zero
PROVEN   even_fails_only_on_bad_input   raises if and only if parts <= 0 or total < 0
PROVEN   remainder_last_sums_to_total   the first version never loses a cent either
REFUTED  remainder_last_is_not_fair     remainder_last(11, 4) = [2, 2, 2, 5]
ASSUMED  Ruby divmod and Lean / % agree when the divisor is positive (the probe checks it)
```

The lesson: a test like `expect(parts.sum).to eq(total)` passes for **both** versions. The sum rule alone does not catch the bug. You catch it only when you write the fairness rule down and check it for all inputs.

The refuted theorem is short:

```lean
-- 11 cents over 4 people gives [2, 2, 2, 5]: the last person pays 3 cents more.
theorem remainder_last_is_not_fair :
    ¬ ∀ total parts xs, remainder_last total parts = .ok xs → Fair xs := by
  intro h
  have := h 11 4 [2, 2, 2, 5] rfl 5 (by decide) 2 (by decide)
  omega
```

To find a witness fast, search a small grid with `#eval` before you try a proof:

```lean
#eval Id.run do
  for t in List.range 20 do
    for p in List.range 6 do
      if let .ok xs := remainder_last t p then
        if !xs.all (fun a => xs.all (a ≤ · + 1)) then return some (t, p, xs)
  return none
-- some (2, 3, [0, 0, 2])
```

The conformance probe runs every `total` from -2 to 61 against every `parts` from -1 to 12, for both functions. That is 1,792 rows, including all the error rows. It then adds 1,000 random cases from a fixed seed: totals up to 10^20 (past 64 bits) and up to 300 parts. That makes 3,792 rows.

## Example 2: an order with payments and refunds

`examples/02_order_flow/` is a state machine. Events arrive over time, in any order, and some arrive twice (a webhook sent again, a job run again).

```
        pay (part)
         ┌────┐
         │    ▼
         └── placed ── pay (rest) ──▶ paid ── ship ──▶ shipped
               │                       │
             cancel                  cancel
               │                       │
               └──────▶ cancelled ◀────┘
                          │   ▲
                          └───┘
                         refund
```

```ruby
module OrderFlow
  Order  = Data.define(:status, :total, :paid, :refunded, :seen)
  Pay    = Data.define(:id, :amount)
  Ship   = Data.define(:id)
  Cancel = Data.define(:id)
  Refund = Data.define(:id, :amount)

  module_function

  def start(total)
    raise ArgumentError, "total must be positive" unless total.positive?

    Order.new(status: :placed, total:, paid: 0, refunded: 0, seen: [])
  end

  def apply(order, event)
    case [order.status, event]
    in [:placed, Pay(amount:)] if amount.positive? && order.paid + amount <= order.total
      paid = order.paid + amount
      order.with(paid:, status: paid == order.total ? :paid : :placed)
    in [:paid, Ship]
      order.with(status: :shipped)
    in [:placed | :paid, Cancel]
      order.with(status: :cancelled)
    in [:cancelled, Refund(amount:)] if amount.positive? && order.refunded + amount <= order.paid
      order.with(refunded: order.refunded + amount)
    else
      nil
    end
  end

  def step(order, event)
    return order if order.seen.include?(event.id)

    nxt = apply(order, event)
    nxt ? nxt.with(seen: order.seen + [event.id]) : order
  end

  def run(order, events)
    events.reduce(order) { |acc, event| step(acc, event) }
  end
end
```

The Lean copy of `apply` is the same `case/in`, written as a `match`:

```lean
def apply (order : Order) (event : Event) : Option Order :=
  match order.status, event with
  | .placed, .pay _ amount =>
    if amount > 0 ∧ order.paid + amount ≤ order.total then
      let paid := order.paid + amount
      some { order with paid, status := if paid = order.total then .paid else .placed }
    else none
  | .paid, .ship _ => some { order with status := .shipped }
  | .placed, .cancel _ | .paid, .cancel _ => some { order with status := .cancelled }
  | .cancelled, .refund _ amount =>
    if amount > 0 ∧ order.refunded + amount ≤ order.paid then
      some { order with refunded := order.refunded + amount }
    else none
  | _, _ => none
```

The rule that must always hold:

```lean
/-- Money and status always agree. -/
structure Valid (o : Order) : Prop where
  refunded_not_negative : 0 ≤ o.refunded
  refunded_le_paid : o.refunded ≤ o.paid
  paid_le_total : o.paid ≤ o.total
  placed_still_owes : o.status = .placed → o.paid < o.total
  paid_in_full : o.status = .paid ∨ o.status = .shipped → o.paid = o.total
  refund_only_when_cancelled : 0 < o.refunded → o.status = .cancelled
```

Verdicts:

```
PROVEN   valid_after_any_events       from a fresh start, ANY list of events keeps Valid
PROVEN   step_twice                   a retried event changes nothing
PROVEN   step_follows_diagram         the status only moves along the diagram above
PROVEN   shipped_is_final             no event changes a shipped order
REFUTED  refund_not_always_possible   pay 100, then ship: no event can refund the money
ASSUMED  event ids and amounts are Integers
```

The key technique: prove that **one step** keeps the rule (`apply_valid`, `step_valid`). Then a short induction gives the rule for **every** list of events:

```lean
theorem run_valid (hv : Valid o) : Valid (run o events) := by
  induction events generalizing o with
  | nil => exact hv
  | cons e events ih => exact ih (step_valid hv)
```

The same pattern works for reducers, background jobs, and anything that folds events into state.

The diagram is data too (`allowed : Status → Status → Bool`). `step_follows_diagram` proves that the code never makes a status move that the diagram does not have. So the diagram and the code cannot quietly disagree.

The refuted rule is a **product question**, not a code bug. "A customer can always get their money back" is false once an order ships. That can be the right design (returns are a separate process), or it can be a missing feature. The proof cannot decide that for you. It only makes sure someone decides.

The conformance probe runs every sequence of up to 4 events over 10 sample events (including duplicate ids, negative amounts, and over-payments), plus the error rows. It then adds 3,000 random sequences from a fixed seed: up to 12 events, totals up to 10^18, and colliding ids. That is 14,113 rows.

## How to verify new code

1. **Pick the core.** Choose one function or state machine. Move I/O out into the shell first.
2. **Write the rules in plain words first.** Take them from intent: what the callers need, product rules, validations. Never take a rule only from the code under test, because then it proves nothing.
3. **Copy the code into Lean**, line for line. Write every simplification on the `Trust:` line of the model.
4. **State and prove.** Put a proven rule under `## Proven` and a counterexample under `## Refuted`. Search small grids with `#eval` to find witnesses fast.
5. **Write the probe.** `probe.lean` prints `input => output` rows over a grid: every edge case plus a dense block of small values. It then adds random rows from a fixed seed, with large values and long inputs that the grid does not reach. `probe.rb` reads the inputs, runs the real Ruby, and prints the same rows. A diff is a bug in the model until you prove otherwise. Fix the model, never the Ruby.
6. **Write the repro.** `counterexamples.rb` runs each refuted witness against the Ruby and prints `REPRODUCED`.
7. **Lock it.** Add the Ruby file to `models.lock`.

Tactics that cover most business code:

| Goal | Tactic |
|---|---|
| Finite cases (an enum, a small list, a concrete witness) | `decide`, `rfl` |
| Linear arithmetic on `Int`/`Nat`, `min`, `max` | `omega` |
| Unfold a definition, take apart an `if` or a `match` | `unfold f`, `split`, `cases x`, `simp` |
| A rule over a list or a sequence of steps | `induction xs generalizing state` |

The project uses core Lean only, with no Mathlib, so the setup stays small and the build is fast.

## Project layout

```
bin/verify                  runs every check below; exits non-zero on the first failure
bin/check-style             rejects Ruby outside the verifiable subset (Prism)
lib/verifiable_style.rb     the rules bin/check-style applies
test/                       tests for the style checker
.github/workflows/          CI: runs the tests and bin/verify on every push
models.lock                 SHA-256 of each verified Ruby file (the drift lock)
lakefile.toml               one Lean library per example
lean-toolchain              pins the Lean version
examples/
  01_money_split/
    money_split.rb          the Ruby under verification
    MoneySplit.lean         model, rules, proofs, counterexamples
    probe.lean              prints input => output rows from the model
    probe.rb                reads those inputs, prints rows from the real Ruby
    counterexamples.rb      runs each refuted witness against the Ruby
  02_order_flow/
    (same files)
```

## Requirements and commands

* Lean 4 through [elan](https://github.com/leanprover/elan). The first build installs the version in `lean-toolchain`.
* Ruby 3.2 or later (for `Data` and pattern matching). The verified code needs no gems.
* The style checker needs the `prism` gem, 1.2 or later: `gem install prism`.

```bash
bin/verify            # proofs, drift lock, conformance, counterexamples
bin/verify --relock   # after you check the model again against changed Ruby
bin/check-style FILE  # verifiable-Ruby check only
ruby test/verifiable_style_test.rb   # tests for the style checker
lake build            # proofs only
```

To add an example, create `examples/NN_name/` with the five files above. Then add a `[[lean_lib]]` entry to `lakefile.toml` and run `shasum -a 256 examples/NN_name/name.rb >> models.lock`.

## Limits

* **The model is written by hand.** Conformance tests it on a finite grid plus random rows, and the drift lock forces a new check after every Ruby change. That is strong evidence that the model matches the Ruby. It is not a proof of it.
* **Ruby itself is trusted.** `Integer`, `Data`, `divmod`, and pattern matching are taken to work as documented.
* **The shell stays assumed.** The database, transactions, concurrency across processes, external APIs, and the clock are outside the model.
* **A proof is only as good as its rule.** A wrong rule gets proven just as well as a right one. Write rules from intent.
* **Lean's kernel is trusted.** `native_decide` would add the compiler to the trusted base as well. These examples do not use it.

## Roadmap

* A Prism-to-Lean translator for the verifiable subset. It would remove the hand copy, so the model could no longer drift from the code.
