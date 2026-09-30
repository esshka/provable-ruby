---
name: verifiable-ruby
description: >
  Write or refactor Ruby into "verifiable Ruby": a pure, integer-only, immutable subset that
  provable-ruby's bin/translate turns into Lean 4 line for line. Covers splitting Rails/ActiveRecord
  code into a pure core plus a thin shell, the `#:` / `# @rbs type` type comments, exactly which
  Ruby the translator accepts, and how to fix every bin/check-style and bin/translate error. Use
  when preparing Ruby for proofs, when check-style or translate fails, or when the user asks for
  pure, side-effect-free, deterministic or "provable" Ruby business logic.
---

# Verifiable Ruby

Plain Ruby 3.2+, no gems, easy to read and test. Each construct has one Lean meaning, so
`${CLAUDE_PLUGIN_ROOT}/bin/translate` can write the model and nobody copies code by hand.

Check a file: `ruby ${CLAUDE_PLUGIN_ROOT}/bin/check-style path/to/core.rb` (silent = pass).
The translator is stricter than the checker; the real test is `${CLAUDE_PLUGIN_ROOT}/bin/translate proofs`.

## The rules

1. **Pure core, thin shell.** The core never touches the database, clock, randomness, network,
   env or globals. The shell loads data, calls the core with plain values, and saves the result.
2. **Values, not objects.** `Data.define` for records; `record.with(field: x)` for a new value. No mutation.
3. **Closed choices as data.** Symbols for statuses, one `Data` class per event kind, `case/in` with an explicit `else`.
4. **Integers only.** Money in cents, time in whole days or seconds. No `Float`.
5. **Visible failure.** Guards at the top raise `ArgumentError`. Return `nil` only for "no result". No `rescue`.
6. **Loops are folds.** `map`, `select`, `sum`, `reduce`, `Array.new(n) { |i| }`. No `each`, `while`, `break`, `next`.
7. **No metaprogramming.** No `send`, `define_method`, `method_missing`, monkey patches, callbacks.
8. **Types in comments.** Every `def` and `Data.define` has a `#:` line above it (RBS syntax).

## File shape

One file = one `module` with `module_function`. Only `Data.define` constants and `def`s inside.

```ruby
# frozen_string_literal: true

module OrderFlow
  # @rbs type status = :placed | :paid | :cancelled
  # @rbs type event = Pay | Cancel

  #: (status, Integer, Array[Integer])
  Order  = Data.define(:status, :total, :seen)
  #: (Integer, Integer)
  Pay    = Data.define(:id, :amount)
  #: (Integer)
  Cancel = Data.define(:id)

  module_function

  #: (Integer) -> Order
  def start(total)
    raise ArgumentError, "total must be positive" unless total.positive?

    Order.new(status: :placed, total:, seen: [])
  end

  #: (Order, event) -> Order?
  def apply(order, event)
    case [order.status, event]
    in [:placed, Pay(amount:)] if amount == order.total
      order.with(status: :paid)
    in [:placed | :paid, Cancel]
      order.with(status: :cancelled)
    else
      nil
    end
  end
end
```

A symbol alias becomes `inductive Status`, a class alias becomes `inductive Event` with one
constructor per class, and a `Data` class outside any union becomes a `structure`.

Types: `Integer`, `String`, `bool`, `Array[T]`, `T?` (nil-able), a `# @rbs type` name, a `Data` class name.
A field common to every member of a union (like `id`) becomes an accessor: `event.id` works.

## What the translator accepts

| Ruby | Lean |
|---|---|
| `raise ArgumentError, "msg" unless c` / `if c` at the top | `if ¬ c then .error "msg" else` (result becomes `Except String T`) |
| `return x if c` at the top | `if c then x else` |
| `x = expr` (each name once) | `let x := expr` |
| `q, r = a.divmod(b)` | `let q := a / b` `let r := a % b` |
| `x = f(...)` with `f` returning `T?`, then only `x ? a : b` | `match f ... with \| some x => a \| none => b` |
| `c ? a : b`, `if/elsif/else` | `if c then a else b` |
| `case [a, b] in [...] ... else ... end` | `match a, b with ... \| _, _ =>` |
| patterns `:sym`, `:a \| :b`, `Klass`, `Klass(field:)`, `Klass(field: name)`, `name` | `.sym`, alternatives, `.klass _ field` |
| `in pattern if guard` | `if guard then ... else <the case's else>` |
| `&&` `\|\|` `!` `==` `!=` `<` `<=` `+ - * / %` | `∧ ∨ ¬ = ≠ < ≤ + - * / %` (`+` on arrays is `++`) |
| `x.positive?` `negative?` `zero?`, `xs.include?(x)` | `x > 0`, `x < 0`, `x = 0`, `x ∈ xs` |
| `rec.field`, `rec.with(a: 1)`, `Rec.new(a: 1, b:)` | `rec.field`, `{ rec with a := 1 }`, `{ a := 1, b }` |
| `Member.new(id: 1)` for a union member | `Event.member 1` |
| `Array.new(n, v)`, `Array.new(n) { \|i\| e }` | `List.replicate n.toNat v`, `(List.range n.toNat).map fun (i : Nat) => e` |
| `xs.map { \|x\| e }`, `select`, `sum`, `length` | `xs.map fun x => e`, `filter`, `.sum`, `(xs.length : Int)` |
| `xs.reduce(init) { \|acc, x\| f(acc, x) }` | `xs.foldl f init` |
| `[a, b].min`, `[a, b].max` | `min a b`, `max a b` |
| `f(a, b)` (another method in the module) | `f a b` |

Not supported (translate stops with the line number): keyword or default parameters, `_1`/`it`
block params, multi-statement blocks, string interpolation, hashes, `Float`, reassigning a local,
a method that both raises and returns `T?`, calling a method that raises from another method,
a guarded `in` arm when a later arm could also match (Ruby would fall through to it).

## Refactor recipe (Rails → core + shell)

1. Find the decision inside the model, job or controller: the math or the status change.
2. Write a module function that takes plain integers, symbols and `Data` values and returns a new value.
   Dates become day counts computed in the shell, money becomes cents, records become `Data` snapshots.
   A `class` with `def self.x` becomes a `module` with `module_function`; callers like `Discount.price(...)`
   keep working.
3. The shell calls it and persists: `update!(fee_cents: LateFee.fee(balance_cents, (today - due_on).to_i))`.
   Retries are now safe, because the core has no state of its own.
4. Keep behavior identical. Run the app's tests before and after. If the old code had a bug, keep it
   in this step and let the proof find it; fixing it is a separate, visible change the user decides on.
   One change is unavoidable: Float money becomes integer cents. When the Float code rounds, write the
   rounding explicitly in integers (e.g. half up for non-negative values: `(cents * (100 - pct) + 50) / 100`),
   state it as a rule of its own, and tell the user it can differ from `Float#round` at exact half cents.

## Fixing errors

| Error | Fix |
|---|---|
| `[folds] no each` / `while` | `map`/`select`/`reduce`, or `Array.new(n) { \|i\| }` |
| `[integers] no Float` | integer cents or units; round in the shell |
| `[pure] no Time` / `puts` / `$x` / `@x` | pass the value in as a parameter from the shell |
| `[values] no mutation (<<)` / `x is reassigned` | build a new value; bind a new name |
| `[case-else]` | add `else` (often `nil` or `raise ArgumentError`) |
| `[failure] no rescue` | validate with guards; let errors surface |
| `needs a #: ... comment` | add the type line directly above the `def` / `Data.define` |
| `unsupported call` / `unsupported expression` | rewrite with a construct from the table above |
| `if this guard fails, Ruby tries a later arm` | move the guard into the arm body with `c ? a : b`, or reorder so no later arm overlaps |
| `Lean` `/` differs on a negative divisor | Ruby floors, Lean `Int` division is Euclidean; guard the divisor positive |
