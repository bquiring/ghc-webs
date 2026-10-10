{-# LANGUAGE PatternSynonyms #-}

-- | Splitting webs at the module boundary by eta-expansion, before
-- annotation.
--
-- See Note [Splitting webs at the boundary].
module GHC.WebCore.Boundary
  ( splitBoundary
  , contractBoundary
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.FVs ( rulesFreeVars )
import GHC.Core.Opt.Arity ( etaExpand )
import GHC.Core.Utils ( exprIsTrivial )
import GHC.Core.Map.Expr ( eqCoreExpr )
import GHC.Core.Coercion ( isReflexiveCo )
import GHC.Core.Type ( Type, Mult, pattern ManyTy, splitFunTy_maybe )
import GHC.Core.TyCo.Compare ( eqType )

import GHC.Data.FastString

import GHC.Types.Id
import GHC.Types.Id.Info
import GHC.Types.Demand ( SubDemand, pattern (:*), splitDmdSig, viewCall
                         , isAbsDmd, isAtMostOnce, topSubDmd )
import GHC.Types.Basic ( Arity, isDefaultInlinePragma, noOccInfo )
import GHC.Types.Var ( FunTyFlag(..) )
import GHC.Types.Name
import GHC.Types.Unique ( Unique )
import GHC.Types.Unique.Supply
import GHC.Types.Unique.FM ( nonDetEltsUFM )
import GHC.Types.Var.Env
import GHC.Types.Var.Set

import GHC.Data.Maybe ( orElse )
import GHC.Utils.Monad ( mapAccumLM )

{- Note [Splitting webs at the boundary]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A web that reaches the module boundary is exposed, and no transformation
touches it (Note [Exposed webs] in GHC.WebCore.Sigs).  On nofib about half
of all webs are exposed.  Often only one use of a function reaches the
boundary, and the others are local: an exported function is also called in
its own module; a local function is passed to an imported one (map f xs),
and also called locally.

Eta-expansion splits such a web.  In

    map (\x -> f x) xs

the exposed web is that of the new lambda.  f's own web meets it only at
the call (f x), which does not link the two: f's lambdas and calls are all
local again.  So, before annotation (with -fcore-webs-boundary, in the early
run only):

 1. Exported functions.  An exported top-level binding  f = \xs -> e  is
    split into a local function and an exported wrapper:

        $ef = \xs -> e[$ef/f]          -- local, not exported
        f   = \xs -> $ef xs            -- exported

    and every occurrence of f in the module becomes $ef.  This is
    worker/wrapper with the identity as the wrapper.  The wrapper also
    eta-expands f's higher-order parameters: see Note [Eta-expanding
    parameters at the boundary].  f is left alone if it has a stable
    unfolding, rules, or an inline pragma, or if a rule mentions it.

 2. Arguments of global Ids.  A local function variable v (arity n > 0)
    passed to an imported function or a data constructor is eta-expanded
    to its arity:  g v  ==>  g (\ys -> v ys).  So is a partial application
    of v to trivial arguments (map (go acc) xs).  Magic Ids (compulsory
    unfoldings) are left alone, and so is v if it has a stable unfolding or
    an inline pragma: the simplifier would inline v into the new lambda,
    leaving a second copy of its body.  (Instance methods marked INLINE,
    passed to the dictionary constructor, grew real/eff/VS by 16%.)

Both are semantically the identity: v has arity n, so it, and its partial
application to fewer than n arguments, are values, and eta-expansion
neither duplicates work nor turns bottom into a lambda.

After the web pass, a split whose local copy no transformation changed is
contracted: see Note [Contracting the boundary split].  If a transformation
did change $ef, the wrapper is where the old calling convention meets the
new one (e.g.  \x y -> $ef x  after dead-parameter deletion): GHC's
worker/wrapper, with the wrapper built by the web pass.  The simplifier,
which runs after the early web pass, eta-reduces the expanded arguments
(\ys -> v ys) whose webs were not changed.  In the late run nothing
simplifies afterwards, so the split is not done.
-}

{- Note [Contracting the boundary split]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If no transformation changed the local copy $ef of an exported function f
(its type and right-hand side after erasure are those the split built), the
split is undone after erasure: the wrapper is dropped, $ef's binding becomes
f's again, with f's original Id (its unfolding and analysis results), and
every occurrence of $ef becomes f.  So an exported function the web pass
did not change is exactly as without the split.

This used to be left to the simplifier (shortOutIndirections), with small
functions not split at all: the exported wrapper had lost f's unfolding, so
a small function (StateX.thenSX in real/infer) no longer inlined in other
modules when partially applied (+4.5% allocation).  With the contraction
every exported function is split: if its copy is changed, the wrapper and
the copy are both small when f was, and both inline.
-}

{- Note [Eta-expanding parameters at the boundary]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The wrapper of an exported function passes its parameters to the local
copy.  A parameter g of function type is exposed (any caller in another
module passes its own lambdas), and passing it on as it is would join the
web of $ef's parameter with g's, exposing it too.  So the wrapper
eta-expands it:

    integrate f a b = $eintegrate (\x -> f x) a b

and $ef's parameter web holds only the wrapper's lambda and the lambdas
passed by local callers.  For a parameter with more arrows, the partial
application is shared, as in g itself:

    g :: a -> b -> c    ==>    \x -> let r = g x in \y -> r y

and a lambda is marked one-shot when f's demand on g says it is called at
most once (g's partial applications, from the call demand), so the
simplifier inlines r where it may (\x y -> g x y).  Only plain arrows are
expanded (not constraint arrows, foralls or newtypes), and not parameters
that f does not use (absent demand).

As for any eta-expansion of a variable, \x -> g x differs from g only when
g is bottom and f's body forces it with seq; GHC's own eta-expansion makes
the same assumption (-fno-pedantic-bottoms).
-}

-- | Split exposed webs at the boundary of the module.
-- See Note [Splitting webs at the boundary]
--
-- Returns the split program and, for each split function, its original Id
-- and its local copy (for 'contractBoundary').
splitBoundary :: UniqSupply -> [CoreRule] -> CoreProgram -> (CoreProgram, [(Id, Id)])
splitBoundary us rules binds
  = (map etaArgsBind (concat binds'), nonDetEltsUFM env)
  where
    rule_fvs = rulesFreeVars rules
    (env, binds') = initUs_ us (mapAccumLM split_bind emptyVarEnv binds)

    -- First pass: choose the exported functions to split, and build their
    -- local copies.  The environment maps each to itself and its local copy.
    split_bind :: IdEnv (Id, Id) -> CoreBind -> UniqSM (IdEnv (Id, Id), [CoreBind])
    split_bind acc (NonRec f rhs)
      | Just n <- splittable f rhs
      = do { u <- getUniqueM
           ; let f_w = mkLocalCopy u f
           ; wrapper <- mkWrapper f n f_w
           ; return ( extendVarEnv acc f (f, f_w)
                    , [ NonRec f_w rhs, NonRec (zapSplit f) wrapper ] ) }
    split_bind acc (Rec prs)
      = do { split <- sequence [ do { u <- getUniqueM; return (f, mkLocalCopy u f, n) }
                               | (f, rhs) <- prs, Just n <- [splittable f rhs] ]
           ; wrappers <- sequence [ NonRec (zapSplit f) <$> mkWrapper f n f_w
                                  | (f, f_w, n) <- split ]
           ; let sub = mkVarEnv [ (f, f_w) | (f, f_w, _) <- split ]
           ; return ( acc `plusVarEnv` mkVarEnv [ (f, (f, f_w)) | (f, f_w, _) <- split ]
                    , Rec [ (lookupVarEnv sub f `orElse` f, rhs) | (f, rhs) <- prs ]
                      : wrappers ) }
    split_bind acc bind = return (acc, [bind])

    splittable f rhs
      | isExportedId f
      , not (isJoinId f)
      , not (isStableUnfolding (realIdUnfolding f))
      , isEmptyRuleInfo (idSpecialisation f)
      , isDefaultInlinePragma (idInlinePragma f)
      , not (f `elemVarSet` rule_fvs)
      , let n = length (filter isId (fst (collectBinders rhs)))
      , n > 0
      = Just n
      | otherwise
      = Nothing

    -- Second pass: redirect the occurrences of split functions to their
    -- local copies (not in the wrappers, which have no occurrences of
    -- them), and eta-expand the arguments of global Ids
    etaArgsBind (NonRec b rhs) = NonRec b (go rhs)
    etaArgsBind (Rec prs)      = Rec [ (b, go rhs) | (b, rhs) <- prs ]

    go :: CoreExpr -> CoreExpr
    go expr = case expr of
      Var v -> Var (maybe v snd (lookupVarEnv env v))
      App {}
        | (Var g, args) <- collectArgs expr
        , isGlobalId g
        , not (hasCompulsoryUnfolding g)
        -> mkApps (Var g) [ if isValArg a then eta_arg (go a) else a | a <- args ]
        | (f, args) <- collectArgs expr
        -> mkApps (go f) (map go args)
      Lam b e          -> Lam b (go e)
      Let bind body    -> Let (etaArgsBind bind) (go body)
      Case e b ty alts -> Case (go e) b ty [ Alt c bs (go rhs) | Alt c bs rhs <- alts ]
      Cast e co        -> Cast (go e) co
      Tick t e         -> Tick t (go e)
      _                -> expr

    -- A local function, or its partial application to trivial arguments,
    -- eta-expanded to its arity
    eta_arg a
      | (Var v, args) <- collectArgs a
      , isLocalId v
      , not (isJoinId v)
      , not (isStableUnfolding (realIdUnfolding v))
      , isDefaultInlinePragma (idInlinePragma v)
      , all exprIsTrivial args
      , let missing = idArity v - length (filter isValArg args)
      , missing > 0
      = etaExpandNoCast missing a
      | otherwise
      = a

-- | The local copy of an exported function: same type and analysis
-- results, not exported, no unfolding or rules
mkLocalCopy :: Unique -> Id -> Id
mkLocalCopy u f = mkLocalIdWithInfo name ManyTy (idType f) info
  where
    name = mkDerivedInternalName (\occ -> mkVarOccFS (fsLit "$e" `appendFS` occNameFS occ))
                                 u (idName f)
    info = idInfo f `setUnfoldingInfo` noUnfolding
                    `setRuleInfo` emptyRuleInfo
                    `setOccInfo` noOccInfo

-- | The exported wrapper keeps its Id, but not its unfolding, which
-- describes the old right-hand side
zapSplit :: Id -> Id
zapSplit f = f `setIdUnfolding` noUnfolding

-- | The exported wrapper  f = \xs -> $ef xs.  Its binders get the demands
-- of f's parameters (from f's demand signature): the binders etaExpand
-- makes have none, and GHC's worker/wrapper unboxes an argument only if
-- its binder's demand says it is strict.  Without them, f's worker took its
-- arguments boxed, and so did every caller in other modules (nofib
-- real/gamteb, PhotoElec.photoElec: +0.4% allocation).
--
-- Its higher-order parameters are eta-expanded: see Note [Eta-expanding
-- parameters at the boundary].
mkWrapper :: Id -> Arity -> Id -> UniqSM CoreExpr
mkWrapper f n f_w
  | (fun, args) <- collectArgs body
  , Var v <- fun, v == f_w
  = mkLams bs . mkApps fun <$> mapM eta_arg args
  | otherwise
  = return wrapper
  where
    wrapper  = go dmds (etaExpandNoCast n (Var f_w))
    (bs, body) = collectBinders wrapper
    dmds = fst (splitDmdSig (idDmdSig f))
    go (d:ds) (Lam b e) | isId b = Lam (b `setIdDemandInfo` d) (go ds e)
    go ds     (Lam b e)          = Lam b (go ds e)
    go _      e                  = e

    -- The binders carry the demands, their occurrences do not
    eta_arg (Var x) | Just b <- lookupVarEnv bndrs x
                    , isId b
                    , not (isAbsDmd (idDemandInfo b))
                    = etaParam b
    eta_arg a = return a
    bndrs = mkVarEnv [ (b, b) | b <- bs ]

-- | A parameter of function type, eta-expanded along its plain arrows,
-- sharing its partial applications
-- See Note [Eta-expanding parameters at the boundary]
etaParam :: Id -> UniqSM CoreExpr
etaParam g = expand (Var g) (idType g) sd
  where
    sd = case idDemandInfo g of _ :* s -> s

    expand :: CoreExpr -> Type -> SubDemand -> UniqSM CoreExpr
    expand e ty call
      | Just (FTF_T_T, mult, arg, res) <- splitFunTy_maybe ty
      = do { x <- mk_bndr (fsLit "p") mult arg
           ; let (once, call') = case viewCall call of
                   Just (c, sd') -> (isAtMostOnce c, sd')
                   Nothing       -> (False, topSubDmd)
                 x' | once      = setOneShotLambda x
                    | otherwise = x
                 app = App e (Var x)
           ; if hasArrow res
             then do { r <- mk_bndr (fsLit "r") ManyTy res
                     ; inner <- expand (Var r) res call'
                     ; return (Lam x' (Let (NonRec r app) inner)) }
             else return (Lam x' app) }
      | otherwise
      = return e

    hasArrow ty | Just (FTF_T_T, _, _, _) <- splitFunTy_maybe ty = True
                | otherwise                                     = False

    mk_bndr :: FastString -> Mult -> Type -> UniqSM Id
    mk_bndr fs mult ty = do { u <- getUniqueM; return (mkSysLocal fs u mult ty) }

-- | Undo the split of each exported function whose local copy no
-- transformation changed.  Takes the split functions, the program after the
-- split, and the program after erasure; returns the program and the
-- functions whose split was undone.
-- See Note [Contracting the boundary split]
contractBoundary :: [(Id, Id)] -> CoreProgram -> CoreProgram -> (CoreProgram, [Id])
contractBoundary split before after
  | isEmptyVarEnv sub = (after, [])
  | otherwise         = (concatMap contract_bind after, nonDetEltsUFM sub)
  where
    before_rhss = mkVarEnv [ (b, (b, rhs)) | (b, rhs) <- flattenBinds before ]
    after_rhss  = mkVarEnv [ (b, (b, rhs)) | (b, rhs) <- flattenBinds after ]

    -- Each unchanged local copy, mapped to its original
    sub :: IdEnv Id
    sub = mkVarEnv [ (f_w, f) | (f, f_w) <- split, unchanged f_w ]
    -- The wrappers to drop
    dropped = mkVarSet [ f | (f, f_w) <- split, f_w `elemVarEnv` sub ]

    unchanged f_w
      | Just (b1, e1) <- lookupVarEnv before_rhss f_w
      , Just (b2, e2) <- lookupVarEnv after_rhss f_w
      = idType b1 `eqType` idType b2 && eqCoreExpr e1 e2
      | otherwise
      = False

    contract_bind (NonRec b rhs)
      | b `elemVarSet` dropped = []
      | otherwise              = [NonRec (bndr b) (subst rhs)]
    contract_bind (Rec prs)    = [Rec [ (bndr b, subst rhs) | (b, rhs) <- prs
                                      , not (b `elemVarSet` dropped) ]]

    bndr b = lookupVarEnv sub b `orElse` b

    subst :: CoreExpr -> CoreExpr
    subst expr = case expr of
      Var v            -> Var (bndr v)
      App f a          -> App (subst f) (subst a)
      Lam b e          -> Lam b (subst e)
      Let bind body    -> Let (sub_bind bind) (subst body)
      Case e b ty alts -> Case (subst e) b ty [ Alt c bs (subst rhs) | Alt c bs rhs <- alts ]
      Cast e co        -> Cast (subst e) co
      Tick t e         -> Tick t (subst e)
      _                -> expr

    sub_bind (NonRec b rhs) = NonRec b (subst rhs)
    sub_bind (Rec prs)      = Rec [ (b, subst rhs) | (b, rhs) <- prs ]

-- | etaExpand, without the reflexive cast it can leave around the lambdas
-- (forall types).  A cast there hides the lambdas from GHC's worker/wrapper
-- (splitFun), so the wrapper of a split function would not get the stable
-- unfolding that a small function gets (certainlyWillInline), and would not
-- inline when partially applied in other modules.
etaExpandNoCast :: Arity -> CoreExpr -> CoreExpr
etaExpandNoCast n e = strip (etaExpand n e)
  where
    strip (Cast e' co) | isReflexiveCo co = strip e'
    strip (Lam b body)                    = Lam b (strip body)
    strip e'                              = e'

hasCompulsoryUnfolding :: Id -> Bool
hasCompulsoryUnfolding v = isCompulsoryUnfolding (realIdUnfolding v)
