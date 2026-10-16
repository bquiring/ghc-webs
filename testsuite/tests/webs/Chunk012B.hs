{-# LANGUAGE DerivingVia, RankNTypes, BangPatterns, StandaloneKindSignatures #-}
module Chunk012B (ZonkT(..), ZonkBndrT(..), runBoth, noBinders, don'tBind) where

import Chunk012A
import GHC.Exts ( oneShot )
import Control.Monad.Fix
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Data.Kind ( Type )

type ZonkT :: (Type -> Type) -> Type -> Type
newtype ZonkT m a = ZonkT { runZonkT :: Int -> m a }

instance Functor m => Functor (ZonkT m) where
  fmap f (ZonkT g) = ZonkT $ \ !env -> fmap f (g env)
  {-# INLINE fmap #-}

instance Applicative m => Applicative (ZonkT m) where
  pure a = ZonkT (\ !_ -> pure a)
  ZonkT f <*> ZonkT x = ZonkT (\ !env -> f env <*> x env)
  ZonkT m *> f = ZonkT (\ !env -> m env *> runZonkT f env)
  {-# INLINE pure #-}
  {-# INLINE (<*>) #-}
  {-# INLINE (*>) #-}

instance Monad m => Monad (ZonkT m) where
  ZonkT m >>= f = ZonkT (\ !env -> do { r <- m env; runZonkT (f r) env })
  (>>)   = (*>)
  {-# INLINE (>>=) #-}
  {-# INLINE (>>) #-}

instance MonadIO m => MonadIO (ZonkT m) where
  liftIO f = ZonkT (\ !_ -> liftIO f)
  {-# INLINE liftIO #-}

instance MonadTrans ZonkT where
  lift ma = ZonkT $ \ !_ -> ma
  {-# INLINE lift #-}

instance MonadFix m => MonadFix (ZonkT m) where
  mfix f = ZonkT $ \ !r -> mfix $ oneShot $ \ a -> runZonkT (f a) r
  {-# INLINE mfix #-}

newtype ZonkBndrT m a = ZonkBndrT { runZonkBndrT' :: forall r. (a -> ZonkT m r) -> ZonkT m r }
  deriving (Functor, Applicative, Monad, MonadIO, MonadFix)
    via Codensity (ZonkT m)

runBoth :: ZonkBndrT IO Int -> IO Int
runBoth (ZonkBndrT k) = runZonkT (k (\x -> pure (x + 1))) 3

noBinders :: Monad m => ZonkT m a -> ZonkBndrT m a
noBinders z = ZonkBndrT (runCodensity (toCodensity z))

don'tBind :: Monad m => ZonkBndrT m a -> ZonkT m a
don'tBind (ZonkBndrT k) = fromCodensity (Codensity k)
