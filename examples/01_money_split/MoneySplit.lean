/-!
# Model of `money_split.rb`

Source: examples/01_money_split/money_split.rb
Trust:
* Ruby `Integer` is Lean `Int`, Ruby `Array` is Lean `List`.
* `raise ArgumentError, msg` is `.error msg`.
* Ruby `divmod` rounds down; Lean `/` and `%` round down too when the divisor is positive.
  The guard makes the divisor positive. The conformance probe checks negative inputs as well.
-/
namespace MoneySplit

def remainder_last (total parts : Int) : Except String (List Int) :=
  if ¬ parts > 0 then .error "parts must be positive" else
  if total < 0 then .error "total must not be negative" else
  let base := total / parts
  .ok (List.replicate (parts - 1).toNat base ++ [total - base * (parts - 1)])

def even (total parts : Int) : Except String (List Int) :=
  if ¬ parts > 0 then .error "parts must be positive" else
  if total < 0 then .error "total must not be negative" else
  let base := total / parts
  let extra := total % parts
  .ok ((List.range parts.toNat).map fun (i : Nat) => if (i : Int) < extra then base + 1 else base)

/-! ## Invariants -/

/-- No cent is lost and no cent is made up. -/
def SumsTo (total : Int) (xs : List Int) : Prop := xs.sum = total

/-- No part is more than one cent bigger than any other part. -/
def Fair (xs : List Int) : Prop := ∀ a ∈ xs, ∀ b ∈ xs, a ≤ b + 1

/-! ## Proven -/

theorem even_fails_only_on_bad_input :
    (∃ msg, even total parts = .error msg) ↔ parts ≤ 0 ∨ total < 0 := by
  unfold even
  split
  · simp; omega
  · split <;> simp <;> omega

theorem even_length (h : even total parts = .ok xs) : xs.length = parts.toNat := by
  unfold even at h
  split at h; · contradiction
  split at h; · contradiction
  injection h with h; subst h
  simp

theorem sum_spread (n : Nat) (k b : Int) (hk : 0 ≤ k) :
    ((List.range n).map fun (i : Nat) => if (i : Int) < k then b + 1 else b).sum = n * b + min k n := by
  induction n with
  | zero => simp; omega
  | succ n ih =>
    rw [List.range_succ, List.map_append, List.sum_append, ih]
    simp only [List.map_cons, List.map_nil, List.sum_cons, List.sum_nil]
    rw [show ((n + 1 : Nat) : Int) = n + 1 by omega, Int.add_mul, Int.one_mul]
    split <;> omega

theorem even_sums_to_total (h : even total parts = .ok xs) : SumsTo total xs := by
  unfold even at h
  split at h; · contradiction
  split at h; · contradiction
  injection h with h; subst h
  have hp : 0 < parts := by omega
  rw [SumsTo, sum_spread _ _ _ (Int.emod_nonneg _ (by omega)), Int.toNat_of_nonneg (by omega)]
  have := Int.mul_ediv_add_emod total parts
  have := Int.emod_lt_of_pos total hp
  omega

theorem even_is_fair (h : even total parts = .ok xs) : Fair xs := by
  unfold even at h
  split at h; · contradiction
  split at h; · contradiction
  injection h with h; subst h
  intro a ha b hb
  simp only [List.mem_map] at ha hb
  obtain ⟨i, _, rfl⟩ := ha
  obtain ⟨j, _, rfl⟩ := hb
  split <;> split <;> omega

theorem even_parts_not_negative (h : even total parts = .ok xs) : ∀ a ∈ xs, 0 ≤ a := by
  unfold even at h
  split at h; · contradiction
  split at h; · contradiction
  injection h with h; subst h
  have := (Int.ediv_nonneg_iff_of_pos (a := total) (b := parts) (by omega)).mpr (by omega)
  intro a ha
  simp only [List.mem_map] at ha
  obtain ⟨i, _, rfl⟩ := ha
  split <;> omega

theorem remainder_last_sums_to_total (h : remainder_last total parts = .ok xs) :
    SumsTo total xs := by
  unfold remainder_last at h
  split at h; · contradiction
  split at h; · contradiction
  injection h with h; subst h
  rw [SumsTo, List.sum_append, List.sum_replicate_int, Int.toNat_of_nonneg (by omega),
    Int.mul_comm (total / parts), List.sum_cons, List.sum_nil]
  omega

/-! ## Refuted (counterexamples) -/

-- 11 cents over 4 people gives [2, 2, 2, 5]: the last person pays 3 cents more.
theorem remainder_last_is_not_fair :
    ¬ ∀ total parts xs, remainder_last total parts = .ok xs → Fair xs := by
  intro h
  have := h 11 4 [2, 2, 2, 5] rfl 5 (by decide) 2 (by decide)
  omega

end MoneySplit
