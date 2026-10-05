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

import GHC.Types.Demand ( isStrUsedDmd )
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
   application spine.  Calls of known functions and jumps are left alone:
   CorePrep already passes their strict arguments by value (using the
   function's demand signature), so the pass is for unknown calls.

2. Strict result fields.  If the result of a web is a product, and every
   call of the web is scrutinised by a case on that constructor whose
   alternative is strict in field i, then each lambda of the web evaluates
   field i in the constructor applications it returns (in tail position):
       K e1 e2   ==>   case e1 of v1 { __DEFAULT -> K v1 e2 }
   A call anywhere else (a lazy let, an argument, a tail call, a case with a
   DEFAULT alternative) is an unknown context, and makes no field strict.

Both only change the order of evaluation within an expression whose value is
demanded anyway, which imprecise exceptions allow.  Strictness comes from
demand analysis (the late run) or is syntactic (isStrictIn: the early run).
Nothing changes type.  A web is transformed once (it is then in 'done').
-}

-- | Is p evaluated first in this body (after any further lambdas)?  Demand
-- analysis says so, or the body is a case on p (under ticks, lets, casts).
isStrictIn :: Id -> CoreExpr -> Bool
isStrictIn p body = isStrUsedDmd (idDemandInfo p) || go (peel body)
  where
    peel (Lam _ e)      = peel e
    peel (WebLam _ _ e) = peel e
    peel e              = e
    go (Case (Var v) _ _ _) = v == p
    go (Case scrut _ _ _)   = go scrut
    go (Tick _ e)           = go e
    go (Let _ e)            = go e
    go (Cast e _)           = go e
    go _                    = False

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

data Info = Info
  { i_lams      :: [Id]
  , i_lazy      :: Bool         -- Some lambda is lazy in its parameter
  , i_depth     :: Int          -- Largest saturation depth
  , i_covar     :: Bool
  , i_calls     :: [Maybe (DataCon, [Bool])]
      -- One per call of the web whose result is the web's result:
      -- Just (K, strict fields) for a case on K, Nothing for anything else
  }

noInfo :: Info
noInfo = Info [] False 0 False []

plusInfo :: Info -> Info -> Info
plusInfo a b = Info { i_lams  = i_lams a ++ i_lams b
                    , i_lazy  = i_lazy a || i_lazy b
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
    go_bind (NonRec _ e) acc = go e acc
    go_bind (Rec prs)    acc = foldr (go . snd) acc prs

    go :: CoreExpr -> Infos -> Infos
    go expr acc = case expr of
      WebLam w x e
        -> go e $ note w (noInfo { i_lams  = [x]
                                 , i_lazy  = not (isStrictIn x e)
                                 , i_depth = 1 + valueLams e
                                 , i_covar = isCoVar x }) acc
      Lam _ e -> go e acc
      App {}    -> go_spine Nothing expr acc
      WebApp {} -> go_spine Nothing expr acc
      Let bind body -> go_bind bind (go body acc)
      Case scrut _ _ alts
        | [Alt (DataAlt dc) ys rhs] <- alts
        , isSpine scrut
        -> go_spine (Just (dc, [ isId y && isStrictIn y rhs | y <- ys ])) scrut $
           go rhs acc
        | otherwise
        -> go scrut $ foldr (\(Alt _ _ rhs) -> go rhs) acc alts
      Cast e _ -> go e acc
      Tick _ e -> go e acc
      _        -> acc

    isSpine (WebApp {}) = True
    isSpine (Tick _ e)  = isSpine e
    isSpine _           = False

    -- An application spine; the context of its result is 'ctxt'
    go_spine ctxt expr acc = case peelTicks expr of
      WebApp w f a -> note w (noInfo { i_calls = [ctxt] }) (go_fun f (go a acc))
      e            -> go_fun e acc

    -- The function part of a spine: further applications are not the
    -- spine's result
    go_fun e acc = case e of
      WebApp _ f a -> go_fun f (go a acc)
      App f a      -> go_fun f (go a acc)
      Tick _ e'    -> go_fun e' acc
      _            -> go e acc

    peelTicks (Tick _ e) = peelTicks e
    peelTicks e          = e

------------------------------------------------------------------
--      Verdicts
------------------------------------------------------------------

data ArgVerdict = StrictArg Int | NotStrictArg String
data ResVerdict = StrictFields DataCon [Int] | NoStrictFields String

-- | The verdicts for one web
verdict :: WebSet -> WebId -> Info -> (ArgVerdict, ResVerdict)
verdict exposed w i
  | w `elementOfUniqSet` exposed = (NotStrictArg "exposed", NoStrictFields "exposed")
  | otherwise = (arg_v, res_v)
  where
    arg_v | null (i_lams i) = NotStrictArg "no lambdas"
          | i_covar i       = NotStrictArg "coercion parameter"
          | i_lazy i        = NotStrictArg "lazy"
          | otherwise       = StrictArg (i_depth i)

    res_v = case i_calls i of
      [] -> NoStrictFields "no calls"
      calls
        | Just cs <- sequence calls
        , (dc, s0) : rest <- cs
        , all ((== dc) . fst) rest
        , let strict = foldr (zipWith (&&) . snd) s0 rest
              fields = [ n | (n, True) <- zip [0..] strict ]
        -> if null fields || null (i_lams i)
           then NoStrictFields (if null (i_lams i) then "no lambdas" else "no strict field")
           else StrictFields dc fields
        | otherwise -> NoStrictFields "unknown call context"

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
    verdicts = [ (w, verdict exposed w i, i)
               | (u, i) <- sortOn (getKey . fst) (nonDetUFMToList infos)
               , let w = mkWebId u
               , not (w `elementOfUniqSet` done) ]
    arg_webs = listToUFM [ (w, k) | (w, (StrictArg k, _), _) <- verdicts ]
    res_webs = listToUFM [ (w, (dc, fs)) | (w, (_, StrictFields dc fs), _) <- verdicts ]
    handled  = mkUniqSet [ w | (w, v, _) <- verdicts, changes v ]
    dump     = [ (w, pprVerdict v, changes v, i_lams i)
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

    -- An application spine: evaluate the strict arguments first.  Calls of
    -- known functions (and jumps) are left alone: CorePrep already passes
    -- their strict arguments by value, using the function's demand signature
    rw_app expr
      | known_head expr = rw_args expr
      | otherwise       = do { (wrap, e') <- go expr 0; return (wrap e') }
      where
        -- n = the number of value arguments applied after this node
        go (WebApp w f a) n
          = do { a' <- rw a
               ; (wrap_a, a'') <- case lookupUFM arg_webs w of
                   Just k | n + 1 >= k -> eval a'
                   _                   -> return (id, a')
               ; (wrap_f, f') <- go f (n + 1)
               ; return (wrap_f . wrap_a, WebApp w f' a'') }
        go (App f a) n
          = do { a' <- rw a
               ; (wrap_f, f') <- go f (if isTypeArg a then n else n + 1)
               ; return (wrap_f, App f' a') }
        go (Tick t e) n
          = do { (wrap, e') <- go e n; return (wrap, Tick t e') }
        go e _
          = do { e' <- rw e; return (id, e') }

    known_head e = case collect_head e of
      Var v -> isJoinId v || idArity v > 0
      _     -> False
    collect_head (App f _)      = collect_head f
    collect_head (WebApp _ f _) = collect_head f
    collect_head (Tick _ f)     = collect_head f
    collect_head f              = f

    -- Rewrite inside the arguments (and head) of a spine only
    rw_args (App f a)      = App <$> rw_args f <*> rw a
    rw_args (WebApp w f a) = WebApp w <$> rw_args f <*> rw a
    rw_args (Tick t e)     = Tick t <$> rw_args e
    rw_args e              = rw e

    -- Evaluate an argument (if lifted and not already a value)
    eval :: CoreExpr -> UniqSM (CoreExpr -> CoreExpr, CoreExpr)
    eval a
      | definitelyLiftedType ty
      , not (exprIsHNF (stripWebForms a))
      = do { v <- mkWild ty
           ; return (\body -> Case a v (exprType body) [Alt DEFAULT [] body], Var v) }
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
