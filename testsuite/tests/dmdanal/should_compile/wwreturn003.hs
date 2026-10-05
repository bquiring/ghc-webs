-- WORKING-THE-WORKER-WRAPPER.md, approach 1 as the document describes it:
-- f is large and used twice, so it is still let-bound when worker/wrapper
-- runs.  Worker/wrapper splits f into $wf (dead y dropped, x unboxed) and a
-- wrapper  \x _ -> case x of I# x# -> $wf x#,  which g returns.  g is too big
-- to inline, so every call through h1 and h2 is an unknown call of the
-- wrapper, passing the dead argument and boxed Ints.  Approach 2 would split
-- g as well, so that h1 = $wg' n returns $wf itself and the calls become
-- h1 a#.
-- (If f were used once, the simplifier would inline its binding before
-- worker/wrapper runs, whatever its size: wwreturn002.)
module WWReturn003 (run) where

g :: Int -> (Int -> Int -> Int)
g n = let k = sum [1 .. n]
          f x y = (x * 1 + k) * (x - 1)
               + (x * 2 + k) * (x - 2)
               + (x * 3 + k) * (x - 3)
               + (x * 4 + k) * (x - 4)
               + (x * 5 + k) * (x - 5)
               + (x * 6 + k) * (x - 6)
               + (x * 7 + k) * (x - 7)
               + (x * 8 + k) * (x - 8)
               + (x * 9 + k) * (x - 9)
               + (x * 10 + k) * (x - 10)
               + (x * 11 + k) * (x - 11)
               + (x * 12 + k) * (x - 12)
               + (x * 13 + k) * (x - 13)
               + (x * 14 + k) * (x - 14)
               + (x * 15 + k) * (x - 15)
               + (x * 16 + k) * (x - 16)
               + (x * 17 + k) * (x - 17)
               + (x * 18 + k) * (x - 18)
               + (x * 19 + k) * (x - 19)
               + (x * 20 + k) * (x - 20)
               + (x * 21 + k) * (x - 21)
               + (x * 22 + k) * (x - 22)
               + (x * 23 + k) * (x - 23)
               + (x * 24 + k) * (x - 24)
               + (x * 25 + k) * (x - 25)
               + (x * 26 + k) * (x - 26)
               + (x * 27 + k) * (x - 27)
               + (x * 28 + k) * (x - 28)
               + (x * 29 + k) * (x - 29)   -- y dead
      in if n > 100 then f else \x y -> f (x + 1) y

run :: Int -> Int -> Int -> Int -> Int
run n m a b = let h1 = g n
                  h2 = g m
              in h1 a b + h1 b a + h2 a b + h2 b a
