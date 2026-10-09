-- | Data types whose fields other modules cannot see: their constructor
-- signatures follow the web transformations, and the types are rebuilt with
-- the new field types.
--
-- See Note [Hidden fields] in GHC.WebCore.Sigs and Note [Signatures follow
-- the transformations].
module GHC.WebCore.HiddenFields
  ( updateDataConSigs, refreshWorkers
  , addSigBinders, removeSigBinders
  , hiddenFieldWebs
  , rebuildHiddenTypes
  , exprCons
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.DataCon
import GHC.Core.TyCo.Rep
import GHC.Core.TyCo.Compare ( eqType )
import GHC.Core.TyCon
import GHC.Core.Type ( mkTyConApp, mkTyVarTys )
import GHC.Builtin.Types ( manyDataConTy )

import GHC.Types.Id
import GHC.Types.Var.Set
import GHC.Types.Unique.Supply ( UniqSupply, uniqsFromSupply )
import GHC.Data.FastString ( fsLit )
import GHC.Types.Id.Make ( mkDataConWorkId )
import GHC.Types.Name ( getName )
import GHC.Types.Name.Env ( emptyNameEnv )
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Types.Web

import GHC.Utils.Outputable
import GHC.Utils.Panic ( pprPanic )

import GHC.WebCore.DataSplit ( mapTyCons, mapTyConsCo )
import GHC.WebCore.Sigs
import GHC.WebCore.Traverse

import Data.Functor.Identity ( runIdentity )
import Data.Maybe ( fromMaybe )

{- Note [Signatures follow the transformations]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A web inside a hidden field's type (Note [Hidden fields] in GHC.WebCore.Sigs)
is internal, so a transformation may change it, and with it the type of the
field.  Every round of a transformation that changes types (arity and result
raising, dead parameters, uncurrying) returns the type rewrite it applied;
the pipeline applies it to the signatures of the constructors with hidden
fields (updateDataConSigs), and gives the occurrences of their workers the
new signatures (refreshWorkers), before Web Lint checks the round.  A
transformation that takes a product apart reads its components' types from
the current signatures (fieldTys), so they carry the webs the next round
may change.

After erasure, a type whose fields changed is rebuilt in place
(rebuildHiddenTypes): same names and uniques, the new field types.  Its name
may appear in exported signatures (an abstract type), so it cannot be a new
type.  Every occurrence in the program is pointed at the rebuilt type
constructor, data constructors and workers, and unfoldings that mention the
old constructors are dropped (stable ones never do: such constructors keep
their fields exposed).

Defunctionalisation leaves hidden-field webs alone for now: it makes new
types, which SpecIndex then replaces, and a rebuilt field would have to
follow.

A web whose product's components mention a web raised in the same round is
not raised (Note [Recursive products] in GHC.WebCore.Transform.ArityRaise).
-}

{- Note [Signatures in the program]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A transformation decides from the types in the program, but a constructor's
definition is a use of its field webs too, and it is not in the program:

    data P a = P Int (a ->{w} Int)
    use :: P (Int, Int) -> Int
    use (P n g) = g (n, n + 1)

Everywhere in the program w takes a pair, so arity raising would raise it;
but the definition's field takes one polymorphic parameter, and its
signature cannot follow (Web Lint stopped compilation).  So, while the
transformations run, each constructor with hidden fields and a signature
gets a top-level binding  sig = K  whose type is the signature
(addSigBinders): the analyses see the definition (w's argument is a type
variable, not a product, and w is rejected), and the type rewrites reach it
like any other binder.  refreshWorkers keeps the right-hand side's type the
same as the binder's.  The bindings go before erasure (removeSigBinders).
-}

-- | Apply a transformation's type rewrite to the signatures of the
-- constructors with hidden fields.  Their own arrows are exposed, so only
-- the fields change.
updateDataConSigs :: (Type -> Type) -> WebSigs -> WebSigs
updateDataConSigs rw sigs = sigs { ws_dcs = mapUFM upd (ws_dcs sigs) }
  where
    upd (dc, ty) | ws_hidden_fields sigs (dataConTyCon dc) = (dc, rw ty)
                 | otherwise                               = (dc, ty)

-- | Give the occurrences of workers of constructors with hidden fields their
-- current signatures.  An occurrence annotation made (the clone, whose
-- arrows have webs) gets the signature; one a transformation made from the
-- constructor itself (mkCoreConApps, applied without webs) gets its shape,
-- without webs.
refreshWorkers :: WebSigs -> CoreProgram -> CoreProgram
refreshWorkers sigs = mapWebsProgram mapper
  where
    mapper = WebMapper { wm_web = id, wm_axiom = id, wm_global_id = refresh, wm_erase = False }
    refresh v
      | Just dc <- isDataConWorkId_maybe v
      , ws_hidden_fields sigs (dataConTyCon dc)
      , Just ty <- lookupDataConSig sigs dc
      = Just (setIdType v (if annotated (idType v) then ty else eraseWebs ty))
      | otherwise
      = Just v

    annotated ty = case ty of
      ForAllTy _ t         -> annotated t
      FunTy { ft_web = w } -> not (isPlaceholderWeb w)
      _                    -> False

-- | A type without its webs
eraseWebs :: Type -> Type
eraseWebs = mapWebsType (WebMapper { wm_web = const placeholderWeb, wm_axiom = id
                                   , wm_global_id = const Nothing, wm_erase = True })

-- | Add a binding for each constructor signature with hidden fields
-- (Note [Signatures in the program]); returns its binders too
addSigBinders :: UniqSupply -> WebSigs -> CoreProgram -> (CoreProgram, VarSet)
addSigBinders us sigs binds = (binds ++ map snd sig_binds, mkVarSet (map fst sig_binds))
  where
    sig_binds = [ (b, NonRec b (Var (setIdType (dataConWorkId dc) ty)))
                | ((dc, ty), u) <- zip hidden (uniqsFromSupply us)
                , let b = mkSysLocal (fsLit "sig") u manyDataConTy ty ]
    hidden = [ (dc, ty) | (dc, ty) <- nonDetEltsUFM (ws_dcs sigs)
                        , ws_hidden_fields sigs (dataConTyCon dc) ]

-- | Remove the bindings 'addSigBinders' added
removeSigBinders :: VarSet -> CoreProgram -> CoreProgram
removeSigBinders bs = filter keep
  where
    keep (NonRec b _) = not (b `elemVarSet` bs)
    keep (Rec _)      = True

-- | The webs inside hidden fields' types
hiddenFieldWebs :: WebSigs -> WebSet
hiddenFieldWebs sigs
  = unionManyUniqSets [ typeWebs (scaledThing f)
                      | (dc, ty) <- nonDetEltsUFM (ws_dcs sigs)
                      , ws_hidden_fields sigs (dataConTyCon dc)
                      , Just (_, fs, _) <- [sigFields dc ty]
                      , f <- fs ]

-- | Rebuild, in place, the types with hidden fields whose constructor
-- signatures changed, and point the (erased) program at them.  Returns the
-- program and the replaced type constructors, old and new.
-- See Note [Signatures follow the transformations]
rebuildHiddenTypes :: WebSigs -> CoreProgram -> (CoreProgram, [(TyCon, TyCon)])
rebuildHiddenTypes sigs binds
  | null changed = (binds, [])
  | otherwise    = (map rw_bind binds, [ (tc, new_tc tc) | tc <- changed ])
  where
    erase = eraseWebs

    -- The new fields of a constructor, if its signature changed them
    new_fields :: DataCon -> Maybe [Scaled Type]
    new_fields dc
      | Just sig <- lookupDataConSig sigs dc
      , Just (_, fs, _) <- sigFields dc sig
      , let fs' = [ Scaled (erase m) (erase t) | Scaled m t <- fs ]
      , not (and (zipWith eqType (map scaledThing fs') (map scaledThing (dataConRepArgTys dc))))
      = Just fs'
      | otherwise
      = Nothing

    changed = [ tc | tc <- nonDetEltsUniqSet tcs, any (isJust' . new_fields) (tyConDataCons tc) ]
    tcs = mkUniqSet [ dataConTyCon dc | (dc, _) <- nonDetEltsUFM (ws_dcs sigs)
                                      , ws_hidden_fields sigs (dataConTyCon dc) ]
    isJust' = maybe False (const True)

    rebuilt :: UniqFM TyCon (TyCon, UniqFM DataCon DataCon)
    rebuilt = listToUFM [ (tc, rebuild tc) | tc <- changed ]
    new_tc tc = maybe tc fst (lookupUFM rebuilt tc)
    new_dc dc = fromMaybe dc (lookupUFM rebuilt (dataConTyCon dc) >>= \(_, m) -> lookupUFM m dc)

    -- Same names and uniques; the fields mention the rebuilt types (lazily,
    -- as the types are recursive)
    rebuild tc = (tycon, listToUFM [ (dc, dc') | (dc, dc') <- zip dcs dcs' ])
      where
        dcs   = tyConDataCons tc
        tycon = mkAlgTyCon (tyConName tc) (tyConBinders tc) (tyConResKind tc) (tyConRoles tc)
                           (tyConCType_maybe tc) [] (mkDataTyConRhs dcs')
                           (VanillaAlgTyCon (fromMaybe (pprPanic "rebuildHiddenTypes" (ppr tc))
                                                       (tyConRepName_maybe tc)))
                           (isGadtSyntaxTyCon tc)
        dcs'  = map mk_con dcs
        mk_con dc = dc'
          where
            fields = [ Scaled m (ty t) | Scaled m t <- fromMaybe (dataConRepArgTys dc) (new_fields dc) ]
            univs  = dataConUnivTyVars dc
            dc' = mkDataCon (dataConName dc) (dataConIsInfix dc) (promotedRepName dc)
                    (dataConSrcBangs dc) (dataConImplBangs dc) (dataConRepStrictness dc)
                    (dataConFieldLabels dc) univs [] emptyNameEnv (dataConUserTyVarBinders dc)
                    [] [] fields (mkTyConApp tycon (mkTyVarTys univs))
                    NoPromInfo tycon (dataConTag dc) []
                    (mkDataConWorkId (getName (dataConWorkId dc)) dc') NoDataConRep
        promotedRepName dc = tyConRepName_maybe (promoteDataCon dc)
                             `orElse` pprPanic "rebuildHiddenTypes: promoted" (ppr dc)

    ty = runIdentity . mapTyCons (`elemUFM` rebuilt) (return . new_tc)
    co = runIdentity . mapTyConsCo (`elemUFM` rebuilt) (return . new_tc)

    old_dcs = mkUniqSet [ dc | tc <- changed, dc <- tyConDataCons tc ]

    rw_bind (NonRec b e) = NonRec (rw_id b) (rw e)
    rw_bind (Rec prs)    = Rec [ (rw_id b, rw e) | (b, e) <- prs ]

    -- A vanilla unfolding that mentions an old constructor is stale
    rw_id v
      | not (isId v) = v
      | otherwise    = drop_stale (setIdType v (ty (idType v)))
    drop_stale v = case realIdUnfolding v of
      u | not (isStableUnfolding u)
        , Just e <- maybeUnfoldingTemplate u
        , any (`elementOfUniqSet` old_dcs) (exprCons e)
        -> setIdUnfolding v noUnfolding
      _ -> v

    rw expr = case expr of
      Var v
        | Just dc <- isDataConWorkId_maybe v, dc `elementOfUniqSet` old_dcs
                     -> Var (dataConWorkId (new_dc dc))
        | isGlobalId v -> expr
        | otherwise  -> Var (rw_id v)
      Lit {}         -> expr
      App f a        -> App (rw f) (rw a)
      Lam b e        -> Lam (rw_id b) (rw e)
      Let bind body  -> Let (rw_bind bind) (rw body)
      Case e b t as  -> Case (rw e) (rw_id b) (ty t)
                             [ Alt (rw_con c) (map rw_id bs) (rw r) | Alt c bs r <- as ]
      Cast e c       -> Cast (rw e) (co c)
      Tick t e       -> Tick t (rw e)
      Type t         -> Type (ty t)
      Coercion c     -> Coercion (co c)
      WebLam {}      -> pprPanic "rebuildHiddenTypes: web form" (ppr expr)
      WebApp {}      -> pprPanic "rebuildHiddenTypes: web form" (ppr expr)

    rw_con (DataAlt dc) = DataAlt (new_dc dc)
    rw_con c            = c

    orElse = flip fromMaybe

-- | The data constructors an expression builds or matches
exprCons :: CoreExpr -> [DataCon]
exprCons e = case e of
  Var v | Just dc <- isDataConWorkId_maybe v -> [dc]
        | Just dc <- isDataConWrapId_maybe v -> [dc]
  App f a       -> exprCons f ++ exprCons a
  Lam _ x       -> exprCons x
  Let bind body -> concatMap exprCons (rhssOfBind bind) ++ exprCons body
  Case x _ _ as -> exprCons x ++ concat [ [ dc | DataAlt dc <- [c] ] ++ exprCons r | Alt c _ r <- as ]
  Cast x _      -> exprCons x
  Tick _ x      -> exprCons x
  _             -> []
