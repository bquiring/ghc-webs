-- happy's AttrGrammar.Mangler, reduced (Note [Data structures CPR analysis
-- cannot read] in GHC.WebCore.Erase): after the early run, a let-bound data
-- structure (z, a one-element list of split pairs) had an occurrence, in
-- another data structure's unfolding, that was not one; CPR analysis, which
-- runs next, asserted (CprAnal.hs, cprTransform)
module Main (main, formatRules) where

import Data.List ( groupBy )
import Data.Maybe ( fromMaybe )
import Roundtrip003A

formatRules :: [Int] -> [SubAssign] -> [Conditional] -> String
formatRules prods subRules conditions = localConditions ++ subProductionRules
  where
    subRulesMap :: [(Int, [(String, [Token])])]
    subRulesMap = map (\l -> foldr (\(_, x) (i, xs) -> (i, x : xs))
                                   (fst (head l), [snd (head l)])
                                   (tail l)) .
                  groupBy (\x y -> fst x == fst y) .
                  map (\(MkSubAssign (i, ident) toks) -> (i, (ident, toks))) $ subRules

    subProductionRules = concat (map formatSubRules prods)

    formatSubRules i =
      let attrs = fromMaybe [] (myLookup i subRulesMap)
      in show i ++ concat (map formatSubRule attrs)

    localConditions = concat (map formatCondition conditions)
    formatCondition (MkConditional toks) = concat (map formatToken toks)

    formatSubRule (attr, _) = attr

    formatToken (SubRef (i, x))
      | i `myElem` prods = x
    formatToken _ = ""

main :: IO ()
main = putStrLn (formatRules [1, 2]
                   [MkSubAssign (1, "a") [LBrace], MkSubAssign (2, "b") [], MkSubAssign (2, "c") []]
                   [MkConditional [SubRef (2, "d"), LBrace, SubRef (1, "e")]])
