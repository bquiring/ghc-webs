-- Functions over pairs passed to polymorphic functions.
--
-- 'opaque :: a -> Int' only sees the function as a value of type a.  The
-- type argument opaque @((Int, Int) -> Int) is rewritten along with
-- everything else, to opaque @((# Int, Int #) -> Int), so mulP's web is
-- still raised.
--
-- 'app :: (a -> b) -> a -> b' applies the function itself, at the
-- polymorphic type a -> b.  Inside app, the arrow's argument is the type
-- variable a, not a pair, so addP's web cannot be raised without
-- specialising app; it is rejected (argument not a product), and the
-- program stays well-typed (Web Lint checks).
module Main (main) where

app :: (a -> b) -> a -> b
app f x = f x
{-# NOINLINE app #-}

opaque :: a -> Int
opaque x = length [x, x]
{-# NOINLINE opaque #-}

useP :: ((Int, Int) -> Int) -> Int
useP f = f (1, 2) + f (3, 4)
{-# NOINLINE useP #-}

addP :: (Int, Int) -> Int
addP (a, b) = a + b
{-# NOINLINE addP #-}

mulP :: (Int, Int) -> Int
mulP (a, b) = a * b
{-# NOINLINE mulP #-}

main :: IO ()
main = print (app addP (1, 2), opaque mulP, useP mulP)
