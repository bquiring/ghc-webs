{-# LANGUAGE PatternSynonyms #-}

-- | Utilities shared by the web transformations (GHC.WebCore.Transform.*).
module GHC.WebCore.Transform.Common
  ( programOccurrences, exprOccurrences
  , complexCoWebs
  , fixBinderInfo, ArgFate(..), argFates
  , UnfoldingPolicy(..), changedBinders, fixUnfolding
  , pprWebVerdicts
  , mkWild
  , splitLeadingLams
  , reorderTopBinds
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.Coercion ( coercionKind )
import GHC.Core.Type ( pattern ManyTy )
import GHC.Types.Var ( isCoVar, varType )
import GHC.Core.TyCo.Rep

import GHC.Data.FastString ( fsLit )

import GHC.Types.Cpr ( topCprSig )
import GHC.Types.Id
import GHC.Types.Id.Info ( emptyRuleInfo )
import GHC.Types.Tickish
import GHC.Types.Unique.Set
import GHC.Types.Unique.Supply
import GHC.Types.Var.Set
import GHC.Types.Web

import GHC.Data.Pair
import GHC.Utils.Outputable

import GHC.WebCore.Traverse ( typeWebs )
import GHC.Core.FVs ( exprFreeVars, rulesFreeVars )
import GHC.Core.Type ( coreFullView )
import GHC.Types.Demand ( DmdSig, splitDmdSig, mkClosedDmdSig, absDmd, topDmd
                         , Demand(..), Card(..), Boxity(..), mkProd
                         , mkCall, viewCall, multCard, isAbs, topSubDmd )

import Data.List ( sortOn )
import GHC.Data.Graph.Directed ( Node(..), SCC(..), stronglyConnCompFromEdgedVerticesUniq )
import GHC.Core.FVs ( bindFreeVars )

-- | All the variables that occur in the program (not binders), including in
-- breakpoint ticks
programOccurrences :: CoreProgram -> VarSet
programOccurrences binds = foldr occBind emptyVarSet binds

-- | All the variables that occur in an expression (not binders)
exprOccurrences :: CoreExpr -> VarSet
exprOccurrences e = occExpr e emptyVarSet

occBind :: CoreBind -> VarSet -> VarSet
occBind (NonRec _ e) acc = occExpr e acc
occBind (Rec prs)    acc = foldr (occExpr . snd) acc prs

occExpr :: CoreExpr -> VarSet -> VarSet
occExpr = go
  where
    go_bind = occBind

    go (Var v)          acc = extendVarSet acc v
    go (Lit {})         acc = acc
    go (App f a)        acc = go f (go a acc)
    go (WebApp _ f a)   acc = go f (go a acc)
    go (Lam _ e)        acc = go e acc
    go (WebLam _ _ e)   acc = go e acc
    go (Let bind body)  acc = go_bind bind (go body acc)
    go (Case e _ _ as)  acc = go e (foldr (\(Alt _ _ rhs) -> go rhs) acc as)
    go (Cast e _)       acc = go e acc
    go (Tick t e)       acc = go e (go_tick t acc)
    go (Type {})        acc = acc
    go (Coercion {})    acc = acc

    go_tick (Breakpoint { breakpointFVs = ids }) acc = extendVarSetList acc ids
    go_tick _ acc = acc

-- | The webs that appear inside coercions that cannot be rewritten
-- structurally.  The structural ones are Refl, GRefl, TyConAppCo, AppCo,
-- ForAllCo, FunCo, AxiomCo, SymCo, TransCo and SubCo; the others are SelCo, LRCo, KindCo, the argument of InstCo, UnivCo,
-- coercion variables and holes.  A transformation must leave these webs
-- alone.
complexCoWebs :: CoreProgram -> WebSet
complexCoWebs binds = foldr go_bind emptyUniqSet binds
  where
    go_bind (NonRec b e) acc = go_bndr b (go e acc)
    go_bind (Rec prs)    acc = foldr (\(b, e) -> go_bndr b . go e) acc prs

    go_bndr b acc
      | isCoVar b = typeWebs (varType b) `unionUniqSets` acc
      | otherwise = acc

    go (Var {})           acc = acc
    go (Lit {})           acc = acc
    go (App f a)          acc = go f (go a acc)
    go (WebApp _ f a)     acc = go f (go a acc)
    go (Lam b e)          acc = go_bndr b (go e acc)
    go (WebLam _ b e)     acc = go_bndr b (go e acc)
    go (Let bind body)    acc = go_bind bind (go body acc)
    go (Case e b _ alts)  acc = go e $ go_bndr b $
                                foldr (\(Alt _ bs rhs) a -> foldr go_bndr (go rhs a) bs) acc alts
    go (Cast e co)        acc = go e (go_co co acc)
    go (Tick _ e)         acc = go e acc
    go (Type t)           acc = go_ty t acc
    go (Coercion co)      acc = go_co co acc

    go_ty ty acc = case ty of
      FunTy { ft_arg = a, ft_res = r } -> go_ty a (go_ty r acc)
      TyConApp _ tys -> foldr go_ty acc tys
      AppTy t1 t2    -> go_ty t1 (go_ty t2 acc)
      ForAllTy _ t   -> go_ty t acc
      CastTy t co    -> go_ty t (go_co co acc)
      CoercionTy co  -> go_co co acc
      _              -> acc

    go_co :: Coercion -> WebSet -> WebSet
    go_co co acc = case co of
      Refl t                 -> go_ty t acc
      GRefl _ t _            -> go_ty t acc
      TyConAppCo _ _ cos     -> foldr go_co acc cos
      AppCo c1 c2            -> go_co c1 (go_co c2 acc)
      ForAllCo { fco_body = c } -> go_co c acc
      FunCo { fco_arg = c1, fco_res = c2 } -> go_co c1 (go_co c2 acc)
      AxiomCo _ cos          -> foldr go_co acc cos
      SymCo c                -> go_co c acc
      TransCo c1 c2          -> go_co c1 (go_co c2 acc)
      SubCo c                -> go_co c acc
      SelCo _ c              -> kind_webs c (go_co c acc)
      LRCo _ c               -> kind_webs c (go_co c acc)
      KindCo c               -> kind_webs c (go_co c acc)
      InstCo c arg           -> kind_webs arg (go_co c (go_co arg acc))
      UnivCo {}              -> kind_webs co acc
      CoVarCo {}             -> kind_webs co acc
      HoleCo {}              -> kind_webs co acc

    kind_webs c acc = case coercionKind c of
      Pair l r -> typeWebs l `unionUniqSets` typeWebs r `unionUniqSets` acc

-- | What a transformation does to each value argument of a function, in
-- order.  See Note [Demand signatures after a transformation]
data ArgFate
  = KeepArg         -- ^ Unchanged
  | DropArg         -- ^ Deleted (dead-parameter elimination)
  | AbsentArg       -- ^ Replaced by (# #) (dead-parameter elimination)
  | MergeWithNext   -- ^ Merged with the next argument into an unboxed tuple
                    --   (uncurrying); the next argument's fate is ignored

{- Note [Demand signatures after a transformation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
CorePrep uses a function's demand signature to decide, at each call, whether
to evaluate an argument first (strict) or allocate a thunk for it (lazy).  So
when a transformation changes a function's arguments we reshape its demand
signature, rather than zap it: zapping makes every argument look lazy, and
cost up to 25% more allocation in nofib (e.g. imaginary/bernouilli).  A
deleted argument's demand is dropped, a unit argument becomes absent, and two
merged arguments become one demand on their unboxed tuple: strict (it is
unlifted), with the two arguments' demands as its components.  CorePrep does
not evaluate the strict components of an unboxed-tuple argument, so the
uncurrying pass evaluates them at the call (see Note [Uncurrying] in
GHC.WebCore.Transform.Uncurry); in the early run, worker/wrapper reads the
product demand and unboxes the components.  (With a top demand instead,
worker/wrapper no longer unboxed them: shootout/binary-trees allocated twice
as much.)
-}

-- | The fates of the value arguments of a type, by looking at its arrows
argFates :: (WebId -> Type -> ArgFate) -> Type -> [ArgFate]
argFates fate ty = case coreFullView ty of
  ForAllTy _ t -> argFates fate t
  FunTy { ft_web = w, ft_res = r }
    -> case fate w r of
         MergeWithNext -> case coreFullView r of
           FunTy { ft_res = r' } -> MergeWithNext : KeepArg : argFates fate r'
           _                     -> KeepArg : argFates fate r
         f -> f : argFates fate r
  _ -> []

reshapeDmdSig :: [ArgFate] -> DmdSig -> DmdSig
reshapeDmdSig fates sig
  = case splitDmdSig sig of
      (dmds, div) -> mkClosedDmdSig (go fates dmds) div
  where
    go (KeepArg : fs)              (d : ds)     = d : go fs ds
    go (DropArg : fs)              (_ : ds)     = go fs ds
    go (AbsentArg : fs)            (_ : ds)     = absDmd : go fs ds
    go (MergeWithNext : _ : fs)    (d1 : d2 : ds) = merged d1 d2 : go fs ds
    go (MergeWithNext : _)         [_]            = [topDmd]
    go _                           ds           = ds

    -- The unboxed tuple of two merged arguments is always evaluated (it is
    -- unlifted), and its components have the arguments' demands, so that
    -- worker/wrapper (which runs after the early web pass) can still unbox
    -- them
    merged d1 d2 = C_1N :* mkProd Unboxed [d1, d2]

-- | Reshape a binder's usage demand (how it is called) for the new
-- arguments.  See Note [Usage information after a transformation]
reshapeUsage :: [ArgFate] -> Demand -> Demand
reshapeUsage fates dmd = case dmd of
  n :* sd -> n :* go fates sd
  _       -> dmd
  where
    go [] sd = sd
    go (f : fs) sd = case viewCall sd of
      Nothing -> sd
      Just (c, sd1)
        | isAbs c   -> sd                   -- never called this deep
        | otherwise -> case f of
            KeepArg       -> mkCall c (go fs sd1)
            AbsentArg     -> mkCall c (go fs sd1)
            -- The call that supplied the deleted argument is gone: its
            -- cardinality multiplies into the next call
            DropArg       -> go fs (scale c sd1)
            -- Two calls become one
            MergeWithNext -> case (fs, viewCall sd1) of
              (_ : fs', Just (c2, sd2))
                | not (isAbs c2) -> mkCall (multCard c c2) (go fs' sd2)
              _ -> topSubDmd

    scale c sd = case viewCall sd of
      Just (c2, sd2) | let c' = multCard c c2, not (isAbs c') -> mkCall c' sd2
      _ -> sd

-- | The number of new arguments among the first n old ones
reshapeCallArity :: [ArgFate] -> Int -> Int
reshapeCallArity = go
  where
    go _ 0 = 0
    go (KeepArg : fs)           n = 1 + go fs (n - 1)
    go (AbsentArg : fs)         n = 1 + go fs (n - 1)
    go (DropArg : fs)           n = go fs (n - 1)
    go (MergeWithNext : _ : fs) n | n >= 2 = 1 + go fs (n - 2)
    go _ _ = 0

-- | Fix up the IdInfo of a binder whose type a transformation changed:
-- set the new type and arity (and join arity), reshape its demand signature
-- (Note [Demand signatures after a transformation]), and zap its CPR
-- signature, which is per-arity.
fixBinderInfo :: Id
              -> Type                 -- ^ New type
              -> (Bool -> Int -> Int) -- ^ New arity, given whether it is a
                                      --   join arity, and the old arity
              -> [ArgFate]            -- ^ The fates of the old value arguments
              -> Id
fixBinderInfo b new_ty new_arity fates
  = setIdCprSig (setIdDmdSig (fix_join (setIdArity b' (new_arity False (idArity b))))
                             (reshapeDmdSig fates (idDmdSig b)))
                topCprSig
    -- The binder's usage demand and call arity describe how it is called
    -- with its old arguments; reshape them for the new ones (see
    -- Note [Usage information after a transformation])
    `setIdDemandInfo` reshapeUsage fates (idDemandInfo b)
    `setIdCallArity` reshapeCallArity fates (idCallArity b)
  where
    b' = setIdType b new_ty
    fix_join b'' = case idJoinPointHood b of
      JoinPoint ar -> asJoinId b'' (new_arity True ar)
      NotJoinPoint -> b''

{- Note [Usage information after a transformation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Demand analysis records on a binder how it is used (idDemandInfo, e.g.
LC(S,C(1,L)): called with two arguments), and Call Arity records how many
arguments it is always called with.  The simplifier eta-expands a binder up
to that many arguments.  After a transformation changes the binder's
arguments, both must be reshaped like its demand signature: a deleted
argument removes a call (its cardinality multiplies into the next one), and
two merged arguments make one call.

Both mistakes have bitten (in the early run, where the simplifier runs
afterwards):

  * Keeping the old usage: uncurrying
        applyToN :: Int -> Tricky -> Tricky      -- Tricky = (# #) -> Tricky
    into  applyToN :: (# Int, Tricky #) -> Tricky
    kept "called with two arguments, then the result once more", so the
    simplifier eta-expanded the uncurried applyToN once too often, and
    applyToN (# n, t #), which must diverge, became a value
    (codeGen/should_run/T24295b, with -fpedantic-bottoms; webs008).
  * Zapping it: after constant propagation and dead-parameter elimination
    deleted a parameter of a loop, the simplifier no longer knew that the
    loop is always called with one more argument, did not eta-expand it,
    and the loop allocated a closure per iteration (nofib real/eff/CS: 4x
    the allocation).
-}

{- Note [Unfoldings and rules after a transformation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A transformation changes the types of some binders.  An unfolding or rule is
then /stale/ if it belongs to such a binder, or mentions one: its template
still has the old types and calling convention.  We zap stale stable
unfoldings and stale rules.  A stale vanilla unfolding is zapped only in the
early run: in the late run nothing inlines afterwards, and Tidy rebuilds
vanilla unfoldings from the final right-hand side (tidyTopUnfolding in
GHC.Iface.Tidy), so they need no care -- and zapping them would hide them
from the interface file, stopping importing modules from inlining (we saw
3000x more allocation in nofib/spectral/minimax when we zapped them all).

Unfoldings and rules that are not stale are always kept, and so are those of
the kept binders (ws_interface_ids), whose types never change.
-}

-- | What to do with unfoldings and rules; see
-- Note [Unfoldings and rules after a transformation]
data UnfoldingPolicy = UnfoldingPolicy
  { up_keep  :: VarSet   -- ^ Binders whose unfoldings and rules are always kept
  , up_early :: Bool     -- ^ The early run: the simplifier runs afterwards
  }

-- | All the binders (let, lambda, case and alternative binders) of a
-- program whose types satisfy the predicate, i.e. will change
changedBinders :: (Type -> Bool) -> CoreProgram -> VarSet
changedBinders changes binds = foldr go_bind emptyVarSet binds
  where
    go_bind (NonRec b e) acc = bndr b (go e acc)
    go_bind (Rec prs)    acc = foldr (\(b, e) -> bndr b . go e) acc prs

    bndr b acc | isId b, changes (idType b) = extendVarSet acc b
               | otherwise                  = acc

    go expr acc = case expr of
      Lam b e          -> bndr b (go e acc)
      WebLam _ b e     -> bndr b (go e acc)
      App f a          -> go f (go a acc)
      WebApp _ f a     -> go f (go a acc)
      Let bind body    -> go_bind bind (go body acc)
      Case e b _ alts  -> go e $ bndr b $
                          foldr (\(Alt _ bs rhs) a -> foldr bndr (go rhs a) bs) acc alts
      Cast e _         -> go e acc
      Tick _ e         -> go e acc
      _                -> acc

-- | Zap the stale unfolding and rules of a binder (after its type has been
-- fixed up).  See Note [Unfoldings and rules after a transformation]
fixUnfolding :: UnfoldingPolicy -> VarSet -> Id -> Id
fixUnfolding pol changed b
  | not (isId b) || b `elemVarSet` up_keep pol = b
  | otherwise = fix_rules (fix_unf b)
  where
    unf = realIdUnfolding b
    mentions vs = not (isEmptyVarSet (vs `intersectVarSet` changed))
    own_change  = b `elemVarSet` changed

    stale_unf = own_change || maybe False (mentions . exprFreeVars) (maybeUnfoldingTemplate unf)
    fix_unf b'
      | not stale_unf         = b'
      | isStableUnfolding unf = zapIdUnfolding b'
      | up_early pol          = zapIdUnfolding b'
      | otherwise             = b'   -- Tidy rebuilds vanilla unfoldings

    stale_rules = own_change || mentions (rulesFreeVars (idCoreRules b))
    fix_rules b'
      | stale_rules = setIdSpecialisation b' emptyRuleInfo
      | otherwise   = b'

-- | One line per web, without uniques: the verdict and the names of the
-- web's lambda binders.  Sorted, so tests can check it.
pprWebVerdicts :: Outputable v => [(v, [Id])] -> SDoc
pprWebVerdicts vs
  = vcat [ doc | (_, doc) <- sortOn fst [ (showSDocUnsafe (line v bs), line v bs) | (v, bs) <- vs ] ]
  where
    line v bs = ppr v <> colon <+> hsep (map (ppr . idName) bs)

-- | Split off the lambdas at the top of an expression.  Transformations put
-- the unpacking of an unboxed-tuple parameter under them: matching an unboxed
-- tuple costs nothing, and a join point's lambdas must stay together (its
-- join arity counts them).
splitLeadingLams :: CoreExpr -> (CoreExpr -> CoreExpr, CoreExpr)
splitLeadingLams (Lam b e)      = case splitLeadingLams e of
                                    (wrap, body) -> (Lam b . wrap, body)
splitLeadingLams (WebLam w b e) = case splitLeadingLams e of
                                    (wrap, body) -> (WebLam w b . wrap, body)
splitLeadingLams e              = (id, e)

-- | A fresh case binder
mkWild :: Type -> UniqSM Id
mkWild ty = do { u <- getUniqueM; return (mkSysLocal (fsLit "wild") u ManyTy ty) }

{- Note [Top-level binding order]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Top-level bindings must be in dependency order for Tidy, which renames them
in order (Core Lint itself puts all top-level binders in scope at once).
Constant propagation and super-beta inlining copy references to top-level
binders (a constant, or the free variables of an inlined lambda) into other
top-level bindings, which may come earlier.  So after the transformations,
the pipeline sorts the top-level bindings again: strongly connected
components of the dependency graph (including the free variables of
unfoldings and rules), in dependency order, keeping the original order where
it is free.
-}

-- | Sort the top-level bindings into dependency order.
-- See Note [Top-level binding order]
reorderTopBinds :: CoreProgram -> CoreProgram
reorderTopBinds binds
  | in_order emptyVarSet binds = binds
  | otherwise                  = map to_bind (stronglyConnCompFromEdgedVerticesUniq nodes)
  where
    -- Already in dependency order: each binding mentions only top-level
    -- binders bound before it (or in its own recursive group)
    in_order _ [] = True
    in_order seen (bind : rest)
      = let seen' = extendVarSetList seen (bindersOf bind)
            fvs   = bindFreeVars bind `intersectVarSet` tops
        in fvs `subVarSet` seen' && in_order seen' rest

    prs   = flattenBinds binds
    tops  = mkVarSet (map fst prs)
    nodes = [ DigraphNode (b, e) b (nonDetEltsUniqSet (bindFreeVars (NonRec b e) `intersectVarSet` tops))
            | (b, e) <- prs ]
    to_bind (AcyclicSCC (b, e)) = NonRec b e
    to_bind (CyclicSCC prs')    = Rec prs'
