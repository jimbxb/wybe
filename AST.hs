--  File     : AST.hs
--  Author   : Peter Schachte
--  Origin   : Thu Oct 14 23:30:58 2010
--  Purpose  : Abstract Syntax Tree for Wybe language
--  Copyright: � 2010-2012 Peter Schachte.  All rights reserved.

-- |The abstract syntax tree, and supporting types and functions.
--  This includes the parse tree, as well as the AST types, which
--  are normalised versions of the parse tree types.
--
--  This also includes the Compiler monad and the Module types.
module AST (
  -- *Types just for parsing
  Item(..), Visibility(..), maxVisibility, minVisibility,
  TypeProto(..), TypeSpec(..), FnProto(..),
  ProcProto(..), Param(..), Stmt(..), 
  Exp(..), Generator(..),
  -- *Source Position Types
  OptPos, Placed(..), place, content, maybePlace, rePlace, mapPlaced,
  updatePlacedM,
  -- *AST types
  Module(..), ModuleInterface(..), ModuleImplementation(..),
  enterModule, exitModule, finishModule, 
  emptyInterface, emptyImplementation,
  ModSpec, ProcDef(..), Ident, VarName, VarInfo(..),
  ProcName, TypeDef(..), ResourceDef(..), FlowDirection(..), 
  argFlowDirection, flowIn, 
  expToStmt, Prim(..), PrimProto(..), primProto, PrimParam(..), primParam,
  PrimVarName(..), PrimArg(..), PrimFlow(..), ArgFlowType(..),
  -- *Stateful monad for the compilation process
  MessageLevel(..), getCompiler, updateCompiler,
  CompilerState(..), Compiler, runCompiler,
  ClauseCompState(..), ClauseComp, runClauseComp, instr,
  updateModules, getModuleImplementationField, getLoadedModule,
  getModule, updateModule, getSpecModule, updateSpecModule,
  updateModImplementation, updateModImplementationM, 
  updateModInterface, updateModProcsM,
  getDirectory, getModuleSpec, getModuleParams, option, 
  optionallyPutStr, verboseMsg, message, freshVar, genProcName,
  getVar, getNextVar, flowVar, inVar, outVar, inOutVar,
  addImport, addType, addSubmod, lookupType, publicType,
  addResource, lookupResource, publicResource,
  addProc, replaceProc, lookupProc, publicProc,

  -- temporary
  showProcDefs, showBlock

  ) where

import Options
import Data.Maybe
import Data.Map as Map
import Data.Set as Set
import Data.List as List
import Text.ParserCombinators.Parsec.Pos
import System.FilePath
import Control.Monad
import Control.Monad.Trans.State
import Control.Monad.Trans (lift,liftIO)
import Config

----------------------------------------------------------------
--                      Types Just For Parsing
----------------------------------------------------------------

-- |An item appearing at the top level of a source file.
data Item
     = TypeDecl Visibility TypeProto [Item] OptPos
     | ModuleDecl Visibility Ident [Item] OptPos
     | ImportMods Visibility Bool [ModSpec] OptPos
     | ImportItems Visibility Bool ModSpec [Ident] OptPos
     | ResourceDecl Visibility Ident TypeSpec OptPos
     | FuncDecl Visibility FnProto TypeSpec (Placed Exp) OptPos
     | ProcDecl Visibility ProcProto [Placed Stmt] OptPos
     | CtorDecl Visibility FnProto OptPos
     | StmtDecl Stmt OptPos

-- |The visibility of a file item.  We only support public and private.
data Visibility = Public | Private
                  deriving (Eq, Show)

-- |Combine two visibilities, taking the most visible.
maxVisibility :: Visibility -> Visibility -> Visibility
maxVisibility Public _ = Public
maxVisibility _ Public = Public
maxVisibility _      _ = Private

-- |Combine two visibilities, taking the least visible.
minVisibility :: Visibility -> Visibility -> Visibility
minVisibility Private _ = Private
minVisibility _ Private = Private
minVisibility _       _ = Public

-- |A type prototype consists of a type name and zero or more type parameters.
data TypeProto = TypeProto Ident [Ident]

-- |A function prototype consists of a function name and zero or more formal 
--  parameters.
data FnProto = FnProto Ident [Param]


----------------------------------------------------------------
--                    Handling Source Positions
----------------------------------------------------------------

-- |Optional source position.
type OptPos = Maybe SourcePos

-- |Some kind of value, with a source position optionally attached.
data Placed t
    = Placed t SourcePos
    | Unplaced t
    deriving Eq

-- |Return the optional position attached to a Placed value.
place :: Placed t -> OptPos
place (Placed _ pos) = Just pos
place (Unplaced _) = Nothing

-- |Return the content of a Placed value.
content :: Placed t -> t
content (Placed content _) = content
content (Unplaced content) = content

-- |Attach a source position to a data value, if one is available.
maybePlace :: t -> OptPos -> Placed t
maybePlace t (Just pos) = Placed t pos
maybePlace t Nothing    = Unplaced t

-- |Attach a source position to a data value, if one is available.
rePlace :: t -> Placed t -> Placed t
rePlace t (Placed _ pos) = Placed t pos
rePlace t (Unplaced _)   = Unplaced t

mapPlaced :: (a -> b) -> Placed a -> Placed b
mapPlaced f (Placed x pos) = Placed (f x) pos
mapPlaced f (Unplaced x) = Unplaced $ f x

-- |Apply a monadic function to the payload of a Placed thing
updatePlacedM :: (t -> Compiler t) -> Placed t -> Compiler (Placed t)
updatePlacedM fn (Placed content pos) = do
    content' <- fn content
    return $ Placed content' pos
updatePlacedM fn (Unplaced content) = do
    content' <- fn content
    return $ Unplaced content'

----------------------------------------------------------------
--                    Compiler monad
----------------------------------------------------------------

-- |The different kinds of compiler messages.
data MessageLevel = Informational | Warning | Error
                  deriving (Eq, Ord, Show)


-- |The state of a compilation, used by the Compiler monad.  Because 
--  this language allows mutually recursive module dependencies, 
--  compilation is bit tricky.  To compile a module and its 
--  dependencies, we first load the module.  Then for each 
--  dependency we have not yet compiled and are not already in the 
--  process of compiling, we compile the dependency, and retain only 
--  the module's interface (this avoids having the source or compiled 
--  version of too many modules in memory at once).  Dependencies we 
--  are in the process of compiling, we collect in a list.  Once we 
--  finish compiling a module's dependencies, we compile the list of 
--  that module's strongly-connected component collected while 
--  compiling the module's dependencies.
data CompilerState = Compiler {
  options :: Options,      -- ^compiler options specified on the command line
  msgs :: [String],        -- ^warnings, error messages, and info messages
  errorState :: Bool,      -- ^whether or not we've seen any errors
  modules :: Map ModSpec Module, -- ^all known modules
  loadCount :: Int,        -- ^counter of module load order
  underCompilation :: [Module], -- ^the modules in the process of being compiled
  deferred :: [Module],         -- ^modules in the same SCC as the current one
  mainClauseSt :: ClauseCompState
                           -- ^stores the main proc being compiled
  }

-- |The compiler monad is a state transformer monad carrying the 
--  compiler state over the IO monad.
type Compiler = StateT CompilerState IO

-- |Run a compiler function from outside the Compiler monad.
runCompiler :: Options -> Compiler t -> IO t
runCompiler opts comp = evalStateT comp 
                        (Compiler opts [] False Map.empty 0 [] [] 
                         freshClauseComp)


-- initCompiler :: Options -> FilePath -> ModSpec -> Maybe [Ident] -> 
--                OptPos -> CompilerState
-- initCompiler opts dir spec params pos = 
--     let typedef params' = Map.insert (last spec)
--                           (TypeDef (List.length params') pos) Map.empty
--         (typs,pubtyps) =
--             case params of
--                 Nothing -> (Map.empty, Map.empty)
--                 Just params' -> (typedef params', typedef params')
--     in Compiler opts [] False Map.empty 0 0 0 0 0 $
--        Module dir spec params 
--        (ModuleInterface pubtyps Map.empty Map.empty Map.empty Set.empty) 
--        (Just $ ModuleImplementation Map.empty Map.empty typs 
--         Map.empty Map.empty)

-- |Return some function of the current compiler state.
getCompiler :: (CompilerState -> t) -> Compiler t
getCompiler getter = do
    state <- get
    return $ getter state

-- |Apply some transformation function to the compiler state.
updateCompiler :: (CompilerState -> CompilerState) -> Compiler ()
updateCompiler updater = do
    state <- get
    put $ updater state

-- |Apply a monadic transformation function to the compiler state.
updateCompilerM :: (CompilerState -> Compiler CompilerState) -> Compiler ()
updateCompilerM updater = do
    state <- get
    state' <- updater state
    put state'

-- |Return Just the specified module, if already loaded; else return Nothing.
getLoadedModule :: ModSpec -> Compiler (Maybe Module)
getLoadedModule modspec = getCompiler (Map.lookup modspec . modules)

-- |Apply some transformation to the map of compiled modules.
updateModules :: (Map ModSpec Module -> Map ModSpec Module) -> Compiler ()
updateModules updater = do
    updateCompiler (\bs -> bs { modules = updater $ modules bs })

-- |Return some function of the module currently being compiled.
getModule :: (Module -> t) -> Compiler t
getModule getter = getCompiler (getter . head . underCompilation)

-- |Transform the module currently being compiled.
updateModule :: (Module -> Module) -> Compiler ()
updateModule updater = do
    updateCompiler (\comp -> let mods = underCompilation comp
                            in  comp { underCompilation =
                                            updater (head mods):tail mods })

-- |Transform the module currently being compiled.
updateModuleM :: (Module -> Compiler Module) -> Compiler ()
updateModuleM updater = do
    updateCompilerM (\comp -> do
                          let mods = underCompilation comp
                          mod' <- updater $ head mods
                          return comp { underCompilation = mod':tail mods })

-- |Return some function of the specified module.
getSpecModule :: ModSpec -> (Module -> t) -> Compiler (Maybe t)
getSpecModule spec getter = 
    getCompiler (maybeApply getter . Map.lookup spec . modules)

-- |Transform the specified module.  Does nothing if it does not exist.
updateSpecModule :: ModSpec -> (Module -> Module) -> Compiler ()
updateSpecModule spec updater = do
    updateCompiler 
      (\comp -> comp { modules = Map.adjust updater spec (modules comp) })

-- |Transform the specified module.  An error if it does not exist.
updateSpecModuleM :: (Module -> Compiler Module) -> ModSpec -> Compiler ()
updateSpecModuleM updater spec = do
    updateCompilerM
      (\comp -> do
            let mods = modules comp
            let mod = Map.lookup spec mods
            case mod of
                Nothing -> error ("nonexistent module " ++ show spec)
                Just m -> do
                    m' <- updater m
                    return $ comp {modules = Map.insert spec m' mods})

-- |Prepare to compile a module by setting up a new Module on the 
--  front of the list of modules underCompilation. 
enterModule :: FilePath -> ModSpec -> Maybe [Ident] -> Compiler ()
enterModule dir modspec params = do
    count0 <- getCompiler loadCount
    let count = 1 + count0
    updateCompiler (\comp -> comp { loadCount = count })
    updateCompiler (\comp -> let mods = Module dir modspec params 
                                       emptyInterface (Just emptyImplementation)
                                       count count 0 0
                                       : underCompilation comp
                            in  comp { underCompilation = mods })

exitModule :: Compiler [ModSpec]
exitModule = do
    mod <- finishModule
    let num = thisLoadNum mod
    if (minDependencyNum mod < num) 
      then do
        updateCompiler (\comp -> comp { deferred = mod:deferred comp })
        return []
      else do
        deferred <- getCompiler deferred
        let (bonus,rest) = span ((==num) . minDependencyNum) deferred
        updateCompiler (\comp -> comp { deferred = rest })
        return $ List.map modSpec $ mod:bonus

finishModule :: Compiler Module
finishModule = do
    mod <- getModule id
    updateCompiler 
      (\comp -> comp { underCompilation = tail (underCompilation comp) })
    updateModules $ Map.insert (modSpec mod) mod
    return mod

-- |Return the directory of the current module.
getDirectory :: Compiler FilePath
getDirectory = getModule modDirectory

-- |Return the module spec of the current module.
getModuleSpec :: Compiler ModSpec
getModuleSpec = getModule modSpec

-- |Return the module (type) parameters of the current module.
getModuleParams :: Compiler (Maybe [Ident])
getModuleParams = getModule modParams

-- |Return the interface of the current module.
getModuleInterface :: Compiler ModuleInterface
getModuleInterface = getModule modInterface

-- |Return the implementation of the current module.
getModuleImplementation :: Compiler (Maybe ModuleImplementation)
getModuleImplementation = getModule modImplementation

-- |Return some function applied to the implementation of the current module.
getModuleImplementationField :: (ModuleImplementation -> t) ->
                               Compiler (Maybe t)
getModuleImplementationField getter = do
  imp <- getModuleImplementation
  case imp of
      Nothing -> return Nothing
      Just imp' -> return $ Just $ getter imp'

-- |Return some function applied to the implementation of the current module
getModuleImplementationMaybe :: (ModuleImplementation -> Maybe t) ->
                               Compiler (Maybe t)
getModuleImplementationMaybe fn = do
  imp <- getModuleImplementation
  case imp of
      Nothing -> return Nothing
      Just imp' -> return $ fn imp'


-- |Add the specified string as a message of the specified severity 
--  referring to the optionally specified source location to the 
--  collected compiler output messages. 
message :: MessageLevel -> String -> OptPos -> Compiler ()
message lvl msg pos = do
    updateCompiler (\bldr -> bldr { msgs = (msgs bldr) ++ [makeMessage msg pos]})
    when (lvl == Error) (updateCompiler (\bldr -> bldr { errorState = True }))

-- |Construct a message string from the specified text and location.
makeMessage :: String -> OptPos -> String
makeMessage msg Nothing = msg
makeMessage msg (Just pos) =
  (sourceName pos) ++ ":" ++ 
  show (sourceLine pos) ++ ":" ++ 
  show (sourceColumn pos) ++ ": " ++ 
  msg



----------------------------------------------------------------
--                 Clause compiler monad
----------------------------------------------------------------

-- |The state of compilation of a clause; used by the ClauseComp
-- monad.
data ClauseCompState = ClauseComp {
    body :: [Placed Prim],       -- ^body of the clause being generated, reversed
    vars :: Map VarName VarInfo, -- ^latest var number for each var
    uses :: Map VarName OptPos,  -- ^where variables are used before defined
    outParams:: [PrimParam],     -- ^variables that must be defined by clause
    tmpCount :: Int              -- ^number of temp vars so far in this clause
  }

initClauseComp :: Map VarName VarInfo -> [PrimParam] -> Int -> ClauseCompState
initClauseComp symtab outParams tmpNum = 
    ClauseComp [] symtab Map.empty outParams tmpNum

freshClauseComp :: ClauseCompState
freshClauseComp = initClauseComp Map.empty [] 0

data VarInfo = VarInfo {
    ordinal :: Int,            -- ^ordinal number of distinct var for this name
    typ :: TypeSpec            -- ^type of this var
    } deriving Show

-- |The clause compiler monad is a state transformer monad carrying the 
--  clause compiler state over the compiler monad.
type ClauseComp = StateT ClauseCompState Compiler

-- |Run a clause compiler function from the Compiler monad.
extendClauseComp :: ClauseCompState -> ClauseComp t 
                    -> Compiler (t, ClauseCompState)
extendClauseComp st clcomp = runStateT clcomp st

-- |Run a clause compiler function from the Compiler monad.
runClauseComp :: [PrimParam] -> Int -> ClauseComp t -> Compiler (t, ClauseCompState)
runClauseComp params tmpNum clcomp =
    let symtab = List.foldr insertInputParam Map.empty params
        outs = List.filter (\p->paramFlow p==FlowOut) params
    in runStateT clcomp $ initClauseComp symtab outs tmpNum


-- |Generate a single instruction for the clause currently being compiled
instr :: Prim -> OptPos -> ClauseComp ()
instr PrimNop _ = return ()      -- Don't bother to generate Nops
instr prim pos = do
  bdy <- gets body
  modify (\st -> st {body = (maybePlace prim pos):bdy})

insertInputParam :: PrimParam -> Map VarName VarInfo -> Map VarName VarInfo
insertInputParam (PrimParam (PrimVarName var num) typ FlowIn _) symtab =
    Map.insert var (VarInfo num typ) symtab
insertInputParam (PrimParam _ _ FlowOut _) symtab = symtab    

-- |Return a fresh variable name.
freshVar :: ClauseComp String
freshVar = do
  ctr <- gets tmpCount
  modify (\st -> st {tmpCount = ctr + 1 })
  return $ "$tmp" ++ (show ctr)

-- |Return the current PrimVarName for a given name string; ie, find 
--  the current suffix for the specified name.
getVar :: VarName -> OptPos -> ClauseComp PrimVarName
-- XXX Just for now, always use suffix 0
getVar name pos = do
    currver <- gets (Map.lookup name . vars)
    case currver of
        Nothing -> do
            -- lift $ message Error ("uninitialised variable "++name) Nothing
            modify (\s -> s {uses = Map.insert name pos $ uses s})
            return $ PrimVarName name 0
        Just (VarInfo num _) -> return $ PrimVarName name num

-- |Return the next PrimVarName for a given name string; ie, find 
--  the next suffix for the specified name
getNextVar :: String -> OptPos -> ClauseComp PrimVarName
getNextVar name pos = do
    info <- gets (Map.lookup name . vars)
    let (num,typ) = case info of
            Nothing -> (0,Unspecified)
            Just (VarInfo num typ) -> ((num + 1), typ)
    modify (\s -> s {vars = Map.insert name (VarInfo num typ) $ vars s})
    return $ PrimVarName name num

-- |Return the primitive procedure call input argument(s) for the 
--  specified variable name and flow direction
flowVar :: String -> FlowDirection -> OptPos -> ClauseComp [PrimArg]
flowVar name ParamIn pos = inVar name pos
flowVar name ParamOut pos = outVar name pos
flowVar name ParamInOut pos = inOutVar name pos
flowVar name NoFlow _ = return []

-- |Return the primitive procedure call input argument for the 
--  specified variable name.
inVar :: String -> OptPos -> ClauseComp [PrimArg]
inVar name pos = do
    primvar <- getVar name pos
    return [ArgVar primvar FlowIn Ordinary]

-- |Return the primitive procedure call output argument for the 
--  specified variable name.
outVar :: String -> OptPos -> ClauseComp [PrimArg]
outVar name pos = do
    primvar <- getNextVar name pos
    return [ArgVar primvar FlowOut Ordinary]

-- |Return the primitive procedure call input and output arguments for the 
--  specified variable name.
inOutVar :: String -> OptPos -> ClauseComp [PrimArg]
inOutVar name pos = do
    primvar <- getVar name pos
    primvar' <- getNextVar name pos
    return [ArgVar primvar FlowIn FirstHalf,
            ArgVar primvar' FlowOut SecondHalf]

-- |Return a new, unused proc ID.
genProcName :: Compiler ProcName
genProcName = do
  ctr <- getModule procCount
  updateModule (\mod -> mod {procCount = ctr + 1 })
  return $ "gen$" ++ show (ctr + 1)

-- |Apply the given function to the current module interface if the 
--  specified visibility is Public.
updateInterface :: Visibility -> (ModuleInterface -> ModuleInterface) -> 
                  Compiler ()
updateInterface Private interfaceOp = return ()  -- do nothing
updateInterface Public interfaceOp =            -- update the interface
    updateModule (\mod -> mod { modInterface = interfaceOp $ modInterface mod })

-- |Apply the given function to the current module implementation, if 
--  there is one.
updateImplementation :: (ModuleImplementation -> ModuleImplementation) -> 
                       Compiler ()
updateImplementation implOp = do
    oldmod <- getModule id
    case modImplementation oldmod of
        Nothing -> return ()
        Just impl ->
            updateModule (\mod -> mod { modImplementation = Just $ implOp impl })

-- |Add the specified type definition to the current module.
addType :: Ident -> TypeDef -> Visibility -> Compiler ()
addType name def@(TypeDef arity _) vis = do
    updateImplementation (updateModTypes (Map.insert name def))
    updateInterface vis (updatePubTypes (Map.insert name def))

-- |Add the specified submodule to the current module.
addSubmod :: Ident -> Module -> OptPos -> Visibility -> Compiler ()
addSubmod name modl pos vis = do
    updateImplementation (updateModSubmods (Map.insert name modl))
    updateInterface vis (updatePubDependencies (Map.insert name pos))

-- |Find the definition of the specified type in the current module.
lookupType :: Ident -> Compiler (Maybe TypeDef)
lookupType name = 
    getModuleImplementationMaybe (\imp -> Map.lookup name $ modTypes imp)

-- |Is the specified type exported by the current module.
publicType :: Ident -> Compiler Bool
publicType name = do
  int <- getModuleInterface
  return $ Map.member name (pubTypes int)

-- |Add the specified resource to the current module.
addResource :: Ident -> ResourceDef -> Visibility -> Compiler ()
addResource name def vis = do
    updateImplementation (updateModResources (Map.insert name def))
    updateInterface vis (updatePubResources 
                         (Map.insert name $ resourceDefPosition def))

-- |Find the definition of the specified resource in the current module.
lookupResource :: Ident -> Compiler (Maybe ResourceDef)
lookupResource name =
    getModuleImplementationMaybe (\imp -> Map.lookup name $ modResources imp)

-- |Is the specified resource exported by the current module.
publicResource :: Ident -> Compiler Bool
publicResource name = getModule (Map.member name . pubResources . modInterface)

-- |Add the specified module spec as an import of the current module.
addImport :: ModSpec -> Bool -> (Maybe [Ident]) -> Visibility -> Compiler ()
addImport modspec imp specific vis = do
    updateImplementation
      (updateModImports
       (\moddeps -> 
         let (ModDependency uses imps) = 
                 Map.findWithDefault 
                 (ModDependency ImportNothing ImportNothing) 
                 modspec moddeps
             uses' = if imp then uses else addImports specific vis uses
             imps' = if imp then addImports specific vis imps else imps
         in Map.insert modspec (ModDependency uses' imps') moddeps))
    updateInterface vis (updateDependencies (Set.insert $ last modspec))

-- |Add the specified proc definition to the current module.
addProc :: Ident -> PrimProto -> [[Placed Prim]] -> OptPos
           -> Visibility -> Compiler ()
addProc name proto clauses pos vis = do
    updateImplementation
      (updateModProcs
       (\procs ->
         let defs = findWithDefault [] name procs
             defs' = defs ++ [ProcDef name proto clauses pos]
         in  Map.insert name defs' procs))
    newid <- getModuleImplementationField 
            (((-1)+) . length . fromJust . Map.lookup name . modProcs)
    updateInterface vis
      (updatePubProcs (mapListInsert name 
                       (ProcCallInfo (fromJust newid) proto pos)))

-- |Prepend the provided elt to mapping for the specified key in the map.
mapListInsert :: Ord a => a -> b -> Map a [b] -> Map a [b]
mapListInsert key elt =
    Map.alter (\maybe -> Just $ elt:fromMaybe [] maybe) key


-- |Replace the specified proc definition in the current module.
replaceProc :: Ident -> Int -> PrimProto -> [[Placed Prim]] -> OptPos
               -> Visibility -> Compiler ()
replaceProc name id proto clauses pos vis = do
    updateImplementation
      (updateModProcs
       (\procs -> 
         let olddefs = findWithDefault [] name procs
             (front,back) = List.splitAt id olddefs
         in Map.insert name (front ++ 
                             (ProcDef name proto clauses pos:tail back)) 
            procs))


-- |Return the definition of the specified proc in the current module.
lookupProc :: Ident -> Compiler (Maybe [ProcDef])
lookupProc name = 
    getModuleImplementationMaybe (\imp -> Map.lookup name $ modProcs imp)


-- |Is the specified proc exported from the current module?
publicProc :: Ident -> Compiler Bool
publicProc name = do
  int <- getModuleInterface
  return $ Map.member name $ pubProcs int


-- |Return some function applied to the user's specified compiler options.
option :: (Options -> t) -> Compiler t
option opt = do
    opts <- getCompiler options
    return $ opt opts

-- |If the specified Boolean option is selected, print out the result 
--  of applying the compiler state state output function.
optionallyPutStr :: (Options -> Bool) -> Compiler String -> Compiler ()
optionallyPutStr opt strcomp = do
    check <- option opt
    str <- strcomp
    when check ((liftIO . putStrLn) str)

-- |If a high enough verbosity level was specified, execute the given 
--  computation to produce a string, and print it out.
verboseMsg :: Int -> Compiler String -> Compiler ()
verboseMsg verbosity = optionallyPutStr ((>= verbosity) . optVerbosity)

-- -- |Initialise the compiler state's type map to empty.
-- initialiseTypes :: Compiler ()
-- initialiseTypes = updateCompiler (\st -> st {types = Map.empty})

-- -- |Update type information to add a type constraint.
-- addTypeConstraint :: VarName -> TypeSpec -> Compiler ()
-- addTypeConstraint var typ = do
--     updateCompiler (\st -> st {types = Map.insertWith meetTypes 
--                                       var typ $ types st})

-- -- |Return the type spec for the specified variable.
-- varType :: VarName -> Compiler TypeSpec
-- varType var = do
--     getCompiler (Map.findWithDefault Unspecified var . types)

-- -- |Combine two type constraints.
-- meetTypes :: TypeSpec -> TypeSpec -> TypeSpec
-- -- XXX Need to return the most general type that satisfies *both* constraints!
-- meetTypes typ _ = typ

----------------------------------------------------------------
--                            AST Types
----------------------------------------------------------------

-- |Holds everything needed to compile a module
data Module = Module {
  modDirectory :: FilePath,      -- ^The directory the module is in
  modSpec :: ModSpec,            -- ^The module path name 
  modParams :: Maybe [Ident],    -- ^The type parameters, if a type
  modInterface :: ModuleInterface, -- ^The public face of this module
  modImplementation :: Maybe ModuleImplementation, 
                                -- ^the module's implementation
  thisLoadNum :: Int,            -- ^the loadCount when loading this module
  minDependencyNum :: Int,       -- ^the smallest loadNum of all dependencies
  varCount :: Int,               -- ^a per proc counter for introduced variables
  procCount :: Int               -- ^a counter for gensym-ed proc names
  }

-- |Apply the given function to the current module implementation.
updateModImplementation :: (ModuleImplementation -> ModuleImplementation) ->
                          Compiler ()
updateModImplementation fn =
    updateModule
      (\mod -> case modImplementation mod of
            Nothing -> mod
            Just impl -> 
                mod { modImplementation = Just $ fn impl })

-- |Apply the given monadic function to the current module implementation.
updateModImplementationM :: 
    (ModuleImplementation -> Compiler ModuleImplementation) -> Compiler ()
updateModImplementationM fn =
    updateModuleM
      (\mod -> case modImplementation mod of
            Nothing -> return mod
            Just impl -> do
                impl' <- fn impl
                return $ mod { modImplementation = Just impl' })

-- |Apply the given function to the current module interface.
updateModInterface :: (ModuleInterface -> ModuleInterface) ->
                     Compiler ()
updateModInterface fn =
    updateModule (\mod -> mod { modInterface = fn $ modInterface mod })

-- |Holds everything needed to compile code that uses a module
data ModuleInterface = ModuleInterface {
    pubTypes :: Map Ident TypeDef,   -- ^The types this module exports
    pubResources :: Map Ident OptPos,       
                                    -- ^The resources this module exports
    pubProcs :: Map Ident [ProcCallInfo], -- ^The procs this module exports
    pubDependencies :: Map Ident OptPos,    
                                    -- ^The other modules this module exports
    dependencies :: Set Ident        -- ^The other modules that must be linked
    }                               --  in by modules that depend on this one

emptyInterface :: ModuleInterface
emptyInterface = 
    ModuleInterface Map.empty Map.empty Map.empty Map.empty Set.empty

-- These functions hack around Haskell's terrible setter syntax

-- |Update the public types of a module interface.
updatePubTypes :: (Map Ident TypeDef -> Map Ident TypeDef) -> 
                 ModuleInterface -> ModuleInterface
updatePubTypes fn modint = modint {pubTypes = fn $ pubTypes modint}

-- |Update the public resources of a module interface.
updatePubResources :: 
    (Map Ident OptPos -> Map Ident OptPos) -> 
    ModuleInterface -> ModuleInterface
updatePubResources fn modint = modint {pubResources = fn $ pubResources modint}

-- |Update the public procs of a module interface.
updatePubProcs :: (Map Ident [ProcCallInfo] -> Map Ident [ProcCallInfo]) -> 
                 ModuleInterface -> ModuleInterface
updatePubProcs fn modint = modint {pubProcs = fn $ pubProcs modint}

-- |Update the public dependencies of a module interface.
updatePubDependencies :: 
    (Map Ident OptPos -> Map Ident OptPos) -> 
    ModuleInterface -> ModuleInterface
updatePubDependencies fn modint = 
    modint {pubDependencies = fn $ pubDependencies modint}

-- |Update the set of all dependencies of a module interface.
updateDependencies :: (Set Ident -> Set Ident) -> ModuleInterface -> ModuleInterface
updateDependencies fn modint = modint {dependencies = fn $ dependencies modint}


-- |Holds everything needed to compile the module itself
data ModuleImplementation = ModuleImplementation {
    modImports :: Map ModSpec ModDependency, -- ^All modules this module imports
    modSubmods :: Map Ident Module,        -- ^All submodules
    modTypes :: Map Ident TypeDef,         -- ^All types defined by this module
    modResources :: Map Ident ResourceDef, -- ^All resources defined by this mod
    modProcs :: Map Ident [ProcDef]        -- ^All procs defined by this module
    }

emptyImplementation :: ModuleImplementation
emptyImplementation =
    ModuleImplementation Map.empty Map.empty Map.empty Map.empty Map.empty



-- These functions hack around Haskell's terrible setter syntax

-- |Update the dependencies of a module implementation.
updateModImports :: (Map ModSpec ModDependency -> Map ModSpec ModDependency) -> 
                   ModuleImplementation -> ModuleImplementation
updateModImports fn modimp = modimp {modImports = fn $ modImports modimp}

-- |Update the map of submodules of a module implementation.
updateModSubmods :: (Map Ident Module -> Map Ident Module) -> 
                   ModuleImplementation -> ModuleImplementation
updateModSubmods fn modimp = modimp {modSubmods = fn $ modSubmods modimp}

-- |Update the map of types of a module implementation.
updateModTypes :: (Map Ident TypeDef -> Map Ident TypeDef) -> 
                 ModuleImplementation -> ModuleImplementation
updateModTypes fn modimp = modimp {modTypes = fn $ modTypes modimp}

-- |Update the map of resources of a module implementation.
updateModResources :: (Map Ident ResourceDef -> Map Ident ResourceDef) -> 
                     ModuleImplementation -> ModuleImplementation
updateModResources fn modimp = modimp {modResources = fn $ modResources modimp}

-- |Update the map of proc definitions of a module implementation.
updateModProcs :: (Map Ident [ProcDef] -> Map Ident [ProcDef]) -> 
                 ModuleImplementation -> ModuleImplementation
updateModProcs fn modimp = modimp {modProcs = fn $ modProcs modimp}

-- |Update the map of proc definitions of a module implementation.
updateModProcsM :: (Map Ident [ProcDef] -> Compiler (Map Ident [ProcDef])) -> 
                 ModuleImplementation -> Compiler ModuleImplementation
updateModProcsM fn modimp = do
    procs' <- fn $ modProcs modimp
    return $ modimp {modProcs = procs'}

-- |An identifier.
type Ident = String

-- |A variable name.
type VarName = String

-- |A proc name.
type ProcName = String

-- |A module specification, as a list of module names; module a.b.c would
--  be represented as ["a","b","c"].
type ModSpec = [Ident]

-- |The dependencies of one module on another, as a pair of uses and imports.
data ModDependency = ModDependency ImportSpec ImportSpec

-- |The uses or imports of one module on another.  Either nothing, or
--  all the item names to be imported and whether they are to be 
--  reexported, as well as whether the whole module is to be 
--  imported, and whether publicly or not.
data ImportSpec = ImportNothing
                | ImportSpec (Map Ident Visibility) (Maybe Visibility)

-- |Add a single import to an ImportSpec.
addImports :: (Maybe [Ident]) -> Visibility -> ImportSpec -> ImportSpec
addImports Nothing vis ImportNothing = ImportSpec Map.empty $ Just vis
addImports Nothing vis (ImportSpec map Nothing) = 
    ImportSpec map $ Just vis
addImports Nothing vis (ImportSpec map (Just vis')) = 
    ImportSpec map $ Just $ maxVisibility vis vis'
addImports (Just imps) vis (ImportSpec map vis') = 
    ImportSpec (List.foldr (\k -> Map.insert k vis) map imps) vis'
addImports (Just imps) vis ImportNothing = 
    ImportSpec (List.foldr (\k -> Map.insert k vis) Map.empty imps) Nothing

-- |A type definition, including the number of type parameters and an 
--  optional source position.
data TypeDef = TypeDef Int OptPos

-- |The arity of a type definition.
typeDefArity :: TypeDef -> Int
typeDefArity (TypeDef arity _) = arity


-- |A resource definition.  For a normal resource, its type; for a 
--  compound resource, a list of other resources.  In both cases, 
--  there may be an optional source position.
data ResourceDef = CompoundResource [Ident] OptPos
                 | SimpleResource TypeSpec OptPos

-- |The optional position of a resource definition.
resourceDefPosition :: ResourceDef -> OptPos
resourceDefPosition (CompoundResource _ pos) = pos
resourceDefPosition (SimpleResource _ pos) = pos

-- |A proc definition, including the ID, prototype, the body, 
--  normalised to a list of primitives, and an optional source 
--  position. 
data ProcDef = ProcDef {
    procName :: Ident, 
    procProto :: PrimProto, 
    procBody :: [[Placed Prim]],
    procPos :: OptPos}
             deriving Eq

-- |Info about a proc call, including the ID, prototype, and an 
--  optional source position. 
data ProcCallInfo = ProcCallInfo ProcID PrimProto OptPos

-- -- |Make a ProcCallInfo from a ProcDef
-- procCallInfo :: ProcDef -> ProcCallInfo
-- procCallInfo (ProcDef _ proto _ pos) = ProcCallInfo id proto pos

-- |An ID for a proc.
type ProcID = Int

-- |A type specification:  the type name and type parameters.  Also 
--  could be Unspecified, meaning a type to be inferred.
data TypeSpec = TypeSpec {
    typeName::Ident,
    typeParams::[TypeSpec] 
    } | Unspecified
              deriving Eq

-- |A manifest constant.
data Constant = Int Int
              | Float Double
              | Char Char
              | String String
                deriving (Show,Eq)

-- |A proc prototype, including name and formal parameters.
data ProcProto = ProcProto ProcName [Param]
               deriving Eq

-- |A formal parameter, including name, type, and flow direction.
data Param = Param VarName TypeSpec FlowDirection
           deriving Eq

-- |A dataflow direction:  in, out, both, or neither.
data FlowDirection = ParamIn | ParamOut | ParamInOut | NoFlow
                   deriving (Show,Eq)

-- |A primitive dataflow direction:  in or out
data PrimFlow = FlowIn | FlowOut
                   deriving (Show,Eq)

-- |Does this flow direction include input?
flowIn :: FlowDirection -> Bool
flowIn ParamIn = True
flowIn ParamInOut = True
flowIn _ = False

-- |Possible program statements.  These will be normalised into 
--  Prims.
data Stmt
     = ProcCall Ident [Placed Exp]
     | ForeignCall Ident Ident [Placed Exp]
     | Cond (Placed Exp) [Placed Stmt] [Placed Stmt]
     | Loop [Placed Stmt]
     | Guard (Placed Exp) Integer
     | Nop
       -- These are only valid in a loop
     | For Generator
     | BreakIf (Placed Exp)
     | NextIf (Placed Exp)

-- |An expression.  These are all normalised into statements.
data Exp
      = IntValue Integer
      | FloatValue Double
      | StringValue String
      | CharValue Char
      | Var VarName FlowDirection
      | Where [Placed Stmt] (Placed Exp)
      | CondExp (Placed Exp) (Placed Exp) (Placed Exp)
      | Fncall Ident [Placed Exp]
      | ForeignFn String String [Placed Exp]

-- |A loop generator (ie, an iterator).  These need to be 
--  generalised, allowing them to be user-defined.
data Generator
      = In VarName (Placed Exp)
      | InRange VarName (Placed Exp) ProcName (Placed Exp) 
        (Maybe (ProcName,Placed Exp))

-- |A variable name in SSA form, ie, a name and an natural number suffix,
--  where the suffix is used to specify which assignment defines the value.

-- |A primitive proc prototype, including name and formal parameters.
data PrimProto = PrimProto ProcName [PrimParam]
               deriving Eq

instance Show PrimProto where
    show (PrimProto name params) =
        name ++ "(" ++ (intercalate ", " $ List.map show params) ++ ")"

primProto :: ProcProto -> PrimProto
primProto (ProcProto name params) =
    PrimProto name (concat $ List.map primParam params)

-- |A formal parameter, including name, type, and flow direction.
data PrimParam =
  PrimParam {
    paramName :: PrimVarName, 
    paramType :: TypeSpec, 
    paramFlow :: PrimFlow, 
    paramFlowType :: ArgFlowType
    } deriving Eq

-- |Convert a single Param to up to two PrimParams
primParam :: Param -> [PrimParam]
primParam (Param name typ ParamIn) = 
    [PrimParam (PrimVarName name 0) typ FlowIn Ordinary]
primParam (Param name typ ParamOut) = 
    [PrimParam (PrimVarName name (-1)) typ FlowOut Ordinary]
primParam (Param name typ NoFlow) = []
primParam (Param name typ ParamInOut) = 
    [PrimParam (PrimVarName name 0) typ FlowIn FirstHalf,
     PrimParam (PrimVarName name (-1)) typ FlowOut SecondHalf]

-- |How to show a formal parameter.
instance Show PrimParam where
  show (PrimParam name typ dir _) =
    primFlowPrefix dir ++ show name ++ ":" ++ show typ

-- A variable name with an integer suffix to distinguish different 
-- values for the same name.  As a special case, a suffix of -1 
-- specifies the ultimate, final value for that name.
data PrimVarName = 
  PrimVarName {
    primVarName :: VarName, 
    primVarNum :: Int
    } deriving (Eq, Ord)

-- |A primitive statment, including those that can only appear in a 
--  loop.
data Prim
     -- XXX PrimCall should optionally contain a module spec.
     = PrimCall ProcName (Maybe ProcID) [PrimArg]
     | PrimForeign String ProcName (Maybe ProcID) [PrimArg]
     | PrimGuard PrimVarName Integer
     | PrimFail
     | PrimNop
     | PrimLoop [Placed Prim]
     | PrimBreakIf PrimVarName
     | PrimNextIf PrimVarName
     deriving Eq

-- |The allowed arguments in primitive proc or foreign proc calls, 
--  just variables and constants.
data PrimArg 
     = ArgVar PrimVarName PrimFlow ArgFlowType
     | ArgInt Integer
     | ArgFloat Double
     | ArgString String
     | ArgChar Char
     deriving Eq

-- |Relates a primitive argument to the corresponding source argument
data ArgFlowType = Ordinary | FirstHalf | SecondHalf | Implicit
     deriving (Eq, Show)

-- |The dataflow direction of an actual argument.
argFlowDirection :: PrimArg -> PrimFlow
argFlowDirection (ArgVar _ flow _) = flow
argFlowDirection (ArgInt _) = FlowIn
argFlowDirection (ArgFloat _) = FlowIn
argFlowDirection (ArgString _) = FlowIn
argFlowDirection (ArgChar _) = FlowIn

-- |Convert a statement read as an expression to a Stmt.
expToStmt :: Exp -> Stmt
expToStmt (Fncall name args) = ProcCall name args
expToStmt (ForeignFn lang name args) = ForeignCall lang name args



----------------------------------------------------------------
--                      Variables (Uses and Defs)
--
-- Finding uses and defines of primitive bodies is made a lot easier 
-- by single assignment form:  we just need to find all variable uses
-- or definitions.
----------------------------------------------------------------

varsInPrims :: PrimFlow -> [Prim] -> Set PrimVarName
varsInPrims dir prims =
    List.foldr Set.union Set.empty $ List.map (varsInPrim dir) prims

varsInPrim :: PrimFlow -> Prim     -> Set PrimVarName
varsInPrim dir (PrimCall _ _ args)      = varsInPrimArgs dir args
varsInPrim dir (PrimForeign _ _ _ args) = varsInPrimArgs dir args
varsInPrim dir (PrimGuard var _)        = Set.singleton var
varsInPrim dir (PrimFail)               = Set.empty
varsInPrim dir (PrimNop)                = Set.empty
varsInPrim dir (PrimLoop prims)         = varsInPrims dir 
                                          $ List.map content prims
varsInPrim dir (PrimBreakIf var)        = Set.singleton var
varsInPrim dir (PrimNextIf var)         = Set.singleton var

varsInPrimArgs :: PrimFlow -> [PrimArg] -> Set PrimVarName
varsInPrimArgs dir args = 
    List.foldr Set.union Set.empty $ List.map (varsInPrimArg dir) args

varsInPrimArg :: PrimFlow -> PrimArg -> Set PrimVarName
varsInPrimArg dir (ArgVar var dir' _) = 
  if dir == dir' then Set.singleton var else Set.empty
varsInPrimArg _ (ArgInt _)            = Set.empty
varsInPrimArg _ (ArgFloat _)          = Set.empty
varsInPrimArg _ (ArgString _)         = Set.empty
varsInPrimArg _ (ArgChar _)           = Set.empty

varsInProto :: PrimFlow -> PrimProto -> Set PrimVarName
varsInProto dir (PrimProto _ params) =
    List.foldr Set.union Set.empty $ List.map (varsInParam dir) params

varsInParam :: PrimFlow -> PrimParam -> Set PrimVarName
varsInParam dir (PrimParam var _ dir' _) =
  -- invert the flow for prototypes, since the direction is opposite
  if dir == dir' then Set.empty else Set.singleton var


----------------------------------------------------------------
--                            Utilities
----------------------------------------------------------------

maybeApply :: (a -> b) -> Maybe a -> Maybe b
maybeApply f (Just x) = Just $ f x
maybeApply f Nothing = Nothing


----------------------------------------------------------------
--                      Showing Compiler State
----------------------------------------------------------------

-- |How to show an Item.
instance Show Item where
  show (TypeDecl vis name items pos) =
    show vis ++ " type " ++ show name ++ " is" 
    ++ showMaybeSourcePos pos ++ "\n  "
    ++ intercalate "\n  " (List.map show items)
    ++ "\nend\n"
  show (ImportMods vis unqualified mods pos) =
      show vis ++ (if unqualified then " import " else " use ") ++ 
      showModSpecs mods ++ showMaybeSourcePos pos ++ "\n  "
  show (ImportItems vis unqualified mod specs pos) =
      show vis ++ " from " ++ showModSpec mod ++
      (if unqualified then " import " else " use ") ++ intercalate ", " specs
      ++ showMaybeSourcePos pos ++ "\n  "
  show (ModuleDecl vis name items pos) =
    show vis ++ " module " ++ show name ++ " is" 
    ++ showMaybeSourcePos pos ++ "\n  "
    ++ intercalate "\n  " (List.map show items)
    ++ "\nend\n"
  show (ResourceDecl vis name typ pos) =
    show vis ++ " resource " ++ show name ++ ":" ++ show typ
    ++ showMaybeSourcePos pos
  show (FuncDecl vis proto typ exp pos) =
    show vis ++ " func " ++ show proto ++ ":" ++ show typ
    ++ showMaybeSourcePos pos
    ++ " = " ++ show exp
  show (ProcDecl vis proto stmts pos) =
    show vis ++ " proc " ++ show proto
    ++ showMaybeSourcePos pos
    ++ show stmts
  show (CtorDecl vis proto pos) =
    show vis ++ " ctor " ++ show proto
    ++ showMaybeSourcePos pos
  show (StmtDecl stmt pos) =
    show stmt ++ showMaybeSourcePos pos

-- |How to show a ModSpec.
showModSpec :: ModSpec -> String
showModSpec spec = intercalate "." spec

-- |How to show a list of ModSpecs.
showModSpecs :: [ModSpec] -> String
showModSpecs specs = intercalate ", " $ List.map showModSpec specs

-- |How to show a module dependency.
showModDependency :: ModSpec -> ModDependency -> String
showModDependency mod (ModDependency uses imports) =
     showImportOrUse "import" mod imports
     ++ showImportOrUse "use" mod uses

-- |How to show a visibility.
visibilityPrefix :: Visibility -> String
visibilityPrefix Public = "public "
visibilityPrefix Private = ""

-- |How to show an import or use declaration.
showImportOrUse :: String -> ModSpec -> ImportSpec -> String
showImportOrUse _ _ ImportNothing = ""
showImportOrUse directive mod (ImportSpec map vis) =
    (case vis of
        Just vis' -> visibilityPrefix vis' ++ directive ++ " " ++ 
                    showModSpec mod ++ " "
        Nothing -> "") ++
    (let mapKVs = assocs map
         pubs = [k | (k,v) <- mapKVs, v==Public]
         privs = [k | (k,v) <- mapKVs, v==Private]
     in (if List.null pubs then "" else 
             "public from " ++ showModSpec mod ++ " " ++ directive ++ " " ++
             intercalate ", " pubs) ++
        (if List.null privs then "" else 
             "from " ++ showModSpec mod ++ " " ++ directive ++ " " ++
             intercalate ", " privs))

-- |How to show a type prototype.
instance Show TypeProto where
  show (TypeProto name []) = name
  show (TypeProto name args) = name ++ "(" ++ intercalate "," args ++ ")"

-- |How to show a function prototype.
instance Show FnProto where
  show (FnProto name []) = name
  show (FnProto name params) = 
    name ++ "(" ++ intercalate "," (List.map show params) ++ ")"

-- |How to show something that may have a source position
instance Show t => Show (Placed t) where
  show pl = show (content pl) ++ showMaybeSourcePos (place pl)
    
-- |How to show an optional source position
showMaybeSourcePos :: OptPos -> String
showMaybeSourcePos (Just pos) = 
  " {" ++ takeBaseName (sourceName pos) ++ ":" 
  ++ show (sourceLine pos) ++ ":" ++ show (sourceColumn pos) ++ "}"
showMaybeSourcePos Nothing = " {?}"

-- |How to show a module.
instance Show Module where
    show mod =
        let int  = modInterface mod
            maybeimpl = modImplementation mod
        in "\n Module " ++ showModSpec (modSpec mod) ++ 
           maybeShow "(" (modParams mod) ")" ++
           "\n  public submods  : " ++ showMapPoses (pubDependencies int) ++
           "\n  public types    : " ++ showMapTypes (pubTypes int) ++
           "\n  public resources: " ++ showMapPoses (pubResources int) ++
           "\n  public procs    : " ++ 
           intercalate "\n                    " 
           [show proto ++ " <" ++ show id ++ ">" ++ showMaybeSourcePos pos | 
            (ProcCallInfo id proto pos) <- 
                List.concat $ Map.elems $ pubProcs int] ++
           if isNothing maybeimpl then "\n  implementation not available"
           else let impl = fromJust maybeimpl
                in
                 "\n  imports         : " ++
                 intercalate "\n                    " 
                 [showModDependency mod dep | 
                  (mod,dep) <- Map.assocs $ modImports impl] ++
                 "\n  types           : " ++ showMapTypes (modTypes impl) ++
                 "\n  resources       : " ++ showMapLines (modResources impl) ++
                 "\n  procs           : " ++ 
                 (showMap "\n                    " ":" (showProcDefs 0)
                  (modProcs impl)) 
                 ++ "\n" ++
                 "\nSubmodules of " ++ showModSpec (modSpec mod) ++ ":\n" ++ 
                 showMapLines (modSubmods impl)

--showTypeMap :: Map Ident TypeDef -> String

-- |How to show a set of identifiers as a comma-separated list
showIdSet :: Set Ident -> String
showIdSet set = intercalate ", " $ Set.elems set

-- |How to show a map, one line per item.
showMapLines :: Show v => Map Ident v -> String
showMapLines = showMap "\n                    " ": " show

-- |How to show a map, items separated by commas.
showMapTypes :: Map Ident TypeDef -> String
showMapTypes = showMap ", " "/" show

-- |How to show a map to source positions, one line per item.
showMapPoses :: Map Ident OptPos -> String
showMapPoses = showMap ", " "" showMaybeSourcePos

-- |How to show a map from identifiers to values, given a separator 
--  for items, and a separator for keys from values, and a function 
--  to show the values.
showMap :: String -> String -> (v -> String) -> Map Ident v -> String
showMap outersep innersep fn m = intercalate outersep
            $ List.map (\(k,v) -> k ++ innersep ++ fn v) $ Map.assocs m

-- |How to show a type definition.
instance Show TypeDef where
  show (TypeDef arity pos) = show arity ++ showMaybeSourcePos pos

-- |How to show a resource definition.
instance Show ResourceDef where
  show (CompoundResource ids pos) =
    intercalate ", " ids ++ showMaybeSourcePos pos
  show (SimpleResource typ pos) =
    show typ ++ showMaybeSourcePos pos

-- |How to show a list of proc definitions.
showProcDefs :: Int -> [ProcDef] -> String
showProcDefs _ [] = ""
showProcDefs firstID (def:defs) =
    showProcDef firstID def ++ showProcDefs (1+firstID) defs
    
-- |How to show a proc definition.
showProcDef :: Int -> ProcDef -> String
showProcDef thisID (ProcDef _ proto def pos) =
    "\nproc " ++ show proto ++ " (id " ++ show thisID ++ "): "
    ++ showMaybeSourcePos pos 
    ++ intercalate "\n" (List.map (showBlock 4) def)

-- |How to show a type specification.
instance Show TypeSpec where
  show Unspecified = "?"
  show (TypeSpec ident []) = ident
  show (TypeSpec ident args) = 
    ident ++ "(" ++ (intercalate "," $ List.map show args) ++ ")"

-- |How to show a proc prototype.
instance Show ProcProto where
  show (ProcProto name params) = 
    name ++ "(" ++ (intercalate ", " $ List.map show params) ++ ")"

-- |How to show a formal parameter.
instance Show Param where
  show (Param name typ dir) =
    flowPrefix dir ++ name ++ ":" ++ show typ

-- |How to show a dataflow direction.
flowPrefix :: FlowDirection -> String
flowPrefix NoFlow     = ""
flowPrefix ParamIn    = ""
flowPrefix ParamOut   = "?"
flowPrefix ParamInOut = "!"

-- |How to show a *primitive* dataflow direction.
primFlowPrefix :: PrimFlow -> String
primFlowPrefix FlowIn    = ""
primFlowPrefix FlowOut   = "?"

-- |Start a new line with the specified indent.
startLine :: Int -> String
startLine ind = "\n" ++ replicate ind ' '

-- |Show a code block (list of primitive statements) with the
--  specified indent.
showBlock :: Int -> [Placed Prim] -> String
showBlock ind stmts = concat (List.map (showPrim ind) stmts)

-- |Show a single primitive statement with the specified indent.
showPrim :: Int -> Placed Prim -> String
showPrim ind stmt = showPrim' ind (content stmt) (place stmt)

-- |Show a single primitive statement with the specified indent and 
--  optional source position.
showPrim' :: Int -> Prim -> OptPos -> String
showPrim' ind (PrimCall name id args) pos =
  startLine ind ++ name ++ maybeShow "<" id ">"
  ++ "(" ++ intercalate ", " (List.map show args) ++ ")"
  ++ showMaybeSourcePos pos
showPrim' ind (PrimForeign lang name id args) pos =
  startLine ind ++ "foreign " ++ lang ++ " " ++ name ++ maybeShow "<" id ">"
  ++ "(" ++ intercalate ", " (List.map show args) ++ ")"
  ++ showMaybeSourcePos pos
showPrim' ind (PrimGuard var val) pos =
  startLine ind ++ "guard " ++ show var ++ " = " ++ show val
  ++ showMaybeSourcePos pos
showPrim' ind (PrimNop) pos =
  startLine ind ++ "NOP"
  ++ showMaybeSourcePos pos
showPrim' ind (PrimFail) pos =
  startLine ind ++ "FAIL"
  ++ showMaybeSourcePos pos
showPrim' ind (PrimLoop block) pos =
  startLine ind ++ "do " ++ showMaybeSourcePos pos
  ++ showBlock (ind+4) block
  ++ startLine ind ++ "end"
showPrim' ind (PrimBreakIf var) pos =
  startLine ind ++ "until " ++ show var ++ showMaybeSourcePos pos
showPrim' ind (PrimNextIf var) pos =
  startLine ind ++ "unless " ++ show var ++ showMaybeSourcePos pos

-- |Show a variable, with its suffix
instance Show PrimVarName where
    show (PrimVarName var suffix) = var ++ ":" ++ show suffix

-- |Show the cases, numbered from the specified case counter, of a 
--  case primitive, with the specified indent and indent for the 
--  cases.
showCases :: Int -> Int -> Int -> [[Placed Prim]] -> String
showCases _ _ _ [] = ""
showCases num labelInd blockInd (block:blocks) =
  startLine labelInd ++ show num ++ ":"
  ++ showBlock blockInd block
  ++ showCases (num+1) labelInd blockInd blocks

-- |Show a single statement.
instance Show Stmt where
  show (ProcCall name args) =
    name ++ "(" ++ intercalate ", " (List.map show args) ++ ")"
  show (Cond exp thn els) =
    "if" ++ show (content exp) ++ " then"
    ++ show thn
    ++ " else "
    ++ show els
    ++ " end"
  show (Loop lstmts) =
    "do " ++ concat (List.map show lstmts) ++ " end"
  show (Guard exp val) =
    "guard " ++ show (content exp) ++ " " ++ show val
  show (For gen) = "for " ++ show gen
  show (BreakIf cond) = "until " ++ show cond
  show (NextIf cond) = "unless " ++ show cond

-- |Show a primitive argument.
instance Show PrimArg where
  show (ArgVar name dir _) = primFlowPrefix dir ++ show name
  show (ArgInt i) = show i
  show (ArgFloat f) = show f
  show (ArgString s) = show s
  show (ArgChar c) = show c


  
-- |Show a single expression.
instance Show Exp where
  show (IntValue i) = show i
  show (FloatValue f) = show f
  show (StringValue s) = show s
  show (CharValue c) = show c
  show (Var name dir) = (flowPrefix dir) ++ name
  show (Where stmts exp) = show exp ++ " where " ++ show stmts
  show (CondExp cond thn els) = 
    "if " ++ show cond ++ " then " ++ show thn ++ " else " ++ show els
  show (Fncall fn args) = 
    fn ++ "(" ++ intercalate ", " (List.map show args) ++ ")"
  show (ForeignFn lang fn args) = 
    "foreign " ++ lang ++ " " ++ fn 
    ++ "(" ++ intercalate ", " (List.map show args) ++ ")"

-- |Show a single generator.
instance Show Generator where
  show (In var exp) = var ++ " in " ++ show exp
  show (InRange var start updateOp step Nothing) =
    var ++ " from " ++ show start ++ " by " ++ updateOp ++ show step
  show (InRange var start updateOp step (Just end)) =
    show (InRange var start updateOp step Nothing) ++ " to " ++ show end

-- |maybeShow pre maybe pos
--  if maybe has something, show pre, the maybe payload, and post
--  if the maybe is Nothing, don't show anything
maybeShow :: Show t => String -> Maybe t -> String -> String
maybeShow pre Nothing pos = ""
maybeShow pre (Just something) post =
  pre ++ show something ++ post
