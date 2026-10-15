{-# LANGUAGE LambdaCase #-}

-- | Compiling a program's modules together as one Core program
-- (-fcore-webs-chunk); see Note [Chunks]
module GHC.WebCore.Chunk
  ( chunkMake
  ) where

import GHC.Prelude

import GHC ( Target, setTargets, LoadHowMuch(..), getModSummary, setSessionDynFlags )
import GHC.Driver.Make ( depanal, load', noIfaceCache )
import GHC.Driver.Messager ( batchMsg )
import GHC.Types.Error ( mkUnknownDiagnostic )
import GHC.Core.Opt.Monad ( getModule )
import GHC.Unit.Module.Graph ( mapMG, mgModSummaries )
import GHC.Types.Avail ( AvailInfo(..) )
import System.Directory ( doesFileExist )
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
import GHC.Unit.Module.ModSummary ( ModSummary(..), ms_location, ms_mod_name, isBootSummary )
import GHC.Unit.Module.Location ( ModLocation(..) )
import GHC.Unit.Module.ModDetails ( ModDetails(..) )
import GHC.Unit.Home.ModInfo ( HomeModInfo(..) )
import GHC.Unit.Home.PackageTable ( hptInternalTableRef, hptCollectDependencies )

import GHC.Utils.Logger
import GHC.Utils.Outputable
import GHC.Utils.Error ( withTiming )
import GHC.Utils.Panic
import GHC.Data.Maybe ( fromMaybe, isNothing )
import GHC.Types.Unique.DFM ( mapUDFM )

import Control.Monad
import Data.IORef
import qualified Data.Set as Set
import System.Exit
import System.FilePath

{- Note [Chunks]
~~~~~~~~~~~~~~~~
With -fcore-webs-chunk, --make compiles a chunk of the program's modules
as one Core program, so that no module boundary inside it exposes a web
(WEBS-CHUNKS.md).  The chunk is every module of the home unit, or the
modules -fcore-webs-chunk-modules=FILE lists (one name per line); the other
modules are compiled as usual.  It works in two steps:

1. Capture.  The modules are compiled as usual, one at a time in dependency
   order, but with a static plugin that, for the chunk's modules, replaces
   the Core pipeline by a pass that records the ModGuts as the desugarer
   left it, followed by the pipeline's last simplifier pass alone (the
   module's own object still needs its compulsory unfoldings inlined:
   levity-polymorphic code panics in code generation otherwise; nofib
   real/cacheprof, puzzle).  -fforce-recomp makes every module go through
   the pipeline.

   The chunk's modules' interfaces carry no pragmas
   (-fomit-interface-pragmas, set in their summaries): no unfoldings, and no
   arity, strictness, CAF or tag information.  The modules outside the
   chunk compile against them, and then call the chunk's code as unknown
   functions that may refer to CAFs, which is right whatever the merged
   program did to it; and the desugarer's simple optimiser of the other
   chunk modules cannot look through an unfolding and bring in binders that
   only that module's own compilation made up (ShellCheck:
   newFormatterOptions1, floated out of ShellCheck.Interface's
   newFormatterOptions by the last simplifier pass), which the merged
   program does not define.

2. Merge and compile.  The bindings of the chunk's modules become one
   program in dependency order.  A module refers to another's binder
   through a global Id from that module's interface, with the binder's
   unique; every such occurrence (in expressions, stable unfoldings and
   rules) becomes the binder itself.  The roots stay exported, so
   everything else is internal:
     * the whole program (every module, with Main): only Main.main and
       :Main.main;
     * otherwise every exported binder of the chunk's modules, but those
       that -fcore-webs-unused-exports lists (exports used by no module
       outside the chunk; webs-bench/unused-exports.py), and every class
       instance's dictionary.
   The merged program's export list is the union of the roots' (or Main's),
   which decides which types' constructors stay visible (classifyTyCon in
   GHC.WebCore.Pipeline): the modules outside see the chunk's types as the
   interfaces describe them.  The class instances are dropped from mg_insts
   (the merged module has no interface of its own).  The merged ModGuts
   (Main's, or the chunk's last module's, with every module's types, rules
   and bindings) then goes through the full Core pipeline with the command
   line's flags (webs included), Tidy and code generation, into one object
   (<odir>/WebsChunk.o).  A program is linked from it and the objects of
   the modules outside the chunk; the chunk's modules' own objects are not
   used.  For a library, the chunk's interfaces and WebsChunk.o are the
   result.

The home package table still describes the captured modules; their rules
are removed from it, or the pipeline would see them twice, once with the
interfaces' global Ids.

Not handled: Template Haskell (the captured modules' code is unoptimised,
but splices run against it, so it works, only slowly), foreign exports of
modules other than Main, hs-boot cycles, per-module OPTIONS_GHC (the
command line's flags apply to the whole chunk), HPC and profiling.
-}

-- | --make with -fcore-webs-chunk: see Note [Chunks]
chunkMake :: [Target] -> Ghc ()
chunkMake targets = do
  hsc_env0 <- getSession
  let dflags0 = hsc_dflags hsc_env0
      logger  = hsc_logger hsc_env0
      odir    = fromMaybe "." (objectDir dflags0)
      capdir  = odir </> "webs-chunk-modules"
  -- The chunk: the modules -fcore-webs-chunk-modules lists, or all of them
  listed <- liftIO $ case websChunkModules dflags0 of
    Nothing -> return Nothing
    Just f  -> Just . Set.fromList . concatMap words . lines <$> readFile f
  let in_chunk m = maybe True (moduleNameString m `Set.member`) listed

  ref <- liftIO (newIORef [])
  let capture = CoreDoPluginPass "webs chunk: capture" $ \g ->
                  do { liftIO (modifyIORef' ref (g :)); return g }
      -- the module's own code still needs the compulsory unfoldings
      -- inlined (levity-polymorphic code cannot be compiled otherwise):
      -- one simplifier pass, the pipeline's last
      lastSimpl todos = take 1 (reverse [ t | t@CoreDoSimplify {} <- concatMap flat todos ])
      flat t = case t of { CoreDoPasses ts -> concatMap flat ts; _ -> [t] }
      plugin  = defaultPlugin
        { installCoreToDos = \_ todos -> do
            { m <- getModule
            ; return (if in_chunk (moduleName m) then capture : lastSimpl todos else todos) }
        , pluginRecompile  = impurePlugin }
      cap_dflags = (dflags0 `gopt_set` Opt_ForceRecomp)
                     { outputFile_  = Nothing
                     , ghcLink      = NoLink
                     , parMakeCount = Just (ParMakeThisMany 1) }
      -- the chunk's modules: interfaces without pragmas (Note [Chunks]),
      -- their dumps out of the way
      chunk_flags d = (d `gopt_set` Opt_OmitInterfacePragmas `gopt_unset` Opt_ExposeAllUnfoldings)
                        { dumpDir = Just capdir }
  _ <- setSessionDynFlags cap_dflags
  modifySession $ \e ->
    e { hsc_plugins = (hsc_plugins e)
          { staticPlugins = StaticPlugin (PluginWithArgs plugin []) True
                            : staticPlugins (hsc_plugins e) } }
  setTargets targets
  graph0 <- depanal [] False
  let graph = mapMG (\ms -> if in_chunk (ms_mod_name ms)
                            then ms { ms_hspp_opts = chunk_flags (ms_hspp_opts ms) } else ms) graph0
      summaries = [ ms | ms <- mgModSummaries graph, isBootSummary ms == NotBoot ]
  ok <- withTiming logger (text "Webs chunk: capture") (const ()) $
          load' noIfaceCache LoadAllTargets mkUnknownDiagnostic (Just batchMsg) graph
  when (failed ok) $ liftIO (exitWith (ExitFailure 1))
  gutss <- reverse <$> liftIO (readIORef ref)
  when (null gutss) $
    liftIO $ throwGhcExceptionIO (CmdLineError "-fcore-webs-chunk: no module in the chunk")

  -- The pipeline for the merged program: the command line's flags, no
  -- capture plugin, and no rules from the home package table
  hsc_env1 <- getSession
  let hpt = hsc_HPT hsc_env1
  liftIO $ modifyIORef' (hptInternalTableRef hpt) $
    mapUDFM (\hmi -> hmi { hm_details = (hm_details hmi) { md_rules = [], md_anns = [] } })
  let hsc_env = hscSetFlags dflags0 $
                hsc_env1 { hsc_plugins = hsc_plugins hsc_env0 }
      main_name = mainModuleNameIs dflags0
      main_guts = [ g | g <- gutss, moduleName (mg_module g) == main_name ]
      -- The whole program: only main stays exported.  Otherwise every
      -- export of the chunk's modules (but the listed unused ones), and
      -- every instance, is a root
      whole = isNothing listed && not (null main_guts)
      base_guts = head (main_guts ++ reverse gutss)
      outside = [ ms | ms <- summaries, not (in_chunk (ms_mod_name ms)) ]
  unused <- liftIO $ readUnusedExportsAll dflags0
  ms <- getModSummary (mg_module base_guts)
  let merged = mergeGuts dflags0 whole unused base_guts gutss
  liftIO $ do
    putDumpFileMaybe logger Opt_D_dump_webs_stats "Webs chunk: modules" FormatText $
      vcat [ text "Modules:" <+> int (length gutss)
           , text "Outside the chunk:" <+> int (length outside)
           , text "Bindings:" <+> int (length (bindersOfBinds (mg_binds merged)))
           , text "Exported:" <+> int (length [ b | b <- bindersOfBinds (mg_binds merged), isExportedId b ]) ]
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
    -- A program: the chunk's object instead of its modules' objects
    when (ghcLink dflags0 == LinkBinary && any ((== main_name) . ms_mod_name) summaries) $ do
      pkgs <- map snd . Set.toList <$> hptCollectDependencies hpt
      let others = [ ml_obj_file (ms_location m) | m <- outside ]
      linkBinary logger (hsc_tmpfs hsc_env) dflags0 (hsc_unit_env hsc_env) (objs ++ others) pkgs

-- | Every module's unused exports (Note [Unused exports] in
-- GHC.WebCore.Pipeline), by module name
readUnusedExportsAll :: DynFlags -> IO (Set.Set (String, String))
readUnusedExportsAll dflags = case websUnusedExports dflags of
  Nothing -> return Set.empty
  Just f  -> do { ok <- doesFileExist f
                ; txt <- if ok then readFile f else return ""
                ; return $! Set.fromList [ (m, o) | [m, o] <- map words (lines txt) ] }

-- | One program from the captured modules (in dependency order)
mergeGuts :: DynFlags -> Bool -> Set.Set (String, String) -> ModGuts -> [ModGuts] -> ModGuts
mergeGuts dflags whole unused main_guts gutss
  = main_guts { mg_binds        = map bind (concatMap mg_binds gutss)
              , mg_exports      = exports
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

    -- What the merged program exports: decides which types' constructors
    -- outside modules see (classifyTyCon in GHC.WebCore.Pipeline)
    exports | whole     = mg_exports main_guts
            | otherwise = [ a | g <- gutss, a <- mg_exports g, keepAvail a ]
    keepAvail (Avail n) = not (cut_name n)
    keepAvail _         = True
    cut_name n = case nameModule_maybe n of
      Just m  -> (moduleNameString (moduleName m), getOccString n) `Set.member` unused
      Nothing -> False

    -- Every top-level binder, by unique: not exported unless a root.
    -- Occurrences become these; the binders also get their unfoldings and
    -- rules rewritten, whose occurrences are these too (not the rewritten
    -- binders: no knot), and the simplifier's substitution makes every
    -- occurrence its binder.
    top   = [ b | g <- gutss, b <- bindersOfBinds (mg_binds g) ]
    env   = mkVarEnv [ (b, unexport b) | b <- top ]
    unexport b
      | isLocalId b, isExportedId b, not (root b) = setIdNotExported b
      | otherwise                                 = b
    root b | whole     = entry b
           | otherwise = not (cut_name (idName b))
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
