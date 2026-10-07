-- A copy of ../should_run/wwcpr001.hs, for the split statistics.
-- The deepest returned lambda builds a pair: (Cpr) in
-- Note [Worker/wrapper for function results].  [+] marks functions the
-- split should apply to, [-] functions it must leave alone.  The pairs'
-- fields are lazy (undefined, trace counts), and the work before the lambda
-- is shared by the partial application (trace counts).
module WWCprDump where

import Debug.Trace (trace)

-- [+] Work, then a lambda building a pair; one field is undefined in one
-- branch, and a branch is a dead end
step :: Int -> Int -> Int -> (Int, Int)
step a b = let t = trace "step: work" (sum [a .. b] * 3 - a) in
           \s -> if s > t + 1000 then error "step: too big"
                 else if s > t then (s - t, trace "step: lazy field" (t * 2 + s))
                 else if s == t then (t, undefined)
                 else (t + s, s * s - t)

-- [+] A state-monad action, as in real/veritas: the state is threaded
-- through a shared computation
type St = (Int, [String])

send :: [String] -> St -> (St, String)
send msgs (n, out) = ((n + length msgs, out ++ msgs), concat msgs)

setMsg :: String -> St -> (St, String)
setMsg m = let g = send (trace "setMsg: work" [m, reverse m, m ++ "!"]) in
           \st -> let r = g st in (fst r, "set:" ++ snd r)

-- [-] A sum type: no single constructor
pick :: Int -> Int -> Int -> Maybe Int
pick a b = let t = trace "pick: work" (product [a .. b] + a) in
           \s -> if s > t then Just (s - t) else if s < 0 then Nothing else Just (t * s + 1)

-- [-] (CprConsumed): its only caller binds the pair lazily, so a case
-- never meets the call
lazyTick :: Int -> Int -> (Int, Int)
lazyTick a = let t = trace "lazyTick: work" (sum [a .. a * 7] * 5 - a) in
             \s -> if s > t then (s - t, s * t + 1) else (t - s, t * s - 1)

-- [-] (CprConsumed): only used as a value (stored in a table)
stored :: Int -> Int -> (Int, Int)
stored a = let t = trace "stored: work" (product [1 .. a] - a * 3) in
           \s -> if s > t then (s + t, s - t) else (t, s)

table :: [Int -> Int -> (Int, Int)]
table = [stored, \a s -> (a, s)]

main :: IO ()
main = do
  let f = step 2 9
  print (fst (f 1), snd (f 1))
  print (fst (f 135))                     -- lazy field never traced
  print (snd (f 140))                     -- traced once
  print (fst (f 130))                     -- undefined field never forced
  print (map (fst . f) [1, 5, 20])        -- work shared: traced once for f
  print (step undefined 3 `seq` "partial application is a value")
  let h = setMsg "ab"
      (st1, o1) = h (0, [])
      (st2, o2) = h st1
  print (st2, o1, o2)
  print (snd (setMsg "x" (5, ["y"])))
  let p = pick 1 4
  print (p 3, p 100, p (-1))
  let r = lazyTick 3 40
  print (fst r)
  print (snd r)
  print (map (\g -> fst (g 4 30)) table)
