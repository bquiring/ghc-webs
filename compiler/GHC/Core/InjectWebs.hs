{-# OPTIONS_GHC -Wno-incomplete-patterns #-}


module GHC.Core.InjectWebs (
) where

import GHC.Prelude

import Data.List
import Data.Data
import Data.Map
import Data.Foldable

import GHC.Core 
import GHC.Core.TyCo.Rep
import GHC.Core.Web
import GHC.Core.Lint
import GHC.Unit.Module.ModGuts
import GHC (LHsRecUpdFields(xOLRecUpdFields), Type)
import GHC.Core.Opt.Simplify.Utils (argInfoExpr)
import GHC.Types.Var
import GHC.Builtin.Names.TH (litEIdKey, codeTyConKey)
import GHC.Data.UnionFind

newtype Counter a = Counter { runCounter :: Int -> (a, Int) }
    deriving (Functor)
instance Applicative Counter where
  pure x = Counter (\s -> (x, s))
  (Counter f) <*> (Counter g) = Counter (\s -> let (h, s') = f s in
                                                 let (x, s'') = g s' in
                                                     (h x, s''))

instance Monad Counter where
  return = pure -- return is just an alias for pure
  (Counter g) >>= f = Counter (\s -> let (x, s') = g s in
                                       runCounter (f x) s')
next :: Counter Int
next = (Counter { runCounter = \n -> (n, n+1)})

type Env = Map Var Var

freshType :: Type -> Counter Type
freshType (TyVarTy x) = do
    return (TyVarTy x)
freshType (AppTy ty1 ty2) = do
    ty1 <- freshType ty1
    ty2 <- freshType ty2
    return (AppTy ty1 ty2)
freshType (TyConApp tycon tys) = do
    tys <- mapM freshType tys
    return (TyConApp tycon tys)
freshType (ForAllTy bndr ty) = do
    ty <- freshType ty
    return (ForAllTy bndr ty)
freshType (FunTy { ft_af, ft_mult, ft_arg, ft_res }) = do
    w <- next
    ft_arg <- freshType ft_arg
    ft_res <- freshType ft_res
    return (FunWTy {ft_web=W w, ft_af, ft_mult, ft_arg, ft_res})
freshType lit@(LitTy _) = 
    return lit
freshType (CastTy ty co) = do
    ty <- freshType ty
    co <- freshCoercion co 
    return (CastTy ty co)
freshType (CoercionTy co) = do
    co <- freshCoercion co 
    return (CoercionTy co)

freshVar :: Var -> Counter Var
freshVar id = do
    let ty = varType id
    ty <- freshType ty
    let x = setVarType id ty
    return x
{- FIXME: will need environment for data cons as well, or need to disallow modifying functions in data cons for now -}
freshExp :: Env -> CoreExpr -> Counter CoreExpr
freshExp env (Var x) =
    case Data.Map.lookup x env of 
        Nothing -> return (Var x)
        Just x -> return (Var x)
freshExp env (Lit l) = 
    return (Lit l)
freshExp env (App f arg) = do
    w <- next
    f <- freshExp env f
    arg <- freshExp env arg
    return (AppW (W w) f arg)
    
freshExp env (Lam x e) = do
    w <- next
    x' <- freshVar x
    let env = Data.Map.insert x x' env
    f <- freshExp env e
    return (LamW (W w) x e)

freshExp env (Let b e) = do
    (b, env) <- freshBind env b
    e <- freshExp env e
    return (Let b e)

freshExp env (Case e x ty alts) = do
    e <- freshExp env e
    x <- freshVar x
    ty <- freshType ty
    alts <- mapM (freshAlt env) alts
    return (Case e x ty alts)
    where 
        freshAlt env (Alt altcon xs e) = do
            xs' <- mapM freshVar xs
            let env = Data.List.foldl (\ env (x, y) -> Data.Map.insert x y env) env (zip xs xs')
            e <- freshExp env e 
            return (Alt altcon xs' e)
            
freshExp env (Cast e co) = do
    e <- freshExp env e
    co <- freshCoercion co
    return (Cast e co)

freshExp env (Tick tickish e) = do
    e <- freshExp env e
    return (Tick tickish e)
freshExp env (Type ty) = do
    ty <- freshType ty
    return (Type ty)
    
freshExp env (Coercion co) = do
    co <- freshCoercion co
    return (Coercion co)
   
{- FIXME: ignoring coercions for now -}
freshCoercion :: Coercion -> Counter Coercion
freshCoercion co = return co

freshBind env (NonRec x e) = do
    x' <- freshVar x 
    e <- freshExp env e
    return (NonRec x' e, Data.Map.insert x x' env)
    
freshBind env (Rec binds) = do
    let xs = Data.List.map fst binds 
    let es = Data.List.map snd binds 
    xs' <- mapM freshVar xs 
    let env = Data.List.foldl (\ env (x, y) -> Data.Map.insert x y env) env (zip xs xs') 
    es <- mapM (freshExp env) es
    return (Rec (zip xs' es), env)

freshBinds :: Env -> [CoreBind] -> Counter ([CoreBind], Env)
freshBinds env binds = do
    (binds, env) <- Data.Foldable.foldlM (\ (binds, env) bind -> do
        (bind', env') <- freshBind env bind
        return (bind' : binds, env')) 
        ([], env) binds
    return (Data.List.reverse binds, env)




newtype RenameWeb a = RenameWeb { runRename :: (Web -> Web) -> a }
    deriving (Functor, Applicative, Monad)

renameWeb :: Web -> RenameWeb Web
renameWeb web = (RenameWeb { runRename = \rename -> rename web})

renameType :: Type -> RenameWeb Type
renameType (TyVarTy x) = do
    return (TyVarTy x)
renameType (AppTy ty1 ty2) = do
    ty1 <- renameType ty1
    ty2 <- renameType ty2
    return (AppTy ty1 ty2)
renameType (TyConApp tycon tys) = do
    tys <- mapM renameType tys
    return (TyConApp tycon tys)
renameType (ForAllTy bndr ty) = do
    ty <- renameType ty
    return (ForAllTy bndr ty)
renameType (FunWTy { ft_web, ft_af, ft_mult, ft_arg, ft_res }) = do
    ft_web <- renameWeb ft_web
    ft_arg <- renameType ft_arg
    ft_res <- renameType ft_res
    return (FunWTy {ft_web=ft_web, ft_af, ft_mult, ft_arg, ft_res})
renameType lit@(LitTy _) = 
    return lit
renameType (CastTy ty co) = do
    ty <- renameType ty
    co <- renameCoercion co 
    return (CastTy ty co)
renameType (CoercionTy co) = do
    co <- renameCoercion co 
    return (CoercionTy co)

renameVar :: Var -> RenameWeb Var
renameVar id = do
    let ty = varType id
    ty <- renameType ty
    let x = setVarType id ty
    return x
{- FIXME: will need environment for data cons as well, or need to disallow modifying functions in data cons for now -}
renameExp :: Env -> CoreExpr -> RenameWeb CoreExpr
renameExp env (Var x) = 
    case Data.Map.lookup x env of 
        Nothing -> return (Var x)
        Just x -> return (Var x)
renameExp env (Lit l) = 
    return (Lit l)
renameExp env (AppW web f arg) = do
    web <- renameWeb web
    f <- renameExp env f
    arg <- renameExp env arg
    return (AppW web f arg)
    
renameExp env (LamW web x e) = do
    web <- renameWeb web
    x' <- renameVar x
    let env' = Data.Map.insert x x' env
    f <- renameExp env' e
    return (LamW web x e)

renameExp env (Let b e) = do
    (b, env) <- renameBind env b
    e <- renameExp env e
    return (Let b e)
            
renameExp env (Case e x ty alts) = do
    e <- renameExp env e
    x <- renameVar x
    ty <- renameType ty
    alts <- mapM (renameAlt env) alts
    return (Case e x ty alts)
    where 
        renameAlt env (Alt altcon xs e) = 
            do { xs' <- mapM renameVar xs
               ; let env' = Data.List.foldl (\ env (x, y) -> Data.Map.insert x y env) env (zip xs xs')
               ; e <- renameExp env' e 
               ; return (Alt altcon xs' e)
               }
renameExp env (Cast e co) = do
    e <- renameExp env e
    co <- renameCoercion co
    return (Cast e co)

renameExp env (Tick tickish e) = do
    e <- renameExp env e
    return (Tick tickish e)
renameExp env (Type ty) = do
    ty <- renameType ty
    return (Type ty)
    
renameExp env (Coercion co) = do
    co <- renameCoercion co
    return (Coercion co)
   
renameBind :: Env -> CoreBind -> RenameWeb (CoreBind, Map Var Var)
renameBind env (NonRec x e) = do
    x' <- renameVar x 
    e <- renameExp env e
    return (NonRec x' e, Data.Map.insert x x' env)
    
renameBind env (Rec binds) = do
    let xs = Data.List.map fst binds 
    let es = Data.List.map snd binds 
    xs' <- mapM renameVar xs 
    let env' = Data.List.foldl (\ env (x, y) -> Data.Map.insert x y env) env (zip xs xs') 
    es <- mapM (renameExp env') es
    return (Rec (zip xs' es), env')

renameBinds :: Env -> [CoreBind] -> RenameWeb ([CoreBind], Env)
renameBinds env binds = do
    (binds, env) <- Data.Foldable.foldlM (\ (binds, env) bind -> do
        (bind', env') <- renameBind env bind
        return (bind' : binds, env')) 
        ([], env) binds
    return (Data.List.reverse binds, env)

{- FIXME: ignoring coercions for now -}
renameCoercion :: Coercion -> RenameWeb Coercion
renameCoercion co = return co


{- should be a ModGuts -}
injectWebs :: ModGuts -> ModGuts
injectWebs modGuts =
    let binds = mg_binds modGuts in
    let ((binds', _), _) = runCounter (freshBinds Data.Map.empty binds) 0 in
        {-
        import GHC.Data.UnionFind
    let webCons = lintCoreBindingsForWebs _ binds' in
    let representativeWeb :: Data.Map.Map Web Web = {- union find -} _ webCons in
    let renameWeb = \web -> case Data.Map.lookup web representativeWeb of
                                Just web -> web
                                Nothing -> web in
    let (binds'', _) = runRename (renameBinds Data.Map.empty binds') renameWeb in
    -}
    let binds'' = binds' in
    modGuts {mg_binds = binds''}
    

{- should be a ModGuts -}
-- eraseWebs :: CoreExpr -> CoreExpr

eraseType :: Type -> Type
eraseType (TyVarTy x) = TyVarTy x
eraseType (AppTy ty1 ty2) =
    let ty1' = eraseType ty1 in
    let ty2' = eraseType ty2 in
    (AppTy ty1' ty2')
eraseType (TyConApp tycon tys) =
    let tys' = Data.List.map eraseType tys in
    (TyConApp tycon tys')
eraseType (ForAllTy bndr ty) =
    let ty' = eraseType ty in
    (ForAllTy bndr ty')
eraseType (FunWTy { ft_web=_, ft_af, ft_mult, ft_arg, ft_res }) =
    let ft_arg' = eraseType ft_arg in
    let ft_res' = eraseType ft_res in
    (FunTy {ft_af, ft_mult, ft_arg=ft_arg', ft_res=ft_res'})
eraseType lit@(LitTy _) = lit
eraseType (CastTy ty co) =
    let ty' = eraseType ty in
    let co' = eraseCoercion co in
    (CastTy ty' co')
eraseType (CoercionTy co) =
    let co' = eraseCoercion co in
    (CoercionTy co')

eraseVar :: Var -> Var
eraseVar id =
    let ty = varType id in
    let ty' = eraseType ty in
    let x = setVarType id ty in
    x
{- FIXME: will need environment for data cons as well, or need to disallow modifying functions in data cons for now -}
eraseExp :: Env -> CoreExpr -> CoreExpr
eraseExp env (Var x) = 
    case Data.Map.lookup x env of 
        Nothing -> Var x 
        Just x -> Var x
eraseExp env (Lit l) = Lit l
eraseExp env (AppW web f arg) =
    let f' = eraseExp env f in
    let arg' = eraseExp env arg in
    (App f' arg')
    
eraseExp env (Lam x e) =
    let x' = eraseVar x in
    let env' = Data.Map.insert x x' env in
    let e' = eraseExp env' e in
    (Lam x' e')

eraseExp env (Let b e) =
    let (b', env') = eraseBind b in
    let e' = eraseExp env' e in
    (Let b' e')
    where
        eraseBind (NonRec x e) =
            let x' = eraseVar x in
            let e' = eraseExp env e in
            (NonRec x' e', Data.Map.insert x x' env)
            
        eraseBind (Rec binds) =
            let xs = Data.List.map fst binds in
            let es = Data.List.map snd binds in
            let xs' = Data.List.map eraseVar xs in
            let env' = Data.List.foldl (\ env (x, y) -> Data.Map.insert x y env) env (zip xs xs') in
            let es' = Data.List.map (eraseExp env') es in
            (Rec (zip xs' es'), env')
eraseExp env (Case e x ty alts) =
    let e' = eraseExp env e in
    let x' = eraseVar x in
    let ty' = eraseType ty in
    let alts' = Data.List.map (eraseAlt env) alts in
    (Case e' x' ty' alts')
    where 
        eraseAlt env (Alt altcon xs e) = 
            let xs' = Data.List.map eraseVar xs in
            let env' = Data.List.foldl (\ env (x, y) -> Data.Map.insert x y env) env (zip xs xs') in
            let e' = eraseExp env' e in
            (Alt altcon xs' e')

eraseExp env (Cast e co) =
    let e' = eraseExp env e in
    let co' = eraseCoercion co in
    (Cast e' co')

eraseExp env (Tick tickish e) =
    let e' = eraseExp env e in
    (Tick tickish e')
eraseExp env (Type ty) =
    let ty' = eraseType ty in
    (Type ty')
    
eraseExp env (Coercion co) =
    let co' = eraseCoercion co in
    (Coercion co')
   
{- FIXME: ignoring coercions for now -}
eraseCoercion :: Coercion -> Coercion
eraseCoercion co = co
