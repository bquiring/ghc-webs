-- -dcore-webs-lint: Core Lint after the web pipeline only, and no Web Lint
-- after the transformations (Note [Checking the web pipeline] in
-- GHC.WebCore.Pipeline).  Useless elimination changes this program in its
-- first round (useless_rounds001); without -dcore-lint, Web Lint must not
-- run after it.
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
