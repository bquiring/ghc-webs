-- letrecE (Datasplit008A, aeson's Data.Aeson.Internal.TH) records bindings with
-- atomicModifyIORef: data splitting must leave the pair its function returns
-- alone (Note [Non-parametric functions] in GHC.WebCore.DataSplit).  Runs the
-- Q computations in IO (newName, runIO and varE need no splice).
module Main (main) where

import Language.Haskell.TH
import Datasplit008A

plus :: ExpQ -> ExpQ -> ExpQ
plus a b = infixE (Just a) (varE (mkName "+")) (Just b)

main :: IO ()
main = do
  e <- runQ (autoletE (\i -> litE (integerL i))
                      (\get -> foldr (\i acc -> plus (get i) acc) (get 0) [1 .. 5 :: Integer]))
  putStrLn (pprint e)
  e2 <- runQ (letrecE (\self i -> if i <= 0 then litE (integerL 0) else plus (litE (integerL 1)) (self (i - 1)))
                      (\get -> get (4 :: Integer)))
  putStrLn (pprint e2)
