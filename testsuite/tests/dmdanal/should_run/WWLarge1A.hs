-- The library part of a larger example for higher-order worker/wrapper
-- (-fworker-wrapper-function-results): text processing.  Cases marked [+]
-- should be split, [-] should not (the reason is given).
module WWLarge1A (mkFormatter, mkMatcher, mkScorer, register, runMatcher, twice, walk, withScorer, Matcher(..)) where


import Data.Char (ord, isUpper, toLower)
import Data.List (foldl')

------------------------------------------------------------------------
-- [+ result] mkScorer builds a weight table, then returns a scoring
-- function whose second argument (a debug flag) is dead.  The partial
-- application  mkScorer key  is shared by many calls, so it cannot be
-- eta-expanded.
mkScorer :: String -> (String -> Bool -> Int)
mkScorer key =
  let table = [ (c, i * 7 + length key) | (i, c) <- zip [1 :: Int ..] (key ++ ['a' .. 'z']) ]
      weight c = maybe 1 id (lookup (toLower c) table)
  in \w _dbg -> foldl' (\acc c -> (acc * 31 + weight c + (if isUpper c then 3 else 0)) `mod` 1000003)
                       (length w) w

------------------------------------------------------------------------
-- [+ result, two levels] mkFormatter does work at two levels; the dead
-- argument (a padding character) is at the second.
mkFormatter :: Int -> (String -> (Int -> Char -> String))
mkFormatter width =
  let pad = width * 2 + 1
  in \prefix -> let hdr = take pad (cycle prefix)
                in \n _padChar -> hdr ++ show (n * pad) ++ reverse hdr

------------------------------------------------------------------------
-- [+ argument] withScorer passes its local scorer, whose second argument
-- is dead, to the consumer k.
withScorer :: ((String -> Int -> Int) -> Int) -> Int -> Int
withScorer k salt =
  let base = sum [ ord c | c <- show salt ] * 13
      score w _unused = foldl' (\acc c -> (acc * 17 + ord c + base) `mod` 999983) salt w
  in k score + score "salt" 0

------------------------------------------------------------------------
-- [- argument] the handler parameter escapes: it is stored in the result,
-- so it could be called with anything later.
register :: ((String -> Int -> Int) -> Int) -> Int -> (Int, [(String -> Int -> Int) -> Int])
register h n =
  let tag w _ = length w * n + sum (map ord w)
  in (h tag, replicate n h)

------------------------------------------------------------------------
-- [- result] newtype-wrapped returned function: the tail is a cast, which
-- the split does not look through (yet).
newtype Matcher = Matcher (String -> Int -> Bool)

mkMatcher :: String -> Matcher
mkMatcher pat = let lp = length pat
                    sig = sum (map ord pat)
                in Matcher (\w _limit -> length w == lp && sum (map ord w) == sig)

runMatcher :: Matcher -> String -> Bool
runMatcher (Matcher m) w = m w 0

------------------------------------------------------------------------
-- [- argument] recursive: walk passes its consumer on to itself, so the
-- consumer is not only called.
walk :: ((Int -> Int -> Int) -> Int) -> [Int] -> Int
walk k []       = 0
walk k (x : xs) = let step a _b = a * x + length xs
                  in k step + walk k xs

------------------------------------------------------------------------
-- [- small] small enough to be inlined whole: not split
twice :: (Int -> Int) -> Int -> Int
twice f x = f (f x)

