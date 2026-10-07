{-# LANGUAGE RankNTypes #-}
-- Worker/wrapper through function arguments when a type parameter comes
-- after value parameters (-fworker-wrapper-function-results; (TypeParams) in
-- Note [Worker/wrapper for function arguments]), as rank-2 types and
-- newtypes over them give.  Each function passes its local function, whose
-- second argument is dead, to its function parameter.  The dead argument is
-- undefined at the calls, and trace counts check that the work before the
-- calls is not repeated.
module Main (main) where

import Debug.Trace (trace)

-- A type parameter after a value parameter
late :: Int -> forall b. ((Int -> Int -> Int) -> b) -> [Int] -> (b, Int)
late n = \g xs ->
  let k = trace "late: work" (sum xs * n + length xs)
      f x _y = x * x * k + x * n + k * k + x * 3 + n * n * x + 7   -- y dead
  in (g f, f n n + sum (map (\x -> f x x) xs))

-- Recursive, passing g on unchanged with the same type argument: (Static)
-- with a later type parameter
loop :: Int -> forall b. ((Int -> Int -> Int) -> b -> b) -> b -> [Int] -> b
loop n = \g acc xs ->
  if n <= 0 then acc
  else let k = sum xs + n
           f x _y = x * k + n * n + x * x * 3 + k * 5 + 1           -- y dead
       in loop (n - 1) g (g f acc) (map (+ 1) xs)

-- Polymorphic recursion at the later type parameter: the recursive call
-- passes g on at [b].  b does not occur in g's type, so it still calls the
-- worker, at [b]
nest :: Int -> forall b. ((Int -> Int -> Int) -> Int) -> b -> [Int] -> (Int, [b])
nest n = \g x xs ->
  let k = sum xs * n + 1
      f y _z = y * k + n * y * y + k * k + 5                     -- z dead
  in if n <= 0 then (g f, [x])
     else case nest (n - 1) g [x, x] (map (* 2) xs) of
            (r, ys) -> (r + g f, concat ys)

-- A newtype over a rank-2 function type, as in effect encodings
newtype P = P (forall r. ((Int -> Int -> Int) -> r) -> r)

runP :: P -> ((Int -> Int -> Int) -> r) -> r
runP (P p) = p

mkP :: Int -> [Int] -> P
mkP n xs = P (\k -> let t = sum (map (\x -> x * x + n) xs) * n + length xs + 2
                        u = product (filter odd xs) + maximum (n : xs)
                        f x _y = x * t + n * x * x + t * t * 3 + x * u + u * u + 11   -- y dead
                    in k f)

main :: IO ()
main = do
  print (late 3 (\f -> f 2 undefined) [1 .. 10])
  print (late 2 (\f -> show (f 1 undefined + f 5 undefined)) [4, 5])
  print (fst (late 4 (\f -> f 0 undefined) [7]) `seq` "late: forced")
  print (loop 5 (\f acc -> f acc undefined `mod` 1000003) 1 [1, 2, 3])
  print (loop 3 (\f acc -> acc ++ [f 1 undefined]) [] [4])
  print (nest 3 (\f -> f 2 undefined) 'a' [1, 2], fst (nest 2 (\f -> f 1 undefined) () [5]))
  print (runP (mkP 3 [1, 2]) (\f -> f 2 undefined), runP (mkP 5 [3]) (\f -> f 1 undefined + f 0 undefined))
  let p = mkP 7 [trace "mkP: list" 1, 2]
  print (runP p (\f -> f 4 undefined), runP p (\f -> show (f 3 undefined)))
