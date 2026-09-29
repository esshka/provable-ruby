import MoneySplit
open MoneySplit

def render : Except String (List Int) → String
  | .ok xs => " ".intercalate (xs.map toString)
  | .error msg => s!"error: {msg}"

def rows (total parts : Int) : List String :=
  [s!"remainder_last {total} {parts} => {render (remainder_last total parts)}",
   s!"even {total} {parts} => {render (even total parts)}"]

-- A fixed seed gives the same rows every run, so a failing diff can be replayed.
def rand (lo hi : Int) : StateM StdGen Int := modifyGet fun g =>
  let (n, g) := randNat g 0 (hi - lo).toNat
  (lo + n, g)

-- Random magnitude up to 10^20, past 64 bits, so Ruby bignums are covered too.
def randomCase : StateM StdGen (Int × Int) := do
  let e ← rand 0 20
  let total ← rand (-10) (10 ^ e.toNat)
  let parts ← rand (-2) 300
  pure (total, parts)

def main : IO Unit := do
  for total in (List.range 64).map (fun (n : Nat) => (n : Int) - 2) do
    for parts in (List.range 14).map (fun (n : Nat) => (n : Int) - 1) do
      (rows total parts).forM IO.println
  let cases := Id.run (((List.range 1000).mapM fun _ => randomCase).run' (mkStdGen 42))
  for (total, parts) in cases do
    (rows total parts).forM IO.println
