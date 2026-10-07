-- | Defunctionalisation over webs: the function values of a web become the
-- values of a new data type, one constructor per lambda, and its calls
-- become calls of an apply function.
--
-- See Note [Defunctionalisation] and WEBS-DEFUNC.md.
module GHC.WebCore.Transform.Defunc
  ( defuncProgram
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.DataCon
import GHC.Core.FVs ( exprFreeVars )
import GHC.Core.TyCo.Rep
import GHC.Core.TyCon
import GHC.Core.Type
import GHC.Core.Utils ( exprType )

import GHC.Types.Basic ( Arity )
import GHC.Types.Cpr ( topCprSig )
import GHC.Types.Demand ( Demand(..), splitDmdSig, mkClosedDmdSig, nopSig, topSubDmd )
import GHC.Types.Id
import GHC.Types.Id.Make ( mkDataConWorkId )
import GHC.Types.Name
import GHC.Types.Name.Env ( emptyNameEnv )
import GHC.Core.Coercion ( coercionKind )
import GHC.Data.Pair ( Pair(..) )
import GHC.Types.SourceText ( SourceText(..) )
import GHC.Types.SrcLoc ( noSrcSpan )
import GHC.Types.Tickish
import GHC.Types.Unique ( Unique, getKey, getUnique )
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Types.Unique.Supply
import GHC.Types.Var ( isCoVar )
import GHC.Types.Var.Env
import GHC.Types.Var.Set
import GHC.Types.Web
import GHC.Unit.Module ( Module )

import GHC.Data.FastString ( fsLit, mkFastString )
import GHC.Utils.Outputable

import GHC.WebCore.Transform.ArityRaise ( knownHead )
import GHC.WebCore.Transform.Common ( UnfoldingPolicy, changedBinders, fixUnfolding )
import GHC.WebCore.Traverse ( typeWebs )

import Control.Monad ( forM )
import Data.List ( sortOn, nub )

{- Note [Defunctionalisation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A non-exposed web w knows every lambda that can reach its calls, and every
call those lambdas can reach.  With lambdas L1 .. Ln, each Li = \^w x. ei
with free local variables vi1 .. vik, defunctionalisation replaces w's
function values by the values of a new data type, and w's calls by calls of
a new apply function:

    data D_w = C_1 t11 .. t1k | ... | C_n tn1 .. tnk

    Li                        ==>   C_i vi1 .. vik
    f @^w a                   ==>   $apply_w f a
    $apply_w = \fd x. case fd of { C_i yi1 .. yik -> ei[yij/vij, x/xi]; ... }
    A -{w}-> B                ==>   D_w                (in every type)

Every call of w becomes a known call of $apply_w: GHC can inline it, take
the case apart where the constructor is known (case-of-known-constructor),
and specialise a higher-order function on it (SpecConstr).  An unknown call
(stg_ap_p, an indirect jump) becomes a case on a tag and a direct jump.

Conditions (v1), checked per web:

  * Not exposed, and no join-point lambdas (a jump is not a call).
  * Every call is unknown.  Defunctionalisation would turn a known call of a
    let-bound function into a call of $apply_w and a case, which is slower
    -- and in a recursive function, the case cannot be resolved statically
    (the function is a loop breaker, so its constructor is not visible).
  * At most 'maxLambdas' lambdas: $apply_w has one alternative per lambda.
  * Monomorphic: every arrow of w in the program has closed argument and
    result types, and no lambda has free type or coercion variables.  (A
    polymorphic web needs a GADT, D_w a b, with an equality per
    constructor; not done.)
  * w appears in no coercion (we do not rewrite coercions).
  * Every free variable of a lambda can be a field: fixed runtime
    representation, not an unboxed tuple or sum.
  * The lambdas' binders are distinct (they key the constructors).

Laziness and sharing: a lambda is a value, and so is a constructor
application; a variable of the arrow type that is a thunk is a thunk of
type D_w.  The body of each lambda moves into $apply_w unchanged, and runs
exactly when the call did.

Binders whose types change get their IdInfo fixed: a binder bound to a
lambda of w is now bound to a constructor (arity 0, no demand signature);
call demands on values of the arrow type lose their call structure (they
are data now), keeping their strictness and cardinality; CPR signatures and
stale unfoldings go (Note [Unfoldings and rules after a transformation]).
-}

maxLambdas :: Int
maxLambdas = 8

data Verdict = Defunc Int | NoDefunc String

instance Outputable Verdict where
  ppr (Defunc n)     = text "defunctionalised" <+> parens (int n <+> text "constructors")
  ppr (NoDefunc why) = text "not defunctionalised" <+> parens (text why)

------------------------------------------------------------------
--      Analysis
------------------------------------------------------------------

data Lam = Lam' { l_bndr :: Id, l_expr :: CoreExpr }

data Info = Info
  { i_lams    :: [Lam]
  , i_known   :: Int
  , i_unknown :: Int
  , i_block   :: Maybe String }   -- Why the web cannot be defunctionalised

noInfo :: Info
noInfo = Info [] 0 0 Nothing

plusInfo :: Info -> Info -> Info
plusInfo a b = Info (i_lams a ++ i_lams b) (i_known a + i_known b)
                    (i_unknown a + i_unknown b) (i_block a `orElse'` i_block b)
  where orElse' (Just r) _ = Just r
        orElse' Nothing r  = r

type Infos = UniqFM WebId Info

note :: WebId -> Info -> Infos -> Infos
note w i infos
  | isPlaceholderWeb w = infos
  | otherwise          = addToUFM_C plusInfo infos w i

block :: String -> Info
block why = noInfo { i_block = Just why }

analyse :: CoreProgram -> Infos
analyse binds = foldr go_bind emptyUFM binds
  where
    go_bind (NonRec b e) acc = go_bndr b (go_rhs b e acc)
    go_bind (Rec prs)    acc = foldr (\(b, e) -> go_bndr b . go_rhs b e) acc prs

    go_rhs b e acc
      | isJoinId b = go_join e acc
      | otherwise  = go e acc

    go_join (Lam _ e)        acc = go_join e acc
    go_join (WebLam w p e)   acc = note w (block "join point") (go_bndr p (go_join e acc))
    go_join e                acc = go e acc

    go :: CoreExpr -> Infos -> Infos
    go expr acc = case expr of
      WebLam w p e  -> note w (noInfo { i_lams = [Lam' p expr] }) (go_bndr p (go e acc))
      Lam b e       -> go_bndr b (go e acc)
      WebApp w f a
        | knownHead f -> note w (noInfo { i_known = 1 })   (go f (go a acc))
        | otherwise   -> note w (noInfo { i_unknown = 1 }) (go f (go a acc))
      App f a       -> go f (go a acc)
      Let bind body -> go_bind bind (go body acc)
      Case e b ty alts
        -> go e $ go_bndr b $ go_ty ty $
           foldr (\(Alt _ bs rhs) a -> foldr go_bndr (go rhs a) bs) acc alts
      Cast e co     -> go e (go_co co acc)
      Tick _ e      -> go e acc
      Type t        -> go_ty t acc
      Coercion co   -> go_co co acc
      _             -> acc

    go_bndr b acc
      | isId b    = go_ty (idType b) acc
      | otherwise = acc

    -- A web whose arrow has a free type variable somewhere is polymorphic
    go_ty :: Type -> Infos -> Infos
    go_ty ty acc = case ty of
      FunTy { ft_web = w, ft_arg = a, ft_res = r }
        | not (closed a && closed r) -> note w (block "polymorphic") (go_ty a (go_ty r acc))
        | otherwise                  -> go_ty a (go_ty r acc)
      TyConApp _ tys -> foldr go_ty acc tys
      AppTy t1 t2    -> go_ty t1 (go_ty t2 acc)
      ForAllTy _ t   -> go_ty t acc
      CastTy t _     -> go_ty t acc
      _              -> acc

    closed t = isEmptyVarSet (tyCoVarsOfType t)

    -- Every web in a coercion is left alone
    go_co co acc = foldr (\w -> note w (block "in a coercion")) acc
                         (nonDetEltsUniqSet (coWebs co))

-- | The webs mentioned in a coercion (in its kind)
coWebs :: Coercion -> WebSet
coWebs co = case coercionKind co of
  Pair l r -> typeWebs l `unionUniqSets` typeWebs r

verdict :: VarSet -> WebSet -> WebId -> Info -> (Verdict, [[Id]])
verdict tops exposed w i
  | w `elementOfUniqSet` exposed  = no "exposed"
  | Just why <- i_block i          = no why
  | null lams                     = no "no lambdas"
  | i_unknown i == 0              = no "no unknown calls"
  | i_known i > 0                 = no "known calls"
  | length lams > maxLambdas      = no "too many lambdas"
  | length (nub (map (getUnique . l_bndr) lams)) /= length lams
                                  = no "shared lambda binders"
  | Just why <- firstJust (map lam_problem lams) = no why
  | otherwise                     = (Defunc (length lams), map fields lams)
  where
    lams = i_lams i
    no why = (NoDefunc why, [])

    fvs l = exprFreeVars (l_expr l)
    fields l = sortOn (getKey . getUnique)
                 [ v | v <- nonDetEltsUniqSet (fvs l), isId v, not (v `elemVarSet` tops) ]

    lam_problem l
      | any (\v -> isTyVar v || isCoVar v) (nonDetEltsUniqSet (fvs l))
      = Just "free type or coercion variables"
      | isCoVar (l_bndr l)
      = Just "coercion parameter"
      | not (all ok_field (fields l))
      = Just "unsuitable free variable"
      | otherwise
      = Nothing

    ok_field v = let t = idType v
                 in typeHasFixedRuntimeRep t && not (isUnboxedTupleType t)
                    && not (isUnboxedSumType t) && not (isJoinId v)

    firstJust (Just x : _) = Just x
    firstJust (_ : xs)     = firstJust xs
    firstJust []           = Nothing

------------------------------------------------------------------
--      The new types
------------------------------------------------------------------

-- | What we build for a web
data DWeb = DWeb
  { d_tycon :: TyCon
  , d_cons  :: UniqFM Id (DataCon, [Id])  -- ^ lambda binder -> constructor, fields
  , d_apply :: Id                         -- ^ $apply_w
  , d_fd    :: Id                         -- ^ its first parameter (D_w)
  , d_x     :: Id                         -- ^ its second parameter (A)
  , d_w1    :: WebId                      -- ^ the webs of its arrows
  , d_w2    :: WebId
  , d_res   :: Type                       -- ^ B, the result type
  , d_wild  :: Id                         -- ^ the case binder in $apply_w
  }

-- | Rewrite the arrows of the defunctionalised webs to their data types
mapTy :: UniqFM WebId DWeb -> Type -> Type
mapTy todo = go
  where
    go ty = case ty of
      FunTy { ft_web = w }
        | Just d <- lookupUFM todo w -> mkTyConApp (d_tycon d) []
      FunTy { ft_arg = a, ft_res = r } -> ty { ft_arg = go a, ft_res = go r }
      TyConApp tc tys -> TyConApp tc (map go tys)
      AppTy t1 t2     -> AppTy (go t1) (go t2)
      ForAllTy b t    -> ForAllTy b (go t)
      CastTy t co     -> CastTy (go t) co
      _               -> ty

-- | Make the data type, constructors and apply function of a web.  Lazy in
-- 'todo' (field types may mention other new types): see the knot in
-- 'defuncProgram'
mkDWeb :: Module -> UniqFM WebId DWeb -> UniqSupply -> Int -> [Lam] -> [[Id]] -> DWeb
mkDWeb this_mod todo us n lams fieldss
  = DWeb { d_tycon = tycon, d_cons = listToUFM (zip (map l_bndr lams) (zip cons fieldss))
         , d_apply = apply, d_fd = fd, d_x = x, d_w1 = w1, d_w2 = w2, d_res = res_ty
         , d_wild = wild }
  where
    k = show n
    uniqs = uniqsFromSupply us
    nth i = uniqs !! i
    (u_tc, u_ap, u_fd, u_x) = (nth 0, nth 1, nth 2, nth 3)
    (u_w1, u_w2, u_wild)    = (nth 4, nth 5, nth 6)
    us_rest = drop 7 uniqs
    tc_name = mkExternalName u_tc this_mod (mkTcOcc ("Defun" ++ k)) noSrcSpan
    tycon   = mkAlgTyCon tc_name [] liftedTypeKind [] Nothing [] (mkDataTyConRhs cons)
                         (VanillaAlgTyCon (mkPrelTyConRepName tc_name)) False
    d_ty    = mkTyConApp tycon []
    cons    = [ mk_con i u1 u2 (map (mapTy todo . idType) fs)
              | (i, fs, (u1, u2)) <- zip3 [fIRST_TAG ..] fieldss (pairs us_rest) ]

    mk_con :: Int -> Unique -> Unique -> [Type] -> DataCon
    mk_con tag u_dc u_wk arg_tys = dc
      where
        dc_occ  = mkDataOcc ("Defun" ++ k ++ "_" ++ show tag)
        dc_name = mkExternalName u_dc this_mod dc_occ noSrcSpan
        wk_name = mkExternalName u_wk this_mod (mkDataConWorkerOcc dc_occ) noSrcSpan
        no_bang = HsSrcBang NoSourceText NoSrcUnpack NoSrcStrict
        dc = mkDataCon dc_name False (mkPrelTyConRepName dc_name)
               (map (const no_bang) arg_tys) (map (const HsLazy) arg_tys)
               (map (const NotMarkedStrict) arg_tys)
               [] [] [] emptyNameEnv [] [] []
               (map unrestricted arg_tys) d_ty NoPromInfo tycon tag []
               (mkDataConWorkId wk_name dc) NoDataConRep

    -- The arrow type of the web, from any lambda
    (arg_ty, res_ty) = case lams of
      (l : _) -> (mapTy todo (idType (l_bndr l)), mapTy todo (exprType (lam_body (l_expr l))))
      []      -> (d_ty, d_ty)
    lam_body (WebLam _ _ e) = e
    lam_body e              = e

    w1 = mkWebId u_w1
    w2 = mkWebId u_w2
    fd = mkSysLocal (fsLit "fd") u_fd ManyTy d_ty
    wild = mkSysLocal (fsLit "wild") u_wild ManyTy d_ty
    x  = mkSysLocal (fsLit "x") u_x ManyTy arg_ty
    apply_ty = d_ty `web_fun` (arg_ty `web2_fun` res_ty)
    web_fun a r  = setFunTyWeb w1 (mkVisFunTyMany a r)
    web2_fun a r = setFunTyWeb w2 (mkVisFunTyMany a r)
    apply = mkSysLocal (mkFastString ("$apply" ++ k)) u_ap ManyTy apply_ty

    pairs (a : b : rest) = (a, b) : pairs rest
    pairs _              = []

------------------------------------------------------------------
--      The program
------------------------------------------------------------------

-- | Defunctionalise the webs that qualify.  Returns the new program (if
-- anything changed), the new type constructors, and the verdicts.
defuncProgram :: Module -> UnfoldingPolicy -> UniqSupply -> WebSet -> CoreProgram
              -> (Maybe (CoreProgram, [TyCon]), [(WebId, SDoc, Bool, [Id])])
defuncProgram this_mod pol us exposed binds
  | isNullUFM todo = (Nothing, dump)
  | otherwise      = (Just (binds' ++ [Rec applies], map d_tycon (nonDetEltsUFM todo)), dump)
  where
    (us1, us2) = splitUniqSupply us
    tops  = mkVarSet (bindersOfBinds binds)
    infos = analyse binds
    verdicts = [ (w, v, fs, i)
               | (u, i) <- sortOn (getKey . fst) (nonDetUFMToList infos)
               , let w = mkWebId u
               , not (null (i_lams i))
               , let (v, fs) = verdict tops exposed w i ]
    dump = [ (w, ppr v, is_defunc v, map l_bndr (i_lams i)) | (w, v, _, i) <- verdicts ]
    is_defunc (Defunc {}) = True
    is_defunc _           = False

    -- The knot: field types may mention any of the new types
    todo :: UniqFM WebId DWeb
    todo = listToUFM [ (w, mkDWeb this_mod todo u n (i_lams i) fs)
                     | (n, (w, Defunc {}, fs, i), u)
                         <- zip3 [1 ..] [ v | v@(_, Defunc {}, _, _) <- verdicts ]
                                 (listSplitUniqSupply us1) ]

    changed = changedBinders (\ty -> any (`elemUFM` todo) (nonDetEltsUniqSet (typeWebs ty))) binds

    (binds', alts) = initUs_ us2 (rewrite pol todo changed binds)

    applies = [ (d_apply d, mk_apply d (lookupWithDefaultUFM alts [] w))
              | (w, d) <- nonDetUFMToList' todo ]
    nonDetUFMToList' m = [ (mkWebId u, d) | (u, d) <- nonDetUFMToList m ]

    mk_apply d as
      = WebLam (d_w1 d) (d_fd d) $ WebLam (d_w2 d) (d_x d) $
        Case (Var (d_fd d)) (d_wild d) (d_res d)
             (sortOn alt_tag [ Alt (DataAlt dc) ys rhs | (dc, ys, rhs) <- as ])
    alt_tag (Alt (DataAlt dc) _ _) = dataConTag dc
    alt_tag _                      = 0

------------------------------------------------------------------
--      The rewrite
------------------------------------------------------------------

type Alts = UniqFM WebId [(DataCon, [Id], CoreExpr)]

rewrite :: UnfoldingPolicy -> UniqFM WebId DWeb -> VarSet -> CoreProgram
        -> UniqSM (CoreProgram, Alts)
rewrite pol todo changed binds
  = do { let env0 = mkVarEnv [ (b, fixBndr b) | b <- bindersOfBinds binds ]
       ; rs <- mapM (rw_top env0) binds
       ; return (map fst rs, foldr (plusUFM_C (++) . snd) emptyUFM rs) }
  where
    rw_top env (NonRec b e) = do { (e', as) <- rw env e; return (NonRec (lk env b) e', as) }
    rw_top env (Rec prs)
      = do { rs <- mapM (\(b, e) -> do { (e', as) <- rw env e; return ((lk env b, e'), as) }) prs
           ; return (Rec (map fst rs), foldr (plusUFM_C (++) . snd) emptyUFM rs) }

    lk env v = lookupVarEnv env v `orElse` v
    orElse (Just x) _ = x
    orElse Nothing  y = y

    ty = mapTy todo

    -- A binder whose type changes: see Note [Defunctionalisation]
    fixBndr b
      | not (isId b)              = b
      | not (b `elemVarSet` changed) = fixUnfolding pol changed b
      | otherwise
      = fixUnfolding pol changed $
        b' `setIdArity` new_arity
           `setIdDmdSig` new_sig
           `setIdCprSig` topCprSig
           `setIdDemandInfo` data_dmd (idDemandInfo b)
           `setIdCallArity` min (idCallArity b) new_arity
      where
        new_ty    = ty (idType b)
        b'        = setIdType b new_ty
        new_arity = min (idArity b) (arrows new_ty)
        new_sig
          | new_arity < idArity b = nopSig
          | otherwise = case splitDmdSig (idDmdSig b) of
              (dmds, div) -> mkClosedDmdSig (zipWith fix_arg dmds
                                                     (map Just (arg_tys (idType b)) ++ repeat Nothing)) div
        fix_arg d (Just t) | any (`elemUFM` todo) (nonDetEltsUniqSet (typeWebs t)) = data_dmd d
        fix_arg d _        = d

    -- A demand on a function value that is now data: keep how strict and how
    -- often, drop the call structure
    data_dmd (n :* _) = n :* topSubDmd

    arrows t = case splitFunTy_maybe' t of
      Just r  -> 1 + arrows r
      Nothing -> 0 :: Arity
    splitFunTy_maybe' t = case coreFullView t of
      ForAllTy _ r              -> splitFunTy_maybe' r
      FunTy { ft_res = r }      -> Just r
      _                         -> Nothing
    arg_tys t = case coreFullView t of
      ForAllTy _ r                    -> arg_tys r
      FunTy { ft_arg = a, ft_res = r } -> a : arg_tys r
      _                               -> []

    bndr env b
      | isId b    = let b' = fixBndr b in return (extendVarEnv env b b', b')
      | otherwise = return (env, b)

    bndrs env [] = return (env, [])
    bndrs env (b : bs) = do { (env1, b') <- bndr env b; (env2, bs') <- bndrs env1 bs
                            ; return (env2, b' : bs') }

    rw :: VarEnv Id -> CoreExpr -> UniqSM (CoreExpr, Alts)
    rw env expr = case expr of
      Var v -> return (Var (lk env v), emptyUFM)
      Lit {} -> return (expr, emptyUFM)
      Type t -> return (Type (ty t), emptyUFM)
      Coercion {} -> return (expr, emptyUFM)
      App f a -> do { (f', as1) <- rw env f; (a', as2) <- rw env a
                    ; return (App f' a', plus as1 as2) }
      WebApp w f a
        | Just d <- lookupUFM todo w
        -> do { (f', as1) <- rw env f; (a', as2) <- rw env a
              ; return ( WebApp (d_w2 d) (WebApp (d_w1 d) (Var (d_apply d)) f') a'
                       , plus as1 as2 ) }
        | otherwise
        -> do { (f', as1) <- rw env f; (a', as2) <- rw env a
              ; return (WebApp w f' a', plus as1 as2) }
      WebLam w x e
        | Just d <- lookupUFM todo w
        , Just (dc, fs) <- lookupUFM (d_cons d) x
        -> do { ys <- forM fs $ \v -> do { u <- getUniqueM
                                         ; return (mkSysLocal (occNameFS (getOccName v)) u ManyTy (ty (idType v))) }
              ; let env' = extendVarEnvList env ((x, d_x d) : zip fs ys)
              ; (e', as) <- rw env' e
              ; let con = foldl (\f v -> WebApp placeholderWeb f (Var (lk env v)))
                                (Var (dataConWorkId dc)) fs
              ; return (con, plus as (unitUFM w [(dc, ys, e')])) }
        | otherwise
        -> do { (env', x') <- bndr env x; (e', as) <- rw env' e
              ; return (WebLam w x' e', as) }
      Lam b e -> do { (env', b') <- bndr env b; (e', as) <- rw env' e
                    ; return (Lam b' e', as) }
      Let (NonRec b rhs) body
        -> do { (rhs', as1) <- rw env rhs
              ; (env', b') <- bndr env b
              ; (body', as2) <- rw env' body
              ; return (Let (NonRec b' rhs') body', plus as1 as2) }
      Let (Rec prs) body
        -> do { (env', bs') <- bndrs env (map fst prs)
              ; rs <- mapM (rw env' . snd) prs
              ; (body', as2) <- rw env' body
              ; return ( Let (Rec (zip bs' (map fst rs))) body'
                       , foldr (plus . snd) as2 rs ) }
      Case scrut b t alts
        -> do { (scrut', as1) <- rw env scrut
              ; (env', b') <- bndr env b
              ; rs <- forM alts $ \(Alt c bs rhs) ->
                        do { (env'', bs') <- bndrs env' bs
                           ; (rhs', as) <- rw env'' rhs
                           ; return (Alt c bs' rhs', as) }
              ; return (Case scrut' b' (ty t) (map fst rs), foldr (plus . snd) as1 rs) }
      Cast e co -> do { (e', as) <- rw env e; return (Cast e' co, as) }
      Tick t e  -> do { (e', as) <- rw env e; return (Tick (rw_tick env t) e', as) }

    rw_tick env t@(Breakpoint { breakpointFVs = ids }) = t { breakpointFVs = map (lk env) ids }
    rw_tick _ t = t

    plus = plusUFM_C (++)
