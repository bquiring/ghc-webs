-- Note [Fresh binders for useless elimination]: GHC's Core binds the same
-- unique (a go1 from list comprehensions) in two case branches of expand.
-- Keyed by unique, the two binding sites shared one element, and a live let
-- was deleted while its uses stayed (Web Lint: out of scope).  From nofib
-- imaginary/gen_regexps.
module Main (main) where

expand :: String -> [String]
expand []        = [""]
expand ('<' : x) = numericRule x
expand ('[' : x) = alphabeticRule x
expand x         = constantRule x

constantRule :: String -> [String]
constantRule (c : rest) = [ c : z | z <- expand rest ]
constantRule []         = []

alphabeticRule :: String -> [String]
alphabeticRule (a : '-' : b : ']' : rest)
  | a <= b    = [ c : z | c <- [a .. b], z <- expand rest ]
  | otherwise = [ c : z | c <- reverse [b .. a], z <- expand rest ]
alphabeticRule _ = []

numericRule :: String -> [String]
numericRule x
  = [ pad (show i) ++ z | i <- if u < v then [u .. v] else [u, u - 1 .. v], z <- expand s ]
  where
    (p, _ : q) = span (/= '-') x
    (r, _ : s) = span (/= '>') q
    (u, v)     = (read p :: Int, read r)
    pad str    = replicate (length r - length str) '0' ++ str

main :: IO ()
main = do
  print (length (expand "[a-c]x<1-12>[d-b]"))
  print (take 4 (expand "a<8-11>[x-y]"))
