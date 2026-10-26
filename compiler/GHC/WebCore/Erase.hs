-- | Erasure: map a web-annotated program back to ordinary Core.
module GHC.WebCore.Erase
  ( eraseProgram
  , restoreOccurrences
  , agreeDataStructures
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.Coercion.Axiom
import GHC.Core.FVs ( exprFreeVars )
import GHC.Core.Map.Expr ( eqCoreExpr )
import GHC.Core.TyCo.Compare ( eqType )
import GHC.Types.Id
import GHC.Types.Var.Env
import GHC.Types.Unique.FM ( nonDetEltsUFM )
import GHC.Types.Unique.Set ( nonDetEltsUniqSet )
import GHC.Data.Maybe ( orElse )
import GHC.Types.Var.Set
import GHC.Types.Var ( isLocalVar )
import GHC.Types.Basic ( activeInFinalPhase )

import GHC.Types.Web

import GHC.WebCore.Sigs
import GHC.WebCore.Traverse

-- | Erase all webs:
--
--   * 'WebLam' becomes 'Lam' and 'WebApp' becomes 'App'
--   * every web becomes 'placeholderWeb'
--   * clones of global Ids and coercion axioms are replaced by the originals
--     (see Note [Exposed webs] in GHC.WebCore.Sigs)
--
-- The result is ordinary Core, suitable for the rest of the compiler.
eraseProgram :: WebSigs -> CoreProgram -> CoreProgram
eraseProgram sigs = mapWebsProgram eraser
  where
    eraser = WebMapper { wm_web       = const placeholderWeb
                       , wm_axiom     = restore_axiom
                       , wm_global_id = \v -> fst <$> lookupGlobalIdSig sigs v
                       , wm_erase     = True }

    restore_axiom rule = case rule of
      UnbranchedAxiom ax
        | Just (orig, _) <- lookupAxiomSig sigs ax
        -> UnbranchedAxiom (toUnbranchedAxiom orig)
      BranchedAxiom ax i
        | Just (orig, _) <- lookupAxiomSig sigs ax
        -> BranchedAxiom orig i
      _ -> rule

{- Note [Occurrences after the round trip]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Annotation replaces every occurrence of a local Id with its annotated binder
(Note [Initial annotation] in GHC.WebCore.Annotate), and data splitting
again synchronises occurrences with binders (syncOccurrences), so the
pass's output had every occurrence carrying its binder's current IdInfo:
demand, signature, call arity, a case binder's evaluated unfolding.  In
the input, occurrences carry whatever IdInfo the simplifier left them, and
one variable's occurrences need not agree (a recursive function's
occurrences in its own body are older than its caller's).  The programs
print the same but are not the same to the passes that read occurrences:
in the SML benchmark cpstak, a case binder's evaluated unfolding at its
occurrences made a later simplifier run pass the boxed case binder instead
of rebuilding I# x, boxity analysis then kept tak's arguments boxed, and
the program ran 17% more instructions with no web transformed at all.

So after erasure, and after data splitting again, restoreOccurrences puts
back the input's occurrences.  Per top-level binding: an occurrence in a
binding gets back the Id that the same binding's input had for that
unique (local uniques repeat in disjoint scopes; a table for the whole
program restored go1_X2 from another binding, at another type: Core Lint,
nofib real/hidden), when

  * its type is unchanged,
  * everything its unfolding mentions is still bound, and
  * for an occurrence of a let binder, it agrees with the binder on being a
    data structure as CPR analysis's isDataStructure judges it (arity 0
    and an evaluated idUnfolding): CPR analysis asserts this of every
    let-bound occurrence it has no signature for, and data splitting can
    leave input occurrences that disagree (dsedge015, useless019).

A unique bound more than once in one top-level binding, in the input or
the output, is never restored there: which binder an occurrence belongs to
is then a question of scope.  Happy's Mangler, with constant
specialisation alone, had two let-bound z_a6xp at the same type in one
binding, one a data structure, and an occurrence of the other got the
data structure's IdInfo back (CPR analysis's assertion; restore002).

New bindings (constant specialisation's copies) keep their binders as
occurrences.  We tried restoring the input's right-hand sides whole, and
checking occurrence by occurrence in checkRoundTrip, but one variable's
occurrences carry different IdInfo in the input (a recursive function's
occurrences in its own body are older than its caller's), so neither is
exact; roundtrip001 checks the effect that matters instead: with nothing
transformed, the final Core is the same with the web pass as without it.
-}

-- | Put back the input's occurrences: Note [Occurrences after the round trip]
restoreOccurrences :: CoreProgram   -- ^ the program before annotation
                   -> CoreProgram   -- ^ the erased program
                   -> CoreProgram
restoreOccurrences old new = map restore_top new
  where
    -- Per top-level binding: local uniques repeat in disjoint scopes, so
    -- the input occurrences a binding gets back are its own binding's
    old_occs_of :: VarEnv (VarEnv Id)
    old_occs_of = mkVarEnv [ (b, env) | bnd <- old
                                      , let env = occs_bind bnd emptyVarEnv
                                                    `delVarEnvList` repeated (bind_bndrs bnd)
                                      , b <- bindersOf bnd ]
    restore_top bnd = case [ env | b <- bindersOf bnd, Just env <- [lookupVarEnv old_occs_of b] ] of
      env : _ -> go_bind (env `delVarEnvList` repeated (bind_bndrs bnd), new_bndrs bnd) bnd
      []      -> bnd     -- a new binding (a specialised copy, say)
    -- Uniques bound more than once in one top-level binding (two inlined
    -- copies of a library function's local z, at the same type, one a data
    -- structure: happy's Mangler): which binder an occurrence belongs to
    -- is a question of scope, so such occurrences keep the Id erasure gave
    -- them, which agrees with their own binder
    repeated :: [Id] -> [Id]
    repeated bs = [ b | (b, n) <- nonDetEltsUFM counts, n > (1 :: Int) ]
      where counts = foldr (\b env -> extendVarEnv_C (\(x, m) _ -> (x, m + 1)) env b (b, 1))
                           emptyVarEnv bs
    occs_bind (NonRec _ r) env = occs r env
    occs_bind (Rec prs)    env = foldr (occs . snd) env prs
    occs e env = case e of
      Var v | isId v, isLocalId v, not (v `elemVarEnv` env) -> extendVarEnv env v v
            | otherwise                                      -> env
      App f a          -> occs f (occs a env)
      Lam _ b          -> occs b env
      Let bnd b        -> occs_bind bnd (occs b env)
      Case s _ _ alts  -> occs s (foldr (\(Alt _ _ r) -> occs r) env alts)
      Cast b _         -> occs b env
      Tick _ b         -> occs b env
      _                -> env

    bound :: VarSet
    bound = mkVarSet (concatMap bind_bndrs new)
    -- the new binders, to compare with the occurrence put back
    -- (let-bound only: CPR analysis's invariant is about let binders; and
    -- only what it checks, isDataStructure, since the occurrences' older
    -- signatures and unfoldings are what made cpstak fast)
    -- (per top-level binding, like the occurrences)
    new_bndrs :: CoreBind -> VarEnv [Id]
    new_bndrs bnd = foldr (\b env -> extendVarEnv_C (++) env b [b]) emptyVarEnv
                          [ b | b <- let_bndrs bnd, isId b ]
    data_structure x = not (isJoinId x) && idArity x == 0 && isEvaldUnfolding (idUnfolding x)  -- as CPR analysis's isDataStructure
    let_bndrs (NonRec b r) = b : expr_lets r
    let_bndrs (Rec prs)    = concatMap (\(b, r) -> b : expr_lets r) prs
    expr_lets e = case e of
      App f a         -> expr_lets f ++ expr_lets a
      Lam _ x         -> expr_lets x
      Let bnd x       -> let_bndrs bnd ++ expr_lets x
      Case s _ _ alts -> expr_lets s ++ concat [ expr_lets r | Alt _ _ r <- alts ]
      Cast x _        -> expr_lets x
      Tick _ x        -> expr_lets x
      _               -> []
    -- Local uniques repeat in disjoint scopes (two go1_X2 in different
    -- bindings, nofib real/hidden): a binder found by unique is the
    -- occurrence's only if the types agree
    binder_of bndrs v = case [ b | b <- lookupVarEnv bndrs v `orElse` []
                           , idType b `eqType` idType v ] of
      b : _ -> Just b
      []    -> Nothing
    consistent bndrs o v = case binder_of bndrs v of
      Just b -> data_structure o == data_structure b
      Nothing -> True     -- a lambda or case binder
    bind_bndrs (NonRec b r) = b : expr_bndrs r
    bind_bndrs (Rec prs)    = concatMap (\(b, r) -> b : expr_bndrs r) prs
    expr_bndrs e = case e of
      App f a         -> expr_bndrs f ++ expr_bndrs a
      Lam b x         -> b : expr_bndrs x
      Let bnd x       -> bind_bndrs bnd ++ expr_bndrs x
      Case s b _ alts -> b : expr_bndrs s ++ concat [ bs ++ expr_bndrs r | Alt _ bs r <- alts ]
      Cast x _        -> expr_bndrs x
      Tick _ x        -> expr_bndrs x
      _               -> []

    restore (old_occs, bndrs) v
      | isId v, isLocalId v
      , Just o <- lookupVarEnv old_occs v
      , idType o `eqType` idType v
      , consistent bndrs o v
      , allVarSet ok (unf_fvs o)
      = o
      | otherwise = v
    unf_fvs o = case maybeUnfoldingTemplate (realIdUnfolding o) of
      Just t  -> exprFreeVars t
      Nothing -> emptyVarSet
    ok x = not (isLocalVar x) || x `elemVarSet` bound

    go_bind env (NonRec b r) = NonRec b (go env r)
    go_bind env (Rec prs)    = Rec [ (b, go env r) | (b, r) <- prs ]
    go env e = case e of
      Var v           -> Var (restore env v)
      App f a         -> App (go env f) (go env a)
      Lam b x         -> Lam b (go env x)
      Let bnd x       -> Let (go_bind env bnd) (go env x)
      Case s b ty alts -> Case (go env s) b ty [ Alt c bs (go env r) | Alt c bs r <- alts ]
      Cast x co       -> Cast (go env x) co
      Tick t x        -> Tick t (go env x)
      _               -> e

{- Note [Data structures CPR analysis cannot read]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
CPR analysis runs right after the early run, with no simplifier pass in
between.  It gives no signature to a let binder that is a data structure
(isDataStructure in GHC.Core.Opt.CprAnal: arity 0 and an evaluated unfolding);
at an occurrence of one it reads the occurrence's own unfolding instead, and
the occurrences in that unfolding in turn.  So it asserts that every
occurrence of such a binder is a data structure too, and that what the
unfolding mentions is in scope.  The early run's output can break both:
occurrences keep older IdInfo than their binders (Note [Occurrences after the
round trip]; data splitting rewrites binders and their unfoldings separately),
and Specialise's copies of different functions share local uniques, so an
unfolding put back in one copy can mention a binder of another
(roundtrip003, happy's AttrGrammar.Mangler with arity raising of known lazy
parameters).

Patching each step did not converge, so at the end of the run
agreeDataStructures walks the program as CPR analysis will (with the binders
in scope, and into the unfoldings it would read), and for each let-bound data
structure with an occurrence CPR analysis could not read, it drops the
binder's vanilla unfolding.  The binder is then an ordinary binding, which CPR
analysis gives a signature (from its right-hand side, a constructor
application) and finds at every occurrence.  The simplifier rebuilds the
unfolding afterwards.  Only such binders change.
-}

-- | Drop the vanilla unfoldings of the let-bound data structures that have an
-- occurrence CPR analysis could not read; returns the program and those
-- binders.  See Note [Data structures CPR analysis cannot read]
agreeDataStructures :: CoreProgram -> (CoreProgram, [Id])
agreeDataStructures binds
  | isEmptyVarSet bad = (binds, [])
  | otherwise         = (map zap_top binds, nonDetEltsUniqSet bad)
  where
    data_structure x = not (isJoinId x) && idArity x == 0 && isEvaldUnfolding (idUnfolding x)  -- as CPR analysis's isDataStructure
    unf_fvs x = case maybeUnfoldingTemplate (idUnfolding x) of
      Just t  -> exprFreeVars t
      Nothing -> emptyVarSet

    -- the binders in scope, each with whether it is let-bound: as in CPR
    -- analysis, the top-level ones bound before (or in the same group)
    bad = snd (foldl' step (emptyVarEnv, emptyVarSet) binds)
    step (env, acc) bnd = let env' = with True (bindersOf bnd) env
                          in (env', acc `unionVarSet` bind_bad env' bnd)

    -- a data structure's right-hand side is not analysed
    bind_bad env (NonRec b r) | data_structure b = emptyVarSet
                              | otherwise        = expr_bad env r
    bind_bad env (Rec prs)    = unionVarSets [ expr_bad env r | (b, r) <- prs, not (data_structure b) ]
    with is_let bs env = extendVarEnvList env [ (b, (b, is_let)) | b <- bs ]

    -- The binders of the occurrences in an expression that CPR analysis
    -- could not read
    expr_bad :: VarEnv (Var, Bool) -> CoreExpr -> VarSet
    expr_bad env e = case e of
      Var v            -> occ_bad env emptyVarSet v
      App f a          -> expr_bad env f `unionVarSet` expr_bad env a
      Lam b x          -> expr_bad (with False [b] env) x
      Let bnd x        -> let env' = with True (bindersOf bnd) env
                          in bind_bad (case bnd of { NonRec {} -> env; Rec {} -> env' }) bnd
                             `unionVarSet` expr_bad env' x
      Case s b _ alts  -> expr_bad env s `unionVarSet`
                          unionVarSets [ expr_bad (with False (b : bs) env) r | Alt _ bs r <- alts ]
      Cast x _         -> expr_bad env x
      Tick _ x         -> expr_bad env x
      _                -> emptyVarSet

    -- An occurrence: of a let-bound data structure, it must be one itself,
    -- active in the final phase, with an unfolding whose occurrences CPR
    -- analysis can read in turn (cprDataStructureUnfolding_maybe)
    occ_bad env seen v
      | isId v, isLocalId v, not (v `elemVarSet` seen)
      , Just (b, True) <- lookupVarEnv env v
      , data_structure b
      = if data_structure v && activeInFinalPhase (idInlineActivation v)
           && allVarSet (in_scope env) (unf_fvs v)
        then unionVarSets [ occ_bad env (extendVarSet seen v) x | x <- nonDetEltsUniqSet (unf_fvs v) ]
        else unitVarSet b
      | otherwise = emptyVarSet
    in_scope env x = not (isLocalVar x) || x `elemVarEnv` env

    zap b | b `elemVarSet` bad = b `setIdUnfolding` noUnfolding
          | otherwise          = b
    zap_top (NonRec b r) = NonRec (zap b) (zap_expr r)
    zap_top (Rec prs)    = Rec [ (zap b, zap_expr r) | (b, r) <- prs ]
    zap_expr e = case e of
      App f a         -> App (zap_expr f) (zap_expr a)
      Lam b x         -> Lam b (zap_expr x)
      Let bnd x       -> Let (zap_top bnd) (zap_expr x)
      Case s b ty alts -> Case (zap_expr s) b ty [ Alt c bs (zap_expr r) | Alt c bs r <- alts ]
      Cast x co       -> Cast (zap_expr x) co
      Tick t x        -> Tick t (zap_expr x)
      _               -> e
