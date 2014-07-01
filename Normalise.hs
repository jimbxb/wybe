--  File     : Normalise.hs
--  RCS      : $Id$
--  Author   : Peter Schachte
--  Origin   : Fri Jan  6 11:28:23 2012
--  Purpose  : Convert parse tree into AST
--  Copyright: � 2012 Peter Schachte.  All rights reserved.

-- |Support for normalising wybe code as parsed to a simpler form
--  to make compiling easier.
module Normalise (normalise, normaliseItem) where

import AST
import Data.Map as Map
import Data.Set as Set
import Data.List as List
import Data.Maybe
import Control.Monad
import Control.Monad.Trans (lift,liftIO)
import Flatten
import Unbranch


-- |Normalise a list of file items, storing the results in the current module.
normalise :: ([ModSpec] -> Compiler ()) -> [Item] -> Compiler ()
normalise modCompiler items = do
    mapM_ (normaliseItem modCompiler) items
    -- liftIO $ putStrLn "File compiled"
    -- every module imports stdlib
    addImport ["wybe"] (ImportSpec (Just Set.empty) Nothing)
    -- Now generate main proc if needed
    stmts <- getModule stmtDecls 
    unless (List.null stmts)
      $ normaliseItem modCompiler 
            (ProcDecl Private (ProcProto "" [] initResources) 
                          (List.reverse stmts) Nothing)

-- |The resources available at the top level
-- XXX this should be all resources with initial values
initResources :: [ResourceFlowSpec]
-- initResources = [ResourceFlowSpec (ResourceSpec ["wybe"] "io") ParamInOut]
initResources = [ResourceFlowSpec (ResourceSpec ["wybe","io"] "io") ParamInOut]


-- |Normalise a single file item, storing the result in the current module.
normaliseItem :: ([ModSpec] -> Compiler ()) -> Item -> Compiler ()
normaliseItem modCompiler (TypeDecl vis (TypeProto name params) items pos) = do
    ty <- addType name (TypeDef (length params) pos) vis
    let eq1 = ProcDecl Public
              (ProcProto "=" [Param "x" ty ParamOut Ordinary,
                              Param "y" ty ParamIn Ordinary] [])
              [Unplaced $
               ForeignCall "llvm" "move" [] [Unplaced $
                                             Var "y" ParamIn Ordinary,
                                             Unplaced $
                                             Var "x" ParamOut Ordinary]]
              Nothing
    let eq2 = ProcDecl Public
              (ProcProto "=" [Param "y" ty ParamIn Ordinary,
                              Param "x" ty ParamOut Ordinary] [])
              [Unplaced $
               ForeignCall "llvm" "move" [] [Unplaced $
                                             Var "y" ParamIn Ordinary,
                                             Unplaced $
                                             Var "x" ParamOut Ordinary]]
              Nothing
    normaliseSubmodule modCompiler name (Just params) vis pos (eq1:eq2:items)
normaliseItem modCompiler (ModuleDecl vis name items pos) = do
    normaliseSubmodule modCompiler name Nothing vis pos items
normaliseItem _ (ImportMods vis modspecs pos) = do
    mapM_ (\spec -> addImport spec (importSpec Nothing vis)) modspecs
normaliseItem _ (ImportItems vis modspec imports pos) = do
    addImport modspec (importSpec (Just imports) vis)
normaliseItem _ (ResourceDecl vis name typ init pos) =
  addSimpleResource name (SimpleResource typ init pos) vis
normaliseItem modCompiler (FuncDecl vis (FnProto name params resources) 
               resulttype result pos) =
  let flowType = Implicit pos
  in  normaliseItem modCompiler
   (ProcDecl
    vis
    (ProcProto name (params ++ [Param "$" resulttype ParamOut flowType]) 
     resources)
    [maybePlace (ProcCall [] "=" Nothing [Unplaced $ Var "$" ParamOut flowType, result])
     pos]
    pos)
normaliseItem _ item@(ProcDecl _ _ _ _) = do
    (item',tmpCtr) <- flattenProcDecl item
    addProc tmpCtr item'
normaliseItem modCompiler (CtorDecl vis proto pos) = do
    modspec <- getModuleSpec
    Just modparams <- getModuleParams
    addCtor modCompiler vis (last modspec) modparams proto pos
normaliseItem _ (StmtDecl stmt pos) = do
    updateModule (\s -> s { stmtDecls = maybePlace stmt pos : stmtDecls s})


normaliseSubmodule :: ([ModSpec] -> Compiler ()) -> Ident -> 
                      Maybe [Ident] -> Visibility -> OptPos -> 
                      [Item] -> Compiler ()
normaliseSubmodule modCompiler name typeParams vis pos items = do
    dir <- getDirectory
    parentModSpec <- getModuleSpec
    let subModSpec = parentModSpec ++ [name]
    addImport subModSpec (importSpec Nothing vis)
    enterModule dir subModSpec typeParams
    case typeParams of
      Nothing -> return ()
      Just _ ->
        updateImplementation 
        (\imp ->
          let set = Set.singleton $ TypeSpec parentModSpec name []
          in imp { modKnownTypes = Map.insert name set $ modKnownTypes imp })
    normalise modCompiler items
    mods <- exitModule
    unless (List.null mods) $ modCompiler mods
    return ()


-- |Add a contructor for the specified type.
addCtor :: ([ModSpec] -> Compiler ()) -> Visibility -> Ident -> [Ident] ->
           FnProto -> OptPos -> Compiler ()
addCtor modCompiler vis typeName typeParams (FnProto ctorName params _) pos = do
    let typespec = TypeSpec [] typeName $ 
                   List.map (\n->TypeSpec [] n []) typeParams
    let flowType = Implicit pos
    normaliseItem modCompiler
      (FuncDecl Public (FnProto ctorName params []) typespec
       (Unplaced $ Where
        ([Unplaced $ ForeignCall "$" "alloc" []
          [Unplaced $ StringValue typeName, Unplaced $ StringValue ctorName,
           Unplaced $ Var "$rec" ParamOut flowType]]
         ++
         (List.map (\(Param var _ dir paramFlowType) ->
                     (Unplaced $ ForeignCall "$" "mutate" []
                      [Unplaced $ StringValue $ typeName,
                       Unplaced $ StringValue ctorName,
                       Unplaced $ StringValue var,
                       Unplaced $ Var "$rec" ParamInOut flowType,
                       Unplaced $ Var var ParamIn paramFlowType]))
          params))
        (Unplaced $ Var "$rec" ParamIn flowType))
       pos)
    mapM_ (addGetterSetter modCompiler vis typespec ctorName pos) params

-- |Add a getter and setter for the specified type.
addGetterSetter :: ([ModSpec] -> Compiler ()) -> Visibility -> TypeSpec ->
                   Ident -> OptPos -> Param -> Compiler ()
addGetterSetter modCompiler vis rectype ctorName pos
                    (Param field fieldtype _ _) = do
    normaliseItem modCompiler $ FuncDecl vis
      (FnProto field [Param "$rec" rectype ParamIn Ordinary] [])
      fieldtype 
      (Unplaced $ ForeignFn "$" "access" []
       [Unplaced $ StringValue $ typeName rectype,
        Unplaced $ StringValue ctorName,
        Unplaced $ StringValue field,
        Unplaced $ Var "$rec" ParamIn Ordinary])
      pos
    normaliseItem modCompiler $ ProcDecl vis 
      (ProcProto field 
       [Param "$rec" rectype ParamInOut Ordinary,
        Param "$field" fieldtype ParamIn Ordinary] [])
      [Unplaced $ ForeignCall "$" "mutate" []
       [Unplaced $ StringValue $ typeName rectype,
        Unplaced $ StringValue ctorName,
        Unplaced $ StringValue field,
        Unplaced $ Var "$rec" ParamInOut Ordinary,
        Unplaced $ Var "$field" ParamIn Ordinary]]
       pos
