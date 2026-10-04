-- | Counting first-class function behaviour in a Core program.
--
-- See Note [First-class function statistics].
module GHC.WebCore.FirstClass
  ( FirstClassStats(..)
  , firstClassStats
  , pprFirstClassStats
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.DataCon ( dataConTyCon )
import GHC.Core.TyCon ( isClassTyCon )
import GHC.Core.Type
import GHC.Core.Utils ( exprType )

import GHC.Types.Id
import GHC.Types.Name ( getOccString )
import GHC.Types.Var.Env

import GHC.Utils.Outputable

import Data.List ( isPrefixOf )

{- Note [First-class function statistics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-ddump-first-class-stats counts, statically (each occurrence in the program
text counts once), how much first-class function behaviour a module's Core
has, before and after the Core optimisation pipeline.  A "function" is a
value whose type, after any foralls, is an arrow (including (=>) arrows).

  returned     value-lambda groups  \x1 .. xn -> body  whose body (after all
               the lambdas) has a function type: functions that return
               functions
  passed       function-typed value arguments of calls that are not data
               constructor applications
  stored_data  function-typed value arguments of data constructor
               applications (not class dictionaries): functions stored in
               data structures
  stored_dict  function-typed value arguments of class dictionary
               constructors (instance methods)

and, for context:

  lams         value-lambda groups
  calls        applications to at least one value argument, other than data
               constructor applications
  unknown_calls  calls whose head is not a let-bound, top-level or imported
               variable (e.g. a lambda- or case-bound variable): calls of
               first-class functions
  partial_apps calls of a let-bound, top-level or imported function with
               fewer value arguments than its arity (manifest arity for local
               functions, idArity for imported ones)
  ww_workers   binders whose name starts with $w (worker/wrapper workers)

Before optimisation, arity information is not computed yet, so partial_apps
uses manifest arities for local functions throughout.
-}

data FirstClassStats = FCS
  { fc_lams          :: !Int
  , fc_returned      :: !Int
  , fc_passed        :: !Int
  , fc_stored_data   :: !Int
  , fc_stored_dict   :: !Int
  , fc_calls         :: !Int
  , fc_unknown_calls :: !Int
  , fc_partial_apps  :: !Int
  , fc_ww_workers    :: !Int }

plusFCS :: FirstClassStats -> FirstClassStats -> FirstClassStats
plusFCS a b = FCS { fc_lams          = fc_lams a          + fc_lams b
               , fc_returned      = fc_returned a      + fc_returned b
               , fc_passed        = fc_passed a        + fc_passed b
               , fc_stored_data   = fc_stored_data a   + fc_stored_data b
               , fc_stored_dict   = fc_stored_dict a   + fc_stored_dict b
               , fc_calls         = fc_calls a         + fc_calls b
               , fc_unknown_calls = fc_unknown_calls a + fc_unknown_calls b
               , fc_partial_apps  = fc_partial_apps a  + fc_partial_apps b
               , fc_ww_workers    = fc_ww_workers a    + fc_ww_workers b }

noFCS :: FirstClassStats
noFCS = FCS 0 0 0 0 0 0 0 0 0

sumFCS :: (a -> FirstClassStats) -> [a] -> FirstClassStats
sumFCS f = foldr (plusFCS . f) noFCS

-- | One line, for scripts: the phase, then key=value pairs
pprFirstClassStats :: String -> FirstClassStats -> SDoc
pprFirstClassStats phase s
  = hsep [ text "first-class-stats", text phase
         , field "lams" fc_lams, field "returned" fc_returned
         , field "passed" fc_passed, field "stored_data" fc_stored_data
         , field "stored_dict" fc_stored_dict, field "calls" fc_calls
         , field "unknown_calls" fc_unknown_calls
         , field "partial_apps" fc_partial_apps
         , field "ww_workers" fc_ww_workers ]
  where
    field name f = text name <> char '=' <> int (f s)

-- | Is this the type of a function?
isFunctionType :: Type -> Bool
isFunctionType ty = case splitForAllTyCoVars ty of
  (_, body) -> isFunTy body

firstClassStats :: CoreProgram -> FirstClassStats
firstClassStats binds = sumFCS (go_bind top_env) binds
  where
    -- Variables bound by let or at the top level, with their manifest
    -- arity: calls of these are known calls
    top_env = mkVarEnvArity [ (b, manifestArity rhs) | (b, rhs) <- flattenBinds binds ]

    go_bind env (NonRec b e) = bndr_stats b `plusFCS` go_rhs env e
    go_bind env (Rec prs)    = sumFCS (\(b, e) -> bndr_stats b `plusFCS` go_rhs env e) prs

    bndr_stats b
      | isId b, "$w" `isPrefixOf` getOccString b = noFCS { fc_ww_workers = 1 }
      | otherwise                                = noFCS

    go_rhs env e = go env e

    go :: KnownEnv -> CoreExpr -> FirstClassStats
    go env expr = case expr of
      Var {}      -> noFCS
      Lit {}      -> noFCS
      Type {}     -> noFCS
      Coercion {} -> noFCS
      Lam {}      -> go_lam env expr
      WebLam {}   -> go_lam env expr
      App {}      -> go_app env expr
      WebApp {}   -> go_app env expr
      Let bind body
        -> let env' = extendKnown env [ (b, manifestArity rhs) | (b, rhs) <- flattenBinds [bind] ]
           in go_bind env' bind `plusFCS` go env' body
      Case scrut _ _ alts -> go env scrut `plusFCS` sumFCS (\(Alt _ _ rhs) -> go env rhs) alts
      Cast e _    -> go env e
      Tick _ e    -> go env e

    -- A lambda group: count it, and whether it returns a function
    go_lam env expr
      | null val_bndrs = go env body
      | otherwise      = noFCS { fc_lams = 1
                                , fc_returned = if isFunctionType (exprType body) then 1 else 0 }
                         `plusFCS` go env body
      where
        (bndrs, body) = collectWebBinders expr
        val_bndrs     = filter isId bndrs

    -- An application spine
    go_app env expr
      = sumFCS (go env) args `plusFCS` go_head `plusFCS` head_stats
      where
        (fun, args) = collectWebArgs expr
        val_args    = filter (not . isTypeArg) args
        n_val       = length val_args
        fun_args    = length (filter (isFunctionType . exprType) val_args)

        go_head = case fun of
          Var {} -> noFCS
          _      -> go env fun

        head_stats
          | n_val == 0 = noFCS
          | Var v <- fun, Just dc <- isDataConId_maybe v
          = if isClassTyCon (dataConTyCon dc)
            then noFCS { fc_stored_dict = fun_args }
            else noFCS { fc_stored_data = fun_args }
          | otherwise
          = noFCS { fc_calls = 1, fc_passed = fun_args
                   , fc_unknown_calls = if known then 0 else 1
                   , fc_partial_apps  = if partial then 1 else 0 }

        known = case fun of
          Var v -> isGlobalId v || v `elemKnown` env
          _     -> False

        partial = case fun of
          Var v | Just ar <- arityOf env v -> n_val < ar
          _ -> False

-- | Variables whose calls are known (let-bound and top-level ones), with
-- their manifest arities
type KnownEnv = VarEnv Int

mkVarEnvArity :: [(Var, Int)] -> KnownEnv
mkVarEnvArity = mkVarEnv

extendKnown :: KnownEnv -> [(Var, Int)] -> KnownEnv
extendKnown = extendVarEnvList

elemKnown :: Var -> KnownEnv -> Bool
elemKnown = elemVarEnv

arityOf :: KnownEnv -> Var -> Maybe Int
arityOf env v
  | isGlobalId v, idArity v > 0 = Just (idArity v)
  | otherwise = case lookupVarEnv env v of
      Just ar | ar > 0 -> Just ar
      _                -> Nothing

-- | The number of value lambdas at the top of an expression
manifestArity :: CoreExpr -> Int
manifestArity e = length (filter isId (fst (collectWebBinders e)))

-- | Like collectBinders, through WebLam too
collectWebBinders :: CoreExpr -> ([Var], CoreExpr)
collectWebBinders = go []
  where
    go bs (Lam b e)      = go (b:bs) e
    go bs (WebLam _ b e) = go (b:bs) e
    go bs e              = (reverse bs, e)

-- | Like collectArgs, through WebApp and ticks
collectWebArgs :: CoreExpr -> (CoreExpr, [CoreArg])
collectWebArgs = go []
  where
    go as (App f a)      = go (a:as) f
    go as (WebApp _ f a) = go (a:as) f
    go as (Tick _ e)     = go as e
    go as e              = (e, as)
