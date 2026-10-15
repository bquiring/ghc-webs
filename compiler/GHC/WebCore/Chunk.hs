{-# LANGUAGE LambdaCase #-}

-- | Compiling a program's modules together as one Core program
-- (-fcore-webs-chunk); see Note [Chunks]
module GHC.WebCore.Chunk
  ( chunkMake
  ) where

import GHC.Prelude

import GHC ( Target, setTargets, load, LoadHowMuch(..), getModSummary, setSessionDynFlags )
import GHC.Driver.DynFlags
import GHC.Driver.Env
import GHC.Driver.Main ( hscSimplify, hscTidy, hscGenHardCode )
import GHC.Driver.Monad
import GHC.Driver.Phases ( StopPhase(..) )
import GHC.Driver.Pipeline ( compileFile )
import GHC.Driver.Plugins
import GHC.Driver.Errors.Types ()

import GHC.Core
import GHC.Core.FVs ( mkRuleInfo )
import GHC.Core.Opt.Pipeline.Types ( CoreToDo(..) )
import GHC.Core.InstEnv ( emptyInstEnv )
import GHC.Core.FamInstEnv ( extendFamInstEnvList, emptyFamInstEnv )

import GHC.Linker.Static ( linkBinary )

import GHC.Types.Id
import GHC.Types.Id.Info
import GHC.Types.Name ( getOccString, nameModule_maybe )
import GHC.Types.Var.Env
import GHC.Types.ForeignStubs
import GHC.Types.Basic ( failed )

import GHC.Unit.Module
import GHC.Unit.Module.ModGuts
import GHC.Unit.Module.ModSummary ( ms_location )
import GHC.Unit.Module.ModDetails ( ModDetails(..) )
import GHC.Unit.Home.ModInfo ( HomeModInfo(..) )
import GHC.Unit.Home.PackageTable ( hptInternalTableRef, hptCollectDependencies )

import GHC.Utils.Logger
import GHC.Utils.Outputable
import GHC.Utils.Error ( withTiming )
import GHC.Utils.Panic
import GHC.Data.Maybe ( fromMaybe )
import GHC.Types.Unique.DFM ( mapUDFM )

import Control.Monad
import Data.IORef
import qualified Data.Set as Set
import System.Exit
import System.FilePath

{- Note [Chunks]
~~~~~~~~~~~~~~~~
With -fcore-webs-chunk, --make compiles the whole program (every module of
the home unit) as one Core program, so that no module boundary exposes a
web (WEBS-CHUNKS.md).  It works in two steps:

1. Capture.  The modules are compiled as usual, one at a time in dependency
   order, but with a static plugin that replaces the Core pipeline by a pass
   that records each module's ModGuts as the desugarer left it, followed by
   the pipeline's last simplifier pass alone (the module's own object still
   needs its compulsory unfoldings inlined: levity-polymorphic code panics
   in code generation otherwise; nofib real/cacheprof, puzzle).  Their objects and interfaces go to
   <odir>/webs-chunk-modules, out of the way; -fforce-recomp makes every
   module go through the pipeline.  Their interfaces carry no unfoldings
   (-fomit-interface-pragmas): the desugarer's simple optimiser would
   otherwise look through another module's unfolding, e.g. resolve a record
   update of a constructor-valued binder, and bring in binders that only
   that module's own compilation made up (ShellCheck: newFormatterOptions1,
   floated out of ShellCheck.Interface's newFormatterOptions by the last
   simplifier pass), which the merged program does not define.

2. Merge and compile.  The bindings of all the modules become one program
   in dependency order.  A module refers to another's binder through a
   global Id from that module's interface, with the binder's unique; every
   such occurrence (in expressions, stable unfoldings and rules) becomes the
   binder itself.  Only the program's entry points stay exported
   (Main.main and :Main.main), so everything else is internal; the class
   instances are dropped from mg_insts (no module imports the result).  The
   merged ModGuts (the Main module's, with every module's types, rules and
   bindings) then goes through the full Core pipeline with the command
   line's flags (webs included), Tidy and code generation, into one object,
   which is linked into the program.

The home package table still describes the captured modules; their rules
are removed from it, or the pipeline would see them twice, once with the
interfaces' global Ids.

Not handled: Template Haskell (the captured modules' code is unoptimised,
but splices run against it, so it works, only slowly), foreign exports of
modules other than Main, hs-boot cycles, per-module OPTIONS_GHC (the
command line's flags apply to the whole program), HPC and profiling.
-}

-- | --make with -fcore-webs-chunk: see Note [Chunks]
chunkMake :: [Target] -> Ghc ()
chunkMake targets = do
  hsc_env0 <- getSession
  let dflags0 = hsc_dflags hsc_env0
      logger  = hsc_logger hsc_env0
      odir    = fromMaybe "." (objectDir dflags0)
      capdir  = odir </> "webs-chunk-modules"
  ref <- liftIO (newIORef [])
  let capture = CoreDoPluginPass "webs chunk: capture" $ \g ->
                  do { liftIO (modifyIORef' ref (g :)); return g }
      -- the module's own code still needs the compulsory unfoldings
      -- inlined (levity-polymorphic code cannot be compiled otherwise):
      -- one simplifier pass, the pipeline's last
      lastSimpl todos = take 1 (reverse [ t | t@CoreDoSimplify {} <- concatMap flat todos ])
      flat t = case t of { CoreDoPasses ts -> concatMap flat ts; _ -> [t] }
      plugin  = defaultPlugin { installCoreToDos = \_ todos -> return (capture : lastSimpl todos)
                              , pluginRecompile  = impurePlugin }
      cap_dflags = (dflags0 `gopt_set` Opt_ForceRecomp `gopt_set` Opt_OmitInterfacePragmas
                            `gopt_unset` Opt_ExposeAllUnfoldings)
                     { objectDir    = Just capdir
                     , hiDir        = Just capdir
                     , stubDir      = Just capdir
                     , dumpDir      = Just capdir
                     , outputFile_  = Nothing
                     , ghcLink      = NoLink
                     , parMakeCount = Just (ParMakeThisMany 1) }
  _ <- setSessionDynFlags cap_dflags
  modifySession $ \e ->
    e { hsc_plugins = (hsc_plugins e)
          { staticPlugins = StaticPlugin (PluginWithArgs plugin []) True
                            : staticPlugins (hsc_plugins e) } }
  setTargets targets
  ok <- withTiming logger (text "Webs chunk: capture") (const ()) (load LoadAllTargets)
  when (failed ok) $ liftIO (exitWith (ExitFailure 1))
  gutss <- reverse <$> liftIO (readIORef ref)

  -- The pipeline for the merged program: the command line's flags, no
  -- capture plugin, and no rules from the home package table
  hsc_env1 <- getSession
  let hpt = hsc_HPT hsc_env1
  liftIO $ modifyIORef' (hptInternalTableRef hpt) $
    mapUDFM (\hmi -> hmi { hm_details = (hm_details hmi) { md_rules = [], md_anns = [] } })
  let hsc_env = hscSetFlags dflags0 $
                hsc_env1 { hsc_plugins = hsc_plugins hsc_env0 }
      main_name = mainModuleNameIs dflags0
  main_guts <- case [ g | g <- gutss, moduleName (mg_module g) == main_name ] of
    g : _ -> return g
    []    -> liftIO $ throwGhcExceptionIO (CmdLineError "-fcore-webs-chunk: no Main module")
  ms <- getModSummary (mg_module main_guts)
  let merged = mergeGuts dflags0 main_guts gutss
  liftIO $ do
    putDumpFileMaybe logger Opt_D_dump_webs_stats "Webs chunk: modules" FormatText $
      vcat [ text "Modules:" <+> int (length gutss)
           , text "Bindings:" <+> int (length (bindersOfBinds (mg_binds merged)))
           , text "Exported:" <+> pprWithCommas ppr
               [ b | b <- bindersOfBinds (mg_binds merged), isExportedId b ] ]
    simpl <- hscSimplify hsc_env [] merged
    (cgguts, _) <- hscTidy hsc_env simpl
    let location = ms_location ms
        base     = odir </> "WebsChunk"
    (asm, mb_stub, foreign_files, _, _) <-
      hscGenHardCode hsc_env cgguts location (base <.> "s")
    unless (null foreign_files) $
      throwGhcExceptionIO (CmdLineError "-fcore-webs-chunk: foreign files are not supported")
    let compile src o = do
          let e = hscSetFlags (dflags0 { outputFile_ = Just o, ghcLink = NoLink }) hsc_env
          r <- compileFile e NoStop (src, Nothing)
          maybe (throwGhcExceptionIO (CmdLineError ("-fcore-webs-chunk: cannot compile " ++ src)))
                return r
    obj  <- compile asm (base <.> "o")
    objs <- case mb_stub of
      Nothing   -> return [obj]
      Just stub -> do { s <- compile stub (base ++ "_stub" <.> "o"); return [obj, s] }
    when (ghcLink dflags0 == LinkBinary) $ do
      pkgs <- map snd . Set.toList <$> hptCollectDependencies hpt
      linkBinary logger (hsc_tmpfs hsc_env) dflags0 (hsc_unit_env hsc_env) objs pkgs

-- | One program from the captured modules (in dependency order)
mergeGuts :: DynFlags -> ModGuts -> [ModGuts] -> ModGuts
mergeGuts dflags main_guts gutss
  = main_guts { mg_binds        = map bind (concatMap mg_binds gutss)
              , mg_tcs          = concatMap mg_tcs gutss
              , mg_insts        = []
              , mg_inst_env     = emptyInstEnv
              , mg_fam_insts    = fam_insts
              , mg_fam_inst_env = extendFamInstEnvList emptyFamInstEnv fam_insts
              , mg_patsyns      = concatMap mg_patsyns gutss
              , mg_rules        = map rule (concatMap mg_rules gutss)
              , mg_foreign      = foldr (plusStubs . mg_foreign) NoStubs gutss
              , mg_foreign_files = concatMap mg_foreign_files gutss
              , mg_anns         = concatMap mg_anns gutss
              , mg_complete_matches = concatMap mg_complete_matches gutss }
  where
    fam_insts = concatMap mg_fam_insts gutss
    main_mod  = mg_module main_guts

    -- Every top-level binder, by unique: not exported unless an entry point.
    -- Occurrences become these; the binders also get their unfoldings and
    -- rules rewritten, whose occurrences are these too (not the rewritten
    -- binders: no knot), and the simplifier's substitution makes every
    -- occurrence its binder.
    top   = [ b | g <- gutss, b <- bindersOfBinds (mg_binds g) ]
    env   = mkVarEnv [ (b, unexport b) | b <- top ]
    unexport b
      | isLocalId b, isExportedId b, not (entry b) = setIdNotExported b
      | otherwise                                  = b
    -- main, and GHC's :Main.main wrapper (in the module :Main)
    entry b = case nameModule_maybe (idName b) of
      Just m -> (m == main_mod && getOccString b == fromMaybe "main" (mainFunIs dflags))
                || take 1 (moduleNameString (moduleName m)) == ":"
      Nothing -> False

    info b = b `setIdUnfolding` unf (realIdUnfolding b)
               `setIdSpecialisation` mkRuleInfo (map rule (ruleInfoRules (idSpecialisation b)))
    unf u = case u of
      CoreUnfolding { uf_tmpl = t } | isStableUnfolding u -> u { uf_tmpl = expr t }
                                    | otherwise           -> noUnfolding
      DFunUnfolding { df_args = as } -> u { df_args = map expr as }
      _                              -> u
    rule r = case r of
      Rule { ru_args = as, ru_rhs = rhs } -> r { ru_args = map expr as, ru_rhs = expr rhs }
      BuiltinRule {}                      -> r

    top_bndr b = info (fromMaybe b (lookupVarEnv env b))
    bind (NonRec b e) = NonRec (top_bndr b) (expr e)
    bind (Rec prs)    = Rec [ (top_bndr b, expr e) | (b, e) <- prs ]

    -- Occurrences of the top-level binders become the binders
    expr = \case
      Var v | isId v, Just v' <- lookupVarEnv env v -> Var v'
      Var v          -> Var v
      Lit l          -> Lit l
      App f a        -> App (expr f) (expr a)
      Lam b x        -> Lam (local b) (expr x)
      Let bd x       -> Let (lbind bd) (expr x)
      Case x b t as  -> Case (expr x) b t [ Alt c bs (expr r) | Alt c bs r <- as ]
      Cast x co      -> Cast (expr x) co
      Tick t x       -> Tick t (expr x)
      Type t         -> Type t
      Coercion co    -> Coercion co
      WebLam w b x   -> WebLam w (local b) (expr x)
      WebApp w f a   -> WebApp w (expr f) (expr a)
    lbind (NonRec b e) = NonRec (local b) (expr e)
    lbind (Rec prs)    = Rec [ (local b, expr e) | (b, e) <- prs ]
    -- a local binder's stable unfolding may mention them too
    local b | isId b    = b `setIdUnfolding` unf (realIdUnfolding b)
            | otherwise = b

    plusStubs NoStubs s = s
    plusStubs s NoStubs = s
    plusStubs (ForeignStubs h1 c1) (ForeignStubs h2 c2) = ForeignStubs (h1 `mappend` h2) (c1 `mappend` c2)
