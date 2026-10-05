-- | Super-beta inlining over webs: when exactly one lambda flows to the calls
-- of a web, inline it at those calls, even unknown ones.
--
-- See Note [Super-beta inlining] and WEBS-INLINING.md.
module GHC.WebCore.Transform.Inline
  ( inlineRound
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.FVs ( exprFreeVars )
import GHC.Core.Subst
import GHC.Core.TyCo.Compare ( eqType )
import GHC.Core.Type ( isUnliftedType, definitelyLiftedType )
import GHC.Core.Unfold ( calcUnfoldingGuidance, UnfoldingOpts(..) )
import GHC.Core.Utils ( exprType, exprIsHNF, stripTicksTopE )
import GHC.Core.Opt.Arity ( exprIsDeadEnd )
import GHC.Types.Var.Env ( mkInScopeSet )

import GHC.Types.Demand ( topDmd )
import GHC.Types.Id
import GHC.Types.Basic ( isNoInlinePragma, isStrongLoopBreaker )
import GHC.Types.Tickish
import GHC.Types.Unique ( getKey )
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Types.Unique.Supply
import GHC.Types.Var.Env ( mkVarEnv, lookupVarEnv )
import GHC.Types.Var.Set
import GHC.Types.Web

import GHC.Utils.Outputable

import GHC.WebCore.Transform.Common ( mkWild )
import GHC.WebCore.Traverse ( stripWebForms )

import Data.List ( sortOn )

{- Note [Super-beta inlining]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If the only lambda of a (non-exposed) web w is L = \^w x. body, then every
function value that reaches a call of w is L (or bottom).  So L can be
inlined at every call of w, even where the function is unknown
(Shivers' super-beta):

    f @^w a @^w2 b    ==>   (case f of _ { __DEFAULT -> let x = a; y = b in body' })

where L = \^w x. \^w2 y. body', and the lambdas of L are matched with the
arguments as far as both go.  Each copy of L gets fresh binders.

Conditions:

  * Environment: L's free variables must be in scope, with the same values,
    at every call.  We require them to be bound at top level (or imported),
    and L to have no free type variables.  A lambda that captures a local
    variable may be called where another activation's binding of that
    variable is in scope.
  * Types: at a call, the function's type must be L's type (with no free
    type variables, L cannot be instantiated at the call; a polymorphic
    function may pass L on at another type).  Other calls are left alone.
  * Size: L must pass GHC's own inlining test: its unfolding guidance
    (calcUnfoldingGuidance) is either "always" (UnfWhen) or its size is at
    most -funfolding-use-threshold.
  * Calls inside L itself are not inlined (that would unroll recursion).
  * Only unknown calls: a call whose function is a variable bound to a known
    function (arity > 0), or a jump, is left to GHC's inliner, which has
    already decided not to inline it.  Super-beta is for the calls the
    inliner cannot see: through lambda-bound variables, fields, and results.
  * L is not bottoming: GHC does not inline bottoming functions either
    (Note [Do not inline top-level bottoming functions]).

Laziness: the function f is still evaluated (unless it is evidently a value),
so a bottom function still diverges.  Arguments are let-bound, so they stay
lazy.  The let binders get L's lambda binders' demands only when every
lambda of L is applied: a lambda binder's demand describes saturated calls.
-}

data Verdict = Inline | NoInline String

instance Outputable Verdict where
  ppr Inline         = text "inline"
  ppr (NoInline why) = text "not inlined" <+> parens (text why)

------------------------------------------------------------------
--      Analysis
------------------------------------------------------------------

data Info = Info
  { i_lams  :: [(Id, CoreExpr)]   -- The lambdas (binder, whole lambda)
  , i_calls :: Int
  , i_block :: Maybe String }   -- Why some lambda may not be inlined

plusInfo :: Info -> Info -> Info
plusInfo a b = Info (i_lams a ++ i_lams b) (i_calls a + i_calls b) (i_block a `orElse'` i_block b)
  where orElse' (Just r) _ = Just r
        orElse' Nothing r  = r

type Infos = UniqFM WebId Info

note :: WebId -> Info -> Infos -> Infos
note w i infos
  | isPlaceholderWeb w = infos
  | otherwise          = addToUFM_C plusInfo infos w i

analyse :: CoreProgram -> Infos
analyse binds = foldr go_bind emptyUFM binds
  where
    go_bind (NonRec b e) acc = go_rhs b e acc
    go_bind (Rec prs)    acc = foldr (\(b, e) -> go_rhs b e) acc prs

    go_rhs b e acc
      | isJoinId b = go_join e acc
      | otherwise  = go_rhs_lam b e acc

    go_join (Lam _ e)          acc = go_join e acc
    go_join l@(WebLam w p e)   acc = note w (Info [(p, l)] 0 (Just "join point")) (go_join e acc)
    go_join e                  acc = go e acc

    -- A lambda that is the right-hand side of a binder with a NOINLINE (or
    -- OPAQUE) pragma, or of a loop breaker, is not inlined either
    go_rhs_lam b e acc
      | Just why <- no_inline b, WebLam w p body <- peel e
      = note w (Info [(p, e)] 0 (Just why)) (go body acc)
      | otherwise = go e acc

    no_inline b
      | isNoInlinePragma (idInlinePragma b)  = Just "NOINLINE"
      | isStrongLoopBreaker (idOccInfo b)    = Just "loop breaker"
      | otherwise                            = Nothing

    peel (Tick _ e) = peel e
    peel (Lam v e) | not (isId v) = peel e
    peel e = e

    go :: CoreExpr -> Infos -> Infos
    go expr acc = case expr of
      WebLam w p e  -> note w (Info [(p, expr)] 0 Nothing) (go e acc)
      Lam _ e       -> go e acc
      WebApp w f a  -> note w (Info [] 1 Nothing) (go f (go a acc))
      App f a       -> go f (go a acc)
      Let bind body -> go_bind bind (go body acc)
      Case e _ _ alts -> go e (foldr (\(Alt _ _ rhs) -> go rhs) acc alts)
      Cast e _      -> go e acc
      Tick _ e      -> go e acc
      _             -> acc

verdict :: UnfoldingOpts -> VarSet -> WebSet -> WebId -> Info -> Verdict
verdict opts tops exposed w i
  | w `elementOfUniqSet` exposed = NoInline "exposed"
  | Just why <- i_block i         = NoInline why
  | i_calls i == 0               = NoInline "no calls"
  | [(_, lam)] <- i_lams i       = check lam
  | otherwise                    = NoInline "more than one lambda"
  where
    check lam
      | not (all top_level (nonDetEltsUniqSet (exprFreeVars lam)))
      = NoInline "captures local variables"
      | exprIsDeadEnd (stripWebForms (lamBody lam))
      = NoInline "bottoming"
      | not (small lam)
      = NoInline "too big"
      | otherwise
      = Inline

    top_level v = isId v && (isGlobalId v || v `elemVarSet` tops)

    small lam = case calcUnfoldingGuidance opts False False (stripWebForms lam) of
      UnfWhen {}                     -> True
      UnfIfGoodArgs { ug_size = sz } -> sz <= unfoldingUseThreshold opts
      UnfNever                       -> False

-- | The body of a lambda, after all its leading lambdas
lamBody :: CoreExpr -> CoreExpr
lamBody (WebLam _ _ e) = lamBody e
lamBody (Lam _ e)      = lamBody e
lamBody (Tick _ e)     = lamBody e
lamBody e              = e

------------------------------------------------------------------
--      One round
------------------------------------------------------------------

-- | Analyse and inline.  A web is inlined once (it is then in 'done').
inlineRound :: UnfoldingOpts -> UniqSupply -> WebSet -> WebSet -> CoreProgram
            -> (Maybe (CoreProgram, WebSet), [(WebId, SDoc, Bool, [Id])])
inlineRound opts us exposed done binds
  | isNullUFM todo = (Nothing, dump)
  | otherwise
  = case initUs_ us (rewriteProgram todo binds) of
      (binds', n) | n > 0     -> (Just (binds', mkUniqSet (map fst todo_list)), dump)
                  | otherwise -> (Nothing, dump)
  where
    tops  = mkVarSet (bindersOfBinds binds)
    infos = analyse binds
    verdicts = [ (w, verdict opts tops exposed w i, i)
               | (u, i) <- sortOn (getKey . fst) (nonDetUFMToList infos)
               , let w = mkWebId u
               , not (null (i_lams i))
               , not (w `elementOfUniqSet` done) ]
    todo_list = [ (w, lam) | (w, Inline, i) <- verdicts, [(_, lam)] <- [i_lams i] ]
    todo = listToUFM todo_list
    dump = [ (w, ppr v, is_inline v, map fst (i_lams i)) | (w, v, i) <- verdicts ]
    is_inline Inline = True
    is_inline _      = False

------------------------------------------------------------------
--      The rewrite
------------------------------------------------------------------

-- | Inline at the calls; also returns the number of calls inlined
rewriteProgram :: UniqFM WebId CoreExpr -> CoreProgram -> UniqSM (CoreProgram, Int)
rewriteProgram todo binds
  = do { rs <- mapM (\(gi, bind) -> rw_top (gi, is_rec bind) bind) (zip [0..] binds)
       ; return (map fst rs, sum (map snd rs)) }
  where
    is_rec (Rec {}) = True
    is_rec _        = False

    rw_top g bind = rw_bind g emptyUniqSet bind

    rw_bind g inside (NonRec b e) = do { (e', n) <- rw g inside e; return (NonRec b e', n) }
    rw_bind g inside (Rec prs)
      = do { rs <- mapM (\(b, e) -> do { (e', n) <- rw g inside e; return ((b, e'), n) }) prs
           ; return (Rec (map fst rs), sum (map snd rs)) }

    -- 'inside': the webs whose lambda we are inside
    rw :: (Int, Bool) -> WebSet -> CoreExpr -> UniqSM (CoreExpr, Int)
    rw g inside expr = case expr of
      WebLam w x e
        | w `elemUFM` todo -> do { (e', n) <- rw g (addOneToUniqSet inside w) e
                                 ; return (WebLam w x e', n) }
        | otherwise        -> do { (e', n) <- rw g inside e; return (WebLam w x e', n) }
      Lam b e       -> do { (e', n) <- rw g inside e; return (Lam b e', n) }
      App {}        -> rw_spine g inside expr
      WebApp {}     -> rw_spine g inside expr
      Let bind body -> do { (bind', n1) <- rw_bind g inside bind
                          ; (body', n2) <- rw g inside body
                          ; return (Let bind' body', n1 + n2) }
      Case e b ty alts
        -> do { (e', n) <- rw g inside e
              ; rs <- mapM (\(Alt c bs rhs) -> do { (rhs', m) <- rw g inside rhs
                                                  ; return (Alt c bs rhs', m) }) alts
              ; return (Case e' b ty (map fst rs), n + sum (map snd rs)) }
      Cast e co     -> do { (e', n) <- rw g inside e; return (Cast e' co, n) }
      Tick t e      -> do { (e', n) <- rw g inside e; return (Tick t e', n) }
      _             -> return (expr, 0)

    -- An application spine: find the first argument whose web is inlined
    rw_spine g inside expr
      = do { (hd', n0) <- rw g inside hd
           ; rs <- mapM (\(mw, a) -> do { (a', m) <- rw g inside a; return ((mw, a'), m) }) args
           ; let args' = map fst rs
                 n1 = n0 + sum (map snd rs)
           ; (e', n2) <- go hd' args'
           ; return (e', n1 + n2) }
      where
        (hd, args) = collect expr []

        go f [] = return (f, 0)
        go f ((Just w, a) : rest)
          | Just lam <- lookupUFM todo w
          , not (w `elementOfUniqSet` inside)
          , not (is_known f)
          , exprType f `eqType` exprType lam
          = do { lam' <- cloneExpr lam
               ; e <- beta f lam' ((Just w, a) : rest)
               ; (e', n) <- go_rest e
               ; return (e', n + 1) }
        go f ((mw, a) : rest) = go (app f mw a) rest

        go_rest (e, rest) = return (foldl (\f (mw, a) -> app f mw a) e rest, 0)

    -- A call of a known function (or a jump) is the inliner's business; see
    -- Note [Super-beta inlining]
    is_known f = case collectArgs (stripTicksTopE (const True) f) of
                   (Var v, _) -> isJoinId v || idArity v > 0
                   _          -> False

    app f (Just w) a = WebApp w f a
    app f Nothing  a = App f a

    collect (App f a)      as = collect f ((Nothing, a) : as)
    collect (WebApp w f a) as = collect f ((Just w, a) : as)
    collect e              as = (e, as)

-- | Apply a copy of the lambda to as many arguments as it has lambdas for,
-- keeping the function's evaluation: returns the result and the arguments
-- left over
beta :: CoreExpr -> CoreExpr -> [(Maybe WebId, CoreExpr)]
     -> UniqSM (CoreExpr, [(Maybe WebId, CoreExpr)])
beta f lam args
  = do { let (pairs, body, rest) = match lam args
             saturated = not (is_lam body)
       ; bound <- mkBinds saturated pairs body
       ; e <- if exprIsHNF (stripWebForms f)
              then return bound
              else do { v <- mkWild (exprType f)
                      ; return (Case f v (exprType bound) [Alt DEFAULT [] bound]) }
       ; return (e, rest) }
  where
    match (WebLam w x e) ((Just w', a) : as)
      | w == w' = let (ps, b, r) = match e as in ((x, a) : ps, b, r)
    match e as = ([], e, as)

    is_lam (WebLam {}) = True
    is_lam (Lam {})    = True
    is_lam (Tick _ e)  = is_lam e
    is_lam _           = False

    -- let x = a in ... (case for an unlifted argument)
    mkBinds _ [] body = return body
    mkBinds sat ((x, a) : ps) body
      = do { inner <- mkBinds sat ps body
           ; let x' | sat       = x
                    | otherwise = setIdDemandInfo x topDmd
           ; return $
               if isUnliftedType (idType x') || not (definitelyLiftedType (idType x'))
               then Case a x' (exprType inner) [Alt DEFAULT [] inner]
               else Let (NonRec (zapIdOccInfo x') a) inner }

-- | Copy an expression with fresh binders
cloneExpr :: CoreExpr -> UniqSM CoreExpr
cloneExpr e0 = go (mkEmptySubst (mkInScopeSet (exprFreeVars e0))) e0
  where
    go :: Subst -> CoreExpr -> UniqSM CoreExpr
    go s expr = case expr of
      Var v          -> return (lookupIdSubst s v)
      Lit {}         -> return expr
      Type t         -> return (Type (substTyUnchecked s t))
      Coercion co    -> return (Coercion (substCo s co))
      App f a        -> App <$> go s f <*> go s a
      WebApp w f a   -> WebApp w <$> go s f <*> go s a
      Lam b e        -> do { (s', b') <- clone s b; Lam b' <$> go s' e }
      WebLam w b e   -> do { (s', b') <- clone s b; WebLam w b' <$> go s' e }
      Let (NonRec b rhs) body
        -> do { rhs' <- go s rhs
              ; (s', b') <- clone s b
              ; Let (NonRec b' rhs') <$> go s' body }
      Let (Rec prs) body
        -> do { (s', bs') <- cloneRecIdBndrsM s (map fst prs)
              ; rhss' <- mapM (go s' . snd) prs
              ; Let (Rec (zip bs' rhss')) <$> go s' body }
      Case scrut b ty alts
        -> do { scrut' <- go s scrut
              ; (s', b') <- clone s b
              ; alts' <- mapM (\(Alt c bs rhs) -> do { (s'', bs') <- cloneBndrsM s' bs
                                                     ; Alt c bs' <$> go s'' rhs }) alts
              ; return (Case scrut' b' (substTyUnchecked s ty) alts') }
      Cast e co      -> (\e' -> Cast e' (substCo s co)) <$> go s e
      Tick t e       -> Tick (substTickish s t) <$> go s e

    clone s b = do { u <- getUniqueM; return (cloneBndr s u b) }
