-- | Solving web constraints: union-find over the pairs of webs that Web Lint
-- collected.
module GHC.WebCore.Solve
  ( WebSolution(..)
  , solveWebs
  , pprWebStats
  ) where

import GHC.Prelude

import GHC.Types.Unique
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Types.Web

import GHC.Data.Bag
import GHC.Data.UnionFind

import GHC.Utils.Outputable

import Control.Monad.ST
import Data.List ( sortOn )
import qualified Data.List as List
import Data.Ord ( comparing )
import qualified Data.Map.Strict as Map

data WebSolution = WebSolution
  { ws_subst          :: WebSubst
      -- ^ Maps every web that is in a constraint to the representative of
      -- its class.  Webs not in the domain are their own representative.
  , ws_classes        :: [[WebId]]
      -- ^ The classes with more than one web, representative first
  , ws_exposed_reps   :: WebSet
      -- ^ Representatives of classes that contain an exposed web
  }

-- | Find a representative for each class of webs that the pairs make equal.
--
-- The representative is an exposed web if the class has one, and otherwise
-- the web with the smallest Unique, so the result does not depend on the
-- order of the pairs.  See Note [Exposed webs] in GHC.WebCore.Sigs
--
-- 'placeholderWeb' may appear in the pairs; it counts as exposed, but is
-- never a representative and is never renamed.
-- See Note [Arrows without webs] in GHC.WebCore.Lint
solveWebs :: WebSet -> Bag (WebId, WebId) -> WebSolution
solveWebs exposed0 pairs
  = WebSolution { ws_subst        = listToUFM [ (w, rep) | (rep, ws) <- classes, w <- ws
                                                         , w /= rep, not (isPlaceholderWeb w) ]
                , ws_classes      = [ rep : filter (/= rep) ws | (rep, ws) <- classes ]
                , ws_exposed_reps = mkUniqSet [ rep | (rep, ws) <- classes
                                                    , any (`elementOfUniqSet` exposed) ws ] }
  where
    exposed   = exposed0 `addOneToUniqSet` placeholderWeb
    pair_list = bagToList pairs
    webs      = nonDetEltsUniqSet $ mkUniqSet $ concat [ [w1, w2] | (w1, w2) <- pair_list ]

    -- Each class, as (representative, members)
    classes :: [(WebId, [WebId])]
    classes = sortOn (rank . fst)
              [ (pick_rep ws, sortOn rank ws) | ws <- groups, length ws > 1 ]

    -- Union-find: one Point per web; union each pair; group by root
    groups :: [[WebId]]
    groups = runST $ do
      { points <- mapM (\w -> (,) w <$> fresh w) webs
      ; let point_env = listToUFM points
            point w   = lookupWithDefaultUFM point_env (error "solveWebs") w
      ; mapM_ (\(w1, w2) -> union (point w1) (point w2)) pair_list
      ; roots <- mapM (\(w, p) -> (\r -> (getKey (getUnique r), [w])) <$> find p) points
      ; return (Map.elems (Map.fromListWith (++) roots)) }

    pick_rep ws = List.minimumBy (comparing rank) ws
    rank w = (isPlaceholderWeb w, not (w `elementOfUniqSet` exposed), getKey (getUnique w))

-- | Statistics for -ddump-webs-stats
pprWebStats :: Int        -- ^ Number of webs in the annotated program
            -> Int        -- ^ Number of webs in the renamed program
            -> WebSet     -- ^ Exposed webs
            -> Int        -- ^ Number of pairs collected
            -> WebSolution -> SDoc
pprWebStats n_webs n_webs_after exposed n_pairs sol
  = vcat [ text "Webs:"                    <+> int n_webs
         , text "Exposed webs:"            <+> int (sizeUniqSet exposed)
         , text "Constraints (pairs):"     <+> int n_pairs
         , text "Classes with >1 web:"     <+> int (length (ws_classes sol))
         , text "Exposed classes:"         <+> int (sizeUniqSet (ws_exposed_reps sol))
         , text "Webs after renaming:"     <+> int n_webs_after
         , text "Class size histogram (size: count):"
         , nest 2 $ vcat [ int sz <> colon <+> int cnt | (sz, cnt) <- histogram ] ]
  where
    histogram = sortOn fst $ Map.toList $
                Map.fromListWith (+) [ (length c, 1 :: Int) | c <- ws_classes sol ]
