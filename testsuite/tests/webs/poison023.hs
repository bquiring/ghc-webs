-- Maybe and Either results whose unused branches hold poison. (Deadness and
-- strictness: the program must behave as it does unoptimised.)
module Main (main) where

poison :: String -> a
poison s = errorWithoutStackTrace ("UNREACHABLE: " ++ s)
{-# NOINLINE poison #-}

lookupish :: Int -> Either Int Int
lookupish n = if even n then Left (n * 2) else Right (poison "right side")
{-# NOINLINE lookupish #-}

onlyLeft :: Either Int Int -> Int
onlyLeft (Left a) = a
onlyLeft (Right _) = -1
{-# NOINLINE onlyLeft #-}

maybeish :: Int -> Maybe (Int, Int)
maybeish n = Just (n, poison "maybe second")
{-# NOINLINE maybeish #-}

main :: IO ()
main = print (map (onlyLeft . lookupish) [1 .. 6], fmap fst (maybeish 4))
