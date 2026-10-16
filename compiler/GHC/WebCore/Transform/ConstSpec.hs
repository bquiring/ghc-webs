-- | Constant specialisation of recursive functions with static function
-- parameters: one copy of the function per known function passed for them.
--
-- See Note [Constant specialisation].
module GHC.WebCore.Transform.ConstSpec
  ( SpecOpts(..)
  , SpecWebs, specWebsInfo
  , constSpecProgram
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.FVs ( exprFreeVars, exprsFreeVars )
import GHC.Core.Stats ( exprSize )
import GHC.Core.Subst
import GHC.Core.TyCo.Rep ( Type(..) )
import GHC.Core.Type
import GHC.Core.Unify ( tcMatchTys )
import GHC.Core.TyCo.Compare ( eqType )
import GHC.Core.TyCo.FVs ( tyCoVarsOfTypesList )
import GHC.Core.Predicate ( isDictId, scopedSort )
import GHC.Core.Utils ( exprType )
import GHC.Types.Var ( isVisibleFunArg, isCoVar )
import GHC.Types.Unique.Set ( elementOfUniqSet )

import GHC.Data.FastString ( appendFS, mkFastString )
import GHC.Types.Demand ( DmdSig )
import GHC.Types.Id
import GHC.Types.Id.Info
import GHC.Types.Name ( mkDerivedInternalName )
import GHC.Types.Name.Occurrence ( mkVarOccFS, occNameFS )
import GHC.Types.Unique.FM
import GHC.Types.Unique.Supply
import GHC.Types.Var.Env
import GHC.Types.Var.Set
import GHC.Types.Web

import GHC.Utils.Outputable

import GHC.WebCore.Transform.Common ( ArgFate(..), reshapeArity, reshapeCallArity, reshapeUsage, reshapeDmdSig
                                    , reorderTopBinds )

import Data.List ( sortOn )
import Data.Maybe ( isJust )
import GHC.Data.Maybe ( orElse )
import GHC.Types.Unique ( Unique )

{- Note [Constant specialisation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A recursive function whose recursive calls pass a function parameter on
unchanged, and that is called from outside with known functions, gets one
copy per known function (nofib solid's CSGtraverse_2, WEBS-EXPERIMENTS.md
§22a):

    trav @a @b q t solve combine = case t of
      Prim p      -> solve p q
      Compose l o r -> combine (trav @a @b q l solve combine) o
                               (trav @a @b q r solve combine)
    ... trav @X @Y q t (prune @Z) merge ...

  ==>

    trav_cs1 @z q t = case t of
      Prim p      -> prune @Z p q
      Compose l o r -> merge (trav_cs1 @z q l) o (trav_cs1 @z q r)
    ... trav_cs1 @Z q t ...

Every call of solve and combine in the copy is known; GHC's later passes
(worker/wrapper, the simplifier) inline them or use their strictness.
Defunctionalisation gets the same effect with a dispatch per call; this
needs no dispatch.

The function.  A top-level binder f = /\as. \xs. body whose body mentions f
only in calls  f @as ys  (the same type variables: no polymorphic
recursion), at least one of them.  A value parameter x_i is /static/ if it
has a function type, is called in the body, and every one of those
recursive calls passes x_i at position i.  A size bound (exprSize of the
right-hand side, specSizeBound) keeps the copies small.

Keys.  At a call  f @ts ys  outside the copies' own recursion, the static
positions where y_i is a known function -- a top-level or imported g,
applied to types only -- make a key: the type arguments ts, and g with its
type arguments per position.  The free type variables of a key (the
caller's own, often) are abstracted: a key is a template, and a call uses
a key's copy if it matches the key (tcMatchTys).  At most specMaxKeys keys
per function.  A variable that a local binder in scope shadows (Note
[Constants and shadowing] in GHC.WebCore.Transform.ConstProp) is neither
a known function nor a call of f.

  -fcore-webs-spec-webs: g is admitted for x_i only if g's first lambda is
    in the web class of x_i's arrow (in the solved program), and that class
    is not exposed and has at most specMaxClass lambdas: the web says which
    functions reach x_i, and only a few do.  One round.
  -fcore-webs-spec-calls: keys from the calls alone, in up to specRounds
    rounds, so that chains work (a copy now passes a known function to
    another function).

The copy.  f_csN = /\cs. \xs'. body[ts[cs]/as, g_i @ss_i/x_i], with cs the
key's type variables (cloned) and xs' the parameters at the other
positions.  Its recursive calls now pass g_i at position i, so they match
the key and go to the copy, like every other matching call in the program.
The copy keeps f's demand signature without the static positions: f's is
sound for every argument, so for these too (Note [Demand signatures after a
transformation] in GHC.WebCore.Transform.Common); worker/wrapper, right
after the early run, reads it.

This runs on ordinary Core at the end of the early run (after erasure), so
GHC's later passes see the known calls.  The generic f stays; once every
call outside it is redirected, it is dead and the simplifier drops it.
-}

-- | What constant specialisation does
data SpecOpts = SpecOpts
  { so_webs   :: Maybe SpecWebs   -- ^ Admit keys by web classes (spec-webs)
  , so_rounds :: Int              -- ^ Rounds of key collection
  }

-- | At most this many copies per function
specMaxKeys :: Int
specMaxKeys = 4

-- | A web class admits its lambdas as keys if it has at most this many
specMaxClass :: Int
specMaxClass = 4

-- | A function is specialised only if its right-hand side is at most this
-- big (exprSize, which counts binders' types)
specSizeBound :: Int
specSizeBound = 4000

------------------------------------------------------------------
--      The web classes (from the solved program)
------------------------------------------------------------------

-- | For -fcore-webs-spec-webs: the web of each top-level function's
-- parameters' arrows and of its own first lambda, and the number of lambdas
-- of each (unexposed) web.  Keyed by binder, read after erasure (binders
-- keep their uniques).
data SpecWebs = SpecWebs
  { sw_param :: UniqFM Id WebId
  , sw_fun   :: UniqFM Id WebId
  , sw_lams  :: UniqFM WebId Int
  }

specWebsInfo :: WebSet -> CoreProgram -> SpecWebs
specWebsInfo exposed binds
  = SpecWebs { sw_param = listToUFM [ (x, w) | (_, rhs) <- tops, x <- leading rhs
                                             , Just w <- [arrowWeb (idType x)] ]
             , sw_fun   = listToUFM [ (g, w) | (g, rhs) <- tops, Just w <- [firstLam rhs] ]
             , sw_lams  = foldr count emptyUFM tops }
  where
    tops = flattenBinds binds

    leading (Lam b e) | isTyVar b = leading e
    leading (WebLam _ b e)        = b : leading e
    leading (Tick _ e)            = leading e
    leading _                     = []

    firstLam (Lam b e) | isTyVar b = firstLam e
    firstLam (WebLam w _ _)        = Just w
    firstLam (Tick _ e)            = firstLam e
    firstLam _                     = Nothing

    arrowWeb ty = case coreFullView ty of
      FunTy { ft_af = af, ft_web = w } | isVisibleFunArg af, not (isPlaceholderWeb w) -> Just w
      _ -> Nothing

    count (_, rhs) acc = go rhs acc
    go e acc = case e of
      WebLam w _ b
        | w `elementOfUniqSet` exposed -> go b acc
        | otherwise                    -> go b (addToUFM_C (+) acc w 1)
      Var {}           -> acc
      Lit {}           -> acc
      App f a          -> go f (go a acc)
      WebApp _ f a     -> go f (go a acc)
      Lam _ b          -> go b acc
      Let bnd b        -> foldr go (go b acc) (rhssOfBind bnd)
      Case s _ _ alts  -> go s (foldr (\(Alt _ _ r) -> go r) acc alts)
      Cast b _         -> go b acc
      Tick _ b         -> go b acc
      Type {}          -> acc
      Coercion {}      -> acc

-- | Is g admitted as a key for parameter x by the web classes?
webAdmits :: SpecWebs -> Id -> Id -> Bool
webAdmits sw x g
  | Just wx <- lookupUFM (sw_param sw) x
  , Just wg <- lookupUFM (sw_fun sw) g
  , wx == wg
  , Just n <- lookupUFM (sw_lams sw) wx
  = n <= specMaxClass
  | otherwise = False

------------------------------------------------------------------
--      Candidates and keys
------------------------------------------------------------------

data Cand = Cand
  { c_fun    :: Id
  , c_tvs    :: [TyVar]
  , c_vals   :: [Id]
  , c_body   :: CoreExpr
  , c_static :: [Int]
  , c_size   :: Int
  }

data Key = Key
  { k_tvs  :: [TyVar]                 -- ^ Template variables
  , k_tys  :: [Type]                  -- ^ f's type arguments
  , k_args :: [(Int, Id, [Type])]     -- ^ Position, known function, its type arguments
  }

data Spec = Spec { sp_key :: Key, sp_id :: Id }

-- | Why a top-level function is not a candidate, or its candidate
candidate :: (Id, CoreExpr) -> Either String Cand
candidate (f, rhs)
  | null vals                       = Left "no value parameters"
  | Nothing <- m_calls              = Left "f occurs other than in calls with its own type variables"
  | Just [] <- m_calls              = Left "not recursive"
  | null static                     = Left "no static function parameter"
  | size > specSizeBound            = Left ("too big (" ++ show size ++ ")")
  | otherwise                       = Right (Cand f tvs vals body static size)
  where
    (tvs, vals, body) = collectTyAndValBinders rhs
    size   = exprSize rhs
    m_calls = recCalls f (map mkTyVarTy tvs) body
    calls  = maybe [] id m_calls
    static = [ i | (i, x) <- zip [0..] vals
                 , isFunTy (idType x), not (isDictId x)
                 , calledIn x body
                 , all (passes i x) calls ]
    passes i x ys = case drop i ys of
      Var y : _ -> y == x
      _         -> False

-- | The value arguments of every occurrence of f, if each is a call with
-- the given type arguments
recCalls :: Id -> [Type] -> CoreExpr -> Maybe [[CoreExpr]]
recCalls f tys = go
  where
    go e = case e of
      Var v | v == f    -> Nothing
            | otherwise -> Just []
      App {} | (Var v, args) <- collectArgs e, v == f
             -> let (targs, vargs) = splitAt (length tys) args
                in if length targs == length tys
                      && and [ case a of { Type t -> eqType t ty; _ -> False } | (a, ty) <- zip targs tys ]
                   then (vargs :) . concat <$> mapM go vargs
                   else Nothing
      App a b         -> (++) <$> go a <*> go b
      Lit {}          -> Just []
      Lam _ b         -> go b
      Let bnd b       -> (++) <$> (concat <$> mapM go (rhssOfBind bnd)) <*> go b
      Case s _ _ alts -> (++) <$> go s <*> (concat <$> mapM (\(Alt _ _ r) -> go r) alts)
      Cast b _        -> go b
      Tick _ b        -> go b
      Type {}         -> Just []
      Coercion {}     -> Just []
      WebApp {}       -> webFormPanic "recCalls"
      WebLam {}       -> webFormPanic "recCalls"

-- | Is x called (applied to a value argument) in e?
calledIn :: Id -> CoreExpr -> Bool
calledIn x = go
  where
    go e = case e of
      App {} | (Var v, args) <- collectArgs e
             -> (v == x && any isValArg args) || any go args
      App a b         -> go a || go b
      Var {}          -> False
      Lit {}          -> False
      Lam _ b         -> go b
      Let bnd b       -> any go (rhssOfBind bnd) || go b
      Case s _ _ alts -> go s || any (\(Alt _ _ r) -> go r) alts
      Cast b _        -> go b
      Tick _ b        -> go b
      Type {}         -> False
      Coercion {}     -> False
      WebApp {}       -> webFormPanic "calledIn"
      WebLam {}       -> webFormPanic "calledIn"

-- | A known function: a top-level or imported binder applied to types only
knownFun :: VarSet -> VarSet -> CoreExpr -> Maybe (Id, [Type])
knownFun tops locals e = case collectArgs e of
  (Var g, args)
    | isId g, not (isJoinId g)
    , isGlobalId g || g `elemVarSet` tops
    , not (g `elemVarSet` locals)   -- Note [Constants and shadowing] in GHC.WebCore.Transform.ConstProp
    , Just tys <- mapM typeArg args
    -> Just (g, tys)
  _ -> Nothing
  where
    typeArg (Type t) = Just t
    typeArg _        = Nothing

-- | The type and value arguments of a call of a candidate, if it has
-- all its type arguments
splitCall :: Cand -> [CoreExpr] -> Maybe ([Type], [CoreExpr])
splitCall c args
  | length targs == length (c_tvs c)
  , Just tys <- mapM typeArg targs
  = Just (tys, rest)
  | otherwise = Nothing
  where
    (targs, rest) = splitAt (length (c_tvs c)) args
    typeArg (Type t) = Just t
    typeArg _        = Nothing

-- | The key a call makes (before abstracting its type variables)
callKey :: SpecOpts -> VarSet -> VarSet -> Cand -> [CoreExpr] -> Maybe ([Type], [(Int, Id, [Type])])
callKey opts tops locals c args = do
  (tys, vargs) <- splitCall c args
  let known = [ (i, g, ss) | i <- c_static c, (a : _) <- [drop i vargs], i < length (c_vals c)
                           , Just (g, ss) <- [knownFun tops locals a]
                           , admitted (c_vals c !! i) g ]
  if null known then Nothing else Just (tys, known)
  where
    admitted x g = case so_webs opts of
      Nothing -> True
      Just sw -> webAdmits sw x g

-- | Does the call match the key?  The template variables' instances
matchKey :: VarSet -> Key -> [Type] -> [CoreExpr] -> Maybe [Type]
matchKey locals k tys vargs = do
  targets <- concat <$> mapM target (k_args k)
  subst   <- tcMatchTys (k_tys k ++ concat [ ss | (_, _, ss) <- k_args k ]) (tys ++ targets)
  return (map (substTyVar subst) (k_tvs k))
  where
    target (i, g, ss) = case drop i vargs of
      a : _ | (Var g', args) <- collectArgs a, g' == g, not (g' `elemVarSet` locals)
            , length args == length ss
            , Just ts <- mapM typeArg args
            -> Just ts
      _ -> Nothing
    typeArg (Type t) = Just t
    typeArg _        = Nothing

-- | Is a call's key an instance of a key, at the same positions?
sameKey :: Key -> ([Type], [(Int, Id, [Type])]) -> Bool
sameKey k (tys, args)
  = map pos (k_args k) == map pos args
  && isJust (tcMatchTys (k_tys k ++ concat [ ss | (_, _, ss) <- k_args k ])
                        (tys ++ concat [ ss | (_, _, ss) <- args ]))
  where pos (i, g, ss) = (i, g, length ss)

-- | Abstract a call's key over its free type variables (cloned), unless
-- they include coercion variables
mkKey :: UniqSupply -> ([Type], [(Int, Id, [Type])]) -> Maybe Key
mkKey us (tys, args)
  | any isCoVar fvs = Nothing
  | otherwise
  = Just (Key { k_tvs = tvs', k_tys = substTys subst tys
              , k_args = [ (i, g, substTys subst ss) | (i, g, ss) <- args ] })
  where
    fvs = scopedSort (tyCoVarsOfTypesList (tys ++ concat [ ss | (_, _, ss) <- args ]))
    in_scope = mkInScopeSet (mkVarSet fvs)
    (subst, tvs') = cloneTyVarBndrs (mkEmptySubst in_scope) fvs us

------------------------------------------------------------------
--      The transformation
------------------------------------------------------------------

-- | Specialise the program; the verdicts for -ddump-webs-spec
constSpecProgram :: SpecOpts -> UniqSupply -> CoreProgram -> (CoreProgram, SDoc)
constSpecProgram opts us0 binds0
  | null cands = (binds0, vcat (map ppr_reject rejects))
  | otherwise  = (reorderTopBinds binds', vcat (map ppr_reject rejects) $$ vcat (map ppr_cand cands))
  where
    tops0 = mkVarSet (bindersOfBinds binds0)
    verdicts = [ (f, candidate (f, rhs)) | (f, rhs) <- flattenBinds binds0, isId f ]
    cands   = [ c | (_, Right c) <- verdicts ]
    rejects = [ (f, why) | (f, Left why) <- verdicts, why /= "no value parameters"
                                                     , why /= "not recursive"
                                                     , why /= "no static function parameter" ]
    cand_env = mkVarEnv [ (c_fun c, c) | c <- cands ]

    (binds', specs_final) = rounds (so_rounds opts) us0 binds0 emptyVarEnv

    rounds :: Int -> UniqSupply -> CoreProgram -> VarEnv [Spec] -> (CoreProgram, VarEnv [Spec])
    rounds 0 _ binds specs = (binds, specs)
    rounds n us binds specs
      | null new  = (binds, specs)
      | otherwise = rounds (n - 1) us2 (map (redirectBind specs') binds ++ copies') specs'
      where
        (us1, us2) = splitUniqSupply us
        tops = tops0 `extendVarSetList` [ sp_id s | ss <- nonDetEltsUFM specs, s <- ss ]
        new  = newKeys tops us1 specs binds
        (specs', copies) = foldl add (specs, []) new
        add (env, cs) (c, k, u) = (extendVarEnv_C (flip (++)) env (c_fun c) [spec], (spec, c) : cs)
          where spec = Spec k (copyId u c k (length (lookupVarEnv env (c_fun c) `orElse` []) + 1))
        -- The copies' right-hand sides, with every call redirected
        copies' = [ Rec [(sp_id s, redirect specs' (copyRhs c (sp_key s)))] | (s, c) <- reverse copies ]

    -- New keys, in order, with a unique each, and at most specMaxKeys per
    -- function in all
    newKeys tops us specs binds = go (listSplitUniqSupply us) specs (calls tops binds)
      where
        go _ _ [] = []
        go uss env ((c, key) : rest)
          | any (\s -> sameKey (sp_key s) key) old = go uss env rest
          | length old >= specMaxKeys = go uss env rest
          | u1 : u2 : uss' <- uss
          , Just k <- mkKey u1 key
          = (c, k, uniqFromSupply u2) : go uss' (extendVarEnv_C (flip (++)) env (c_fun c) [Spec k (c_fun c)]) rest
          | otherwise = go uss env rest
          where old = lookupVarEnv env (c_fun c) `orElse` []

    -- Every call of a candidate in the program, with its key
    calls tops binds = concatMap (go_e emptyVarSet . snd) (flattenBinds binds)
      where
        go_e locals e = case e of
          App {} | (Var v, args) <- collectArgs e
                 , not (v `elemVarSet` locals)
                 , Just c <- lookupVarEnv cand_env v
                 , Just key <- callKey opts tops locals c args
                 -> (c, key) : concatMap (go_e locals) args
          App a b         -> go_e locals a ++ go_e locals b
          Var {}          -> []
          Lit {}          -> []
          Lam b body      -> go_e (extendVarSet locals b) body
          Let bnd body    -> let locals' = extendVarSetList locals (bindersOf bnd)
                                 rhs_locals = case bnd of { Rec {} -> locals'; NonRec {} -> locals }
                             in concatMap (go_e rhs_locals) (rhssOfBind bnd) ++ go_e locals' body
          Case s b _ alts -> go_e locals s
                             ++ concatMap (\(Alt _ bs r) -> go_e (extendVarSetList locals (b : bs)) r) alts
          Cast b _        -> go_e locals b
          Tick _ b        -> go_e locals b
          Type {}         -> []
          Coercion {}     -> []
          WebApp {}       -> webFormPanic "constSpec"
          WebLam {}       -> webFormPanic "constSpec"

    ppr_reject (f, why) = text "Not specialised:" <+> ppr f <> colon <+> text why
    ppr_cand c = hang (text "Candidate:" <+> ppr (c_fun c) <+> text "static" <+> ppr (c_static c)
                         <+> text "size" <+> int (c_size c))
                    2 (case lookupVarEnv specs_final (c_fun c) of
                         Nothing -> text "no known calls"
                         Just ss -> vcat [ ppr (sp_id s) <+> text "for" <+> ppr_key (sp_key s) | s <- ss ])
    ppr_key k = sep [ text "@" <> ppr (k_tvs k), brackets (pprWithCommas ppr (k_tys k))
                    , pprWithCommas (\(i, g, ss) -> int i <> text "=" <> ppr g <+> pprWithCommas ppr ss) (k_args k) ]

-- | The copy's binder: f's demand signature, arity and usage without the
-- key's positions
copyId :: Unique -> Cand -> Key -> Int -> Id
copyId u c k n = mkLocalIdWithInfo name ManyTy ty info
  where
    f    = c_fun c
    name = mkDerivedInternalName (\occ -> mkVarOccFS (occNameFS occ `appendFS` mkFastString ("_cs" ++ show n)))
                                 u (idName f)
    ty   = exprType (copyRhs c k)
    fates = [ if i `elem` keyPositions k then DropArg else KeepArg | (i, _) <- zip [0..] (c_vals c) ]
    info = flip setCallArityInfo (reshapeCallArity fates (idCallArity f)) $
           flip setDemandInfo    (reshapeUsage fates (idDemandInfo f)) $
           flip setDmdSigInfo    (reshapeDmdSig fates (idDmdSig f) :: DmdSig) $
           flip setArityInfo     (reshapeArity fates (idArity f)) $
           vanillaIdInfo

keyPositions :: Key -> [Int]
keyPositions k = [ i | (i, _, _) <- k_args k ]

-- | The copy's right-hand side (calls not yet redirected)
copyRhs :: Cand -> Key -> CoreExpr
copyRhs c k = mkLams (k_tvs k) (mkLams vals' (substExpr subst2 (c_body c)))
  where
    known = [ (c_vals c !! i, mkTyApps (Var g) ss) | (i, g, ss) <- k_args k ]
    in_scope = mkInScopeSet (exprFreeVars (mkLams (c_tvs c) (mkLams (c_vals c) (c_body c)))
                             `unionVarSet` mkVarSet (k_tvs k)
                             `unionVarSet` exprsFreeVars (map snd known))
    subst0 = extendIdSubstList (extendTvSubstList (mkEmptySubst in_scope) (zip (c_tvs c) (k_tys k))) known
    (subst2, vals') = substBndrs subst0 [ x | (i, x) <- zip [0..] (c_vals c), i `notElem` keyPositions k ]

-- | Redirect the calls that match a key to its copy
redirect :: VarEnv [Spec] -> CoreExpr -> CoreExpr
redirect specs = go emptyVarSet
  where
    go locals e = case e of
      App {} | (Var v, args) <- collectArgs e
             , not (v `elemVarSet` locals)
             , Just ss <- lookupVarEnv specs v
             -> let args' = map (go locals) args
                in try locals v (sortOn (negate . length . keyPositions . sp_key) ss) args'
      App a b         -> App (go locals a) (go locals b)
      Var {}          -> e
      Lit {}          -> e
      Lam b body      -> Lam b (go (extendVarSet locals b) body)
      Let bnd body    -> let locals' = extendVarSetList locals (bindersOf bnd)
                         in Let (go_bind locals locals' bnd) (go locals' body)
      Case s b ty alts -> Case (go locals s) b ty
                            [ Alt con bs (go (extendVarSetList locals (b : bs)) r) | Alt con bs r <- alts ]
      Cast b co       -> Cast (go locals b) co
      Tick t b        -> Tick t (go locals b)
      Type {}         -> e
      Coercion {}     -> e
      WebApp {}       -> webFormPanic "redirect"
      WebLam {}       -> webFormPanic "redirect"

    go_bind locals _       (NonRec b r) = NonRec b (go locals r)
    go_bind _      locals' (Rec prs)    = Rec [ (b, go locals' r) | (b, r) <- prs ]

    try _ v [] args = mkApps (Var v) args
    try locals v (s : ss) args
      | let k = sp_key s
            ntys = length (k_tys k)
            (targs, vargs) = splitAt ntys args
      , length targs == ntys
      , Just tys <- mapM typeArg targs
      , Just inst <- matchKey locals k tys vargs
      = mkApps (Var (sp_id s)) (map Type inst ++ [ a | (j, a) <- zip [0..] vargs, j `notElem` keyPositions k ])
      | otherwise = try locals v ss args

    typeArg (Type t) = Just t
    typeArg _        = Nothing

redirectBind :: VarEnv [Spec] -> CoreBind -> CoreBind
redirectBind specs (NonRec b r) = NonRec b (redirect specs r)
redirectBind specs (Rec prs)    = Rec [ (b, redirect specs r) | (b, r) <- prs ]
