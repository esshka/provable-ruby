import MoneySplit
open MoneySplit

def render : Except String (List Int) → String
  | .ok xs => " ".intercalate (xs.map toString)
  | .error msg => s!"error: {msg}"

def main : IO Unit := do
  for total in (List.range 64).map (fun (n : Nat) => (n : Int) - 2) do
    for parts in (List.range 14).map (fun (n : Nat) => (n : Int) - 1) do
      IO.println s!"remainder_last {total} {parts} => {render (remainder_last total parts)}"
      IO.println s!"even {total} {parts} => {render (even total parts)}"
