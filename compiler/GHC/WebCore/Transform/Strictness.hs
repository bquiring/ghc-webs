-- | Web-based strictness: strict arguments are evaluated at the call, and
-- result fields that every caller forces are evaluated in the definition.
--
-- See Note [Web strictness] and WEBS-STRICTNESS.md.
module GHC.WebCore.Transform.Strictness
  ( strictnessRound
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.DataCon
import GHC.Core.Type
import GHC.Types.Var ( isCoVar )
import GHC.Core.Utils ( exprType, exprIsHNF )

import GHC.Types.Demand ( isStrUsedDmd, splitDmdSig )
import GHC.Types.Var.Env
import GHC.Types.Id
import GHC.Types.Unique ( getKey )
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Types.Unique.Supply
import GHC.Types.Web

import GHC.Utils.Outputable

import GHC.WebCore.Transform.Common ( mkWild )
import GHC.WebCore.Traverse ( stripWebForms )

import Data.List ( sortOn )

{- Note [Web strictness]
~~~~~~~~~~~~~~~~~~~~~~~~~
Two dual transformations (WEBS-STRICTNESS.md):

1. Strict arguments.  If every lambda of a (non-exposed) web is strict in
   its parameter, a call of the web evaluates the argument first:
       f @^w a   ==>   case a of a' { __DEFAULT -> f @^w a' }
   A lambda's demand on its parameter describes full applications, so each
   lambda has a saturation depth k (the number of value lambdas from its own
   on), and a call evaluates the argument only if it supplies at least the
   web's largest k arguments from this one on.  The case wraps the whole
   application spine.  At a call of a known function (or a jump), an
   argument that the function's demand signature already makes strict is
   left alone: CorePrep passes it by value.

2. Strict result fields.  If the result of a web is a product, and every
   call of the web is scrutinised by a case on that constructor whose
   alternative is strict in field i, then each lambda of the web evaluates
   field i in the constructor applications it returns (in tail position):
       K e1 e2   ==>   case e1 of v1 { __DEFAULT -> K v1 e2 }

Both only change the order of evaluation within an expression whose value is
demanded anyway, which imprecise exceptions allow.  Nothing changes type.  A
web is transformed once (it is then in 'done').

Both analyses are fixpoints over the webs (Note [Web strictness fixpoints]).

Note [Web strictness fixpoints]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Demand analysis treats an argument of an unknown call as lazy.  So in

    \^w1 x. g @^w2 x          -- g a parameter

x looks lazy even if every lambda of w2 is strict.  We compute strictness
of the webs together, as a greatest fixpoint: assume every eligible web is
strict, then repeatedly drop the webs one of whose lambdas is not strict in
its parameter under the current assumption, until nothing changes.
'strictIn' says whether a parameter is evaluated whenever an expression is:
it is scrutinised or called; a case scrutinee is strict in it, or every
alternative is; or it is passed, at a call supplying enough arguments, to a
web assumed strict.  Demand analysis's own verdict (idDemandInfo) counts
too.  Starting from "strict" is what makes recursive webs strict (as in
demand analysis, which starts from bottom).

Result fields are the dual.  A call of a web has a context:

  * a case on a constructor K, which is strict in some fields of K;
  * a tail position of a lambda of a web w': the call's result is w''s
    result, so its fields are forced exactly when w''s are;
  * anything else (a lazy let, an argument, a cast, a case with DEFAULT
    alternatives): unknown.

The strict fields of a web are the intersection over its calls' contexts.
Tail contexts make this a fixpoint too, again computed from the top: a web
starts with "every field strict" and is lowered by its contexts until
nothing changes.  Join points are lambdas whose calls (jumps) are in tail
positions, so a join point's result fields come from the lambda it is in.
-}

-- | Webs with strict arguments (assumed, during the fixpoint), with depth
type StrictWebs = UniqFM WebId Int

-- | Is x evaluated whenever the expression is evaluated (to WHNF)?
-- Demand analysis says so, or 'strictIn' does.
isStrictIn :: StrictWebs -> Id -> CoreExpr -> Bool
isStrictIn sw x e = isStrUsedDmd (idDemandInfo x) || strictIn sw x e

-- | Is x evaluated whenever the body of a lambda is, after any further
-- lambdas (that is, at the lambda's saturation depth)?
isStrictInBody :: StrictWebs -> Id -> CoreExpr -> Bool
isStrictInBody sw x body = isStrictIn sw x (peel body)
  where
    peel (Lam _ e)      = peel e
    peel (WebLam _ _ e) = peel e
    peel e              = e

-- | Syntactic strictness, using the strict webs at calls.
-- See Note [Web strictness fixpoints]
strictIn :: StrictWebs -> Id -> CoreExpr -> Bool
strictIn sw x = go emptyVarEnv
  where
    -- joins: join points whose body is strict in x
    go :: VarEnv Bool -> CoreExpr -> Bool
    go joins expr = case expr of
      Var v -> v == x || lookupVarEnv joins v == Just True
      Case scrut _ _ alts -> go joins scrut || all (\(Alt _ _ rhs) -> go joins rhs) alts
      Let (NonRec j rhs) body
        | isJoinId j -> go (extendVarEnv joins j (go joins (peel_join rhs))) body
      Let (Rec prs) body
        | all (isJoinId . fst) prs
        -> go (extendVarEnvList joins [ (j, False) | (j, _) <- prs ]) body
      Let _ body -> go joins body
      Tick _ e   -> go joins e
      Cast e _   -> go joins e
      App {}     -> spine joins expr 0
      WebApp {}  -> spine joins expr 0
      _          -> False

    -- n = the number of value arguments applied after this node
    spine joins expr n = case expr of
      WebApp w f a -> (strict_at w (n + 1) && go joins a) || spine joins f (n + 1)
      App f a      -> spine joins f (if isValArg a then n + 1 else n)
      Tick _ f     -> spine joins f n
      Cast f _     -> spine joins f n
      f            -> go joins f      -- Evaluating a call evaluates its head

    strict_at w supplied = case lookupUFM sw w of
      Just k -> supplied >= k
      Nothing -> False

    peel_join (Lam _ e)      = peel_join e
    peel_join (WebLam _ _ e) = peel_join e
    peel_join e              = e

-- | The number of value lambdas at the top of an expression
valueLams :: CoreExpr -> Int
valueLams (Lam b e) | isId b = 1 + valueLams e
                    | otherwise = valueLams e
valueLams (WebLam _ _ e) = 1 + valueLams e
valueLams (Tick _ e)     = valueLams e
valueLams _              = 0

------------------------------------------------------------------
--      Analysis
------------------------------------------------------------------

-- | The context of a call's result.  See Note [Web strictness fixpoints]
data Ctxt
  = CScrut DataCon [Var] CoreExpr   -- ^ case <call> of K ys -> rhs
  | CTail WebId                     -- ^ a tail of a lambda of this web
  | CUnknown

data Info = Info
  { i_lams      :: [(Id, CoreExpr)]  -- The lambdas' parameters and bodies
  , i_depth     :: Int               -- Largest saturation depth
  , i_covar     :: Bool
  , i_calls     :: [Ctxt]
      -- One per call of the web whose result is the web's result
  }

noInfo :: Info
noInfo = Info [] 0 False []

plusInfo :: Info -> Info -> Info
plusInfo a b = Info { i_lams  = i_lams a ++ i_lams b
                    , i_depth = max (i_depth a) (i_depth b)
                    , i_covar = i_covar a || i_covar b
                    , i_calls = i_calls a ++ i_calls b }

type Infos = UniqFM WebId Info

note :: WebId -> Info -> Infos -> Infos
note w i infos
  | isPlaceholderWeb w = infos
  | otherwise          = addToUFM_C plusInfo infos w i

analyse :: CoreProgram -> Infos
analyse binds = foldr go_bind emptyUFM binds
  where
    go_bind (NonRec _ e) acc = go CUnknown e acc
    go_bind (Rec prs)    acc = foldr (go CUnknown . snd) acc prs

    -- ctxt: the context of the expression's value, if it is a call's result
    go :: Ctxt -> CoreExpr -> Infos -> Infos
    go ctxt expr acc = case expr of
      WebLam w x e
        -> go (CTail w) e $ note w (noInfo { i_lams  = [(x, e)]
                                           , i_depth = 1 + valueLams e
                                           , i_covar = isCoVar x }) acc
      Lam _ e -> go CUnknown e acc
      App {}    -> go_spine ctxt expr acc
      WebApp {} -> go_spine ctxt expr acc
      Let (NonRec b rhs) body
        | isJoinId b -> go ctxt rhs (go ctxt body acc)
        | otherwise  -> go CUnknown rhs (go ctxt body acc)
      Let (Rec prs) body
        -> foldr (\(b, rhs) -> go (if isJoinId b then ctxt else CUnknown) rhs)
                 (go ctxt body acc) prs
      Case scrut _ _ alts
        | [Alt (DataAlt dc) ys rhs] <- alts
        , isSpine scrut
        -> go_spine (CScrut dc ys rhs) scrut $ go ctxt rhs acc
        | otherwise
        -> go CUnknown scrut $ foldr (\(Alt _ _ rhs) -> go ctxt rhs) acc alts
      Cast e _ -> go CUnknown e acc
      Tick _ e -> go ctxt e acc
      _        -> acc

    isSpine (WebApp {}) = True
    isSpine (Tick _ e)  = isSpine e
    isSpine _           = False

    -- An application spine; the context of its result is 'ctxt'
    go_spine ctxt expr acc = case peelTicks expr of
      WebApp w f a -> note w (noInfo { i_calls = [ctxt] }) (go_fun f (go CUnknown a acc))
      e            -> go_fun e acc

    -- The function part of a spine: further applications are not the
    -- spine's result
    go_fun e acc = case e of
      WebApp _ f a -> go_fun f (go CUnknown a acc)
      App f a      -> go_fun f (go CUnknown a acc)
      Tick _ e'    -> go_fun e' acc
      _            -> go CUnknown e acc

    peelTicks (Tick _ e) = peelTicks e
    peelTicks e          = e

------------------------------------------------------------------
--      The fixpoints
------------------------------------------------------------------

-- | The webs with strict arguments: the greatest fixpoint.
-- See Note [Web strictness fixpoints]
strictArgWebs :: WebSet -> Infos -> StrictWebs
strictArgWebs exposed infos = loop initial
  where
    initial = mapUFM i_depth (filterUFM_Directly candidate infos)
    candidate u i = not (mkWebId u `elementOfUniqSet` exposed)
                 && not (null (i_lams i)) && not (i_covar i)

    loop sw | sizeUFM sw' == sizeUFM sw = sw
            | otherwise                 = loop sw'
      where sw' = filterUFM_Directly (\u _ -> all_strict sw u) sw

    all_strict sw u = case lookupUFM_Directly infos u of
      Just i  -> all (\(x, body) -> isStrictInBody sw x body) (i_lams i)
      Nothing -> False

-- | The strict result fields of a web, during the fixpoint
data Fields = FTop                   -- ^ No context seen yet: every field
            | FFields DataCon [Bool]
            | FNone String
  deriving Eq

meetFields :: Fields -> Fields -> Fields
meetFields FTop f = f
meetFields f FTop = f
meetFields n@(FNone _) _ = n
meetFields _ n@(FNone _) = n
meetFields (FFields dc1 s1) (FFields dc2 s2)
  | dc1 == dc2 = FFields dc1 (zipWith (&&) s1 s2)
  | otherwise  = FNone "unknown call context"

-- | The strict result fields of every web: the greatest fixpoint.
-- See Note [Web strictness fixpoints]
strictResultFields :: WebSet -> StrictWebs -> Infos -> UniqFM WebId Fields
strictResultFields exposed sw infos = loop initial
  where
    initial = mapUFM_Directly start infos
    start u i
      | mkWebId u `elementOfUniqSet` exposed = FNone "exposed"
      | null (i_lams i)                      = FNone "no lambdas"
      | null (i_calls i)                     = FNone "no calls"
      | otherwise                            = FTop

    loop st | st' == st = st
            | otherwise = loop st'
      where st' = mapUFM_Directly (step st) st

    step _  _ f@(FNone _) = f
    step st u _ = case lookupUFM_Directly infos u of
      Just i  -> foldr (meetFields . ctxt st) FTop (i_calls i)
      Nothing -> FNone "no calls"

    ctxt _  (CScrut dc ys rhs) = FFields dc [ isId y && isStrictIn sw y rhs | y <- ys ]
    ctxt st (CTail w)          = case lookupUFM st w of
                                   Just (FNone _) -> FNone "unknown call context"
                                   Just f         -> f
                                   Nothing        -> FNone "unknown call context"
    ctxt _  CUnknown           = FNone "unknown call context"

------------------------------------------------------------------
--      Verdicts
------------------------------------------------------------------

data ArgVerdict = StrictArg Int | NotStrictArg String
data ResVerdict = StrictFields DataCon [Int] | NoStrictFields String

-- | The verdicts for one web
verdict :: WebSet -> StrictWebs -> UniqFM WebId Fields -> WebId -> Info
        -> (ArgVerdict, ResVerdict)
verdict exposed sw rfs w i
  | w `elementOfUniqSet` exposed = (NotStrictArg "exposed", NoStrictFields "exposed")
  | otherwise = (arg_v, res_v)
  where
    arg_v | null (i_lams i)            = NotStrictArg "no lambdas"
          | i_covar i                  = NotStrictArg "coercion parameter"
          | Just k <- lookupUFM sw w   = StrictArg k
          | otherwise                  = NotStrictArg "lazy"

    res_v = case lookupUFM rfs w of
      Just (FFields dc strict)
        | fields@(_:_) <- [ n | (n, True) <- zip [0..] strict ]
        -> StrictFields dc fields
        | otherwise -> NoStrictFields "no strict field"
      Just (FNone why) -> NoStrictFields why
      Just FTop        -> NoStrictFields "only tail calls"
      Nothing          -> NoStrictFields "no calls"

pprVerdict :: (ArgVerdict, ResVerdict) -> SDoc
pprVerdict (a, r) = ppr_a a <> semi <+> ppr_r r
  where
    ppr_a (StrictArg k)      = text "strict argument (depth" <+> int k <> text ")"
    ppr_a (NotStrictArg why) = text "lazy argument" <+> parens (text why)
    ppr_r (StrictFields dc fs) = text "strict result fields" <+> ppr dc <+> ppr fs
    ppr_r (NoStrictFields why) = text "no strict result fields" <+> parens (text why)

changes :: (ArgVerdict, ResVerdict) -> Bool
changes (StrictArg {}, _)    = True
changes (_, StrictFields {}) = True
changes _                    = False

------------------------------------------------------------------
--      One round
------------------------------------------------------------------

-- | Analyse and rewrite.  Webs in 'done' were handled in an earlier round.
strictnessRound :: UniqSupply -> WebSet -> WebSet -> CoreProgram
                -> (Maybe (CoreProgram, WebSet), [(WebId, SDoc, Bool, [Id])])
strictnessRound us exposed done binds
  | isNullUFM arg_webs && isNullUFM res_webs = (Nothing, dump)
  | otherwise = ( Just (initUs_ us (rewriteProgram arg_webs res_webs binds), handled)
                , dump )
  where
    infos = analyse binds
    sw    = strictArgWebs exposed infos
    rfs   = strictResultFields exposed sw infos
    verdicts = [ (w, verdict exposed sw rfs w i, i)
               | (u, i) <- sortOn (getKey . fst) (nonDetUFMToList infos)
               , let w = mkWebId u
               , not (w `elementOfUniqSet` done) ]
    arg_webs = listToUFM [ (w, k) | (w, (StrictArg k, _), _) <- verdicts ]
    res_webs = listToUFM [ (w, (dc, fs)) | (w, (_, StrictFields dc fs), _) <- verdicts ]
    handled  = mkUniqSet [ w | (w, v, _) <- verdicts, changes v ]
    dump     = [ (w, pprVerdict v, changes v, map fst (i_lams i))
               | (w, v, i) <- verdicts, not (null (i_lams i)) || changes v ]

------------------------------------------------------------------
--      The rewrite
------------------------------------------------------------------

rewriteProgram :: UniqFM WebId Int                     -- ^ Strict-argument webs, with depth
               -> UniqFM WebId (DataCon, [Int])        -- ^ Strict-result-field webs
               -> CoreProgram -> UniqSM CoreProgram
rewriteProgram arg_webs res_webs binds = mapM rw_bind binds
  where
    rw_bind (NonRec b e) = NonRec b <$> rw e
    rw_bind (Rec prs)    = Rec <$> mapM (\(b, e) -> (,) b <$> rw e) prs

    rw :: CoreExpr -> UniqSM CoreExpr
    rw expr = case expr of
      WebLam w x e
        | Just (dc, fs) <- lookupUFM res_webs w
        -> WebLam w x <$> (rw e >>= tails dc fs)
        | otherwise
        -> WebLam w x <$> rw e
      Lam b e       -> Lam b <$> rw e
      App {}        -> rw_app expr
      WebApp {}     -> rw_app expr
      Let bind body -> Let <$> rw_bind bind <*> rw body
      Case e b ty alts
        -> Case <$> rw e <*> pure b <*> pure ty
                <*> mapM (\(Alt c bs rhs) -> Alt c bs <$> rw rhs) alts
      Cast e co     -> (\e' -> Cast e' co) <$> rw e
      Tick t e      -> Tick t <$> rw e
      _             -> return expr

    -- An application spine: evaluate the strict arguments first.  At a call
    -- of a known function (or a jump), an argument that its demand
    -- signature makes strict is left alone: CorePrep already passes it by
    -- value.  See Note [Web strictness]
    rw_app expr = do { (wrap, e') <- go expr 0; return (wrap e') }
      where
        sig_strict = case collect_head expr of
          Var v | isJoinId v || idArity v > 0
                -> map isStrUsedDmd (fst (splitDmdSig (idDmdSig v)))
          _     -> []
        n_args = count_args expr

        -- n = the number of value arguments applied after this node
        go (WebApp w f a) n
          = do { a' <- rw a
               ; (wrap_a, a'') <- case lookupUFM arg_webs w of
                   Just k | n + 1 >= k
                          , not (by_sig (n_args - 1 - n)) -> eval a'
                   _                                      -> return (id, a')
               ; (wrap_f, f') <- go f (n + 1)
               ; return (wrap_f . wrap_a, WebApp w f' a'') }
        go (App f a) n
          = do { a' <- rw a
               ; (wrap_f, f') <- go f (if isValArg a then n + 1 else n)
               ; return (wrap_f, App f' a') }
        go (Tick t e) n
          = do { (wrap, e') <- go e n; return (wrap, Tick t e') }
        go e _
          = do { e' <- rw e; return (id, e') }

        by_sig i = i >= 0 && i < length sig_strict && sig_strict !! i

    count_args (App f a)      = count_args f + (if isValArg a then 1 else 0)
    count_args (WebApp _ f _) = count_args f + 1
    count_args (Tick _ f)     = count_args f
    count_args _              = 0 :: Int

    collect_head (App f _)      = collect_head f
    collect_head (WebApp _ f _) = collect_head f
    collect_head (Tick _ f)     = collect_head f
    collect_head f              = f

    -- Evaluate an argument (if lifted and not already a value)
    eval :: CoreExpr -> UniqSM (CoreExpr -> CoreExpr, CoreExpr)
    eval a
      | definitelyLiftedType ty
      , not (exprIsHNF (stripWebForms a))
      = do { v <- mkWild ty
             -- The evaluated unfolding stops a second evaluation of v
             -- (exprIsHNF), e.g. by the tails of an enclosing lambda
           ; let v' = v `setIdUnfolding` evaldUnfolding
           ; return (\body -> Case a v' (exprType body) [Alt DEFAULT [] body], Var v') }
      | otherwise
      = return (id, a)
      where ty = exprType a

    -- The tail positions of a lambda's body: evaluate the strict fields of
    -- the constructor applications returned there
    tails :: DataCon -> [Int] -> CoreExpr -> UniqSM CoreExpr
    tails dc fs = go
      where
        go expr = case expr of
          Let bind@(NonRec j rhs) body
            | isJoinId j -> do { rhs' <- under_lams rhs; Let (NonRec j rhs') <$> go body }
            | otherwise  -> Let bind <$> go body
          Let (Rec prs) body
            | all (isJoinId . fst) prs
            -> do { prs' <- mapM (\(j, rhs) -> (,) j <$> under_lams rhs) prs
                  ; Let (Rec prs') <$> go body }
            | otherwise -> Let (Rec prs) <$> go body
          Case e b ty alts -> Case e b ty <$> mapM (\(Alt c bs rhs) -> Alt c bs <$> go rhs) alts
          Tick t e  -> Tick t <$> go e
          _ | Just (vals, mk) <- conApp expr
            -> do { (wraps, vals') <- unzip <$> sequence
                                        [ if n `elem` fs then eval v else return (id, v)
                                        | (n, v) <- zip [0..] vals ]
                  ; return (foldr (.) id wraps (mk vals')) }
            | otherwise -> return expr

        -- A join point's body (after its lambdas) is a tail too
        under_lams (Lam b e)      = Lam b <$> under_lams e
        under_lams (WebLam w b e) = WebLam w b <$> under_lams e
        under_lams e              = go e

        -- A saturated application of dc's worker: its value arguments, and
        -- a way to rebuild it with new ones (keeping each argument's web)
        conApp e = case collect e [] of
          (Var v, args)
            | Just dc' <- isDataConWorkId_maybe v, dc' == dc
            , let vals = [ a | (Just _, a) <- args ]
            , length vals == dataConRepArity dc
            -> Just (vals, \vals' -> rebuild (Var v) args vals')
          _ -> Nothing

        collect (App f a)      as = collect f ((Nothing, a) : as)
        collect (WebApp w f a) as = collect f ((Just w, a) : as)
        collect e              as = (e, as)

        rebuild f ((Nothing, a) : as) vs     = rebuild (App f a) as vs
        rebuild f ((Just w, _) : as) (v:vs)  = rebuild (WebApp w f v) as vs
        rebuild f _ _                        = f
