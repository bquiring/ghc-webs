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
isConstant :: VarSet -> CoreExpr -> Bool
isConstant tops e = case e of
  Lit l -> case l of { LitString {} -> False; LitRubbish {} -> False; _ -> True }
  Tick t e' | not (tickishIsCode t) -> isConstant tops e'
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
        && all (isConstant tops) vals
      | null args
      = (isGlobalId v || v `elemVarSet` tops) && noFreeVarsOfType (idType v)
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
constResult :: VarSet -> WebId -> CoreExpr -> Maybe CoreExpr
constResult tops w body
  = case go emptyVarSet body of
      Just (Just c) -> Just c
      _             -> Nothing
  where
    -- Nothing: some tail is not a constant; Just Nothing: no constant tail
    -- (so far); Just (Just c): every constant tail is c
    go :: VarSet -> CoreExpr -> Maybe (Maybe CoreExpr)
    go joins expr = case expr of
      Let (NonRec j rhs) e
        | isJoinId j -> go joins (joinBody rhs) `both` go (extendVarSet joins j) e
      Let (Rec prs) e
        | all (isJoinId . fst) prs
        -> let joins' = extendVarSetList joins (map fst prs)
           in foldr (both . go joins' . joinBody . snd) (go joins' e) prs
      Let _ e -> go joins e
      Case _ _ _ alts -> foldr (both . (\(Alt _ _ rhs) -> go joins rhs)) (Just Nothing) alts
      Tick t e | not (tickishIsCode t) -> go joins e
      _ | isConstant tops expr                     -> Just (Just expr)
        | exprIsDeadEnd (stripWebForms expr)       -> Just Nothing
        | Just j <- jumpTo expr, j `elemVarSet` joins -> Just Nothing
        | spineWeb expr == Just w                  -> Just Nothing
        | otherwise                                -> Nothing

    both (Just Nothing) r                = r
    both r (Just Nothing)                = r
    both (Just (Just c1)) (Just (Just c2))
      | eqCoreExpr c1 c2                 = Just (Just c1)
    both _ _                             = Nothing

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

    go_bind g (NonRec b e) acc = go_rhs g b e acc
    go_bind g (Rec prs)    acc = foldr (\(b, e) -> go_rhs g b e) acc prs

    go_rhs g b e acc
      | isJoinId b = go_join g e acc
      | otherwise  = go g e acc

    go_join g (Lam _ e)      acc = go_join g e acc
    go_join g (WebLam w p e) acc = go_lam g True w p e (go_join g e acc)
    go_join g e              acc = go g e acc

    go_lam g is_join w p e acc
      = note w (noInfo { i_lams = [(p, g)]
                       , i_ress = [constResult tops w e]
                       , i_join = is_join }) acc

    go :: (Int, Bool) -> CoreExpr -> Infos -> Infos
    go g expr acc = case expr of
      WebLam w p e   -> go_lam g False w p e (go g e acc)
      Lam _ e        -> go g e acc
      WebApp w f a   -> note w (noInfo { i_args = [if isConstant tops a then Just a else Nothing] })
                             (go g f (go g a acc))
      App f a        -> go g f (go g a acc)
      Let bind body  -> go_bind g bind (go g body acc)
      Case e _ _ alts -> go g e (foldr (\(Alt _ _ rhs) -> go g rhs) acc alts)
      Cast e _       -> go g e acc
      Tick _ e       -> go g e acc
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

pprVerdict :: (ArgVerdict, ResVerdict) -> SDoc
pprVerdict (a, r) = ppr_a a <> semi <+> ppr_r r
  where
    ppr_a (ArgConst c)     = text "constant argument" <+> ppr c
    ppr_a (NoArgConst why) = text "no constant argument" <+> parens (text why)
    ppr_r (ResConst c)     = text "constant result" <+> ppr c
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
    arg_webs = listToUFM [ (w, c) | (w, (ArgConst c, _), _) <- verdicts ]
    res_webs = listToUFM [ (w, c) | (w, (_, ResConst c), _) <- verdicts, useful w ]
    handled  = mkUniqSet ([ w | (w, (ArgConst _, _), _) <- verdicts ] ++ nonDetKeysW res_webs)
    nonDetKeysW m = [ mkWebId u | (u, _) <- nonDetUFMToList m ]
    dump     = [ (w, pprVerdict v, changes w v, map fst (i_lams i)) | (w, v, i) <- verdicts ]

    changes _ (ArgConst {}, _) = True
    changes w (_, ResConst {}) = useful w
    changes _ _                = False

    -- A constant result is useful if some call of the web is scrutinised
    useful w = w `elementOfUniqSet` scrutinised
    scrutinised = scrutinisedWebs binds

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
        | Just c <- lookupUFM arg_webs w -> WebLam w x (rw (extendVarEnv env x c) e)
        | otherwise                      -> WebLam w x (rw env e)
      Lam b e        -> Lam b (rw env e)
      WebApp w f a   -> WebApp w (rw env f) (rw env a)
      App f a        -> App (rw env f) (rw env a)
      Let bind body  -> Let (rw_bind_env env bind) (rw env body)
      Case scrut b ty alts
        | Just w <- spineWeb scrut
        , Just c <- lookupUFM res_webs w
        , Just rhs <- matching c alts
        -> Case (rw env scrut) b ty [Alt DEFAULT [] (rw env rhs)]
        | otherwise
        -> Case (rw env scrut) b ty [ Alt con bs (rw env rhs) | Alt con bs rhs <- alts ]
      Cast e co      -> Cast (rw env e) co
      Tick t e       -> Tick (rw_tick env t) (rw env e)
      Type {}        -> expr
      Coercion {}    -> expr

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
