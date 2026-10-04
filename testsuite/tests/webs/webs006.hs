-- Cross-module check: f's exposed vanilla unfolding calls the local g.  Tidy
-- builds that unfolding from the transformed right-hand side, so the
-- importing module (which inlines f and calls g directly) and the library
-- agree on g's (possibly transformed) calling convention.  Both modules are
-- compiled with all the web transformations.
module Main (main) where

import Webs006A

main :: IO ()
main = print (f 2, f 5)
