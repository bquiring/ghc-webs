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
import GHC.Core.FVs ( exprFreeVars, exprsFreeVars, exprFreeVarsList )
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
import GHC.Types.Basic ( Arity )

import GHC.Data.FastString ( appendFS, mkFastString, fsLit )
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

import Data.List ( find, sortOn )
import Data.Maybe ( isJust )
import GHC.Data.Maybe ( orElse )
import GHC.Types.Unique ( Unique )
import Control.Monad ( zipWithM )

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
a key's copy if it matches the key (tcMatchTys).  At most so_max_keys keys
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
  , so_lams   :: Bool             -- ^ Keys may be partial applications and lambdas,
                                  --   and candidates non-recursive: Note [Specialising on lambdas]
  , so_max_keys :: Int            -- ^ At most this many copies per function
                                  --   (-fcore-webs-spec-max-keys, default 4)
  }

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
  , k_args :: [KeyArg]
  }

-- | A known function at a static position, applied to types and perhaps to
-- some values (Note [Specialising on lambdas]): the copy takes the values
data KeyArg = KeyArg
  { ka_pos  :: Int        -- ^ Position among f's value parameters
  , ka_fun  :: Id
  , ka_tys  :: [Type]     -- ^ Its type arguments
  , ka_vals :: [Id]       -- ^ The copy's parameters for its value arguments
  }

-- | A key before its type variables are abstracted: per position, the
-- known function, its type arguments and its number of value arguments
type RawKey = ([Type], [(Int, Id, [Type], Int)])

data Spec = Spec { sp_key :: Key, sp_id :: Id }

-- | Why a top-level function is not a candidate, or its candidate
candidate :: Bool -> (Id, CoreExpr) -> Either String Cand
candidate lams (f, rhs)
  | null vals                       = Left "no value parameters"
  | Nothing <- m_calls              = Left "f occurs other than in calls with its own type variables"
  | null calls, null static         = Left "not recursive"
  | null static                     = Left "no static function parameter"
  | size > specSizeBound            = Left ("too big (" ++ show size ++ ")")
  | otherwise                       = Right (Cand f tvs vals body static size)
  where
    (tvs, vals, body) = collectTyAndValBinders rhs
    size   = exprSize rhs
    m_calls = recCalls f (map mkTyVarTy tvs) body
    calls  = maybe [] id m_calls
    static
      | null calls = [ i | lams, (i, x) <- zip [0..] vals, fun_param x
                         , let (n, in_rec) = callSites x body
                         , n >= 2 || in_rec ]   -- Note [Specialising on lambdas]
      | otherwise  = [ i | (i, x) <- zip [0..] vals, fun_param x
                         , calledIn x body
                         , all (passes i x) calls ]
    fun_param x = isFunTy (idType x) && not (isDictId x)
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

-- | How many calls of x there are in e, and whether one is in the
-- right-hand side of a local recursive binding (a loop)
callSites :: Id -> CoreExpr -> (Int, Bool)
callSites x = go False
  where
    go in_rec e = case e of
      App {} | (Var v, args) <- collectArgs e
             -> let here | v == x, any isValArg args = (1, in_rec)
                         | otherwise                 = (0, False)
                in sumOf (here : map (go in_rec) args)
      App a b            -> plus (go in_rec a) (go in_rec b)
      Lam _ b            -> go in_rec b
      Let (NonRec _ r) b -> plus (go in_rec r) (go in_rec b)
      Let (Rec prs) b    -> sumOf (go in_rec b : map (go True . snd) prs)
      Case s _ _ alts    -> sumOf (go in_rec s : [ go in_rec r | Alt _ _ r <- alts ])
      Cast b _           -> go in_rec b
      Tick _ b           -> go in_rec b
      _                  -> (0, False)
    plus (a, b) (c, d) = (a + c, b || d)
    sumOf = foldr plus (0, False)

-- | A known function: a top-level or imported binder applied to types only,
-- or (with so_lams) also to fewer values than its arity, so that it is a
-- value (Note [Specialising on lambdas])
knownFun :: Bool -> (Id -> Arity) -> VarSet -> VarSet -> CoreExpr -> Maybe (Id, [Type], [CoreExpr])
knownFun lams arity tops locals e = case collectArgs e of
  (Var g, args)
    | isId g, not (isJoinId g)
    , isGlobalId g || g `elemVarSet` tops
    , not (g `elemVarSet` locals)   -- Note [Constants and shadowing] in GHC.WebCore.Transform.ConstProp
    , (targs, vals) <- span isTypeArg args
    , Just tys <- mapM typeArg targs
    , not (any isTypeArg vals)
    , null vals || (lams && length vals < arity g)
    -> Just (g, tys, vals)
  _ -> Nothing

typeArg :: CoreExpr -> Maybe Type
typeArg (Type t) = Just t
typeArg _        = Nothing

-- | The number of value lambdas at the top of a right-hand side
valArity :: CoreExpr -> Arity
valArity = length . filter isId . fst . collectBinders

-- | Each top-level binder's arity, from its right-hand side; an imported
-- one's from its IdInfo
arityIn :: CoreProgram -> Id -> Arity
arityIn binds = \g -> lookupVarEnv env g `orElse` idArity g
  where env = mkVarEnv [ (b, valArity r) | (b, r) <- flattenBinds binds ]

-- | The types of the value arguments a function type takes
valArgTys :: Type -> [Type]
valArgTys ty = case splitFunTy_maybe ty of
  Just (_, _, arg, res) -> arg : valArgTys res
  Nothing               -> []

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

-- | The key a call makes (before abstracting its type variables)
callKey :: SpecOpts -> (Id -> Arity) -> VarSet -> VarSet -> Cand -> [CoreExpr] -> Maybe RawKey
callKey opts arity tops locals c args = do
  (tys, vargs) <- splitCall c args
  let known = [ (i, g, ss, length vs) | i <- c_static c, (a : _) <- [drop i vargs], i < length (c_vals c)
                                      , Just (g, ss, vs) <- [knownFun (so_lams opts) arity tops locals a]
                                      , null vs || g /= c_fun c   -- Note [Specialising on lambdas]
                                      , admitted (c_vals c !! i) g ]
  if null known then Nothing else Just (tys, known)
  where
    admitted x g = case so_webs opts of
      Nothing -> True
      Just sw -> webAdmits sw x g

-- | Does the call match the key?  The template variables' instances, and
-- per position the value arguments of the known function
matchKey :: VarSet -> Key -> [Type] -> [CoreExpr] -> Maybe ([Type], [(Int, [CoreExpr])])
matchKey locals k tys vargs = do
  targets <- mapM target (k_args k)
  subst   <- tcMatchTys (k_tys k ++ concatMap ka_tys (k_args k)) (tys ++ concatMap fst targets)
  return (map (substTyVar subst) (k_tvs k), [ (ka_pos a, vs) | (a, (_, vs)) <- zip (k_args k) targets ])
  where
    target a = case drop (ka_pos a) vargs of
      arg : _ | (Var g', args) <- collectArgs arg, g' == ka_fun a, not (g' `elemVarSet` locals)
              , (targs, vals) <- splitAt (length (ka_tys a)) args
              , length targs == length (ka_tys a)
              , Just ts <- mapM typeArg targs
              , length vals == length (ka_vals a), not (any isTypeArg vals)
              -> Just (ts, vals)
      _ -> Nothing

-- | Is a call's key an instance of a key, at the same positions?
sameKey :: Key -> RawKey -> Bool
sameKey k (tys, args)
  = [ (ka_pos a, ka_fun a, length (ka_tys a), length (ka_vals a)) | a <- k_args k ]
      == [ (i, g, length ss, n) | (i, g, ss, n) <- args ]
  && isJust (tcMatchTys (k_tys k ++ concatMap ka_tys (k_args k))
                        (tys ++ concat [ ss | (_, _, ss, _) <- args ]))

-- | Abstract a call's key over its free type variables (cloned), unless
-- they include coercion variables; with fresh parameters for the values of
-- partial applications
mkKey :: UniqSupply -> RawKey -> Maybe Key
mkKey us (tys, args)
  | any isCoVar fvs = Nothing
  | otherwise
  = do { kargs <- zipWithM karg (listSplitUniqSupply us2) args
       ; return (Key { k_tvs = tvs', k_tys = substTys subst tys, k_args = kargs }) }
  where
    (us1, us2) = splitUniqSupply us
    fvs = scopedSort (tyCoVarsOfTypesList (tys ++ concat [ ss | (_, _, ss, _) <- args ]))
    in_scope = mkInScopeSet (mkVarSet fvs)
    (subst, tvs') = cloneTyVarBndrs (mkEmptySubst in_scope) fvs us1
    karg u (i, g, ss, n)
      | length arg_tys < n = Nothing
      | otherwise
      = Just (KeyArg { ka_pos = i, ka_fun = g, ka_tys = ss'
                     , ka_vals = zipWith (\v ty -> mkSysLocal (fsLit "z") v ManyTy ty)
                                         (uniqsFromSupply u) (take n arg_tys) })
      where ss'     = substTys subst ss
            arg_tys = valArgTys (piResultTys (idType g) ss')

------------------------------------------------------------------
--      The transformation
------------------------------------------------------------------

-- | Specialise the program; the verdicts for -ddump-webs-spec
constSpecProgram :: SpecOpts -> UniqSupply -> CoreProgram -> (CoreProgram, SDoc)
constSpecProgram opts us_all binds_in
  | null cands0 = (binds_in, vcat (map ppr_reject rejects))
  | otherwise   = ( reorderTopBinds binds'
                  , vcat (map ppr_reject rejects) $$ vcat (map ppr_cand cands) $$ vcat (map ppr_lift lifted) )
  where
    (us_lift, us0) = splitUniqSupply us_all
    lams = so_lams opts
    verdicts_of bs = [ (f, candidate lams (f, rhs)) | (f, rhs) <- flattenBinds bs, isId f ]
    cands0  = [ c | (_, Right c) <- verdicts_of binds_in ]
    rejects = [ (f, why) | (f, Left why) <- verdicts_of binds_in, why /= "no value parameters"
                                                              , why /= "not recursive"
                                                              , why /= "no static function parameter" ]

    -- Note [Specialising on lambdas]: lift the lambdas passed for static
    -- parameters, and take the candidates again (their bodies now pass the
    -- lifted functions)
    (binds0, lifted)
      | lams      = liftLambdas us_lift (mkVarEnv [ (c_fun c, c) | c <- cands0 ]) binds_in
      | otherwise = (binds_in, [])
    cands | lams      = [ c | (_, Right c) <- verdicts_of binds0 ]
          | otherwise = cands0
    tops0 = mkVarSet (bindersOfBinds binds0)
    cand_env = mkVarEnv [ (c_fun c, c) | c <- cands ]

    (binds1, specs_final) = rounds (so_rounds opts) us0 binds0 emptyVarEnv
    binds' | lams      = unliftProgram (mkVarSet keyed) lifted binds1
           | otherwise = binds1
    keyed = [ ka_fun a | ss <- nonDetEltsUFM specs_final, s <- ss, a <- k_args (sp_key s) ]

    rounds :: Int -> UniqSupply -> CoreProgram -> VarEnv [Spec] -> (CoreProgram, VarEnv [Spec])
    rounds 0 _ binds specs = (binds, specs)
    rounds n us binds specs
      | null new  = (binds, specs)
      | otherwise = rounds (n - 1) us2 (map (redirectBind specs') binds ++ copies') specs'
      where
        (us1, us2) = splitUniqSupply us
        tops = tops0 `extendVarSetList` [ sp_id s | ss <- nonDetEltsUFM specs, s <- ss ]
        new  = newKeys tops (arityIn binds) us1 specs binds
        (specs', copies) = foldl add (specs, []) new
        add (env, cs) (c, k, u) = (extendVarEnv_C (flip (++)) env (c_fun c) [spec], (spec, c) : cs)
          where spec = Spec k (copyId u c k (length (lookupVarEnv env (c_fun c) `orElse` []) + 1))
        -- The copies' right-hand sides, with every call redirected
        copies' = [ Rec [(sp_id s, redirect specs' (copyRhs c (sp_key s)))] | (s, c) <- reverse copies ]

    -- New keys, in order, with a unique each, and at most so_max_keys per
    -- function in all
    newKeys tops arity us specs binds = go (listSplitUniqSupply us) specs (calls tops arity binds)
      where
        go _ _ [] = []
        go uss env ((c, key) : rest)
          | any (\s -> sameKey (sp_key s) key) old = go uss env rest
          | length old >= so_max_keys opts = go uss env rest
          | u1 : u2 : uss' <- uss
          , Just k <- mkKey u1 key
          = (c, k, uniqFromSupply u2) : go uss' (extendVarEnv_C (flip (++)) env (c_fun c) [Spec k (c_fun c)]) rest
          | otherwise = go uss env rest
          where old = lookupVarEnv env (c_fun c) `orElse` []

    -- Every call of a candidate in the program, with its key
    calls tops arity binds = concatMap (go_e emptyVarSet . snd) (flattenBinds binds)
      where
        go_e locals e = case e of
          App {} | (Var v, args) <- collectArgs e
                 , not (v `elemVarSet` locals)
                 , Just c <- lookupVarEnv cand_env v
                 , Just key <- callKey opts arity tops locals c args
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
                    , pprWithCommas ppr_arg (k_args k) ]
    ppr_arg a = int (ka_pos a) <> text "=" <> ppr (ka_fun a) <+> pprWithCommas ppr (ka_tys a)
                <+> hsep (map ppr (ka_vals a))
    ppr_lift (l, _) = text "Lifted:" <+> ppr l
                      <+> (if l `elem` keyed then text "(a key)" else text "(not a key: put back)")

-- | The copy's binder: f's demand signature, arity and usage without the
-- key's positions
copyId :: Unique -> Cand -> Key -> Int -> Id
copyId u c k n = mkLocalIdWithInfo name ManyTy ty info
  where
    f    = c_fun c
    name = mkDerivedInternalName (\occ -> mkVarOccFS (occNameFS occ `appendFS` mkFastString ("_cs" ++ show n)))
                                 u (idName f)
    ty   = exprType (copyRhs c k)
    fates = [ case keyArgAt k i of
                Nothing -> KeepArg
                Just a | null (ka_vals a) -> DropArg
                       | otherwise        -> SplitArg (length (ka_vals a))
            | (i, _) <- zip [0..] (c_vals c) ]
    info = flip setCallArityInfo (reshapeCallArity fates (idCallArity f)) $
           flip setDemandInfo    (reshapeUsage fates (idDemandInfo f)) $
           flip setDmdSigInfo    (reshapeDmdSig fates (idDmdSig f) :: DmdSig) $
           flip setArityInfo     (reshapeArity fates (idArity f)) $
           vanillaIdInfo

keyPositions :: Key -> [Int]
keyPositions k = map ka_pos (k_args k)

keyArgAt :: Key -> Int -> Maybe KeyArg
keyArgAt k i = find ((== i) . ka_pos) (k_args k)

-- | The copy's right-hand side (calls not yet redirected).  A partial
-- application's value arguments become parameters, at its position
copyRhs :: Cand -> Key -> CoreExpr
copyRhs c k = mkLams (k_tvs k) (mkLams params (substExpr subst2 (c_body c)))
  where
    known = [ (c_vals c !! ka_pos a, mkVarApps (mkTyApps (Var (ka_fun a)) (ka_tys a)) (ka_vals a))
            | a <- k_args k ]
    in_scope = mkInScopeSet (exprFreeVars (mkLams (c_tvs c) (mkLams (c_vals c) (c_body c)))
                             `unionVarSet` mkVarSet (k_tvs k)
                             `unionVarSet` exprsFreeVars (map snd known))
    subst0 = extendIdSubstList (extendTvSubstList (mkEmptySubst in_scope) (zip (c_tvs c) (k_tys k))) known
    (subst2, vals') = substBndrs subst0 [ x | (i, x) <- zip [0..] (c_vals c), i `notElem` keyPositions k ]
    params = go 0 (c_vals c) vals'
    go i (_ : xs) ks | Just a <- keyArgAt k i = ka_vals a ++ go (i + 1) xs ks
    go i (_ : xs) (x' : ks)                   = x' : go (i + 1) xs ks
    go _ _ _                                  = []

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
      , Just (inst, pas) <- matchKey locals k tys vargs
      = mkApps (Var (sp_id s)) (map Type inst ++ concat [ lookup j pas `orElse` [a] | (j, a) <- zip [0..] vargs ])
      | otherwise = try locals v ss args

redirectBind :: VarEnv [Spec] -> CoreBind -> CoreBind
redirectBind specs (NonRec b r) = NonRec b (redirect specs r)
redirectBind specs (Rec prs)    = Rec [ (b, redirect specs r) | (b, r) <- prs ]

------------------------------------------------------------------
--      Lambdas as keys
------------------------------------------------------------------

{- Note [Specialising on lambdas]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
With -fcore-webs-spec-lambdas (and -fcore-webs-spec-calls), a key may also
pass, for a static parameter, a partial application of a known function to
fewer values than its arity, or a lambda.  This is SpecConstr for
functions: GHC's SpecConstr once specialised on lambdas, but it is
disabled there ("fragile, and the spec_loop can be infinite": Note
[Specialising for lambda parameters] in GHC.Core.Opt.SpecConstr).  Here
the number of keys and of rounds bounds it.

Partial applications.  At a call  f @ts (g @ss e1 .. en)  the key is g @ss
with n values, and the copy takes n parameters zs at that position, with
x_i := g @ss zs in its body:

    f_cs1 @cs z1 .. zn = body[g @ss zs / x_i]
    ... f_cs1 @ts e1 .. en ...

g @ss e1 .. en is a value (n is below g's arity), so nothing is computed
twice: the e_j were thunks in the partial application, and are thunks
passed to the copy.  (nofib spectral/ida: f_func_split's hot call passes
f_prune a_cut_off.)  A partial application of f itself is no key: its
values are the copy's parameters, so the copy's calls of it are as unknown
in their own static arguments as before (nofib spectral/mate's moveLine is
passed, as its continuation, moveLine applied to the next direction: such
keys used up the four, and made no call known).

Lambdas.  Before the rounds, a lambda passed for a static parameter of a
candidate is lambda-lifted into a new top-level function f_ll over its free
local variables (type variables first), and the argument becomes the
partial application  f_ll @as ys.  Nested lambdas are lifted inner first,
so that a lifted lambda's body passes the inner one's partial application.
A lambda that calls one of its free variables is not lifted: the copy would
still make that unknown call each time it calls the parameter (the
boundary wrapper  \x -> case eta (D# x) of ...  of an exported function).
Nor is one that mentions the top-level function it is in: lifting would
move that function's recursive call out of its body.  After the rounds, a
lifted function that is in no key is put back: its
partial applications become the lambda again (beta-reduced), and its
binding is dropped.  (nofib imaginary/integrate: integrate1D is passed
\x -> integrate1D l u (\y -> y * x).)

Non-recursive candidates.  A function that is not recursive is a candidate
too, with a function parameter static if it is called at two or more
places, or in the right-hand side of a local recursive binding (a loop).
The copy is then an inlining of f with the function, which GHC did not do
because f is too big: worthwhile when the calls are many or repeated
(integrate1D calls its function nine times; mate's moveLine calls inc in
its loop ml).
-}

-- | Lambda-lift the lambdas passed for the static parameters of the
-- candidates' calls.  Returns the program, with the lifted functions'
-- bindings added, and the lifted functions.
-- See Note [Specialising on lambdas]
liftLambdas :: UniqSupply -> VarEnv Cand -> CoreProgram -> (CoreProgram, [(Id, CoreExpr)])
liftLambdas us cand_env binds = (binds' ++ [ NonRec l r | (l, r) <- lifted ], lifted)
  where
    (binds', lifted) = initUs_ us $
      do { rs <- mapM lift_bind binds
         ; return (map fst rs, concatMap snd rs) }

    lift_bind (NonRec b r) = do { (r', ls) <- go (unitVarSet b) emptyVarSet r; return (NonRec b r', ls) }
    lift_bind (Rec prs)    = do { rs <- mapM (go (mkVarSet (map fst prs)) emptyVarSet . snd) prs
                                ; return (Rec (zip (map fst prs) (map fst rs)), concatMap snd rs) }

    -- selves: the enclosing top-level binders
    go :: VarSet -> VarSet -> CoreExpr -> UniqSM (CoreExpr, [(Id, CoreExpr)])
    go selves locals e = case e of
      App {} | (Var v, args) <- collectArgs e
             , not (v `elemVarSet` locals)
             , Just c <- lookupVarEnv cand_env v
             , Just (tys, vargs) <- splitCall c args
             -> do { rs  <- mapM (go selves locals) vargs
                   ; rs' <- zipWithM (lift_arg selves locals c) [0..] (map fst rs)
                   ; return ( mkApps (Var v) (map Type tys ++ map fst rs')
                            , concatMap snd rs ++ concatMap snd rs') }
      App a b    -> do { (a', l1) <- go selves locals a; (b', l2) <- go selves locals b; return (App a' b', l1 ++ l2) }
      Lam b body -> do { (body', l) <- go selves (extendVarSet locals b) body; return (Lam b body', l) }
      Let bnd body
        -> do { let locals' = extendVarSetList locals (bindersOf bnd)
              ; (bnd', l1) <- case bnd of
                  NonRec b r -> do { (r', l) <- go selves locals r; return (NonRec b r', l) }
                  Rec prs    -> do { rs <- mapM (go selves locals' . snd) prs
                                   ; return (Rec (zip (map fst prs) (map fst rs)), concatMap snd rs) }
              ; (body', l2) <- go selves locals' body
              ; return (Let bnd' body', l1 ++ l2) }
      Case s b ty alts
        -> do { (s', l1) <- go selves locals s
              ; rs <- mapM (\(Alt con bs r) -> do { (r', l) <- go selves (extendVarSetList locals (b : bs)) r
                                                  ; return (Alt con bs r', l) }) alts
              ; return (Case s' b ty (map fst rs), l1 ++ concatMap snd rs) }
      Cast b co  -> do { (b', l) <- go selves locals b; return (Cast b' co, l) }
      Tick t b   -> do { (b', l) <- go selves locals b; return (Tick t b', l) }
      _          -> return (e, [])

    lift_arg selves locals c i arg
      | i `elem` c_static c
      , not (any (`elemVarSet` selves) fvs)   -- Note [Specialising on lambdas]
      , Lam b _ <- arg, isId b
      , not (any isCoVar fvs)
      , not (any isJoinId ids)
      , not (any (\x -> isFunTy (idType x) && calledIn x arg) ids)
      = do { u   <- getUniqueM
           ; us' <- getUniqueSupplyM
             -- A free case binder has an OtherCon unfolding, which a
             -- lambda binder must not have
           ; let bndrs = tvs ++ map (`setIdUnfolding` noUnfolding) ids
                 in_scope = mkInScopeSet (exprFreeVars arg `unionVarSet` mkVarSet bndrs)
                 (subst, bndrs') = cloneBndrs (mkEmptySubst in_scope) us' bndrs
                 rhs  = mkLams bndrs' (substExpr subst arg)
                 name = mkDerivedInternalName (\occ -> mkVarOccFS (occNameFS occ `appendFS` mkFastString "_ll"))
                                              u (idName (c_fun c))
                 l    = mkLocalIdWithInfo name ManyTy (exprType rhs)
                                          (vanillaIdInfo `setArityInfo` valArity rhs)
           ; return (mkVarApps (Var l) bndrs, [(l, rhs)]) }
      | otherwise
      = return (arg, [])
      where
        fvs = exprFreeVarsList arg
        -- The variables bound inside the top-level binding; top-level
        -- binders (and the lifted functions) stay free
        ids = [ v | v <- fvs, isId v, v `elemVarSet` locals ]
        tvs = scopedSort ([ v | v <- fvs, isTyVar v ] ++ tyCoVarsOfTypesList (map idType ids))

-- | Put back the lifted functions that are in no key: each partial
-- application becomes the lambda again, and the binding goes.
-- See Note [Specialising on lambdas]
unliftProgram :: VarSet -> [(Id, CoreExpr)] -> CoreProgram -> CoreProgram
unliftProgram keyed lifted binds
  = [ b' | b <- binds, Just b' <- [go_bind b] ]
  where
    back = mkVarEnv [ (l, r) | (l, r) <- lifted, not (l `elemVarSet` keyed) ]

    go_bind (NonRec b r) | b `elemVarEnv` back = Nothing
                         | otherwise           = Just (NonRec b (go r))
    go_bind (Rec prs) = Just (Rec [ (b, go r) | (b, r) <- prs ])

    -- (a closed lambda's is the lifted function alone)
    go e = case e of
      _ | (Var l, args) <- collectArgs e
        , Just rhs <- lookupVarEnv back l
        , let (bs, body) = collectNBinders' (length args) rhs
        , length bs == length args
        -> beta bs (map go args) body
      App a b          -> App (go a) (go b)
      Lam b body       -> Lam b (go body)
      Let bnd body     -> Let (case bnd of
                                 NonRec b r -> NonRec b (go r)
                                 Rec prs    -> Rec [ (b, go r) | (b, r) <- prs ]) (go body)
      Case s b ty alts -> Case (go s) b ty [ Alt con bs (go r) | Alt con bs r <- alts ]
      Cast b co        -> Cast (go b) co
      Tick t b         -> Tick t (go b)
      _                -> e

    -- The lifted function's own binders (type variables and free
    -- variables), and its lambda, put back into its body
    collectNBinders' n rhs = go_n n [] rhs
      where go_n 0 acc r          = (reverse acc, r)
            go_n k acc (Lam b r)  = go_n (k - 1) (b : acc) r
            go_n _ acc r          = (reverse acc, r)

    -- The in-scope set comes from the body with the inner lifted functions
    -- already put back: their right-hand sides bring free variables (other
    -- top-level binders) that the original body did not mention
    beta bs args body = substExpr subst body'
      where
        body'    = go body
        in_scope = mkInScopeSet (exprsFreeVars args `unionVarSet` exprFreeVars (mkLams bs body'))
        subst = foldl add (mkEmptySubst in_scope) (zip bs args)
        add sb (b, Type t) | isTyVar b = extendTvSubst sb b t
        add sb (b, a)                  = extendIdSubst sb b a
