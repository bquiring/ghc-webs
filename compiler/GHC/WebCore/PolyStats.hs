-- | Counting function-level polymorphism in a Core program, and how each
-- polymorphic function is instantiated.
--
-- See Note [Polymorphism statistics].
module GHC.WebCore.PolyStats
  ( pprPolyStats
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.Predicate ( isPredTy )
import GHC.Core.TyCo.Compare ( eqType )
import GHC.Core.TyCo.Rep
import GHC.Core.Type

import GHC.Builtin.Types ( unitTy )
import GHC.Builtin.Uniques ( mkBuiltinUnique )

import GHC.Data.FastString ( fsLit )

import GHC.Types.Id
import GHC.Types.Name ( mkSystemName )
import GHC.Types.Name.Occurrence ( mkTyVarOccFS )
import GHC.Types.Var
import GHC.Types.Var.Env
import GHC.Types.Var.Set

import GHC.Utils.Outputable

import Data.List ( partition )

{- Note [Polymorphism statistics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
With -ddump-first-class-stats, the "after" phase (the end of the Core
pipeline, before CorePrep) also counts function-level polymorphism: a
binding (top-level or let) whose right-hand side starts with type lambdas.
For each such binding defined in the module, every type parameter is
classified by its instantiations: the type arguments at the binding's
occurrences.  An instantiation inside the binding's own right-hand side
whose argument is the parameter itself (a recursive call at the same type)
is neutral, and not counted.

  exported   the binding is exported: other modules instantiate it too
  escaping   some occurrence is not applied to all the type arguments
             (passed to a rank-n position, or a partial type application)
  unused     no instantiation other than neutral ones
  constant   every instantiation is the same closed type: type constant
             propagation would monomorphise it
  open       every instantiation is the same type, but it mentions type
             variables (e.g. a local function always used at the enclosing
             function's type variable)
  shape      the instantiations differ, and their anti-unifier (least
             general generalisation) has a type constructor at the top,
             e.g. always some pair (T1, T2): the parameter could be replaced
             by one per hole of the anti-unifier
  variable   the anti-unifier is a bare variable: genuinely polymorphic
  other_kind the parameter's kind is not Type (RuntimeRep, levity, ...)

and, for scale: type applications by head (bindings defined here, imported
functions, data constructors), overloaded bindings (with dictionary
parameters), and type lambdas that are not at the top of a binding.

The output is one line, "poly-stats after key=value ...", and one line per
constant, open and shape parameter ("poly-param KIND binder #i: type, over N
instantiations"), for inspection.
-}

data PBind = PBind
  { b_id       :: Id
  , b_tvs      :: [TyVar]     -- its type parameters
  , b_exported :: Bool
  , b_top      :: Bool
  , b_overload :: Bool }      -- has dictionary parameters

-- | An occurrence of a polymorphic binding: its type arguments (fewer than
-- its parameters if it escapes), and whether it is inside the binding's
-- own right-hand side
data Occ = Occ [Type] (Maybe Id)

pprPolyStats :: CoreProgram -> SDoc
pprPolyStats binds
  = vcat (summary : details)
  where
    top_ids = mkVarSet (bindersOfBinds binds)

    -- All polymorphic bindings, top-level and local
    pbinds :: [PBind]
    pbinds = [ pb | b <- binds, pb <- collectBinds True b ]

    collectBinds :: Bool -> CoreBind -> [PBind]
    collectBinds top bind
      = [ PBind b tvs (isExportedId b) top (any isDict vals)
        | (b, rhs) <- flattenBinds [bind]
        , isId b, not (isJoinId b)
        , let (bs, _) = collectBinders (stripTicks rhs)
              (tvs, rest) = span isTyVar bs
              vals = takeWhile isId rest
        , not (null tvs) ]
        ++ concat [ concatMap (collectBinds False) (innerBinds rhs) | (_, rhs) <- flattenBinds [bind] ]

    isDict v = isPredTy (idType v)

    innerBinds :: CoreExpr -> [CoreBind]
    innerBinds e = case e of
      -- the let's right-hand sides are searched by collectBinds
      Let b body       -> b : innerBinds body
      Lam _ x          -> innerBinds x
      App f a          -> innerBinds f ++ innerBinds a
      Case x _ _ alts  -> innerBinds x ++ concat [ innerBinds r | Alt _ _ r <- alts ]
      Cast x _         -> innerBinds x
      Tick _ x         -> innerBinds x
      _                -> []

    pmap :: VarEnv PBind
    pmap = mkVarEnv [ (b_id pb, pb) | pb <- pbinds ]

    -- Aliases: a binding whose right-hand side is just a polymorphic
    -- binding (GHC eta-reduces  /\a b. go @a @b  to  go).  Their
    -- instantiations count for the binding they stand for, and an exported
    -- alias exports it.
    aliases :: VarEnv Id
    aliases = mkVarEnv [ (b, v) | (b, rhs) <- allPairs, Var v <- [stripTicks rhs]
                                , not (b `elemVarEnv` pmap), isId b ]
    -- Every binding pair, at any depth
    allPairs = flattenBinds (concatMap allBindsOf binds)
    allBindsOf b = b : concatMap (concatMap allBindsOf . innerBinds) (rhssOfBind b)
    resolve :: Id -> Maybe Id
    resolve v = go (10 :: Int) v
      where go 0 _ = Nothing
            go k x | x `elemVarEnv` pmap = Just x
                   | Just y <- lookupVarEnv aliases x = go (k - 1) y
                   | otherwise = Nothing
    exported_via_alias = mkVarSet [ t | (b, _) <- allPairs, b `elemVarEnv` aliases
                                      , isExportedId b, Just t <- [resolve b] ]

    -- Occurrences of polymorphic bindings, with the binding whose
    -- right-hand side they are in (innermost first)
    occs :: VarEnv [Occ]
    occs = foldr add emptyVarEnv (concatMap (occsBind []) binds)
      where add (v, o) env = extendVarEnv_C (++) env v [o]

    occsBind :: [Id] -> CoreBind -> [(Id, Occ)]
    occsBind encl bind = concat [ occsExpr (b : encl) rhs | (b, rhs) <- flattenBinds [bind]
                                                          , not (b `elemVarEnv` aliases) ]

    occsExpr :: [Id] -> CoreExpr -> [(Id, Occ)]
    occsExpr encl e = case e of
      Var x | Just v <- resolve x -> [(v, Occ [] (owner v))]
      App {} | (Var x, args) <- collectArgs e, Just v <- resolve x
        -> (v, Occ [ t | Type t <- takeWhile isTypeArg args ] (owner v))
           : concatMap (occsExpr encl) (dropWhile isTypeArg args)
      App f a          -> occsExpr encl f ++ occsExpr encl a
      Lam _ x          -> occsExpr encl x
      Let b body       -> occsBind encl b ++ occsExpr encl body
      Case x _ _ alts  -> occsExpr encl x ++ concat [ occsExpr encl r | Alt _ _ r <- alts ]
      Cast x _         -> occsExpr encl x
      Tick _ x         -> occsExpr encl x
      _                -> []
      where owner v | v `elem` encl = Just v
                    | otherwise     = Nothing

    -- Classify each type parameter of each binding defined here
    classified :: [(PBind, Int, Class)]
    classified = [ (pb, i, classify pb i tv) | pb <- pbinds, (i, tv) <- zip [0..] (b_tvs pb) ]

    classify :: PBind -> Int -> TyVar -> Class
    classify pb i tv
      | not (isLiftedTypeKind (tyVarKind tv)) = OtherKind
      | b_exported pb || b_id pb `elemVarSet` exported_via_alias = CExported
      | any short os  = Escaping
      | otherwise = case args of
          [] -> Unused
          a0 : rest
            | all (eqType a0) rest
            -> if noFreeVarsOfType a0 then Constant a0 n else Open a0 n
            | otherwise
            -> case lgg args of
                 TyVarTy {} -> Variable
                 g          -> Shape g n
      where
        os = lookupVarEnv occs (b_id pb) `orElse'` []
        short (Occ ts _) = length ts < length (b_tvs pb)
        -- the i-th argument of each occurrence, without the neutral ones
        args = [ t | Occ ts own <- os, let t = ts !! i
                   , not (own == Just (b_id pb) && isTyVarTy' tv t) ]
        n  = length args

    isTyVarTy' tv t = case getTyVar_maybe t of
      Just tv' -> tv' == tv
      Nothing  -> False

    orElse' (Just x) _ = x
    orElse' Nothing y  = y

    count p = length (filter p classified)
    is_ c (_, _, c') = sameClass c c'

    tyApps = concatMap tyAppsBind binds
    tyAppsBind b = concatMap tyAppsExpr (rhssOfBind b)
    tyAppsExpr :: CoreExpr -> [TyAppHead]
    tyAppsExpr e = case e of
      App {} | (f, args) <- collectArgs e
        -> [ headOf f | any isTypeArg args ] ++ concatMap tyAppsExpr (f : args)
      Lam _ x          -> tyAppsExpr x
      Let b body       -> tyAppsBind b ++ tyAppsExpr body
      Case x _ _ alts  -> tyAppsExpr x ++ concat [ tyAppsExpr r | Alt _ _ r <- alts ]
      Cast x _         -> tyAppsExpr x
      Tick _ x         -> tyAppsExpr x
      _                -> []
      where
        headOf (Var v)
          | isDataConId v            = HDataCon
          | v `elemVarEnv` pmap      = HLocal
          | isGlobalId v             = HImported
          | v `elemVarSet` top_ids   = HLocal
        headOf _                     = HOther

    -- Type lambdas not at the top of a binding
    innerTyLams = sum (map innerTyLamsBind binds)
    innerTyLamsBind b = sum [ goTop rhs | rhs <- rhssOfBind b ]
    goTop e = let (_, body) = collectTyBinders (stripTicks e)
              in goInner body
    goInner :: CoreExpr -> Int
    goInner e = case e of
      Lam b x | isTyVar b -> 1 + goInner x
              | otherwise -> goInner x
      App f a          -> goInner f + goInner a
      Let b body       -> innerTyLamsBind b + goInner body
      Case x _ _ alts  -> goInner x + sum [ goInner r | Alt _ _ r <- alts ]
      Cast x _         -> goInner x
      Tick _ x         -> goInner x
      _                -> 0

    (top_pb, local_pb) = partition b_top pbinds

    summary = hsep
      [ text "poly-stats after"
      , field "poly_binds"    (length pbinds)
      , field "poly_top"      (length top_pb)
      , field "poly_local"    (length local_pb)
      , field "poly_exported" (length (filter b_exported pbinds))
      , field "overloaded"    (length (filter b_overload pbinds))
      , field "ty_params"     (length classified)
      , field "exported"      (count (is_ CExported))
      , field "escaping"      (count (is_ Escaping))
      , field "unused"        (count (is_ Unused))
      , field "constant"      (count (is_ (Constant unitTy 0)))
      , field "open"          (count (is_ (Open unitTy 0)))
      , field "shape"         (count (is_ (Shape unitTy 0)))
      , field "variable"      (count (is_ Variable))
      , field "other_kind"    (count (is_ OtherKind))
      , field "tyapp_local"    (length (filter (== HLocal) tyApps))
      , field "tyapp_imported" (length (filter (== HImported) tyApps))
      , field "tyapp_datacon"  (length (filter (== HDataCon) tyApps))
      , field "tyapp_other"    (length (filter (== HOther) tyApps))
      , field "inner_tylams"  innerTyLams ]
    field name v = text name <> char '=' <> int v

    details = [ text "poly-param" <+> text kind <+> ppr (b_id pb) <+> char '#' <> int i
                <> colon <+> ppr t <> comma <+> text "over" <+> int n <+> text "instantiations"
              | (pb, i, c) <- classified
              , Just (kind, t, n) <- [detail c] ]
    detail c = case c of
      Constant t n -> Just ("constant", t, n)
      Open t n     -> Just ("open", t, n)
      Shape t n    -> Just ("shape", t, n)
      _            -> Nothing

data TyAppHead = HLocal | HImported | HDataCon | HOther
  deriving Eq

data Class = CExported | Escaping | Unused | Constant Type Int | Open Type Int
           | Shape Type Int | Variable | OtherKind

sameClass :: Class -> Class -> Bool
sameClass a b = tag a == tag b
  where
    tag :: Class -> Int
    tag c = case c of
      CExported -> 0; Escaping -> 1; Unused -> 2; Constant {} -> 3; Open {} -> 4
      Shape {} -> 5; Variable -> 6; OtherKind -> 7

stripTicks :: CoreExpr -> CoreExpr
stripTicks (Tick _ e) = stripTicks e
stripTicks e          = e

-- | The least general generalisation of a non-empty list of types: equal
-- columns are kept, a type constructor (or arrow) common to all is kept with
-- its arguments generalised, and anything else becomes a variable (one per
-- distinct column of types, so  [(Int, a), (Bool, a)]  gives  (b, a)).
lgg :: [Type] -> Type
lgg tys = fst (go tys [])
  where
    go :: [Type] -> [([Type], TyVar)] -> (Type, [([Type], TyVar)])
    go ts memo
      | (t0 : rest) <- ts, all (eqType t0) rest = (t0, memo)
      | Just (tc, argss) <- commonTyCon ts
      = let (args', memo') = goList (transposeN argss) memo
        in (mkTyConApp tc args', memo')
      | Just (args, ress) <- commonFun ts
      = let (a', memo1) = go args memo
            (r', memo2) = go ress memo1
        in (mkVisFunTyMany a' r', memo2)
      | Just tv <- lookupCol ts memo = (mkTyVarTy tv, memo)
      | otherwise
      = let tv = mkTyVar (mkHoleName (length memo)) liftedTypeKind
        in (mkTyVarTy tv, (ts, tv) : memo)

    goList [] memo = ([], memo)
    goList (c : cs) memo = let (t, memo1) = go c memo
                               (ts, memo2) = goList cs memo1
                           in (t : ts, memo2)

    lookupCol ts memo = case [ tv | (ts', tv) <- memo, length ts' == length ts
                                                  , and (zipWith eqType ts ts') ] of
      (tv : _) -> Just tv
      []       -> Nothing

    commonTyCon ts = case mapM (splitTyConApp_maybe . coreFullView) ts of
      Just ((tc, as) : rest)
        | not (any isFunTy ts)
        , all (\(tc', as') -> tc' == tc && length as' == length as) rest
        -> Just (tc, as : map snd rest)
      _ -> Nothing
    commonFun ts = case mapM visFun ts of
      Just prs -> Just (map fst prs, map snd prs)
      Nothing  -> Nothing
    visFun t = case splitFunTy_maybe t of
      Just (af, _, a, r) | isVisibleFunArg af -> Just (a, r)
      _ -> Nothing

    transposeN :: [[Type]] -> [[Type]]
    transposeN xss = case mapM uncons' xss of
      Just prs | not (null xss) -> map fst prs : transposeN (map snd prs)
      _                         -> []
    uncons' (x : xs) = Just (x, xs)
    uncons' []       = Nothing

    mkHoleName i = mkSystemName (mkBuiltinUnique (900000 + i))
                                (mkTyVarOccFS (fsLit ("h" ++ show i)))
