-- The result of the outer arrow is hidden behind a type variable:
-- app :: (a -> r) -> a -> r is used with r := Int -> Int.  The web must be
-- rejected, or the program would become ill-typed (Web Lint checks).
module Main (main) where

app :: (a -> r) -> a -> r
app f x = f x
{-# NOINLINE app #-}

add2 :: Int -> Int -> Int
add2 a b = a * 2 + b
{-# NOINLINE add2 #-}

main :: IO ()
main = print (app add2 1 5)
