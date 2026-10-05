-- Laziness: a curried function strict in its first argument, but only once
-- fully applied.  The partial application  f (g n)  is a value that never
-- forces (g n), so forcing it must terminate.  The saturation depth of the
-- web is 2, so only calls with two arguments evaluate the first one.  This
-- test fails if the partial application evaluates its argument.
module Main (main) where

g :: Int -> Int
g n = if n > 5 then error "strict003: argument evaluated" else n
{-# NOINLINE g #-}

forcePartial :: (Int -> Int -> Int) -> Int -> ()
forcePartial f n = f (g n) `seq` ()
{-# NOINLINE forcePartial #-}

applyFull :: (Int -> Int -> Int) -> Int -> Int
applyFull f n = f (g n) n
{-# NOINLINE applyFull #-}

add :: Int -> Int -> Int
add x y = if x > 0 then x * 2 + y else y - x
{-# NOINLINE add #-}

main :: IO ()
main = print (forcePartial add 10, applyFull add 3)
