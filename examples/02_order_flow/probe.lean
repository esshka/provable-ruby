import OrderFlow
open OrderFlow

def OrderFlow.Status.name : Status → String
  | .placed => "placed"
  | .paid => "paid"
  | .shipped => "shipped"
  | .cancelled => "cancelled"

def token : Event → String
  | .pay id amount => s!"pay:{id}:{amount}"
  | .ship id => s!"ship:{id}"
  | .cancel id => s!"cancel:{id}"
  | .refund id amount => s!"refund:{id}:{amount}"

def alphabet : List Event :=
  [.pay 1 40, .pay 2 60, .pay 3 100, .pay 4 (-5), .pay 1 60,
   .ship 5, .cancel 6, .refund 7 30, .refund 8 100, .refund 9 0]

def words : Nat → List (List Event)
  | 0 => [[]]
  | n + 1 => (words n).flatMap fun es => alphabet.map (es ++ [·])

def render : Except String Order → String
  | .ok o => s!"{o.status.name} {o.total} {o.paid} {o.refunded} {o.seen}"
  | .error msg => s!"error: {msg}"

def row (total : Int) (events : List Event) : String :=
  let input := " ".intercalate (toString total :: events.map token)
  s!"{input} => {render ((start total).map (run · events))}"

-- A fixed seed gives the same rows every run, so a failing diff can be replayed.
def rand (lo hi : Int) : StateM StdGen Int := modifyGet fun g =>
  let (n, g) := randNat g 0 (hi - lo).toNat
  (lo + n, g)

-- Amounts favor total and its halves, so random sequences still reach paid, shipped and refunds.
def randomEvent (total : Int) : StateM StdGen Event := do
  let id ← rand 1 8
  let r ← rand (-5) (total + 5)
  let amount := [total, total / 2, total - total / 2, r].getD (← rand 0 3).toNat r
  match (← rand 0 3).toNat with
  | 0 => pure (.pay id amount)
  | 1 => pure (.ship id)
  | 2 => pure (.cancel id)
  | _ => pure (.refund id amount)

def randomCase : StateM StdGen (Int × List Event) := do
  let e ← rand 0 18
  let total ← rand (-2) (10 ^ e.toNat)
  let n ← rand 0 12
  let events ← (List.range n.toNat).mapM fun _ => randomEvent total
  pure (total, events)

def main : IO Unit := do
  for total in [-1, 0] do
    IO.println s!"{total} => {render (start total)}"
  for events in (List.range 5).flatMap words do
    IO.println (row 100 events)
  let cases := Id.run (((List.range 3000).mapM fun _ => randomCase).run' (mkStdGen 42))
  for (total, events) in cases do
    IO.println (row total events)
