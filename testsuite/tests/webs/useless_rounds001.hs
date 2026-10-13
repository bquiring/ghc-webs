-- Useless elimination reached a fixpoint only at its round limit: around a
-- call it cannot mask (the primop unsafeFreezeArray#, whose state token is
-- dead) the rewrite builds a projection, case e of (# s, a #) -> (# a #),
-- and the next round took the projection's dead s as a change and built it
-- again (Cabal-syntax's Language.Haskell.Extension, the same accumArray).
-- The pass must settle in two rounds (-dshow-passes shows them).
module Main (main) where

import Data.Array

data Colour = Red | Green | Blue | Cyan | Magenta | Yellow
  deriving (Show, Eq, Ord, Enum, Bounded)

table :: Array Char [(String, Colour)]
table = accumArray (flip (:)) [] ('a', 'z')
          [ (head s, (s, c)) | c <- [minBound .. maxBound], let s = map toLower' (show c) ]
  where toLower' ch = if ch >= 'A' && ch <= 'Z' then toEnum (fromEnum ch + 32) else ch

lookupColour :: String -> Maybe Colour
lookupColour s@(c : _) | inRange (bounds table) c = lookup s (table ! c)
lookupColour _ = Nothing

main :: IO ()
main = mapM_ (print . lookupColour) ["red", "cyan", "blue", "black", ""]
