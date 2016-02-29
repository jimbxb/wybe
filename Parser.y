{
--  File     : Parser.y
--  Author   : Peter Schachte
--  Origin   : Tue Nov 08 22:23:55 2011
--  Purpose  : Parser for the Wybe language
--  Copyright: © 2011-2012 Peter Schachte.  All rights reserved.

-- |The wybe parser (generated by happy).
module Parser (parse) where
import Scanner
import AST
-- import Text.ParserCombinators.Parsec.Pos
}

%name parse
%tokentype { Token }
%error { parseError }

%token 
      int             { TokInt _ _ }
      float           { TokFloat _ _ }
      char            { TokChar _ _ }
      dstring         { TokString DoubleQuote _ _ }
      bstring         { TokString BackQuote _ _ }
      '='             { TokSymbol "=" _ }
      '+'             { TokSymbol "+" _ }
      '-'             { TokSymbol "-" _ }
      '*'             { TokSymbol "*" _ }
      '/'             { TokSymbol "/" _ }
      '^'             { TokSymbol "^" _ }
      '++'            { TokSymbol "++" _ }
      '<'             { TokSymbol "<" _ }
      '>'             { TokSymbol ">" _ }
      '<='            { TokSymbol "<=" _ }
      '>='            { TokSymbol ">=" _ }
      -- '=='            { TokSymbol "==" _ }
      '/='            { TokSymbol "/=" _ }
      '|'             { TokSymbol "|" _ }
      '..'            { TokSymbol ".." _ }
-- If any other symbol tokens that can be used as funcs or procs are
-- defined here, they need to be added to the defintion of Symbol below
      ','             { TokComma _ }
      ';'             { TokSymbol ";" _ }
      ':'             { TokSymbol ":" _ }
      '::'            { TokSymbol "::" _ }
      '.'             { TokSymbol "." _ }
      '?'             { TokSymbol "?" _ }
      '!'             { TokSymbol "!" _ }
      'public'        { TokIdent "public" _ }
      'test'          { TokIdent "test" _ }
      'resource'      { TokIdent "resource" _ }
      'type'          { TokIdent "type" _ }
      'module'        { TokIdent "module" _ }
      'use'           { TokIdent "use" _ }
      'func'          { TokIdent "func" _ }
      'proc'          { TokIdent "proc" _ }
      'ctor'          { TokIdent "ctor" _ }
      'let'           { TokIdent "let" _ }
      'where'         { TokIdent "where" _ }
      'end'           { TokIdent "end" _ }
      'in'            { TokIdent "in" _ }
      'if'            { TokIdent "if" _ }
      'case'          { TokIdent "case" _ }
      'is'            { TokIdent "is" _ }
      'then'          { TokIdent "then" _ }
      'else'          { TokIdent "else" _ }
      'do'            { TokIdent "do" _ }
      'for'           { TokIdent "for" _ }
      'while'         { TokIdent "while" _ }
      'until'         { TokIdent "until" _ }
      'when'          { TokIdent "when" _ }
      'unless'        { TokIdent "unless" _ }
      'from'          { TokIdent "from" _ }
      'and'           { TokIdent "and" _ }
      'or'            { TokIdent "or" _ }
      'not'           { TokIdent "not" _ }
      'foreign'       { TokIdent "foreign" _ }
      'mod'           { TokIdent "mod" _ }
      ident           { TokIdent _ _ }
      '('             { TokLBracket Paren _ }
      ')'             { TokRBracket Paren _ }
      '['             { TokLBracket Bracket _ }
      ']'             { TokRBracket Bracket _ }
      '{'             { TokLBracket Brace _ }
      '}'             { TokRBracket Brace _ }
      symbol          { TokSymbol _ _ }


%nonassoc 'where' 'let'
%left 'or'
%left 'and'
%left 'not'
%nonassoc 'in' '=' '/='
%left '>' '<' '<=' '>='
-- %nonassoc 'by'
%nonassoc '..'
%right '++'
%left '+' '-'
%left '*' '/' 'mod'
%left '^'
%left NEG
%left '.'
%%

Items :: { [Item] }
    : RevItems                  { reverse $1 }

RevItems :: { [Item] }
    : RevItems Item             { $2:$1 }
    | {- empty -}               { [] }


Item  :: { Item }
    : Visibility 'type' TypeProto  TypeImpln Items 'end'
                                { TypeDecl $1 $3 $4 $5 $ 
				    Just $ tokenPosition $2 }
    -- : Visibility 'type' TypeProto OptRepresentation Items 'end'
    --                             { TypeDecl $1 $3 $4 $5 $ 
    --     			    Just $ tokenPosition $2 }
    | Visibility 'module' ident 'is' Items 'end'
                                { ModuleDecl $1 (identName $3) $5 $ 
				    Just $ tokenPosition $2 }
    | Visibility 'use' ModSpecs
                                { ImportMods $1 $3 $ Just $ tokenPosition $2 }
    | Visibility 'from' ModSpec 'use' Idents
                                { ImportItems $1 $3 $5 $
				    Just $ tokenPosition $2 }
    | Visibility 'resource' ident OptType OptInit
                                { ResourceDecl $1 (identName $3) $4 $5
				    $ Just $ tokenPosition $2 }
    | Visibility 'func' Determinism FnProto OptType '=' Exp
                                { FuncDecl $1 $3 False (content $4) $5 $7
				    $ Just $ tokenPosition $2 }
    | Visibility 'proc' Determinism ProcProto ProcBody
                                { ProcDecl $1 $3 False $4 $5
                                    $ Just $ tokenPosition $2 }
    -- | Visibility 'ctor' FnProto { CtorDecl $1 $3
    --     			    $ Just $ tokenPosition $2 }
    | Stmt                      { StmtDecl (content $1) (place $1) }


TypeProto :: { TypeProto }
    : ident OptIdents           { TypeProto (identName $1) $2 }

OptRepresentation :: { TypeRepresentation }
    : 'is' ident                { identName $2 }
    | {- empty -}               { defaultTypeRepresentation }

TypeImpln :: { TypeImpln }
    : 'is' ident                { TypeRepresentation $ identName $2 }
    | '=' Visibility TypeCtors  { TypeCtors $2 $3 }

TypeCtors :: { [Placed FnProto] }
    : RevTypeCtors              { reverse $1 }

RevTypeCtors :: { [Placed FnProto] }
    : RevTypeCtors '|' FnProto  {  $3 : $1 }
    | FnProto                   { [$1] }


ModSpecs :: { [ModSpec] }
    : RevModSpecList            { reverse $1 }
RevModSpecList :: { [ModSpec] }
    : ModSpec                   { [$1] }
    | RevModSpecList ',' ModSpec
                                { $3:$1 }

ModSpec :: { ModSpec }
    : ident RevModuleTail       { identName $1:reverse $2 }

RevModuleTail :: { ModSpec }
    : {- empty -}               { [] }
    | RevModuleTail '.' ident   { identName $3:$1}

FnProto :: { Placed FnProto }
    : PlacedFuncProcName OptParamList UseResources
                                { fmap (\n -> FnProto n $2 $3) $1 }

FuncProcName :: { String }
    : ident                     { identName $1 }
    | Symbol                    { content $1 }


PlacedFuncProcName :: { Placed String }
    : ident                     { Placed (identName $1) (tokenPosition $1) }
    | Symbol                    { $1 }


Symbol :: { Placed String }
    : '='                       { Placed (symbolName $1) (tokenPosition $1) }
    | '+'                       { Placed (symbolName $1) (tokenPosition $1) }
    | '-'                       { Placed (symbolName $1) (tokenPosition $1) }
    | '*'                       { Placed (symbolName $1) (tokenPosition $1) }
    | '/'                       { Placed (symbolName $1) (tokenPosition $1) }
    | '++'                      { Placed (symbolName $1) (tokenPosition $1) }
    | '<'                       { Placed (symbolName $1) (tokenPosition $1) }
    | '>'                       { Placed (symbolName $1) (tokenPosition $1) }
    | '<='                      { Placed (symbolName $1) (tokenPosition $1) }
    | '>='                      { Placed (symbolName $1) (tokenPosition $1) }
    -- | '=='                      { Placed (symbolName $1) (tokenPosition $1) }
    | '/='                      { Placed (symbolName $1) (tokenPosition $1) }
    | '|'                       { Placed (symbolName $1) (tokenPosition $1) }
    | '..'                      { Placed (symbolName $1) (tokenPosition $1) }
    | 'and'                     { Placed (identName $1) (tokenPosition $1) }
    | 'or'                      { Placed (identName $1) (tokenPosition $1) }
    | 'not'                     { Placed (identName $1) (tokenPosition $1) }
    | '[' ']'                   { Placed "[]" (tokenPosition $1) }
    | '[' '|' ']'               { Placed "[|]" (tokenPosition $1) }
    | '{' '}'                   { Placed "{}" (tokenPosition $1) }
    | symbol                    { Placed (symbolName $1) (tokenPosition $1) }


ProcProto :: { ProcProto }
    : FuncProcName OptProcParamList UseResources
                                { ProcProto $1 $2 $3 }

OptParamList :: { [Param] }
    : {- empty -}               { [] }
    | '(' Params ')'            { $2 }

Params :: { [Param] }
    : RevParams                 { reverse $1 }

RevParams :: { [Param] }
    : Param                     { [$1] }
    | RevParams ',' Param       { $3 : $1 }

Param :: { Param }
    : ident OptType             { Param (identName $1) $2 ParamIn Ordinary }

OptProcParamList :: { [Param] }
    : {- empty -}               { [] }
    | '(' ProcParams ')'        { $2 }

ProcParams :: { [Param] }
    : RevProcParams             { reverse $1 }

RevProcParams :: { [Param] }
    : ProcParam                 { [$1] }
    | RevProcParams ',' ProcParam
                                { $3 : $1 }

ProcParam :: { Param }
    : FlowDirection ident OptType
                                { Param (identName $2) $3 $1 Ordinary}

FlowDirection :: { FlowDirection }
    : {- empty -}               { ParamIn }
    | '?'                       { ParamOut }
    | '!'                       { ParamInOut }

OptType :: { TypeSpec }
    : {- empty -}               { Unspecified }
    | ':' Type                  { $2 }


Type :: { TypeSpec }
    : ident OptTypeList         { TypeSpec [] (identName $1) $2 }

OptTypeList :: { [TypeSpec] }
    : {- empty -}               { [] }
    | '(' Types ')'             { $2 }

Types :: { [TypeSpec] }
    : RevTypes                  { reverse $1 }

RevTypes :: { [TypeSpec] }
    : Type                      { [$1] }
    | RevTypes ',' Type         { $3 : $1 }


OptIdents :: { [String] }
    : {- empty -}               { [] }
    | '(' Idents ')'            { $2 }

Idents :: { [String] }
    : RevIdents                 { reverse $1 }

RevIdents :: { [Ident] }
    : ident                     { [identName $1] }
    | RevIdents ',' ident       { (identName $3):$1 }

Visibility :: { Visibility }
    : {- empty -}               { Private }
    | 'public'                  { Public }

Determinism :: { Determinism }
    : {- empty -}               { Det }
    | 'test'                    { SemiDet }

UseResources :: { [ResourceFlowSpec] }
    : {- empty -}               { [] }
    | 'use' ResourceFlowSpecs       { $2 }


ResourceFlowSpecs :: { [ResourceFlowSpec] }
    :  RevResourceFlowSpecs     { reverse $1 }

RevResourceFlowSpecs :: { [ResourceFlowSpec] }
    : ResourceFlowSpec          { [$1] }
    | RevResourceFlowSpecs ',' ResourceFlowSpec
                                { $3:$1 }

ResourceFlowSpec :: { ResourceFlowSpec }
    : FlowDirection modIdent    { ResourceFlowSpec 
	                          (ResourceSpec (fst $2) (snd $2))
                                  $1 }


modIdent :: { (ModSpec,Ident) }
--    : dottedIdents ident     { ($1,identName $2) }
-- XXX this does not allow module qualified resources
: ident { ([],identName $1) }

dottedIdents :: { [Ident] }
    : {- empty -}               { [] }
    |  ident '.' dottedIdents   { (identName $1:$3) }


ProcBody :: { [Placed Stmt] }
    : Stmts 'end'               { $1 }

Stmts :: { [Placed Stmt] }
    : RevStmts                  { reverse $1 }

RevStmts :: { [Placed Stmt] }
    : Stmt                      { [$1] }
    | RevStmts Stmt             { $2:$1 }

Stmt :: { Placed Stmt }
    : ident                     { Placed (ProcCall [] (identName $1)
					  Nothing [])
                                         (tokenPosition $1)}
    | SimpleExp '=' Exp               { maybePlace (ProcCall [] (symbolName $2)
                                              Nothing [$1, $3])
                                             (place $1) }
    | ident ArgList             { Placed (ProcCall [] (identName $1)
					  Nothing $2)
	                                 (tokenPosition $1) }
    | SimpleExp '.' ident ArgList     { maybePlace (ProcCall [] (identName $3)
					      Nothing ($1:$4))
	                                     (place $1) }
    | SimpleExp '.' ident             { maybePlace (ProcCall [] (identName $3)
					      Nothing [$1])
	                                     (place $1) }
--    | symbol ArgList            { Placed (Fncall [] (symbolName $1) $2)
--	                                 (tokenPosition $1) }
    | 'foreign' ident FuncProcName flags ArgList
                                { Placed (ForeignCall (identName $2)
					  $3 $4 $5)
                                         (tokenPosition $1) }
    -- | 'if' Exp 'then' Stmts Condelse
    --                             { Placed (Cond [] $2 $4 $5)
    --                              (tokenPosition $1) }
    | 'if' IfCases              { Placed $2 (tokenPosition $1) }
    | 'do' Stmts 'end'          { Placed (Loop $2)
                                  (tokenPosition $1) }
    | 'for' Exp 'in' Exp        { Placed (For $2 $4)
                                  (tokenPosition $1) }
    | 'until' Exp               { Placed (Cond [] $2 [Unplaced $ Break]
                                                     [Unplaced $ Nop])
                                  (tokenPosition $1) }
    | 'while' Exp               { Placed (Cond [] $2 [Unplaced $ Nop]
                                                     [Unplaced $ Break])
                                  (tokenPosition $1) }
    | 'unless' Exp              { Placed (Cond [] $2 [Unplaced $ Nop]
                                                     [Unplaced $ Next])
                                         (tokenPosition $1) }
    | 'when' Exp                { Placed (Cond [] $2 [Unplaced $ Next]
					             [Unplaced $ Nop])
                                         (tokenPosition $1) }

IfCases :: { Stmt }
    : Exp '::' Stmts IfCases    { Cond [] $1 $3 [Unplaced $4] }
    | Exp '::' Stmts 'end'      { Cond [] $1 $3 [] }


-- Condelse :: { [Placed Stmt] }
--     : 'else' Stmts 'end'        { $2 }
--     |  'end'                    { [] }


OptInit :: { Maybe (Placed Exp) }
    : {- empty -}               { Nothing }
    | '=' Exp                   { Just $2 }



SimpleExp :: { Placed Exp }
    : Exp '+' Exp               { maybePlace (Fncall [] (symbolName $2)
                                              [$1, $3])
	                                     (place $1) }
    | Exp '-' Exp               { maybePlace (Fncall [] (symbolName $2)
                                              [$1, $3])
                                             (place $1) }
    | Exp '*' Exp               { maybePlace (Fncall [] (symbolName $2)
                                              [$1, $3])
                                             (place $1) }
    | Exp '/' Exp               { maybePlace (Fncall [] (symbolName $2)
                                              [$1, $3])
                                             (place $1) }
    | Exp 'mod' Exp             { maybePlace (Fncall [] (identName $2)
                                              [$1, $3])
                                             (place $1) }
    | Exp '^' Exp               { maybePlace (Fncall [] (symbolName $2)
                                              [$1, $3])
                                             (place $1) }
    | Exp '++' Exp              { maybePlace (Fncall [] (symbolName $2)
                                              [$1, $3])
                                             (place $1) }
    | Exp '<' Exp               { maybePlace (Fncall [] (symbolName $2)
                                              [$1, $3])
                                             (place $1) }
    | Exp '<=' Exp              { maybePlace (Fncall [] (symbolName $2)
                                              [$1, $3])
                                             (place $1) }
    | Exp '>' Exp               { maybePlace (Fncall [] (symbolName $2)
                                              [$1, $3])
                                             (place $1) }
    | Exp '>=' Exp              { maybePlace (Fncall [] (symbolName $2)
                                              [$1, $3])
                                             (place $1) }
    -- | Exp '==' Exp              { maybePlace (Fncall [] (symbolName $2)
    --                                           [$1, $3])
    --                                          (place $1) }
    | Exp '/=' Exp              { maybePlace (Fncall [] (symbolName $2)
                                              [$1, $3])
                                             (place $1) }
   | 'not' Exp                 { Placed (Fncall [] (identName $1) [$2])
	                                 (tokenPosition $1) }
   | Exp 'and' Exp             { maybePlace (Fncall [] (identName $2)
                                             [$1, $3])
	                                     (place $1) }
   | Exp 'or' Exp              { maybePlace (Fncall [] (identName $2)
                                             [$1, $3])
                                            (place $1) }
   | Exp '..' Exp              { maybePlace (Fncall [] (symbolName $2) 
					      [$1, $3, Unplaced $ IntValue 1])
                                            (place $1) }
    | '(' Exp ')'               { Placed (content $2) (tokenPosition $1) }
    | '-' Exp %prec NEG         { Placed (Fncall [] "-" [$2])
	                                 (tokenPosition $1) }
    | int                       { Placed (IntValue $ intValue $1)
	                                 (tokenPosition $1) }
    | float                     { Placed (FloatValue $ floatValue $1)
	                                 (tokenPosition $1) }
    | char                      { Placed (CharValue $ charValue $1)
	                                 (tokenPosition $1) }
    | dstring                   { Placed (StringValue $ stringValue $1)
	                                 (tokenPosition $1) }
    | bstring                   { Placed (StringValue $ stringValue $1)
	                                 (tokenPosition $1) }
    | '?' ident                 { Placed (Var (identName $2) ParamOut Ordinary)
	                                 (tokenPosition $1) }
    | '!' ident                 { Placed (Var (identName $2) 
					  ParamInOut Ordinary)
	                                 (tokenPosition $1) }
    | '[' ']'                   { Placed (Fncall [] "[]" [])
	                                 (tokenPosition $1) }
    | '[' Exp ListTail          { Placed (Fncall [] "[|]" [$2, $3])
	                                 (tokenPosition $1) }
    | '{' '}'                   { Placed (Fncall [] "{}" [])
	                                 (tokenPosition $1) }
    | Exp ':' Type              { maybePlace (Typed (content $1) $3 False)
	                                 (place $1) }
    | ident                     { Placed (Var (identName $1) ParamIn Ordinary)
	                                 (tokenPosition $1) }
    | Exp '=' Exp               { maybePlace (Fncall [] (symbolName $2)
                                              [$1, $3])
                                             (place $1) }
    | ident ArgList             { Placed (Fncall [] (identName $1) $2)
	                                 (tokenPosition $1) }
    | Exp '.' ident ArgList     { maybePlace (Fncall [] (identName $3) ($1:$4))
	                                     (place $1) }
    | Exp '.' ident             { maybePlace (Fncall [] (identName $3) [$1])
	                                     (place $1) }
-- XXX do we /want/ to allow prefix use of operators?
--    | symbol ArgList            { Placed (Fncall [] (symbolName $1) $2)
--	                                 (tokenPosition $1) }
    | 'foreign' ident FuncProcName flags ArgList
                                { Placed (ForeignFn (identName $2)
					  $3 $4 $5)
                                         (tokenPosition $1) }

Exp :: { Placed Exp }
    : 'if' Exp 'then' Exp 'else' Exp
                                { Placed (CondExp $2 $4 $6)
        			         (tokenPosition $1) }
    | 'let' Stmts 'in' Exp      { Placed (Where $2 $4) (tokenPosition $1) }
    | Exp 'where' ProcBody      { maybePlace (Where $3 $1) (place $1) }
    | SimpleExp                 { $1 }



flags :: { [Ident] }
    : revFlags                  { reverse $1 }
    | {- empty -}               { [] }

revFlags :: { [Ident] }
    : ident                     { [identName $1] }
    | revFlags ',' ident        { identName $3:$1 }


--optMod :: { ModSpec }
--    : {- empty -}               { [] }
--    | ModSpec '.'               { $1 }


ListTail :: { Placed Exp }
    : ']'                       { Unplaced (Fncall [] "[]" []) }
    | ',' Exp ListTail          { Unplaced (Fncall [] "[|]" [$2,$3]) }
    | '|' Exp ']'               { $2 }


OptArgList :: { [Placed Exp] }
    : {- empty -}               { [] }
    | '(' ExpList ')'       { $2 }

ArgList :: { [Placed Exp] }
    : '(' ExpList ')'       { $2 }

ExpList :: { [Placed Exp] }
    : RevExpList                { reverse $1 }

RevExpList :: { [Placed Exp] }
    : Exp                       { [$1] }
    | RevExpList ',' Exp        { $3:$1 }

{
parseError :: [Token] -> a
parseError [] = error $ "Parse error at end of file"
parseError (tok:_) = error $ (showPosition (tokenPosition tok)) 
                             ++ ": Parse error"
}
