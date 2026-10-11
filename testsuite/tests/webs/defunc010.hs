{-# LANGUAGE RankNTypes #-}
-- Defunctionalised lambdas that take class dictionaries (after hpke's
-- Crypto.HPKE.AEAD, whose mkSealA takes a function polymorphic in its
-- ByteArray types): the apply function's parameters for the dictionaries
-- are constraints, and their arrows must be too (mkFunctionType, not
-- mkVisFunTyMany: ASSERT failed in mkWebFunTy).
module Main (main) where

type Enc = forall s t. (Monoid s, Show t) => (Int -> s) -> t -> Int -> s

encA, encB, encC :: Enc
encA f t k = f (k + 1) <> f (length (show t))
{-# NOINLINE encA #-}
encB f _ k = f k <> f k
{-# NOINLINE encB #-}
encC f t k = mconcat (map f [k, k - 1 .. 0]) <> f (length (show t))
{-# NOINLINE encC #-}

mkSeal :: Enc -> Int -> (String, [Int])
mkSeal enc k = (enc show 'x' k, enc (\i -> [i * i]) True k)
{-# NOINLINE mkSeal #-}

main :: IO ()
main = do
  print (map (mkSeal encA) [1 .. 3])
  print (map (mkSeal encB) [1 .. 3])
  print (map (mkSeal encC) [1 .. 3])
