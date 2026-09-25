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

def main : IO Unit := do
  for total in [-1, 0] do
    IO.println s!"{total} => {render (start total)}"
  for events in (List.range 5).flatMap words do
    let input := " ".intercalate ("100" :: events.map token)
    IO.println s!"{input} => {render ((start 100).map (run · events))}"
