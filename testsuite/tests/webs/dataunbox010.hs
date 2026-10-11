-- See Dataunbox010A (JuicyPixels' Codec.Picture.Metadata): a match on Refl
-- binds a coercion variable that a cast uses, so the field it came from is
-- live and is not dropped (Note [Dead fields] in GHC.WebCore.DataFlatten).
module Main (main) where

import qualified Dataunbox010A as M

main :: IO ()
main = do
  let m = M.insert M.Title "juicy" (M.simpleMetadata M.SourcePng (640 :: Int) 480 (72 :: Int) 96)
      m2 = M.insert (M.Exif M.TagA) (M.ExifLong 7) (M.delete M.DpiY m)
  print (M.lookup M.Width m, M.lookup M.DpiY m, M.lookup M.Title m, M.lookup M.Gamma m)
  print (M.lookup M.DpiY m2, M.lookup (M.Exif M.TagA) m2, M.lookup (M.Exif M.TagB) m2)
  print (M.extractExifMetas m2)
  print m2
