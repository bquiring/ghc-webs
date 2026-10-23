-- roundtrip002: two inlined foldrs at one type in one binding share the
-- uniques of their locals; one z is a data structure ([eofName]), the other
-- not.  Restoring occurrences by unique gave the second z's occurrences the
-- first's evaluated unfolding (CPR analysis's assertion; happy's Mangler).
-- Note [Occurrences after the round trip] in GHC.WebCore.Erase.
module Main where

eofName :: String
eofName = "%eof"
{-# NOINLINE eofName #-}

getTerm :: Int -> [String]
getTerm n = [show n | even n]
{-# NOINLINE getTerm #-}

check :: [Int] -> [Int] -> ([String], Int) -> ([String], [String])
check dirs dirs2 extra = (terms, others)
  where
    terms  = concat (map getTerm dirs) ++ [eofName]
    others = concat (map getTerm dirs2) ++ (case extra of (a, _) -> a)
{-# NOINLINE check #-}

main :: IO ()
main = print (check [1 .. 6] [7 .. 12] (["x"], 0))
