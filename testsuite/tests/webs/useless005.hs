-- Note [Useless elimination], laziness: dead lazy arguments that are
-- bottom (an error, a loop, undefined) are never evaluated, before or after
-- the parameter is deleted.
module Main (main) where

apply3 :: (Int -> Int -> Int -> Int) -> Int -> Int
apply3 h n = h n (errorWithoutStackTrace "useless005: second forced")
                 (let loop k = loop (k + 1) :: Int in loop n)
{-# NOINLINE apply3 #-}

main :: IO ()
main = print (apply3 (\a _ _ -> a + 1) 4, apply3 (\a _ _ -> a * 2) 5)
