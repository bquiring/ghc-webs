{-# LANGUAGE MultiWayIf #-}

-- | Constant propagation over webs: constant arguments are substituted into
-- the lambdas of the web, and constant results into the case expressions
-- that scrutinise its calls.
--
-- See Note [Web constant propagation] and WEBS-CONST-PROP.md.
module GHC.WebCore.Transform.ConstProp
  ( constPropRound
  ) where

import GHC.Prelude

import GHC.Core
import GHC.Core.DataCon
import GHC.Core.Map.Expr ( eqCoreExpr )
import GHC.Core.FVs ( exprFreeVars )
import GHC.Core.Opt.Arity ( exprIsDeadEnd )
import GHC.Core.Type
import GHC.Core.Utils ( exprType, findAlt, stripTicksTopE )
import GHC.Core.TyCo.Compare ( eqType )
import GHC.Types.Var ( isCoVar )

import GHC.Types.Id
import GHC.Types.Literal ( Literal(..) )
import GHC.Types.Tickish
import GHC.Types.Unique ( getKey )
import GHC.Types.Unique.FM
import GHC.Types.Unique.Set
import GHC.Types.Unique.Supply
import GHC.Types.Var.Env
import GHC.Types.Var.Set
import GHC.Types.Web

import GHC.Utils.Outputable

import GHC.WebCore.Traverse ( stripWebForms )

import Data.List ( sortOn )
import Data.Maybe ( isJust )

{- Note [Web constant propagation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Arguments.  If every call of a (non-exposed) web w passes the same constant
c, then every lambda of w is applied only to c:

    \^w x. e     ==>   \^w x. e[c/x]

x is then dead, and dead-parameter elimination removes it (and the
argument at every call).  Partial applications are calls too.

Results.  If every lambda of w returns the same constant c (each tail of its
body is c, a dead end, a tail call of w, or a jump to a join point bound in
tail position whose tails are such), then a call of w that returns returns
c, so a case on the call can pick its alternative now:

    case f @^w a of b { alts }   ==>   case f @^w a of b { __DEFAULT -> rhs }

where rhs is the alternative of alts that matches c.  The call is still
evaluated (it may diverge, or have effects through unsafePerformIO).

A constant is a literal (other than a string), a nullary data constructor
(possibly applied to closed types), or a variable bound at top level or
imported, of closed type.  Each is in scope everywhere and duplicating it
duplicates no work.  The constant's type must be the lambda's parameter type
(a polymorphic lambda may be applied to a constant only at some instance).

Laziness: substituting a constant for a variable bound to it changes nothing;
a constant is already a value, or a top-level variable whose evaluation is
shared.
-}

{- Note [Constants and shadowing]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Core lets a local binder shadow a top-level one with the same unique: GHC's
eta expansion names its binders eta_B0, eta_B1, ... and one of them can end
up at top level.  In JuicyPixels' Codec.Picture.Bitmap a top-level
eta_B0 :: Word16 and a local eta_B0 :: IndexedBmpFormat both existed, and
the local one, passed to a derived Show function, was taken for the
top-level constant: its parameter was replaced by eta_B0, now bound to the
wrong variable (Web Lint: type mismatch between binder and occurrence).  So
a variable is a top-level constant only if no local binder in scope has its
unique, and the rewrite substitutes neither under a binder that shadows the
parameter nor a constant whose variable a binder shadows (the parameter
then stays used, and dead-parameter elimination keeps it).
-}

data ArgVerdict = ArgConst CoreExpr | NoArgConst String
data ResVerdict = ResConst CoreExpr | NoResConst String

------------------------------------------------------------------
--      Analysis
------------------------------------------------------------------

data Info = Info
  { i_lams  :: [(Id, (Int, Bool))]  -- Each lambda's binder, and the index of
                                    -- its top-level binding group (and
                                    -- whether that group is recursive)
  , i_args  :: [Maybe CoreExpr]     -- One per call: the constant, if it is one
  , i_ress  :: [Maybe CoreExpr]     -- One per lambda: its constant result
  , i_join  :: Bool                 -- Some lambda is a join point's
  }

noInfo :: Info
noInfo = Info [] [] [] False

plusInfo :: Info -> Info -> Info
plusInfo a b = Info (i_lams a ++ i_lams b) (i_args a ++ i_args b)
                    (i_ress a ++ i_ress b) (i_join a || i_join b)

type Infos = UniqFM WebId Info

note :: WebId -> Info -> Infos -> Infos
note w i infos
  | isPlaceholderWeb w = infos
  | otherwise          = addToUFM_C plusInfo infos w i

-- | Is this expression a constant (see Note [Web constant propagation])?
-- Literals, saturated constructor applications to constants (with closed
-- type arguments), and top-level or imported variables of closed type.
isConstant :: VarSet -> VarSet -> CoreExpr -> Bool
isConstant tops locals e = case e of
  Lit l -> case l of { LitString {} -> False; LitRubbish {} -> False; _ -> True }
  Tick t e' | not (tickishIsCode t) -> isConstant tops locals e'
  _ | (Var v, args) <- collectWebArgs e
    , closed v args
    -> True
  _ -> False
  where
    closed v args
      | Just dc <- isDataConWorkId_maybe v
      , let (tys, vals) = span isTypeArg args
      = length vals == dataConRepArity dc
        && all closed_ty tys
        && all (isConstant tops locals) vals
      | null args
      = (isGlobalId v || (v `elemVarSet` tops && not (v `elemVarSet` locals)))
        && noFreeVarsOfType (idType v)
        && not (isJoinId v)
      | otherwise
      = False
    closed_ty (Type t) = noFreeVarsOfType t
    closed_ty _        = False

-- | Like collectArgs, through web applications too
collectWebArgs :: CoreExpr -> (CoreExpr, [CoreExpr])
collectWebArgs e = go e []
  where
    go (App f a)      as = go f (a:as)
    go (WebApp _ f a) as = go f (a:as)
    go f              as = (f, as)

-- | The constant result of a lambda of web w: Just c if every tail is c
-- (see Note [Web constant propagation])
constResult :: VarSet -> VarSet -> WebId -> CoreExpr -> Maybe CoreExpr
constResult tops locals0 w body
  = case go locals0 emptyVarSet body of
      Just (Just c) -> Just c
      _             -> Nothing
  where
    -- Nothing: some tail is not a constant; Just Nothing: no constant tail
    -- (so far); Just (Just c): every constant tail is c
    go :: VarSet -> VarSet -> CoreExpr -> Maybe (Maybe CoreExpr)
    go locals joins expr = case expr of
      Let (NonRec j rhs) e
        | isJoinId j -> go (locals `extendVarSetList` joinBndrs rhs) joins (joinBody rhs)
                        `both` go (extendVarSet locals j) (extendVarSet joins j) e
      Let (Rec prs) e
        | all (isJoinId . fst) prs
        -> let joins'  = extendVarSetList joins (map fst prs)
               locals' = extendVarSetList locals (map fst prs)
           in foldr (both . (\rhs -> go (locals' `extendVarSetList` joinBndrs rhs) joins'
                                         (joinBody rhs)) . snd)
                    (go locals' joins' e) prs
      Let bind e -> go (extendVarSetList locals (bindersOf bind)) joins e
      Case _ b _ alts -> foldr (both . (\(Alt _ bs rhs) -> go (extendVarSetList locals (b : bs)) joins rhs))
                               (Just Nothing) alts
      Tick t e | not (tickishIsCode t) -> go locals joins e
      _ | isConstant tops locals expr              -> Just (Just expr)
        | exprIsDeadEnd (stripWebForms expr)       -> Just Nothing
        | Just j <- jumpTo expr, j `elemVarSet` joins -> Just Nothing
        | spineWeb expr == Just w                  -> Just Nothing
        | otherwise                                -> Nothing

    both (Just Nothing) r                = r
    both r (Just Nothing)                = r
    both (Just (Just c1)) (Just (Just c2))
      | eqCoreExpr c1 c2                 = Just (Just c1)
    both _ _                             = Nothing

-- | The binders of a join point's lambdas
joinBndrs :: CoreExpr -> [Var]
joinBndrs (Lam b e)      = b : joinBndrs e
joinBndrs (WebLam _ b e) = b : joinBndrs e
joinBndrs _              = []

joinBody :: CoreExpr -> CoreExpr
joinBody (Lam _ e)      = joinBody e
joinBody (WebLam _ _ e) = joinBody e
joinBody e              = e

jumpTo :: CoreExpr -> Maybe Id
jumpTo e = case e of
  App f _      -> jumpTo f
  WebApp _ f _ -> jumpTo f
  Tick _ f     -> jumpTo f
  Var v | isJoinId v -> Just v
  _            -> Nothing

spineWeb :: CoreExpr -> Maybe WebId
spineWeb (WebApp w _ _) = Just w
spineWeb (Tick _ e)     = spineWeb e
spineWeb _              = Nothing

analyse :: VarSet -> CoreProgram -> Infos
analyse tops binds = foldr top emptyUFM (zip [0..] binds)
  where
    top (i, bind) acc = go_bind (i, isRec bind) bind acc
    isRec (Rec {}) = True
    isRec _        = False

    -- locals: the local binders in scope (a local binder may share its
    -- unique with a top-level one: Note [Constants and shadowing])
    go_bind g (NonRec b e) acc = go_rhs g emptyVarSet b e acc
    go_bind g (Rec prs)    acc = foldr (\(b, e) -> go_rhs g emptyVarSet b e) acc prs

    go_local_bind g ls (NonRec b e) acc = go_rhs g ls b e acc
    go_local_bind g ls (Rec prs)    acc = foldr (\(b, e) -> go_rhs g ls b e) acc prs

    go_rhs g ls b e acc
      | isJoinId b = go_join g ls e acc
      | otherwise  = go g ls e acc

    go_join g ls (Lam b e)      acc = go_join g (extendVarSet ls b) e acc
    go_join g ls (WebLam w p e) acc = go_lam g ls True w p e (go_join g (extendVarSet ls p) e acc)
    go_join g ls e              acc = go g ls e acc

    go_lam g ls is_join w p e acc
      = note w (noInfo { i_lams = [(p, g)]
                       , i_ress = [constResult tops (extendVarSet ls p) w e]
                       , i_join = is_join }) acc

    go :: (Int, Bool) -> VarSet -> CoreExpr -> Infos -> Infos
    go g ls expr acc = case expr of
      WebLam w p e   -> go_lam g ls False w p e (go g (extendVarSet ls p) e acc)
      Lam b e        -> go g (extendVarSet ls b) e acc
      WebApp w f a   -> note w (noInfo { i_args = [if isConstant tops ls a then Just a else Nothing] })
                             (go g ls f (go g ls a acc))
      App f a        -> go g ls f (go g ls a acc)
      Let bind body  -> let ls' = extendVarSetList ls (bindersOf bind)
                            ls_rhs = case bind of { Rec {} -> ls'; NonRec {} -> ls }
                        in go_local_bind g ls_rhs bind (go g ls' body acc)
      Case e b _ alts -> go g ls e (foldr (\(Alt _ bs rhs) -> go g (extendVarSetList ls (b : bs)) rhs) acc alts)
      Cast e _       -> go g ls e acc
      Tick _ e       -> go g ls e acc
      _              -> acc

verdict :: WebSet -> WebId -> Info -> (ArgVerdict, ResVerdict)
verdict exposed w i
  | w `elementOfUniqSet` exposed = (NoArgConst "exposed", NoResConst "exposed")
  | otherwise                    = (arg_v, res_v)
  where
    arg_v = case i_args i of
      [] -> NoArgConst "no calls"
      cs | Just (c : rest) <- sequence cs
         , all (eqCoreExpr c) rest
         -> if | not (all (\(x, _) -> isId x && not (isCoVar x) && idType x `eqType` exprType c)
                            (i_lams i))
                 -> NoArgConst "parameter type"
               | otherwise
                 -> ArgConst c
         | otherwise -> NoArgConst "not constant"

    res_v
      | i_join i = NoResConst "join point"
      | otherwise = case sequence (i_ress i) of
          Just (c : rest) | all (eqCoreExpr c) rest -> ResConst c
          _ -> NoResConst "not constant"

-- | A verdict, given whether the constant argument and the constant result
-- change the program (a parameter that never occurs, a result no case
-- scrutinises: "no change")
pprVerdict :: (Bool, Bool) -> (ArgVerdict, ResVerdict) -> SDoc
pprVerdict (use_a, use_r) (a, r) = ppr_a a <> semi <+> ppr_r r
  where
    ppr_a (ArgConst c)     = text "constant argument" <+> ppr c
                             <+> (if use_a then empty else text "(no change: parameter unused)")
    ppr_a (NoArgConst why) = text "no constant argument" <+> parens (text why)
    ppr_r (ResConst c)     = text "constant result" <+> ppr c
                             <+> (if use_r then empty else text "(no change: no scrutinised call)")
    ppr_r (NoResConst why) = text "no constant result" <+> parens (text why)

------------------------------------------------------------------
--      One round
------------------------------------------------------------------

-- | Analyse and rewrite.  Webs in 'done' were handled in an earlier round.
constPropRound :: UniqSupply -> WebSet -> WebSet -> CoreProgram
               -> (Maybe (CoreProgram, WebSet), [(WebId, SDoc, Bool, [Id])])
constPropRound _us exposed done binds
  | isNullUFM arg_webs && isNullUFM res_webs = (Nothing, dump)
  | otherwise = (Just (rewriteProgram arg_webs res_webs binds, handled), dump)
  where
    tops = mkVarSet (bindersOfBinds binds)
    infos = analyse tops binds
    verdicts = [ (w, v, i)
               | (u, i) <- sortOn (getKey . fst) (nonDetUFMToList infos)
               , let w = mkWebId u
               , not (null (i_lams i))
               , not (w `elementOfUniqSet` done)
               , let v = verdict exposed w i ]
    arg_webs = listToUFM [ (w, c) | (w, (ArgConst c, _), i) <- verdicts, used i ]
    res_webs = listToUFM [ (w, c) | (w, (_, ResConst c), _) <- verdicts, useful w ]
    handled  = mkUniqSet (nonDetKeysW arg_webs ++ nonDetKeysW res_webs)
    nonDetKeysW m = [ mkWebId u | (u, _) <- nonDetUFMToList m ]
    dump     = [ (w, pprVerdict (used i, useful w) v, changes w i v, map fst (i_lams i))
               | (w, v, i) <- verdicts ]

    changes _ i (ArgConst {}, _) | used i = True
    changes w _ (_, ResConst {})          = useful w
    changes _ _ _                         = False

    -- Substituting a constant argument changes something only if a
    -- lambda's parameter occurs (GHC's void arguments, (##), to join
    -- points and thunks are usually unused)
    used i = any ((`elemVarSet` occurring) . fst) (i_lams i)
    occurring = occurringVars binds

    -- A constant result is useful if some call of the web is scrutinised
    useful w = w `elementOfUniqSet` scrutinised
    scrutinised = scrutinisedWebs binds

-- | The variables that occur in a program (not as binders)
occurringVars :: CoreProgram -> VarSet
occurringVars binds = foldr go_bind emptyVarSet binds
  where
    go_bind b acc = foldr go acc (rhssOfBind b)
    go expr acc = case expr of
      Var v         -> extendVarSet acc v
      WebLam _ _ e  -> go e acc
      Lam _ e       -> go e acc
      WebApp _ f a  -> go f (go a acc)
      App f a       -> go f (go a acc)
      Let bind body -> go_bind bind (go body acc)
      Case e _ _ as -> go e (foldr (\(Alt _ _ rhs) -> go rhs) acc as)
      Cast e _      -> go e acc
      Tick _ e      -> go e acc
      _             -> acc

-- | The webs of calls that are scrutinised by a case
scrutinisedWebs :: CoreProgram -> WebSet
scrutinisedWebs binds = foldr go_bind emptyUniqSet binds
  where
    go_bind b acc = foldr go acc (rhssOfBind b)
    go expr acc = case expr of
      Case scrut _ _ alts
        | Just w <- spineWeb scrut -> addOneToUniqSet (go scrut (go_alts alts acc)) w
        | otherwise                -> go scrut (go_alts alts acc)
      WebLam _ _ e  -> go e acc
      Lam _ e       -> go e acc
      WebApp _ f a  -> go f (go a acc)
      App f a       -> go f (go a acc)
      Let bind body -> go_bind bind (go body acc)
      Cast e _      -> go e acc
      Tick _ e      -> go e acc
      _             -> acc
    go_alts alts acc = foldr (\(Alt _ _ rhs) -> go rhs) acc alts

------------------------------------------------------------------
--      The rewrite
------------------------------------------------------------------

rewriteProgram :: UniqFM WebId CoreExpr -> UniqFM WebId CoreExpr -> CoreProgram -> CoreProgram
rewriteProgram arg_webs res_webs = map rw_bind
  where
    rw_bind (NonRec b e) = NonRec b (rw emptyVarEnv e)
    rw_bind (Rec prs)    = Rec [ (b, rw emptyVarEnv e) | (b, e) <- prs ]

    -- The environment maps parameters to their constants
    rw :: IdEnv CoreExpr -> CoreExpr -> CoreExpr
    rw env expr = case expr of
      Var v | Just c <- lookupVarEnv env v -> c
            | otherwise                    -> expr
      Lit {} -> expr
      WebLam w x e
        | Just c <- lookupUFM arg_webs w -> WebLam w x (rw (extendVarEnv (under env [x]) x c) e)
        | otherwise                      -> WebLam w x (rw (under env [x]) e)
      Lam b e        -> Lam b (rw (under env [b]) e)
      WebApp w f a   -> WebApp w (rw env f) (rw env a)
      App f a        -> App (rw env f) (rw env a)
      Let bind body  -> let env' = under env (bindersOf bind)
                        in Let (rw_bind_env (case bind of { Rec {} -> env'; NonRec {} -> env }) bind)
                               (rw env' body)
      Case scrut b ty alts
        | Just w <- spineWeb scrut
        , Just c <- lookupUFM res_webs w
        , Just rhs <- matching c alts
        -> Case (rw env scrut) b ty [Alt DEFAULT [] (rw (under env (b : alt_bndrs alts)) rhs)]
        | otherwise
        -> Case (rw env scrut) b ty [ Alt con bs (rw (under env (b : bs)) rhs) | Alt con bs rhs <- alts ]
      Cast e co      -> Cast (rw env e) co
      Tick t e       -> Tick (rw_tick env t) (rw env e)
      Type {}        -> expr
      Coercion {}    -> expr

    -- Under binders bs: a parameter they shadow is not substituted, nor is a
    -- constant that mentions a variable they shadow (Note [Constants and
    -- shadowing]); its parameter just stays used
    under env bs
      | isEmptyVarEnv env = env
      | otherwise = filterVarEnv (\c -> not (any (`elemVarSet` exprFreeVars c) bs))
                                 (delVarEnvList env bs)
    alt_bndrs alts = concat [ bs | Alt _ bs _ <- alts ]

    rw_bind_env env (NonRec b e) = NonRec b (rw env e)
    rw_bind_env env (Rec prs)    = Rec [ (b, rw env e) | (b, e) <- prs ]

    -- A breakpoint may not mention a parameter that is now a constant
    rw_tick env t@(Breakpoint { breakpointFVs = ids })
      = t { breakpointFVs = filter (\v -> not (isJust (lookupVarEnv env v))) ids }
    rw_tick _ t = t

    -- The alternative that matches the constant result: its right-hand
    -- side, with its binders bound to the constant's fields
    matching c alts = case stripTicksTopE (const True) c of
      Lit l | Just (Alt _ _ rhs) <- findAlt (LitAlt l) alts -> Just rhs
      e | (Var v, args) <- collectWebArgs e
        , Just dc <- isDataConWorkId_maybe v
        , Just (Alt con bs rhs) <- findAlt (DataAlt dc) alts
        -> case con of
             DataAlt _ | let vals = dropWhile isTypeArg args
                       , length vals == length bs
                       -> Just (mkLets (zipWith NonRec bs vals) rhs)
             DEFAULT   -> Just rhs
             _         -> Nothing
      _ -> Nothing
