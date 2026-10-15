module Chunk007B (Report (..), HasOpts (..), report) where

import Chunk007A

data Report = Report { _ropts :: Opts, _title :: String }

instance HasOpts Report where
  opts f (Report o t) = fmap (\o' -> Report o' t) (f o)

report :: Int -> String
report n =
  let r  = Report defOpts "r"
      r' = over depth (+ n) (over ignore not r)
  in view name r' ++ " " ++ show (view depth r') ++ " " ++ show (view ignore r') ++ " " ++ _title r'
