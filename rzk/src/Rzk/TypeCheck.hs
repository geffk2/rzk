{-# OPTIONS_GHC -fno-warn-type-defaults #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE RecordWildCards #-}
module Rzk.TypeCheck where

import Control.Applicative ((<|>))
import Control.Monad.Reader
import Control.Monad.Except
import Data.List (tails, (\\), intercalate, nub, partition, zip4)
import Data.Maybe (fromMaybe, isNothing, catMaybes, mapMaybe)
import Data.Tuple (swap)

import Free.Scoped
import Language.Rzk.Free.Syntax
import qualified Language.Rzk.Syntax as Rzk

import Debug.Trace
import Unsafe.Coerce

defaultTypeCheck
  :: TypeCheck Rzk.VarIdent a
  -> Either (TypeErrorInScopedContext Rzk.VarIdent) a
defaultTypeCheck tc = runExcept (runReaderT tc emptyContext)

data Decl var = Decl
  { declName :: var
  , declType :: TermT var
  , declValue :: Maybe (TermT var)
  }

type Decl' = Decl Rzk.VarIdent

typecheckModulesWithLocation :: [(FilePath, Rzk.Module)] -> TypeCheck Rzk.VarIdent ()
typecheckModulesWithLocation = \case
  [] -> return ()
  m : ms -> do
    decls <- typecheckModuleWithLocation m
    localDeclsPrepared decls $
      typecheckModulesWithLocation ms

typecheckModules :: [Rzk.Module] -> TypeCheck Rzk.VarIdent ()
typecheckModules = \case
  [] -> return ()
  m : ms -> do
    decls <- typecheckModule m
    localDeclsPrepared decls $
      typecheckModules ms

typecheckModuleWithLocation :: (FilePath, Rzk.Module) -> TypeCheck Rzk.VarIdent [Decl']
typecheckModuleWithLocation (path, module_) = do
  traceTypeCheck Normal ("Checking module from " <> path) $ do
    withLocation (LocationInfo { locationFilePath = Just path, locationLine = Nothing }) $
      typecheckModule module_

typecheckModule :: Rzk.Module -> TypeCheck Rzk.VarIdent [Decl']
typecheckModule (Rzk.Module _loc _lang commands) = go 1 commands
  where
    totalCommands = length commands

    go :: Integer -> [Rzk.Command] -> TypeCheck Rzk.VarIdent [Decl']
    go _i [] = return []

    go  i (command@(Rzk.CommandUnsetOption _loc optionName) : moreCommands) = do
      traceTypeCheck Normal ("[ " <> show i <> " out of " <> show totalCommands <> " ]"
          <> " Unsetting option " <> optionName) $ do
        withCommand command $ do
          unsetOption optionName $
            go (i + 1) moreCommands

    go  i (command@(Rzk.CommandSetOption _loc optionName optionValue) : moreCommands) = do
      traceTypeCheck Normal ("[ " <> show i <> " out of " <> show totalCommands <> " ]"
          <> " Setting option " <> optionName <> " = " <> optionValue ) $ do
        withCommand command $ do
          setOption optionName optionValue $
            go (i + 1) moreCommands

    go  i (command@(Rzk.CommandDefine _loc name params ty term) : moreCommands) =
      traceTypeCheck Normal ("[ " <> show i <> " out of " <> show totalCommands <> " ]"
          <> " Checking #define " <> show (Pure name :: Term') ) $ do
        withCommand command $ do
          paramDecls <- concat <$> mapM paramToParamDecl params
          ty' <- typecheck (toTerm' (addParamDecls paramDecls ty)) universeT >>= whnfT -- >>= pure . termIsWHNF
          term' <- typecheck (toTerm' (addParams params term)) ty' >>= whnfT >>= pure . termIsWHNF
          let decl = Decl name ty' (Just term')
          fmap (decl :) $
            localDeclPrepared decl $ do
              Context{..} <- ask
              termSVG <- if renderSVG then renderTermSVG (Pure name) else pure Nothing
              maybe id trace termSVG $ do
                go (i + 1) moreCommands

    go  i (command@(Rzk.CommandPostulate _loc name params ty) : moreCommands) =
      traceTypeCheck Normal ("[ " <> show i <> " out of " <> show totalCommands <> " ]"
          <> " Checking #postulate " <> show (Pure name :: Term') ) $ do
        withCommand command $ do
          paramDecls <- concat <$> mapM paramToParamDecl params
          ty' <- typecheck (toTerm' (addParamDecls paramDecls ty)) universeT >>= whnfT -- >>= pure . termIsWHNF
          let decl = Decl name ty' Nothing
          fmap (decl :) $
            localDeclPrepared decl $
              go (i + 1) moreCommands

    go  i (command@(Rzk.CommandCheck _loc term ty) : moreCommands) =
      traceTypeCheck Normal ("[ " <> show i <> " out of " <> show totalCommands <> " ]"
          <> " Checking " <> Rzk.printTree term <> " : " <> Rzk.printTree ty ) $ do
        withCommand command $ do
          ty' <- typecheck (toTerm' ty) universeT >>= whnfT -- >>= pure . termIsWHNF
          _term' <- typecheck (toTerm' term) ty'
          go (i + 1) moreCommands

    go  i (Rzk.CommandCompute loc term : moreCommands) =
      go i (Rzk.CommandComputeWHNF loc term : moreCommands)

    go  i (command@(Rzk.CommandComputeNF _loc term) : moreCommands) =
      traceTypeCheck Normal ("[ " <> show i <> " out of " <> show totalCommands <> " ]"
          <> " Computing NF for " <> Rzk.printTree term) $ do
        withCommand command $ do
          term' <- infer (toTerm' term) >>= nfT
          traceTypeCheck Normal ("  " <> show (untyped term')) $ do
            go (i + 1) moreCommands

    go  i (command@(Rzk.CommandComputeWHNF _loc term) : moreCommands) =
      traceTypeCheck Normal ("[ " <> show i <> " out of " <> show totalCommands <> " ]"
          <> " Computing WHNF for " <> Rzk.printTree term) $ do
        withCommand command $ do
          term' <- infer (toTerm' term) >>= whnfT
          traceTypeCheck Normal ("  " <> show (untyped term')) $ do
            go (i + 1) moreCommands

setOption :: String -> String -> TypeCheck var a -> TypeCheck var a
setOption "verbosity" = \case
  "debug"   -> localVerbosity Debug
  "normal"  -> localVerbosity Normal
  "silent"  -> localVerbosity Silent
  _ -> const $
    issueTypeError $ TypeErrorOther "unknown verbosity level (use \"debug\", \"normal\", or \"silent\")"
setOption optionName = const $ const $
  issueTypeError $ TypeErrorOther ("unknown option " <> show optionName)

unsetOption :: String -> TypeCheck var a -> TypeCheck var a
unsetOption "verbosity" = localVerbosity (verbosity emptyContext)
unsetOption optionName = const $
  issueTypeError $ TypeErrorOther ("unknown option " <> show optionName)

paramToParamDecl :: Rzk.Param -> TypeCheck var [Rzk.ParamDecl]
paramToParamDecl (Rzk.ParamPatternShape loc pat cube tope) = pure [Rzk.ParamVarShape loc pat cube tope]
paramToParamDecl (Rzk.ParamPatternType loc pats ty) = pure $ map (\pat -> Rzk.ParamVarType loc pat ty) pats
paramToParamDecl Rzk.ParamPattern{} = issueTypeError $
  TypeErrorOther "untyped pattern in parameters"

addParamDecls :: [Rzk.ParamDecl] -> Rzk.Term -> Rzk.Term
addParamDecls [] = id
addParamDecls (paramDecl : paramDecls)
  = Rzk.TypeFun Nothing paramDecl . addParamDecls paramDecls

addParams :: [Rzk.Param] -> Rzk.Term -> Rzk.Term
addParams [] = id
addParams params = Rzk.Lambda Nothing params

data TypeError var
  = TypeErrorOther String
  | TypeErrorUnify (TermT var) (TermT var) (TermT var)
  | TypeErrorUnifyTerms (TermT var) (TermT var)
  | TypeErrorNotPair (TermT var) (TermT var)
  | TypeErrorNotFunction (TermT var) (TermT var)
  | TypeErrorUnexpectedLambda (Term var) (TermT var)
  | TypeErrorUnexpectedPair (Term var) (TermT var)
  | TypeErrorUnexpectedRefl (Term var) (TermT var)
  | TypeErrorCannotInferBareLambda (Term var)
  | TypeErrorCannotInferBareRefl (Term var)
  | TypeErrorUndefined var
  | TypeErrorTopeNotSatisfied [TermT var] (TermT var)
  | TypeErrorTopesNotEquivalent (TermT var) (TermT var)
  | TypeErrorInvalidArgumentType (Term var) (TermT var)
  | TypeErrorDuplicateTopLevel Rzk.VarIdent
  deriving (Functor, Foldable)

data TypeErrorInContext var = TypeErrorInContext
  { typeErrorError   :: TypeError var
  , typeErrorContext :: Context var
  } deriving (Functor, Foldable)

data TypeErrorInScopedContext var
  = PlainTypeError (TypeErrorInContext var)
  | ScopedTypeError (Maybe Rzk.VarIdent) (TypeErrorInScopedContext (Inc var))
  deriving (Functor, Foldable)

type TypeError' = TypeError Rzk.VarIdent

ppTypeError' :: TypeError' -> String
ppTypeError' = \case
  TypeErrorOther msg -> msg
  TypeErrorUnify term expected actual -> unlines
    [ "cannot unify expected type"
    , "  " <> show (untyped expected)
    , "with actual type"
    , "  " <> show (untyped actual)
    , "for term"
    , "  " <> show (untyped term) ]
  TypeErrorUnifyTerms expected actual -> unlines
    [ "cannot unify term"
    , "  " <> show (untyped expected)
    , "with term"
    , "  " <> show (untyped actual) ]
  TypeErrorNotPair term ty -> unlines
    [ "expected a cube product or dependent pair"
    , "but got type"
    , "  " <> show (untyped ty)
    , "for term"
    , "  " <> show (untyped term)
    , case ty of
        TypeFunT{} -> "\nPerhaps the term is applied to too few arguments?"
        _ -> ""
    ]

  TypeErrorUnexpectedLambda term ty -> unlines
    [ "unexpected lambda abstraction"
    , "  " <> show term
    , "when typechecking against a non-function type"
    , "  " <> show ty
    ]
  TypeErrorUnexpectedPair term ty -> unlines
    [ "unexpected pair"
    , "  " <> show term
    , "when typechecking against a type that is not a product or a dependent sum"
    , "  " <> show ty
    ]
  TypeErrorUnexpectedRefl term ty -> unlines
    [ "unexpected refl"
    , "  " <> show term
    , "when typechecking against a type that is not an identity type"
    , "  " <> show ty
    ]

  TypeErrorNotFunction term ty -> unlines
    [ "expected a function or extension type"
    , "but got type"
    , "  " <> show (untyped ty)
    , "for term"
    , "  " <> show (untyped term)
    , case term of
        AppT _ty f _x -> "\nPerhaps the term\n  " <> show (untyped f) <> "\nis applied to too many arguments?"
        _ -> ""
    ]
  TypeErrorCannotInferBareLambda term -> unlines
    [ "cannot infer the type of the argument"
    , "in lambda abstraction"
    , "  " <> show term
    ]
  TypeErrorCannotInferBareRefl term -> unlines
    [ "cannot infer the type of term"
    , "  " <> show term
    ]
  TypeErrorUndefined var -> unlines
    [ "undefined variable: " <> show (Pure var :: Term') ]
  TypeErrorTopeNotSatisfied topes tope -> unlines
    [ "local context is not included in (does not entail) the tope"
    , "  " <> show (untyped tope)
    , "in local context (normalised)"
    , intercalate "\n" (map ("  " <>) (map show topes))
    , intercalate "\n" (map ("  " <>) (map show (generateTopesForPoints (allTopePoints tope))))] -- FIXME: remove
  TypeErrorTopesNotEquivalent expected actual -> unlines
    [ "expected tope"
    , "  " <> show (untyped expected)
    , "but got"
    , "  " <> show (untyped actual) ]

  TypeErrorInvalidArgumentType argType argKind -> unlines
    [ "invalid function parameter type"
    , "  " <> show argType
    , "function parameter can be a cube, a shape, or a type"
    , "but given parameter type has type"
    , "  " <> show (untyped argKind)
    ]

  TypeErrorDuplicateTopLevel name -> unlines
    [ "duplicate top-level definition"
    , "  " <> Rzk.printTree name
    ]

ppTypeErrorInContext :: TypeErrorInContext Rzk.VarIdent -> String
ppTypeErrorInContext TypeErrorInContext{..} = intercalate "\n"
  [ ppContext' typeErrorContext
  , ppTypeError' typeErrorError
  ]

ppTypeErrorInScopedContextWith'
  :: [Rzk.VarIdent]
  -> [Rzk.VarIdent]
  -> TypeErrorInScopedContext Rzk.VarIdent
  -> String
ppTypeErrorInScopedContextWith' used vars = \case
  PlainTypeError err -> ppTypeErrorInContext err
  ScopedTypeError orig err -> withFresh orig $ \(x, xs) ->
    ppTypeErrorInScopedContextWith' (x:used) xs $ fmap (g x) err
  where
    g x Z = x
    g _ (S y) = y

    withFresh Nothing f =
      case vars of
        x:xs -> f (x, xs)
        _ -> panicImpossible "not enough fresh variables"
    withFresh (Just z) f = f (z', filter (/= z') vars)    -- FIXME: very inefficient filter
      where
        z' = refreshVar used z -- FIXME: inefficient

ppTypeErrorInScopedContext' :: TypeErrorInScopedContext Rzk.VarIdent -> String
ppTypeErrorInScopedContext' err = ppTypeErrorInScopedContextWith' vars (defaultVarIdents \\ vars) err
  where
    vars = nub (foldMap pure err)

issueTypeError :: TypeError var -> TypeCheck var a
issueTypeError err = do
  context <- ask
  throwError $ PlainTypeError $ TypeErrorInContext
    { typeErrorError = err
    , typeErrorContext = context
    }

panicImpossible :: String -> a
panicImpossible msg = error $ unlines
  [ "PANIC! Impossible happened (" <> msg <> ")!"
  , "Please, report a bug at https://github.com/fizruk/rzk/issues"
    -- TODO: add details and/or instructions how to produce an artifact for reproducing
  ]

data Action var
  = ActionTypeCheck (Term var) (TermT var)
  | ActionUnify (TermT var) (TermT var) (TermT var)
  | ActionUnifyTerms (TermT var) (TermT var)
  | ActionInfer (Term var)
  | ActionContextEntailedBy [TermT var] (TermT var)
  | ActionContextEntails [TermT var] (TermT var)
  | ActionContextEquiv [TermT var] [TermT var]
  | ActionWHNF (TermT var)
  | ActionNF (TermT var)
  | ActionCheckCoherence (TermT var, TermT var) (TermT var, TermT var)
  deriving (Functor, Foldable)

type Action' = Action Rzk.VarIdent

ppTermInContext :: Eq var => TermT var -> TypeCheck var String
ppTermInContext term =  do
  Context{..} <- ask
  return (show (untyped (toRzkVarIdent varOrigs <$> term)))
  where
    vars = nub (foldMap pure term)
    mapping = zip vars defaultVarIdents
    toRzkVarIdent origs var = fromMaybe (Rzk.VarIdent "_") $
      join (lookup var origs) <|> lookup var mapping

ppSomeAction :: Eq var => [(var, Maybe Rzk.VarIdent)] -> Int -> Action var -> String
ppSomeAction origs n action = ppAction n (toRzkVarIdent <$> action)
  where
    vars = nub (foldMap pure action)
    mapping = zip vars defaultVarIdents
    toRzkVarIdent var = fromMaybe (Rzk.VarIdent "_") $
      join (lookup var origs) <|> lookup var mapping

ppAction :: Int -> Action' -> String
ppAction n = unlines . map (replicate (2 * n) ' ' <>) . \case
  ActionTypeCheck term ty ->
    [ "typechecking"
    , "  " <> show term
    , "against type"
    , "  " <> show (untyped ty) ]

  ActionUnify term expected actual ->
    [ "unifying expected type"
    , "  " <> show (untyped expected)
    , "with actual type"
    , "  " <> show (untyped actual)
    , "for term"
    , "  " <> show (untyped term) ]

  ActionUnifyTerms expected actual ->
    [ "unifying term"
    , "  " <> show expected
    , "with term"
    , "  " <> show actual ]

  ActionInfer term ->
    [ "inferring type for term"
    , "  " <> show term ]

  ActionContextEntailedBy ctxTopes term ->
    [ "checking if local context"
    , intercalate "\n" (map (("  " <>) . show . untyped) ctxTopes)
    , "includes (is entailed by) restriction tope"
    , "  " <> show (untyped term) ]

  ActionContextEntails ctxTopes term ->
    [ "checking if local context"
    , intercalate "\n" (map (("  " <>) . show . untyped) ctxTopes)
    , "is included in (entails) the tope"
    , "  " <> show (untyped term) ]

  ActionContextEquiv ctxTopes terms ->
    [ "checking if local context"
    , intercalate "\n" (map (("  " <>) . show . untyped) ctxTopes)
    , "is equivalent to the union of the topes"
    , intercalate "\n" (map (("  " <>) . show . untyped) terms) ]

  ActionWHNF term ->
    [ "computing WHNF for term"
    , "  " <> show term ]

  ActionNF term ->
    [ "computing normal form for term"
    , "  " <> show (untyped term) ]

  ActionCheckCoherence (ltope, lterm) (rtope, rterm) ->
    [ "checking coherence for"
    , "  " <> show (untyped ltope)
    , "  |-> " <> show (untyped lterm)
    , "and"
    , "  " <> show (untyped rtope)
    , "  |-> " <> show (untyped rterm) ]


traceAction' :: Int -> Action' -> a -> a
traceAction' n action = trace ("[debug]\n" <> ppAction n action)

unsafeTraceAction' :: Int -> Action var -> a -> a
unsafeTraceAction' n = traceAction' n . unsafeCoerce

data LocationInfo = LocationInfo
  { locationFilePath  :: Maybe FilePath
  , locationLine      :: Maybe Int
  }

data Verbosity
  = Debug
  | Normal
  | Silent
  deriving (Eq, Ord)

trace' :: Verbosity -> Verbosity -> String -> a -> a
trace' msgLevel currentLevel
  | currentLevel <= msgLevel = trace
  | otherwise                = const id

traceTypeCheck :: Verbosity -> String -> TypeCheck var a -> TypeCheck var a
traceTypeCheck msgLevel msg tc = do
  Context{..} <- ask
  trace' msgLevel verbosity msg tc

localVerbosity :: Verbosity -> TypeCheck var a -> TypeCheck var a
localVerbosity v = local $ \Context{..} -> Context { verbosity = v, .. }

data Covariance
  = Covariant     -- ^ Positive position.
  | Contravariant -- ^ Negative position

data Context var = Context
  { varTypes          :: [(var, TermT var)]
  , varValues         :: [(var, Maybe (TermT var))]
  , varOrigs          :: [(var, Maybe Rzk.VarIdent)]
  , localTopes        :: [TermT var]
  , localTopesNF      :: [TermT var]
  , localTopesNFUnion :: [[TermT var]]
  , localTopesEntailBottom  :: Bool
  , actionStack       :: [Action var]
  , currentCommand    :: Maybe Rzk.Command
  , location          :: Maybe LocationInfo
  , verbosity         :: Verbosity
  , covariance        :: Covariance
  , renderSVG         :: Bool
  } deriving (Functor, Foldable)

emptyContext :: Context var
emptyContext = Context
  { varTypes = []
  , varValues = []
  , varOrigs = []
  , localTopes = []
  , localTopesNF = []
  , localTopesNFUnion = [[]]
  , localTopesEntailBottom = False
  , actionStack = []
  , currentCommand = Nothing
  , location = Nothing
  , verbosity = Normal
  , covariance = Covariant
  , renderSVG = True -- FIXME: make false by default
  }

ppContext' :: Context Rzk.VarIdent -> String
ppContext' Context{..} = unlines
  [ "Definitions in context:"
  , unlines
      [ show (Pure x :: Term') <> " : " <> show (untyped ty)
      | (x, ty) <- reverse varTypes ]
--  , unlines
--      [ show (Pure x :: Term') <> " = " <> show (untyped term)
--      | (x, Just term) <- reverse varValues ]
  , intercalate "\n" (map (("when " <>) . ppAction 0) (reverse actionStack))
  , "Local tope context:"
  , intercalate "\n" (map (("  " <>) . show . untyped) localTopes)
  , case location of
      Just (LocationInfo (Just path) _) -> "\n" <> path <> ":"
      _ -> ""
  , case currentCommand of
      Just (Rzk.CommandDefine _loc name _params _ty _term) ->
        "  Error occurred when checking\n    #define " <> show (Pure name :: Term')
      Just (Rzk.CommandPostulate _loc name _params _ty ) ->
        "  Error occurred when checking\n    #postulate " <> show (Pure name :: Term')
      Just (Rzk.CommandCheck _loc term ty) ->
        "  Error occurred when checking\n    " <> Rzk.printTree term <> " : " <> Rzk.printTree ty
      Just (Rzk.CommandCompute _loc term) ->
        "  Error occurred when computing\n    " <> Rzk.printTree term
      Just (Rzk.CommandComputeNF _loc term) ->
        "  Error occurred when computing NF for\n    " <> Rzk.printTree term
      Just (Rzk.CommandComputeWHNF _loc term) ->
        "  Error occurred when computing WHNF for\n    " <> Rzk.printTree term
      Just (Rzk.CommandSetOption _loc optionName _optionValue) ->
        "  Error occurred when trying to set option\n    #set-option " <> show optionName
      Just (Rzk.CommandUnsetOption _loc optionName) ->
        "  Error occurred when trying to unset option\n    #unset-option " <> show optionName
      Nothing -> ""
--  , "Local tope context (expanded):"
--  , intercalate "\n" (map (("  " <>) . show . untyped) (intercalate [TopeAndT topeT topeBottomT topeBottomT] (saturateTopes [] <$> simplifyLHS localTopes)))
  ]

doesShadowName :: Rzk.VarIdent -> TypeCheck var Bool
doesShadowName name = asks $ \Context{..} ->
  name `elem` mapMaybe snd varOrigs

checkTopLevelDuplicate :: Rzk.VarIdent -> TypeCheck var ()
checkTopLevelDuplicate name = do
  doesShadowName name >>= \case
    True -> issueTypeError (TypeErrorDuplicateTopLevel name)
    False -> return ()

checkNameShadowing :: Rzk.VarIdent -> TypeCheck var ()
checkNameShadowing name = do
  doesShadowName name >>= \case
    True -> do
      trace ("Warning: " <> Rzk.printTree name <> " shadows an existing definition") $
        return ()
    False -> return ()

withLocation :: LocationInfo -> TypeCheck var a -> TypeCheck var a
withLocation loc = local $ \Context{..} -> Context { location = Just loc, .. }

withCommand :: Rzk.Command -> TypeCheck var a -> TypeCheck var a
withCommand command = local $ \Context{..} -> Context { currentCommand = Just command, .. }

localDecls :: [Decl Rzk.VarIdent] -> TypeCheck Rzk.VarIdent a -> TypeCheck Rzk.VarIdent a
localDecls [] = id
localDecls (decl : decls) = localDecl decl . localDecls decls

localDeclsPrepared :: [Decl Rzk.VarIdent] -> TypeCheck Rzk.VarIdent a -> TypeCheck Rzk.VarIdent a
localDeclsPrepared [] = id
localDeclsPrepared (decl : decls) = localDeclPrepared decl . localDeclsPrepared decls

localDecl :: Decl Rzk.VarIdent -> TypeCheck Rzk.VarIdent a -> TypeCheck Rzk.VarIdent a
localDecl (Decl x ty term) tc = do
  ty' <- whnfT ty
  term' <- traverse whnfT term
  localDeclPrepared (Decl x ty' term') tc

localDeclPrepared :: Decl Rzk.VarIdent -> TypeCheck Rzk.VarIdent a -> TypeCheck Rzk.VarIdent a
localDeclPrepared (Decl x ty term) tc = do
  checkTopLevelDuplicate x
  local update tc
  where
    update Context{..} = Context
      { varTypes = (x, ty) : varTypes
      , varValues = (x, term) : varValues
      , varOrigs = (x, Just x) : varOrigs
      , .. }

type TypeCheck var = ReaderT (Context var) (Except (TypeErrorInScopedContext var))

showSomeTermTs :: Eq var => [TermT var] -> String
showSomeTermTs terms = show [ untyped (rename <$> term) | term <- terms ]
  where
    vars = nub (foldMap (foldMap pure) terms)
    mapping = zip vars defaultVarIdents
    rename x = fromMaybe (Rzk.VarIdent "?") (lookup x mapping)

traceStartAndFinish :: Show a => String -> a -> a
traceStartAndFinish tag = trace ("start [" <> tag <> "]") .
  (\x -> trace ("finish [" <> tag <> "] with " <> show x) x)

entail :: Eq var => [TermT var] -> TermT var -> Bool
entail topes tope = all (`solveRHS` tope) $
  saturateTopes (allTopePoints tope) <$>
    simplifyLHS topes'
  where
    topes' = nubTermT (topes <> generateTopesForPoints (allTopePoints tope))

nubTermT :: Eq var => [TermT var] -> [TermT var]
nubTermT [] = []
nubTermT (t:ts) = t : nubTermT (filter (/= t) ts)

saturateTopes :: Eq var => [TermT var] -> [TermT var] -> [TermT var]
saturateTopes _points topes = saturateWith
  (\tope ts -> tope `elem` ts)
  generateTopes
  topes

-- FIXME: cleanup
saturateWith :: (a -> [a] -> Bool) -> ([a] -> [a] -> [a]) -> [a] -> [a]
saturateWith elem' step zs = go (nub' zs) []
  where
    go lastNew xs
      | null new = lastNew
      | otherwise = lastNew <> go new xs'
      where
        xs' = lastNew <> xs
        new = filter (not . (`elem'` xs')) (nub' $ step lastNew xs)
    nub' [] = []
    nub' (x:xs) = x : nub' (filter (not . (`elem'` [x])) xs)

generateTopes :: Eq var => [TermT var] -> [TermT var] -> [TermT var]
generateTopes newTopes oldTopes
  | topeBottomT `elem` newTopes = []
  | topeEQT cube2_0T cube2_1T `elem` newTopes = [topeBottomT]
  | otherwise = concat
      [  -- symmetry EQ
        [ topeEQT y x | TopeEQT _ty x y <- newTopes ]
        -- transitivity EQ (1)
      , [ topeEQT x z
        | TopeEQT _ty x y : newTopes' <- tails newTopes
        , TopeEQT _ty y' z <- newTopes' <> oldTopes
        , y == y' ]
        -- transitivity EQ (2)
      , [ topeEQT x z
        | TopeEQT _ty y z : newTopes' <- tails newTopes
        , TopeEQT _ty x y' <- newTopes' <> oldTopes
        , y == y' ]

        -- transitivity LEQ (1)
      , [ topeLEQT x z
        | TopeLEQT _ty x y : newTopes' <- tails newTopes
        , TopeLEQT _ty y' z <- newTopes' <> oldTopes
        , y == y' ]
        -- transitivity LEQ (2)
      , [ topeLEQT x z
        | TopeLEQT _ty y z : newTopes' <- tails newTopes
        , TopeLEQT _ty x y' <- newTopes' <> oldTopes
        , y == y' ]

        -- antisymmetry LEQ
      , [ topeEQT x y
        | TopeLEQT _ty x y : newTopes' <- tails newTopes
        , TopeLEQT _ty y' x' <- newTopes' <> oldTopes
        , y == y'
        , x == x' ]

        -- FIXME: special case of substitution of EQ
        -- transitivity EQ-LEQ (1)
      , [ topeLEQT x z
        | TopeEQT  _ty y z : newTopes' <- tails newTopes
        , TopeLEQT _ty x y' <- newTopes' <> oldTopes
        , y == y' ]
  
        -- FIXME: special case of substitution of EQ
        -- transitivity EQ-LEQ (2)
      , [ topeLEQT x z
        | TopeEQT  _ty x y : newTopes' <- tails newTopes
        , TopeLEQT _ty y' z <- newTopes' <> oldTopes
        , y == y' ]
  
        -- FIXME: special case of substitution of EQ
        -- transitivity EQ-LEQ (3)
      , [ topeLEQT x z
        | TopeLEQT  _ty y z : newTopes' <- tails newTopes
        , TopeEQT _ty x y' <- newTopes' <> oldTopes
        , y == y' ]
  
        -- FIXME: special case of substitution of EQ
        -- transitivity EQ-LEQ (4)
      , [ topeLEQT x z
        | TopeLEQT  _ty x y : newTopes' <- tails newTopes
        , TopeEQT _ty y' z <- newTopes' <> oldTopes
        , y == y' ]

        -- FIXME: consequence of LEM for LEQ and antisymmetry for LEQ
      , [ topeEQT x y | TopeLEQT _ty x y@Cube2_0T{} <- newTopes ]
        -- FIXME: consequence of LEM for LEQ and antisymmetry for LEQ
      , [ topeEQT x y | TopeLEQT _ty x@Cube2_1T{} y <- newTopes ]
      ]

generateTopesForPoints :: Eq var => [TermT var] -> [TermT var]
generateTopesForPoints points = nubTermT $ concat
  [ [ topeOrT (topeLEQT x y) (topeLEQT y x)
    | x : points' <- tails points, y <- points'
    , x /= y
    , x `notElem` [cube2_0T, cube2_1T]
    , y `notElem` [cube2_0T, cube2_1T] ]
  ]

allTopePoints :: Eq var => TermT var -> [TermT var]
allTopePoints = nubTermT . foldMap subPoints . nubTermT . topePoints

topePoints :: TermT var -> [TermT var]
topePoints = \case
  TopeTopT{} -> []
  TopeBottomT{} -> []
  TopeAndT _ l r -> topePoints l <> topePoints r
  TopeOrT  _ l r -> topePoints l <> topePoints r
  TopeEQT  _ x y -> [x, y]
  TopeLEQT _ x y -> [x, y]
  _ -> []

subPoints :: TermT var -> [TermT var]
subPoints = \case
  p@(PairT _ x y) -> p : foldMap subPoints [x, y]
  p@Pure{} -> [p]
  p@(Free (AnnF TypeInfo{..} _))
    | Cube2T{} <- infoType -> [p]
  _ -> []

simplifyLHS :: Eq var => [TermT var] -> [[TermT var]]
simplifyLHS topes = map nubTermT $
  case topes of
    [] -> [[]]
    TopeTopT{} : topes' -> simplifyLHS topes'
    TopeBottomT{} : _  -> [[topeBottomT]]
    TopeAndT _ l r : topes' -> simplifyLHS (l : r : topes')
    TopeOrT  _ l r : topes' -> simplifyLHS (l : topes') <> simplifyLHS (r : topes')
    TopeEQT  _ (PairT _ x y) (PairT _ x' y') : topes' ->
      simplifyLHS (topeEQT x x' : topeEQT y y' : topes')
    t : topes' -> map (t:) (simplifyLHS topes')

solveRHS :: Eq var => [TermT var] -> TermT var -> Bool
solveRHS topes tope =
  case tope of
    _ | topeBottomT `elem` topes -> True
    TopeTopT{}     -> True
    TopeEQT  _ty (PairT _ty1 x y) (PairT _ty2 x' y')
      | solveRHS topes (topeEQT x x') && solveRHS topes (topeEQT y y') -> True
    TopeEQT  _ty l r -> or
      [ l == r
      , tope `elem` topes
      , topeEQT r l `elem` topes
      ]
    TopeLEQT _ty l r
      | l == r -> True
      | solveRHS topes (topeEQT l r) -> True
      | solveRHS topes (topeEQT l cube2_0T) -> True
      | solveRHS topes (topeEQT r cube2_1T) -> True
    -- TopeBottomT{}  -> solveLHS topes tope
    TopeAndT _ l r -> solveRHS topes l && solveRHS topes r
    TopeOrT  _ l r -> solveRHS topes l || solveRHS topes r
    _ -> tope `elem` topes

checkTope :: Eq var => TermT var -> TypeCheck var Bool
checkTope tope = do
  ctxTopes <- asks localTopes
  performing (ActionContextEntails ctxTopes tope) $ do
    topes' <- asks localTopesNF
    tope' <- nfTope tope
    return (topes' `entail` tope')

checkTopeEntails :: Eq var => TermT var -> TypeCheck var Bool
checkTopeEntails tope = do
  ctxTopes <- asks localTopes
  performing (ActionContextEntailedBy ctxTopes tope) $ do
    contextTopes <- asks localTopesNF
    restrictionTope <- nfTope tope
    let contextTopesRHS = foldr topeAndT topeTopT contextTopes
    return ([restrictionTope] `entail` contextTopesRHS)

contextEntailedBy :: Eq var => TermT var -> TypeCheck var ()
contextEntailedBy tope = do
  ctxTopes <- asks localTopes
  performing (ActionContextEntailedBy ctxTopes tope) $ do
    contextTopes <- asks localTopesNF
    restrictionTope <- nfTope tope
    let contextTopesRHS = foldr topeOrT topeBottomT contextTopes
    unless ([restrictionTope] `entail` contextTopesRHS) $
      issueTypeError $ TypeErrorTopeNotSatisfied [restrictionTope] contextTopesRHS

contextEntails :: Eq var => TermT var -> TypeCheck var ()
contextEntails tope = do
  ctxTopes <- asks localTopes
  performing (ActionContextEntails ctxTopes tope) $ do
    topeIsEntailed <- checkTope tope
    topes' <- asks localTopesNF
    unless topeIsEntailed $
      issueTypeError $ TypeErrorTopeNotSatisfied topes' tope

topesEquiv :: Eq var => TermT var -> TermT var -> TypeCheck var Bool
topesEquiv expected actual = performing (ActionUnifyTerms expected actual) $ do
  expected' <- nfT expected
  actual' <- nfT actual
  return ([expected'] `entail` actual' && [actual'] `entail` expected')

contextEquiv :: Eq var => [TermT var] -> TypeCheck var ()
contextEquiv topes = do
  ctxTopes <- asks localTopes
  performing (ActionContextEquiv ctxTopes topes) $ do
    contextTopes <- asks localTopesNF
    recTopes <- mapM nfTope topes
    let contextTopesRHS = foldr topeOrT topeBottomT contextTopes
        recTopesRHS     = foldr topeOrT topeBottomT recTopes
    unless (contextTopes `entail` recTopesRHS) $
      issueTypeError $ TypeErrorTopeNotSatisfied contextTopes recTopesRHS
    unless (recTopes `entail` contextTopesRHS) $
      issueTypeError $ TypeErrorTopeNotSatisfied recTopes contextTopesRHS

switchVariance :: TypeCheck var a -> TypeCheck var a
switchVariance = local $ \Context{..} -> Context
  { covariance = switch covariance, .. }
    where
      switch Covariant = Contravariant
      switch Contravariant = Covariant

enterScopeContext :: Maybe Rzk.VarIdent -> TermT var -> Context var -> Context (Inc var)
enterScopeContext orig ty Context{..} = Context
  { varTypes = (Z, S <$> ty) : [ (S x, fmap S t) | (x, t) <- varTypes ]
  , varValues = (Z, Nothing) : [ (S x, fmap S <$> t) | (x, t) <- varValues ]
  , varOrigs = (Z, orig) : [ (S x, o) | (x, o) <- varOrigs ]
  , localTopes = map (fmap S) localTopes
  , localTopesNF = map (fmap S) localTopesNF
  , localTopesNFUnion = map (map (fmap S)) localTopesNFUnion
  , actionStack = map (fmap S) actionStack
  , ..
  }

enterScope :: Maybe Rzk.VarIdent -> TermT var -> TypeCheck (Inc var) b -> TypeCheck var b
enterScope orig ty action = do
  newContext <- asks (enterScopeContext orig ty)
  lift $ withExceptT (ScopedTypeError orig) $
    runReaderT action newContext

performing :: Eq var => Action var -> TypeCheck var a -> TypeCheck var a
performing action tc = do
  Context{..} <- ask
  unless (length actionStack < 1000) $  -- FIXME: which depth is reasonable? factor out into a parameter
    issueTypeError $ TypeErrorOther "maximum depth reached"
  traceTypeCheck Debug (ppSomeAction varOrigs (length actionStack) action) $
    local (const Context { actionStack = action : actionStack, .. }) $ tc

stripTypeRestrictions :: TermT var -> TermT var
stripTypeRestrictions (TypeRestrictedT _ty ty _restriction) = stripTypeRestrictions ty
stripTypeRestrictions t = t

-- | Perform at most one \(\eta\)-expansion at the top-level to assist unification.
etaMatch :: Eq var => Maybe (TermT var) -> TermT var -> TermT var -> TypeCheck var (TermT var, TermT var)
-- FIXME: double check the next 3 rules
etaMatch _mterm expected@TypeRestrictedT{} actual@TypeRestrictedT{} = pure (expected, actual)
etaMatch  mterm expected (TypeRestrictedT _ty ty _rs) = etaMatch mterm expected ty
etaMatch (Just term) expected@TypeRestrictedT{} actual =
  etaMatch (Just term) expected (typeRestrictedT actual [(topeTopT, term)])
-- ------------------------------------
etaMatch _mterm expected@LambdaT{} actual@LambdaT{} = pure (expected, actual)
etaMatch _mterm expected@PairT{}   actual@PairT{}   = pure (expected, actual)
etaMatch _mterm expected@LambdaT{} actual = do
  actual' <- etaExpand actual
  pure (expected, actual')
etaMatch _mterm expected actual@LambdaT{} = do
  expected' <- etaExpand expected
  pure (expected', actual)
etaMatch _mterm expected@PairT{} actual = do
  actual' <- etaExpand actual
  pure (expected, actual')
etaMatch _mterm expected actual@PairT{} = do
  expected' <- etaExpand expected
  pure (expected', actual)
etaMatch _mterm expected actual = pure (expected, actual)

etaExpand :: Eq var => TermT var -> TypeCheck var (TermT var)
etaExpand term@LambdaT{} = pure term
etaExpand term@PairT{} = pure term
etaExpand term = do
  ty <- typeOf term
  case stripTypeRestrictions ty of
    TypeFunT _ty orig param mtope ret -> pure $
      lambdaT ty orig (Just (param, mtope))
        (appT ret (S <$> term) (Pure Z))

    TypeSigmaT _ty _orig a b -> pure $
      pairT ty
        (firstT a term)
        (secondT (substituteT (firstT a term) b) term)

    CubeProductT _ty a b -> pure $
      pairT ty
        (firstT a term)
        (secondT b term)

    _ -> pure term

inCubeLayer :: Eq var => TermT var -> TypeCheck var Bool
inCubeLayer = \case
  RecBottomT{} -> pure False
  UniverseT{} -> pure False

  UniverseCubeT{} -> pure True
  CubeProductT{} -> pure True
  CubeUnitT{} -> pure True
  CubeUnitStarT{} -> pure True
  Cube2T{} -> pure True
  Cube2_0T{} -> pure True
  Cube2_1T{} -> pure True

  t -> typeOf t >>= inCubeLayer

inTopeLayer :: Eq var => TermT var -> TypeCheck var Bool
inTopeLayer = \case
  RecBottomT{} -> pure False
  UniverseT{} -> pure False

  UniverseCubeT{} -> pure True
  UniverseTopeT{} -> pure True

  CubeProductT{} -> pure True
  CubeUnitT{} -> pure True
  CubeUnitStarT{} -> pure True
  Cube2T{} -> pure True
  Cube2_0T{} -> pure True
  Cube2_1T{} -> pure True

  TopeTopT{} -> pure True
  TopeBottomT{} -> pure True
  TopeAndT{} -> pure True
  TopeOrT{} -> pure True
  TopeEQT{} -> pure True
  TopeLEQT{} -> pure True

  TypeFunT _ty orig param _mtope ret -> do
    enterScope orig param $ inTopeLayer ret

  t -> typeOfUncomputed t >>= inTopeLayer

tryRestriction :: Eq var => TermT var -> TypeCheck var (Maybe (TermT var))
tryRestriction = \case
  TypeRestrictedT _ _ rs -> do
    let go [] = pure Nothing
        go ((tope, term') : rs') = do
          checkTope tope >>= \case
            True -> pure (Just term')
            False -> go rs'
    go rs
  _ -> pure Nothing

-- | Compute a typed term to its WHNF.
--
-- >>> whnfT "(\\p -> first (second p)) (x, (y, z))" :: Term'
-- y
whnfT :: Eq var => TermT var -> TypeCheck var (TermT var)
whnfT tt = performing (ActionWHNF tt) $ case tt of
  -- universe constants
  UniverseT{} -> pure tt
  UniverseCubeT{} -> pure tt
  UniverseTopeT{} -> pure tt

  -- cube layer (except vars, pairs, and applications)
  CubeProductT{} -> nfTope tt
  CubeUnitT{} -> pure tt
  CubeUnitStarT{} -> pure tt
  Cube2T{} -> pure tt
  Cube2_0T{} -> pure tt
  Cube2_1T{} -> pure tt

  -- tope layer (except vars, pairs of points, and applications)
  TopeTopT{} -> pure tt
  TopeBottomT{} -> pure tt
  TopeAndT{} -> nfTope tt
  TopeOrT{} -> nfTope tt
  TopeEQT{} -> nfTope tt
  TopeLEQT{} -> nfTope tt

  -- type layer terms that should not be evaluated further
  LambdaT{} -> pure tt
  PairT{} -> pure tt
  ReflT{} -> pure tt
  TypeFunT{} -> pure tt
  TypeSigmaT{} -> pure tt
  TypeIdT{} -> pure tt
  RecBottomT{} -> pure tt

  -- type ascriptions are ignored, since we already have a typechecked term
  TypeAscT _ty term _ty' -> whnfT term

  Free (AnnF info _)
    | Just tt' <- infoWHNF info -> pure tt'

  -- check if we have cube or a tope term (if so, compute NF)
  _ -> typeOf tt >>= \case
    UniverseCubeT{} -> nfTope tt
    UniverseTopeT{} -> nfTope tt

    -- check if we have cube point term (if so, compute NF)
    typeOf_tt -> typeOf typeOf_tt >>= \case
      UniverseCubeT{} -> nfTope tt

      -- now we are in the type layer
      _ -> do
        -- check if we are in the empty context
        inBottom <- asks localTopesEntailBottom
        if inBottom
           then pure recBottomT -- if so, reduce to recBOT
           else tryRestriction typeOf_tt >>= \case
            Just tt' -> whnfT tt'
            Nothing -> case tt of
              t@(Pure var) ->
                valueOfVar var >>= \case
                  Nothing -> pure t
                  Just term -> whnfT term

              AppT ty f x ->
                whnfT f >>= \case
                  LambdaT _ty _orig _arg body ->
                    whnfT (substituteT x body)
                  f' -> typeOf f' >>= \case
                    TypeFunT _ty _orig _param (Just tope) UniverseTopeT{} -> do
                      topeAndT
                        <$> (AppT ty <$> nfT f' <*> nfT x)
                        <*> nfT (substituteT x tope)
                    -- FIXME: this seems to be a hack, and will not work in all situations!
                    -- FIXME: need to check performance of this code thoroughly
                    -- FIXME: for now, it seems to add ~2x slowdown
                    TypeFunT info _orig _param _mtope ret@TypeRestrictedT{}
                      | TypeRestrictedT{} <- infoType info -> pure (AppT ty f' x)
                      | otherwise -> do
                          let ret' = substituteT x ret
                          tryRestriction ret' >>= \case -- FIXME: to many unnecessary checks?
                            Nothing -> pure (AppT ty { infoType = ret' } f' x)
                            Just tt' -> whnfT tt'
                    _ -> pure (AppT ty f' x)

              FirstT ty t ->
                whnfT t >>= \case
                  PairT _ l _r -> whnfT l
                  t' -> pure (FirstT ty t')

              SecondT ty t ->
                whnfT t >>= \case
                  PairT _ _l r -> whnfT r
                  t' -> pure (SecondT ty t')
              IdJT ty tA a tC d x p ->
                whnfT p >>= \case
                  ReflT{} -> whnfT d
                  p' -> pure (IdJT ty tA a tC d x p')

              RecOrT _ty rs -> do
                let go [] = pure Nothing
                    go ((tope, tt') : rs') = do
                      checkTope tope >>= \case
                        True -> pure (Just tt')
                        False -> go rs'
                go rs >>= \case
                  Just tt' -> whnfT tt'
                  Nothing
                    | [tt'] <- nubTermT (map snd rs) -> whnfT tt'
                    | otherwise -> pure tt

              TypeRestrictedT ty type_ rs -> do
                rs' <- traverse (\(tope, term) -> (,) <$> nfT tope <*> pure term) rs
                case filter ((/= topeBottomT) . fst) rs' of
                  [] -> whnfT type_  -- get rid of restrictions at BOT
                  rs'' -> TypeRestrictedT ty <$> whnfT type_ <*> pure rs''

nfTope :: Eq var => TermT var -> TypeCheck var (TermT var)
nfTope tt = performing (ActionNF tt) $ fmap termIsNF $ case tt of
  Pure var ->
    valueOfVar var >>= \case
      Nothing -> pure tt
      Just term -> nfTope term

  -- see if normal form is already available
  Free (AnnF info _) | Just tt' <- infoNF info -> pure tt'

  -- universe constants
  UniverseT{} -> pure tt
  UniverseCubeT{} -> pure tt
  UniverseTopeT{} -> pure tt

  -- cube layer constants
  CubeUnitT{} -> pure tt
  CubeUnitStarT{} -> pure tt
  Cube2T{} -> pure tt
  Cube2_0T{} -> pure tt
  Cube2_1T{} -> pure tt

  -- cube layer with computation
  CubeProductT _ty l r -> cubeProductT <$> nfTope l <*> nfTope r

  -- tope layer constants
  TopeTopT{} -> pure tt
  TopeBottomT{} -> pure tt

  -- tope layer with computation
  TopeAndT ty l r ->
    nfTope l >>= \case
      TopeBottomT{} -> pure topeBottomT
      l' -> nfTope r >>= \case
        TopeBottomT{} -> pure topeBottomT
        r' -> pure (TopeAndT ty l' r')

  TopeOrT  ty l r -> do
    l' <- nfTope l
    r' <- nfTope r
    case (l', r') of
      (TopeBottomT{}, _) -> pure r'
      (_, TopeBottomT{}) -> pure l'
      _ -> pure (TopeOrT ty l' r')

  TopeEQT  ty l r -> TopeEQT  ty <$> nfTope l <*> nfTope r
  TopeLEQT ty l r -> TopeLEQT ty <$> nfTope l <*> nfTope r

  -- type ascriptions are ignored, since we already have a typechecked term
  TypeAscT _ty term _ty' -> nfTope term
  
  PairT ty l r -> PairT ty <$> nfTope l <*> nfTope r

  AppT ty f x ->
    nfTope f >>= \case
      LambdaT _ty _orig _arg body ->
        nfTope (substituteT x body)
      f' -> typeOfUncomputed f' >>= \case
        TypeFunT _ty _orig _param (Just tope) UniverseTopeT{} -> do
          topeAndT
            <$> (AppT ty f' <$> nfTope x)
            <*> nfTope (substituteT x tope)
        _ -> AppT ty f' <$> nfTope x

  FirstT ty t ->
    nfTope t >>= \case
      PairT _ty x _y -> pure x
      t' -> pure (FirstT ty t')

  SecondT ty t ->
    nfTope t >>= \case
      PairT _ty _x y -> pure y
      t' -> pure (SecondT ty t')

  LambdaT ty orig _mparam body
    | TypeFunT _ty _origF param mtope _ret <- infoType ty ->
        LambdaT ty orig (Just (param, mtope)) <$> enterScope orig param (nfTope body)
  LambdaT{} -> panicImpossible "lambda with a non-function type in the tope layer"

  TypeFunT{} -> panicImpossible "exposed function type in the tope layer"
  TypeSigmaT{} -> panicImpossible "dependent sum type in the tope layer"
  TypeIdT{} -> panicImpossible "identity type in the tope layer"
  ReflT{} -> panicImpossible "refl in the tope layer"
  IdJT{} -> panicImpossible "idJ eliminator in the tope layer"
  TypeRestrictedT{} -> panicImpossible "extension types in the tope layer"

  RecOrT{} -> panicImpossible "recOR in the tope layer"
  RecBottomT{} -> panicImpossible "recBOT in the tope layer"

-- | Compute a typed term to its NF.
--
-- >>> nfT "(\\p -> first (second p)) (x, (y, z))" :: Term'
-- y
nfT :: Eq var => TermT var -> TypeCheck var (TermT var)
nfT tt = performing (ActionNF tt) $ case tt of
  -- universe constants
  UniverseT{} -> pure tt
  UniverseCubeT{} -> pure tt
  UniverseTopeT{} -> pure tt

  -- cube layer constants
  CubeUnitT{} -> pure tt
  CubeUnitStarT{} -> pure tt
  Cube2T{} -> pure tt
  Cube2_0T{} -> pure tt
  Cube2_1T{} -> pure tt

  -- cube layer with computation
  CubeProductT{} -> nfTope tt

  -- tope layer constants
  TopeTopT{} -> pure tt
  TopeBottomT{} -> pure tt

  -- tope layer with computation
  TopeAndT{} -> nfTope tt
  TopeOrT{} -> nfTope tt
  TopeEQT{} -> nfTope tt
  TopeLEQT{} -> nfTope tt

  -- type layer constants
  ReflT ty _x -> pure (ReflT ty Nothing)
  RecBottomT{} -> pure tt

  -- type ascriptions are ignored, since we already have a typechecked term
  TypeAscT _ty term _ty' -> nfT term

  -- now we are in the type layer
  _ -> do
    -- check if we are in the empty context
    inBottom <- asks localTopesEntailBottom
    if inBottom
       then pure recBottomT -- if so, reduce to recBOT
       else typeOf tt >>= tryRestriction >>= \case
        Just tt' -> nfT tt'
        Nothing -> case tt of
          t@(Pure var) ->
            valueOfVar var >>= \case
              Nothing -> pure t
              Just term -> nfT term

          TypeFunT ty orig param mtope ret -> do
            param' <- nfT param
            enterScope orig param' $ do
              mtope' <- traverse nfT mtope
              maybe id localTope mtope' $
                TypeFunT ty orig param' mtope' <$> nfT ret
          AppT ty f x ->
            whnfT f >>= \case
              LambdaT _ty _orig _arg body ->
                nfT (substituteT x body)
              f' -> typeOf f' >>= \case
                TypeFunT _ty _orig _param (Just tope) UniverseTopeT{} -> do
                  topeAndT
                    <$> (AppT ty <$> nfT f' <*> nfT x)
                    <*> nfT (substituteT x tope)
                _ -> AppT ty <$> nfT f' <*> nfT x
          LambdaT ty orig _mparam body -> do
            case stripTypeRestrictions (infoType ty) of
              TypeFunT _ty _orig param mtope _ret -> do
                param' <- nfT param
                enterScope orig param' $ do
                  mtope' <- traverse nfT mtope
                  maybe id localTope mtope' $
                    LambdaT ty orig (Just (param', mtope')) <$> nfT body
              _ -> panicImpossible "lambda with a non-function type"


          TypeSigmaT ty orig a b -> do
            a' <- nfT a
            enterScope orig a' $ do
              TypeSigmaT ty orig a' <$> nfT b
          PairT ty l r -> PairT ty <$> nfT l <*> nfT r
          FirstT ty t ->
            whnfT t >>= \case
              PairT _ l _r -> nfT l
              t' -> FirstT ty <$> nfT t'
          SecondT ty t ->
            whnfT t >>= \case
              PairT _ _l r -> nfT r
              t' -> SecondT ty <$> nfT t'

          TypeIdT ty x _tA y -> TypeIdT ty <$> nfT x <*> pure Nothing <*> nfT y
          IdJT ty tA a tC d x p ->
            whnfT p >>= \case
              ReflT{} -> nfT d
              p' -> IdJT ty <$> nfT tA <*> nfT a <*> nfT tC <*> nfT d <*> nfT x <*> nfT p'

          RecOrT _ty rs -> do
            let go [] = pure Nothing
                go ((tope, tt') : rs') = do
                  checkTope tope >>= \case
                    True -> pure (Just tt')
                    False -> go rs'
            go rs >>= \case
              Just tt' -> nfT tt'
              Nothing
                | [tt'] <- nubTermT (map snd rs) -> nfT tt'
                | otherwise -> pure tt


          TypeRestrictedT ty type_ rs -> do
            rs' <- forM rs $ \(tope, term) -> do
              nfTope tope >>= \case
                TopeBottomT{} -> pure Nothing
                tope' -> do
                  term' <- localTope tope' $
                    nfT term
                  return (Just (tope', term'))
            case catMaybes rs' of
              [] -> nfT type_
              rs'' -> TypeRestrictedT ty <$> nfT type_ <*> pure rs''

valueOfVar :: Eq var => var -> TypeCheck var (Maybe (TermT var))
valueOfVar x = asks (lookup x . varValues) >>= \case
  Nothing -> issueTypeError $ TypeErrorUndefined x
  Just ty -> return ty

typeOfVar :: Eq var => var -> TypeCheck var (TermT var)
typeOfVar x = asks (lookup x . varTypes) >>= \case
  Nothing -> issueTypeError $ TypeErrorUndefined x
  Just ty -> return ty

typeOfUncomputed :: Eq var => TermT var -> TypeCheck var (TermT var)
typeOfUncomputed = \case
  Pure x -> typeOfVar x
  Free (AnnF TypeInfo{..} _) -> pure infoType

typeOf :: Eq var => TermT var -> TypeCheck var (TermT var)
typeOf t = typeOfUncomputed t >>= whnfT 

unifyTopes :: Eq var => TermT var -> TermT var -> TypeCheck var ()
unifyTopes l r = do
  let equiv = and
        [ [l] `entail` r
        , [r] `entail` l ]
  unless equiv $
    issueTypeError (TypeErrorTopesNotEquivalent l r)

inAllSubContexts :: TypeCheck var () -> TypeCheck var () -> TypeCheck var ()
inAllSubContexts handleSingle tc = do
  topeSubContexts <- asks localTopesNFUnion
  case topeSubContexts of
    [] -> panicImpossible "empty set of alternative contexts"
    [_] -> handleSingle
    _:_:_ -> do
      forM_ topeSubContexts $ \topes' -> do
        local (\Context{..} -> Context
            { localTopes = topes'
            , localTopesNF = topes'
            , localTopesNFUnion = [topes']
            , .. }) $
          tc

unify :: Eq var => Maybe (TermT var) -> TermT var -> TermT var -> TypeCheck var ()
unify mterm expected actual = performUnification `catchError` \typeError -> do
  inAllSubContexts (throwError typeError) performUnification
  where
    performUnification = unifyInCurrentContext mterm expected actual 

unifyInCurrentContext :: Eq var => Maybe (TermT var) -> TermT var -> TermT var -> TypeCheck var ()
unifyInCurrentContext mterm expected actual = performing action $
  unless (expected == actual) $ do      -- NOTE: this gives a small, but noticeable speedup
    expectedVal <- whnfT expected
    actualVal <- whnfT actual
    (expected', actual') <- asks covariance >>= \case
      Covariant -> etaMatch mterm expectedVal actualVal
      Contravariant -> swap <$> etaMatch mterm actualVal expectedVal
    unless (expected' == actual') $ do  -- NOTE: this gives a small, but noticeable speedup
      case actual' of
        RecBottomT{} -> return ()
        RecOrT _ty rs' ->
          case expected' of
            RecOrT _ty rs -> sequence_ $
              checkCoherence <$> rs <*> rs'
            _ -> do
              forM_ rs' $ \(tope, term) ->
                localTope tope $
                  unifyTerms expected' term
        _ -> typeOf expected' >>= typeOf >>= \case
          UniverseCubeT{} -> contextEntails (topeEQT expected' actual')
          _ -> do
            let def = unless (expected' == actual') err
                err =
                  case mterm of
                    Nothing   -> issueTypeError (TypeErrorUnifyTerms expected' actual')
                    Just term -> issueTypeError (TypeErrorUnify term expected' actual')
                errS = do
                  let expectedS = S <$> expected'
                      actualS = S <$> actual'
                  case mterm of
                    Nothing   -> issueTypeError (TypeErrorUnifyTerms expectedS actualS)
                    Just term -> issueTypeError (TypeErrorUnify (S <$> term) expectedS actualS)
            case expected' of
              Pure{} -> def

              UniverseT{} -> def
              UniverseCubeT{} -> def
              UniverseTopeT{} -> def

              CubeUnitT{} -> def
              CubeUnitStarT{} -> def
              Cube2T{} -> def
              Cube2_0T{} -> def
              Cube2_1T{} -> def
              CubeProductT _ l r ->
                case actual' of
                  CubeProductT _ l' r' -> do
                    unifyTerms l l'
                    unifyTerms r r'
                  _ -> err

              PairT _ty l r ->
                case actual' of
                  PairT _ty' l' r' -> do
                    unifyTerms l l'
                    unifyTerms r r'

                  -- one part of eta-expansion for pairs
                  -- FIXME: add symmetric version!
                  _ -> err

              FirstT _ty t ->
                case actual' of
                  FirstT _ty' t' -> unifyTerms t t'
                  _ -> err

              SecondT _ty t ->
                case actual' of
                  SecondT _ty' t' -> unifyTerms t t'
                  _ -> err

              TopeTopT{}    -> unifyTopes expected' actual'
              TopeBottomT{} -> unifyTopes expected' actual'
              TopeEQT{}     -> unifyTopes expected' actual'
              TopeLEQT{}    -> unifyTopes expected' actual'
              TopeAndT{}    -> unifyTopes expected' actual'
              TopeOrT{}     -> unifyTopes expected' actual'

              RecBottomT{} -> return () -- unifies with anything
              RecOrT _ty rs ->
                case actual' of
                  -- ----------------------------------------------
                  -- IMPORTANT: this pattern matching is redundant,
                  -- but it is not obvious, so
                  -- take care when refactoring!
                  -- ----------------------------------------------
  --                RecOrT _ty rs' -> sequence_ $
  --                  checkCoherence <$> rs <*> rs'
                  -- ----------------------------------------------
                  _ -> do
                    forM_ rs $ \(tope, term) ->
                      localTope tope $
                        unifyTerms term actual'

              TypeFunT _ty _orig cube mtope ret ->
                case actual' of
                  TypeFunT _ty' orig' cube' mtope' ret' -> do
                    switchVariance $  -- unifying in the negative position!
                      unifyTerms cube cube' -- FIXME: unifyCubes
                    enterScope orig' cube $ do
                      case (mtope, mtope') of
                        (Just tope, Just tope') -> do
                          topeNF <- nfT tope
                          topeNF' <- nfT tope'
                          unifyTopes topeNF topeNF'
                        (Nothing, Nothing)      -> return ()
                        (Just tope, Nothing)    -> nfT tope >>= (`unifyTopes` topeTopT)
                        (Nothing, Just tope)    -> nfT tope >>= unifyTopes topeTopT
                      case mterm of
                        Nothing -> unifyTerms ret ret'
                        Just term -> unifyTypes (appT ret' (S <$> term) (Pure Z)) ret ret'
                  _ -> err

              TypeSigmaT _ty _orig a b ->
                case actual' of
                  TypeSigmaT _ty' orig' a' b' -> do
                    unify Nothing a a'
                    enterScope orig' a $ unify Nothing b b'
                  _ -> err

              TypeIdT _ty x _tA y ->
                case actual' of
                  TypeIdT _ty' x' _tA' y' -> do
                    -- unify Nothing tA tA' -- TODO: do we need this check?
                    unify Nothing x x'
                    unify Nothing y y'
                  _ -> err

              AppT _ty f x ->
                case actual' of
                  AppT _ty' f' x' -> do
                    unify Nothing f f'
                    unify Nothing x x'
                  _ -> err

              LambdaT ty _orig _mparam body ->
                case stripTypeRestrictions (infoType ty) of
                  TypeFunT _ty _origF param mtope _ret ->
                    case actual' of
                      LambdaT ty' orig' _mparam' body' -> do
                        case stripTypeRestrictions (infoType ty') of
                          TypeFunT _ty' _origF' param' mtope' _ret' -> do
                            unify Nothing param param'
                            enterScope orig' param $ do
                              case (mtope, mtope') of
                                (Just tope, Just tope') -> do
                                  unify Nothing tope tope'
                                  localTope tope $ unify Nothing body body'
                                (Nothing, Nothing) -> do
                                  unify Nothing body body'
                                _ -> errS
                          _ -> err
                      _ -> err
                  _ -> err

              ReflT ty _x | TypeIdT _ty x _tA y <- infoType ty ->
                case actual' of
                  ReflT ty' _x' | TypeIdT _ty' x' _tA' y' <- infoType ty' -> do
                    -- unify Nothing tA tA' -- TODO: do we need this check?
                    unify Nothing x x'
                    unify Nothing y y'
                  _ -> err
              ReflT{} -> panicImpossible "refl with a non-identity type!"

              IdJT _ty a b c d e f ->
                case actual' of
                  IdJT _ty' a' b' c' d' e' f' -> do
                    unify Nothing a a'
                    unify Nothing b b'
                    unify Nothing c c'
                    unify Nothing d d'
                    unify Nothing e e'
                    unify Nothing f f'
                  _ -> err

              TypeAscT{} -> panicImpossible "type ascription at the root of WHNF"

              TypeRestrictedT _ty ty rs ->
                case actual' of
                  TypeRestrictedT _ty' ty' rs' -> do
                    unify mterm ty ty'
                    sequence_
                      [ localTope tope $ do
                          -- FIXME: can do less entails checks?
                          contextEntails (foldr topeOrT topeBottomT (map fst rs')) -- expected is less specified than actual
                          forM_ rs' $ \(tope', term') -> do
                            localTope tope' $
                              unify Nothing term term'
                      | (tope, term) <- rs
                      ]
                  _ -> err    -- FIXME: need better unification for restrictions

  where
    action = case mterm of
               Nothing -> ActionUnifyTerms expected actual
               Just term -> ActionUnify term expected actual

unifyTypes :: Eq var => TermT var -> TermT var -> TermT var -> TypeCheck var ()
unifyTypes = unify . Just

unifyTerms :: Eq var => TermT var -> TermT var -> TypeCheck var ()
unifyTerms = unify Nothing

localTope :: Eq var => TermT var -> TypeCheck var a -> TypeCheck var a
localTope tope tc = do
  Context{..} <- ask
  tope' <- nfTope tope
  -- A small optimisation to help unify terms faster
  let refine = case tope' of
        TopeEQT _ x y | x == y -> const tc          -- no new information added!
        _ | tope' `elem` localTopes -> const tc
          | otherwise -> id
  refine $ do
    local (f tope' localTopesNF) tc
  where
    f tope' localTopes' Context{..} = Context
      { localTopes = tope : localTopes
      , localTopesNF = tope' : localTopesNF
      , localTopesNFUnion = map nubTermT
          [ new <> old
          | new <- simplifyLHS [tope']
          , old <- localTopesNFUnion ]
      , localTopesEntailBottom = entailsBottom
      , .. }
      where
        entailsBottom = (tope' : localTopes') `entail` topeBottomT

universeT :: TermT var
universeT = iterate f (panicImpossible msg) !! 30
  where
    msg = "going too high up the universe levels"
    f t = UniverseT TypeInfo
      { infoType = t
      , infoNF = Just universeT
      , infoWHNF = Just universeT }

cubeT :: TermT var
cubeT = UniverseCubeT TypeInfo
  { infoType = universeT
  , infoNF = Just cubeT
  , infoWHNF = Just cubeT }

topeT :: TermT var
topeT = UniverseTopeT TypeInfo
  { infoType = universeT
  , infoNF = Just topeT
  , infoWHNF = Just topeT }

topeEQT :: TermT var -> TermT var -> TermT var
topeEQT l r = TopeEQT info l r
  where
    info = TypeInfo
      { infoType = topeT
      , infoNF = Nothing
      , infoWHNF = Nothing
      }

topeLEQT :: TermT var -> TermT var -> TermT var
topeLEQT l r = TopeLEQT info l r
  where
    info = TypeInfo
      { infoType = topeT
      , infoNF = Nothing
      , infoWHNF = Nothing
      }

topeOrT :: TermT var -> TermT var -> TermT var
topeOrT l r = TopeOrT info l r
  where
    info = TypeInfo
      { infoType = topeT
      , infoNF = Nothing
      , infoWHNF = Nothing
      }

topeAndT :: TermT var -> TermT var -> TermT var
topeAndT l r = TopeAndT info l r
  where
    info = TypeInfo
      { infoType = topeT
      , infoNF = Nothing
      , infoWHNF = Nothing
      }

cubeProductT :: TermT var -> TermT var -> TermT var
cubeProductT l r = t
  where
    t = CubeProductT info l r
    info = TypeInfo
      { infoType  = cubeT
      , infoNF    = Nothing
      , infoWHNF  = Nothing
      }

cubeUnitT :: TermT var
cubeUnitT = CubeUnitT TypeInfo
  { infoType = cubeT
  , infoNF = Just cubeUnitT
  , infoWHNF = Just cubeUnitT }

cubeUnitStarT :: TermT var
cubeUnitStarT = CubeUnitStarT TypeInfo
  { infoType = cubeUnitT
  , infoNF = Just cubeUnitStarT
  , infoWHNF = Just cubeUnitStarT }

cube2T :: TermT var
cube2T = Cube2T TypeInfo
  { infoType = cubeT
  , infoNF = Just cube2T
  , infoWHNF = Just cube2T }

cube2_0T :: TermT var
cube2_0T = Cube2_0T TypeInfo
  { infoType = cube2T
  , infoNF = Just cube2_0T
  , infoWHNF = Just cube2_0T }

cube2_1T :: TermT var
cube2_1T = Cube2_1T TypeInfo
  { infoType = cube2T
  , infoNF = Just cube2_1T
  , infoWHNF = Just cube2_1T }

topeTopT :: TermT var
topeTopT = TopeTopT TypeInfo
  { infoType = topeT
  , infoNF = Just topeTopT
  , infoWHNF = Just topeTopT }

topeBottomT :: TermT var
topeBottomT = TopeBottomT TypeInfo
  { infoType = topeT
  , infoNF = Just topeBottomT
  , infoWHNF = Just topeBottomT }

recBottomT :: TermT var
recBottomT = RecBottomT TypeInfo
  { infoType = recBottomT
  , infoNF = Just recBottomT
  , infoWHNF = Just recBottomT }

typeRestrictedT :: TermT var -> [(TermT var, TermT var)] -> TermT var
typeRestrictedT ty rs = t
  where
    t = TypeRestrictedT info ty rs
    info = TypeInfo
      { infoType  = universeT
      , infoNF    = Nothing
      , infoWHNF  = Nothing
      }

lambdaT
  :: TermT var
  -> Maybe Rzk.VarIdent
  -> Maybe (TermT var, Maybe (Scope TermT var))
  -> Scope TermT var
  -> TermT var
lambdaT ty orig mparam body = t
  where
    t = LambdaT info orig mparam body
    info = TypeInfo
      { infoType  = ty
      , infoNF    = Nothing
      , infoWHNF  = Just t
      }

appT :: TermT var -> TermT var -> TermT var -> TermT var
appT ty f x = t
  where
    t = AppT info f x
    info = TypeInfo
      { infoType  = ty
      , infoNF    = Nothing
      , infoWHNF  = Nothing
      }

pairT :: TermT var -> TermT var -> TermT var -> TermT var
pairT ty l r = t
  where
    t = PairT info l r
    info = TypeInfo
      { infoType  = ty
      , infoNF    = Nothing
      , infoWHNF  = Just t
      }

firstT :: TermT var -> TermT var -> TermT var
firstT ty arg = t
  where
    t = FirstT info arg
    info = TypeInfo
      { infoType  = ty
      , infoNF    = Nothing
      , infoWHNF  = Nothing
      }

secondT :: TermT var -> TermT var -> TermT var
secondT ty arg = t
  where
    t = SecondT info arg
    info = TypeInfo
      { infoType  = ty
      , infoNF    = Nothing
      , infoWHNF  = Nothing
      }

reflT
  :: TermT var
  -> Maybe (TermT var, Maybe (TermT var))
  -> TermT var
reflT ty mx = t
  where
    t = ReflT info mx
    info = TypeInfo
      { infoType  = ty
      , infoNF    = Just (ReflT info Nothing)
      , infoWHNF  = Just (ReflT info Nothing)
      }

typeFunT
  :: Maybe Rzk.VarIdent
  -> TermT var
  -> Maybe (Scope TermT var)
  -> Scope TermT var
  -> TermT var
typeFunT orig cube mtope ret = t
  where
    t = TypeFunT info orig cube mtope ret
    info = TypeInfo
      { infoType  = universeT
      , infoNF    = Nothing
      , infoWHNF  = Just t
      }

typeSigmaT
  :: Maybe Rzk.VarIdent
  -> TermT var
  -> Scope TermT var
  -> TermT var
typeSigmaT orig a b = t
  where
    t = TypeSigmaT info orig a b
    info = TypeInfo
      { infoType  = universeT
      , infoNF    = Nothing
      , infoWHNF  = Just t
      }

recOrT
  :: TermT var
  -> [(TermT var, TermT var)]
  -> TermT var
recOrT ty rs = t
  where
    t = RecOrT info rs
    info = TypeInfo
      { infoType  = ty
      , infoNF    = Nothing
      , infoWHNF  = Nothing
      }

typeIdT :: TermT var -> Maybe (TermT var) -> TermT var -> TermT var
typeIdT x tA y = t
  where
    t = TypeIdT info x tA y
    info = TypeInfo
      { infoType  = universeT
      , infoNF    = Nothing
      , infoWHNF  = Just t
      }

idJT
  :: TermT var
  -> TermT var
  -> TermT var
  -> TermT var
  -> TermT var
  -> TermT var
  -> TermT var
  -> TermT var
idJT ty tA a tC d x p = t
  where
    t = IdJT info tA a tC d x p
    info = TypeInfo
      { infoType  = ty
      , infoNF    = Nothing
      , infoWHNF  = Nothing
      }

typeAscT :: TermT var -> TermT var -> TermT var
typeAscT x ty = t
  where
    t = TypeAscT info x ty
    info = TypeInfo
      { infoType  = ty
      , infoNF    = Nothing
      , infoWHNF  = Nothing
      }

typecheck :: Eq var => Term var -> TermT var -> TypeCheck var (TermT var)
typecheck term ty = performing (ActionTypeCheck term ty) $ do
  whnfT ty >>= \case

    RecBottomT{} -> do
      return recBottomT

    TypeRestrictedT _ty ty' rs -> do
      term' <- typecheck term ty'
      contextEntailedBy (foldr topeOrT topeBottomT (map fst rs))
      forM_ rs $ \(tope, rterm) -> do
        localTope tope $
          unifyTerms rterm term'
      return term'    -- FIXME: correct?

    ty' -> case term of
      Lambda orig mparam body ->
        case ty' of
          TypeFunT _ty _orig' param' mtope' ret -> do
            case mparam of
              Nothing -> return ()
              Just (param, Nothing) -> do
                (paramType, mtope) <- do
                  paramType <- infer param
                  typeOf paramType >>= \case
                    -- an argument can be a shape
                    TypeFunT _ty _orig cube _mtope UniverseTopeT{} -> do
                      mapM_ checkNameShadowing orig
                      enterScope orig cube $ do
                        let tope' = appT topeT (S <$> paramType) (Pure Z)  -- eta expand ty'
                        return (cube, Just tope')
                    _kind -> return (paramType, Nothing)
                unifyTerms param' paramType
                mapM_ checkNameShadowing orig
                enterScope orig param' $ do
                  mapM_ (unifyTerms (fromMaybe topeTopT mtope')) mtope
              Just (param, mtope) -> do
                param'' <- typecheck param =<< typeOf param'
                unifyTerms param' param''
                mapM_ checkNameShadowing orig
                enterScope orig param' $ do
                  mtope'' <- typecheck (fromMaybe TopeTop mtope) topeT
                  unifyTerms (fromMaybe topeTopT mtope') mtope''

            mapM_ checkNameShadowing orig
            enterScope orig param' $ do
              maybe id localTope mtope' $ do
                body' <- typecheck body ret
                return (lambdaT ty' orig (Just (param', mtope')) body')

          _ -> issueTypeError $ TypeErrorUnexpectedLambda term ty

      Pair l r ->
        case ty' of
          CubeProductT _ty a b -> do
            l' <- typecheck l a
            r' <- typecheck r b
            return (pairT ty' l' r')
          TypeSigmaT _ty _orig a b -> do
            l' <- typecheck l a
            r' <- typecheck r (substituteT l' b)
            return (pairT ty' l' r')
          _ -> issueTypeError $ TypeErrorUnexpectedPair term ty

      Refl mx ->
        case ty' of
          TypeIdT _ty y _tA z -> do
            tA <- typeOf y
            forM_ mx $ \(x, mxty) -> do
              forM_ mxty $ \xty -> do
                xty' <- typecheck xty universeT
                unifyTerms tA xty'
              x' <- typecheck x tA
              unifyTerms x' y
              unifyTerms x' z
            when (isNothing mx) $
              unifyTerms y z
            return (reflT ty' (Just (y, Just tA)))
          _ -> issueTypeError $ TypeErrorUnexpectedRefl term ty

        -- FIXME: this does not make typechecking faster, why?
--      RecOr rs -> do
--        rs' <- forM rs $ \(tope, rterm) -> do
--          tope' <- typecheck tope topeT
--          contextEntailedBy tope'
--          localTope tope' $ do
--            rterm' <- typecheck rterm ty
--            return (tope', rterm')
--        return (recOrT ty rs')

      _ -> do
        term' <- infer term
        inferredType <- typeOf term'
        unifyTypes term' ty' inferredType
        return term'

inferAs :: Eq var => TermT var -> Term var -> TypeCheck var (TermT var)
inferAs expectedKind term = do
  term' <- infer term
  ty <- typeOf term'
  kind <- typeOf ty
  unifyTypes ty expectedKind kind
  return term'

infer :: Eq var => Term var -> TypeCheck var (TermT var)
infer tt = performing (ActionInfer tt) $ case tt of
  Pure x -> pure (Pure x)

  Universe     -> pure universeT
  UniverseCube -> pure cubeT
  UniverseTope -> pure topeT

  CubeUnit      -> pure cubeUnitT
  CubeUnitStar  -> pure cubeUnitStarT

  Cube2 -> pure cube2T
  Cube2_0 -> pure cube2_0T
  Cube2_1 -> pure cube2_1T

  CubeProduct l r -> do
    l' <- typecheck l cubeT
    r' <- typecheck r cubeT
    return (cubeProductT l' r')

  Pair l r -> do
    l' <- infer l
    r' <- infer r
    lt <- typeOf l'
    rt <- typeOf r'
    typeOf lt >>= \case
      UniverseCubeT{} -> return (pairT (cubeProductT lt rt) l' r')
      _ -> do
        -- NOTE: infer as a non-dependent pair!
        return (pairT (typeSigmaT Nothing lt (S <$> rt)) l' r')

  First t -> do
    t' <- infer t
    fmap stripTypeRestrictions (typeOf t') >>= \case
      RecBottomT{} -> pure recBottomT -- FIXME: is this ok?
      TypeSigmaT _ty _orig lt _rt ->
        return (firstT lt t')
      CubeProductT _ty l _r ->
        return (firstT l t')
      ty -> issueTypeError $ TypeErrorNotPair t' ty

  Second t -> do
    t' <- infer t
    fmap stripTypeRestrictions (typeOf t') >>= \case
      RecBottomT{} -> pure recBottomT -- FIXME: is this ok?
      TypeSigmaT _ty _orig lt rt ->
        return (secondT (substituteT (firstT lt t') rt) t')
      CubeProductT _ty _l r ->
        return (secondT r t')
      ty -> issueTypeError $ TypeErrorNotPair t' ty

  TopeTop -> pure topeTopT
  TopeBottom -> pure topeBottomT

  TopeEQ l r -> do
    l' <- inferAs cubeT l
    lt <- typeOf l'
    r' <- typecheck r lt
    return (topeEQT l' r')

  TopeLEQ l r -> do
    l' <- typecheck l cube2T
    r' <- typecheck r cube2T
    return (topeLEQT l' r')

  TopeAnd l r -> do
    l' <- typecheck l topeT
    r' <- typecheck r topeT
    return (topeAndT l' r')

  TopeOr l r -> do
    l' <- typecheck l topeT
    r' <- typecheck r topeT
    return (topeOrT l' r')

  RecBottom -> do
    contextEntails topeBottomT
    return recBottomT

  RecOr rs -> do
    ttts <- forM rs $ \(tope, term) -> do
      tope' <- typecheck tope topeT
      contextEntailedBy tope'
      localTope tope' $ do
        term' <- inferAs universeT term
        ty <- typeOf term'
        return (tope', (term', ty))
    let rs' = map (fmap fst) ttts
        ts  = map (fmap snd) ttts
    sequence_ [ checkCoherence l r | l:rs'' <- tails rs', r <- rs'' ]
    contextEquiv (map fst ttts)
    return (recOrT (recOrT universeT ts) rs')

  TypeFun orig a Nothing b -> do
    a' <- infer a
    typeOf a' >>= \case
      -- an argument can be a type
      UniverseT{} ->
        case a' of
          -- except if its a TOPE universe
          UniverseTopeT{} ->
            issueTypeError $ TypeErrorOther "tope params are illegal"
          _ -> do
            mapM_ checkNameShadowing orig
            b' <- enterScope orig a' $ inferAs universeT b
            return (typeFunT orig a' Nothing b')
      -- an argument can be a cube
      UniverseCubeT{} -> do
        mapM_ checkNameShadowing orig
        b' <- enterScope orig a' $ inferAs universeT b
        return (typeFunT orig a' Nothing b')
      -- an argument can be a shape
      TypeFunT _ty _orig cube _mtope UniverseTopeT{} -> do
        mapM_ checkNameShadowing orig
        enterScope orig cube $ do
          let tope' = appT topeT (S <$> a') (Pure Z)  -- eta expand a'
          localTope tope' $ do
            b' <- inferAs universeT b
            return (typeFunT orig cube (Just tope') b')
      ty -> issueTypeError $ TypeErrorInvalidArgumentType a ty

  TypeFun orig cube (Just tope) ret -> do
    cube' <- typecheck cube cubeT
    mapM_ checkNameShadowing orig
    enterScope orig cube' $ do
      tope' <- typecheck tope topeT
      localTope tope' $ do
        ret' <- inferAs universeT ret
        return (typeFunT orig cube' (Just tope') ret')

  TypeSigma orig a b -> do
    a' <- inferAs universeT a  -- FIXME: separate universe of universes from universe of types
    mapM_ checkNameShadowing orig
    b' <- enterScope orig a' $ inferAs universeT b
    return (typeSigmaT orig a' b')

  TypeId x (Just tA) y -> do
    tA' <- typecheck tA universeT
    x' <- typecheck x tA'
    y' <- typecheck y tA'
    return (typeIdT x' (Just tA') y')

  TypeId x Nothing y -> do
    x' <- inferAs universeT x
    tA <- typeOf x'
    y' <- typecheck y tA
    return (typeIdT x' (Just tA) y')

  App f x -> do
    f' <- inferAs universeT f
    fmap stripTypeRestrictions (typeOf f') >>= \case
      RecBottomT{} -> pure recBottomT -- FIXME: is this ok?
      TypeFunT _ty _orig a mtope b -> do
        x' <- typecheck x a
        case b of
          UniverseTopeT{} -> return ()
          _ -> mapM_ (contextEntails . substituteT x') mtope   -- FIXME: need to check?
        return (appT (substituteT x' b) f' x')
      ty -> issueTypeError $ TypeErrorNotFunction f' ty

  Lambda _orig Nothing _body -> do
    issueTypeError $ TypeErrorCannotInferBareLambda tt
  Lambda orig (Just (ty, Nothing)) body -> do
    ty' <- infer ty
    mtope <- typeOf ty' >>= \case
      -- an argument can be a type
      UniverseT{} ->
        case ty' of
          -- except if its a TOPE universe
          UniverseTopeT{} ->
            issueTypeError $ TypeErrorOther "tope params are illegal"
          _ -> return Nothing
      -- an argument can be a cube
      UniverseCubeT{} -> return Nothing
      -- an argument can be a shape
      TypeFunT _ty _orig cube _mtope UniverseTopeT{} -> do
        mapM_ checkNameShadowing orig
        enterScope orig cube $ do
          let tope' = appT topeT (S <$> ty') (Pure Z)  -- eta expand ty'
          return (Just tope')
      kind -> issueTypeError $ TypeErrorInvalidArgumentType ty kind
    mapM_ checkNameShadowing orig
    enterScope orig ty' $ do
      maybe id localTope mtope $ do
        body' <- infer body
        ret <- typeOf body' 
        return (lambdaT (typeFunT orig ty' mtope ret) orig (Just (ty', mtope)) body')
  Lambda orig (Just (cube, Just tope)) body -> do
    cube' <- typecheck cube cubeT
    mapM_ checkNameShadowing orig
    enterScope orig cube' $ do
      tope' <- infer tope
      body' <- localTope tope' $ infer body
      ret <- typeOf body'
      return (lambdaT (typeFunT orig cube' (Just tope') ret) orig (Just (cube', Just tope')) body')

  Refl Nothing -> issueTypeError $ TypeErrorCannotInferBareRefl tt
  Refl (Just (x, Nothing)) -> do
    x' <- inferAs universeT x
    ty <- typeOf x'
    return (reflT (typeIdT x' (Just ty) x') (Just (x', Just ty)))
  Refl (Just (x, Just ty)) -> do
    ty' <- typecheck ty universeT
    x' <- typecheck x ty'
    return (reflT (typeIdT x' (Just ty') x') (Just (x', Just ty')))

  IdJ tA a tC d x p -> do
    tA' <- typecheck tA universeT
    a' <- typecheck a tA'
    let typeOf_C =
          typeFunT Nothing tA' Nothing $
            typeFunT Nothing (typeIdT (S <$> a') (Just (S <$> tA')) (Pure Z)) Nothing $
              universeT
    tC' <- typecheck tC typeOf_C
    let typeOf_d =
          appT universeT
            (appT (typeFunT Nothing (typeIdT a' (Just tA') a') Nothing universeT)
              tC' a')
            (reflT (typeIdT a' (Just tA') a') Nothing)
    d' <- typecheck d typeOf_d
    x' <- typecheck x tA'
    p' <- typecheck p (typeIdT a' (Just tA') x')
    let ret =
          appT universeT
            (appT (typeFunT Nothing (typeIdT a' (Just tA') x') Nothing universeT)
              tC' x')
            p'
    return (idJT ret tA' a' tC' d' x' p')

  TypeAsc term ty -> do
    ty' <- inferAs universeT ty
    term' <- typecheck term ty'
    return (typeAscT term' ty')

  TypeRestricted ty rs -> do
    ty' <- typecheck ty universeT
    rs' <- forM rs $ \(tope, term) -> do
      tope' <- typecheck tope topeT
      term' <- localTope tope' $ typecheck term ty'
      return (tope', term')
    return (typeRestrictedT ty' rs')

checkCoherence
  :: Eq var
  => (TermT var, TermT var)
  -> (TermT var, TermT var)
  -> TypeCheck var ()
checkCoherence (ltope, lterm) (rtope, rterm) =
  performing (ActionCheckCoherence (ltope, lterm) (rtope, rterm)) $ do
    localTope (topeAndT ltope rtope) $ do
      ltype <- stripTypeRestrictions <$> typeOf lterm   -- FIXME: why strip?
      rtype <- stripTypeRestrictions <$> typeOf rterm   -- FIXME: why strip?
      -- FIXME: do we need to unify types here or is it included in unification of terms?
      unifyTerms ltype rtype
      unifyTerms lterm rterm

inferStandalone :: Eq var => Term var -> Either (TypeErrorInScopedContext var) (TermT var)
inferStandalone term = runExcept (runReaderT (infer term) emptyContext)

unsafeInferStandalone' :: Term' -> TermT'
unsafeInferStandalone' t =
  case inferStandalone t of
    Left err -> error $ intercalate "\n"
      [ "Type Error:"
      , ppTypeErrorInScopedContext' err
      ]
    Right tt -> tt

mkRenderObjectEntry :: String -> String -> String -> (String, RenderObjectData)
mkRenderObjectEntry objId objColor objLabel = (objId, objData)
  where
    objData = RenderObjectData
      { renderObjectDataLabel = objLabel
      , renderObjectDataColor = objColor
      }

renderTermInCubeSVG
  :: Eq var
  => (TermT var, TermT var, TermT var)
  -> (TermT var -> TypeCheck var' (Maybe RenderObjectData))
  -> TypeCheck var' String
renderTermInCubeSVG (t1, t2, t3) labelOf = do
  let (===) = topeEQT
      allVertices = mconcat <$> replicateM 3 [("0", [cube2_0T]), ("1", [cube2_1T])]
      allEdges =
        [ (fromId <> "-" <> toId, (from, to))
        | (fromId, from) : vs <- tails allVertices
        , (toId, to) <- vs
        , and (zipWith (<=) fromId toId)
        ]
      allFaces =
        [ (v1_id <> "-" <> v2_id <> "-" <> v3_id, (v1, v2, v3))
        | (v1_id, v1) : vs <- tails allVertices
        , (v2_id, v2) : vs' <- tails vs
        , and (zipWith (<=) v1_id v2_id)
        , (v3_id, v3) <- vs'
        , and (zipWith (<=) v2_id v3_id)
        ]
  vertices <- catMaybes <$> sequence
    [ fmap (vertexId,) <$>
        labelOf (topeAndT (topeAndT (t1 === s1) (t2 === s2)) (t3 === s3))
    | (vertexId, [s1, s2, s3]) <- allVertices ]
  edges <- catMaybes <$> sequence
    [ fmap (edgeId,) <$>
        labelOf (foldr topeAndT topeTopT $ concat
          [ [ t' === f | (t', (f, _)) <- constant ]
          , [ t' === t'' | (t', _):(t'', _):_ <- tails changing ] ])
    | (edgeId, (fs, ss)) <- allEdges
    , let (constant, changing) = partition (uncurry (==) . snd) (zip [t1, t2, t3] (zip fs ss)) ]
  faces <- catMaybes <$> sequence
    [ fmap (faceId,) <$>
        labelOf (foldr topeAndT topeTopT $ concat
          [ [ t' === s | (t', s) <- constant ]
          , [ t' === t'' | t':t'':_ <- tails changeFirst ]
          , [ t' === t'' | t':t'':_ <- tails changeSecond ]
          , [ topeLEQT t' t'' | t' <- changeSecond, t'' <- take 1 changeFirst ] ])
    | (faceId, (v1, v2, v3)) <- allFaces
    , let (constant, changeFirst, changeSecond) = mconcat $ flip map (zip4 [t1, t2, t3] v1 v2 v3) $ \case
            (t', s1, s2, s3)
              | s1 == s2 && s2 == s3 -> ([(t', s1)], [], [])
              | s1 /= s2 && s2 == s3 -> ([], [t'], [])
              | otherwise            -> ([], [], [t'])
    ]
  return $ renderCube defaultCamera (pi/7) $ \obj ->
    lookup obj (vertices <> edges <> faces)

renderTermSVG :: Eq var => TermT var -> TypeCheck var (Maybe String)
renderTermSVG t = typeOf t >>= \case
  TypeFunT _ orig arg mtope ret -> enterScope orig arg $ do
    maybe id localTope mtope $ do
      let labelOf tope = do
            checkTopeEntails tope >>= \case
              False -> pure Nothing
              True -> localTope tope $ do
                  body' <- whnfT (appT ret (S <$> t) (Pure Z))
                  bodyLabel <- ppTermInContext body'
                  let bodyLabel' = if length bodyLabel > 10 then take 7 bodyLabel <> "..." else bodyLabel
                  pure $ Just RenderObjectData
                    { renderObjectDataLabel = bodyLabel'
                    , renderObjectDataColor = "black"
                    }
      case arg of
        CubeProductT _ (CubeProductT _ Cube2T{} Cube2T{}) Cube2T{} -> do
          let t1 = firstT cube2T (firstT (cubeProductT cube2T cube2T) (Pure Z))
              t2 = secondT cube2T (firstT (cubeProductT cube2T cube2T) (Pure Z))
              t3 = secondT cube2T (Pure Z)
          Just <$> renderTermInCubeSVG (t1, t2, t3) labelOf

        CubeProductT _ Cube2T{} (CubeProductT _ Cube2T{} Cube2T{}) -> do
          let t1 = firstT cube2T (Pure Z)
              t2 = firstT cube2T (secondT (cubeProductT cube2T cube2T) (Pure Z))
              t3 = secondT cube2T (secondT (cubeProductT cube2T cube2T) (Pure Z))
          Just <$> renderTermInCubeSVG (t1, t2, t3) labelOf

        CubeProductT _ Cube2T{} Cube2T{} -> do
          let t1 = firstT cube2T (Pure Z)
              t2 = secondT cube2T (Pure Z)
          whnfT ret >>= \case
            TypeRestrictedT _info (TypeFunT _ orig2 arg2@Cube2T{} mtope2 ret2) _rs -> enterScope orig2 arg2 $ do
              maybe id localTope mtope2 $ do
                let labelOf2 tope = do
                      checkTopeEntails tope >>= \case
                        False -> pure Nothing
                        True -> localTope tope $ do
                            body' <- whnfT (appT ret2 (S <$> (appT ret (S <$> t) (Pure Z))) (Pure Z))
                            bodyLabel <- ppTermInContext body'
                            let bodyLabel' = if length bodyLabel > 10 then take 7 bodyLabel <> "..." else bodyLabel
                            pure $ Just RenderObjectData
                              { renderObjectDataLabel = bodyLabel'
                              , renderObjectDataColor = "black"
                              }
                    t1' = S <$> t1
                    t2' = S <$> t2
                    t3 = Pure Z
                Just <$> renderTermInCubeSVG (t1', t2', t3) labelOf2
            TypeFunT _ orig2 arg2@Cube2T{} mtope2 ret2 -> enterScope orig2 arg2 $ do
              maybe id localTope mtope2 $ do
                let labelOf2 tope = do
                      checkTopeEntails tope >>= \case
                        False -> pure Nothing
                        True -> localTope tope $ do
                            body' <- whnfT (appT ret2 (S <$> (appT ret (S <$> t) (Pure Z))) (Pure Z))
                            bodyLabel <- ppTermInContext body'
                            let bodyLabel' = if length bodyLabel > 10 then take 7 bodyLabel <> "..." else bodyLabel
                            pure $ Just RenderObjectData
                              { renderObjectDataLabel = bodyLabel'
                              , renderObjectDataColor = "black"
                              }
                    t1' = S <$> t1
                    t2' = S <$> t2
                    t3 = Pure Z
                Just <$> renderTermInCubeSVG (t1', t2', t3) labelOf2
            _ret' -> do
              let (===) = topeEQT
              x <- labelOf (topeAndT (t1 === cube2_0T) (t2 === cube2_0T))
              y <- labelOf (topeAndT (t1 === cube2_0T) (t2 === cube2_1T))
              z <- labelOf (topeAndT (t1 === cube2_1T) (t2 === cube2_0T))
              w <- labelOf (topeAndT (t1 === cube2_1T) (t2 === cube2_1T))
              f <- labelOf (t2 === cube2_0T)
              g <- labelOf (t2 === cube2_1T)
              h <- labelOf (t1 === cube2_0T)
              k <- labelOf (t1 === cube2_1T)
              d <- labelOf (t1 === t2)
              tr1 <- labelOf (topeLEQT t2 t1)
              tr2 <- labelOf (topeLEQT t1 t2)
              return $ Just $ renderCube defaultCamera 0 $ \case
                "000" -> x
                "010" -> y
                "100" -> z
                "110" -> w
                "000-100" -> f
                "010-110" -> g
                "000-010" -> h
                "100-110" -> k
                "000-110" -> d
                "000-100-110" -> tr1
                "000-010-110" -> tr2
                _ -> Nothing

        Cube2T{} -> do
          x <- labelOf (topeEQT (Pure Z) cube2_0T)
          y <- labelOf (topeEQT (Pure Z) cube2_1T)
          f <- labelOf topeTopT
          return $ Just $ renderCube defaultCamera 0 $ \case
            "000" -> x
            "100" -> y
            "000-100" -> f
            _ -> Nothing

        _ -> renderTermSVG (appT ret (S <$> t) (Pure Z))

  _t' -> return Nothing

type Point2D a = (a, a)
type Point3D a = (a, a, a)
type Edge3D a = (Point3D a, Point3D a)
type Face3D a = (Point3D a, Point3D a, Point3D a)
type Volume3D a = (Point3D a, Point3D a, Point3D a, Point3D a)

data CubeCoords2D a b = CubeCoords2D
  { vertices :: [(Point3D a, Point2D b)]
  , edges :: [(Edge3D a, (Point2D b, Point2D b))]
  , faces :: [(Face3D a, (Point2D b, Point2D b, Point2D b))]
  , volumes :: [(Volume3D a, (Point2D b, Point2D b, Point2D b, Point2D b))]
  }

data Matrix3D a = Matrix3D
  a a a
  a a a
  a a a

data Matrix4D a = Matrix4D
  a a a a
  a a a a
  a a a a
  a a a a

data Vector3D a = Vector3D a a a

data Vector4D a = Vector4D a a a a

rotateX :: Floating a => a -> Matrix3D a
rotateX theta = Matrix3D
  1 0 0
  0 (cos theta) (- sin theta)
  0 (sin theta) (cos theta)

rotateY :: Floating a => a -> Matrix3D a
rotateY theta = Matrix3D
  (cos theta) 0 (sin theta)
  0 1 0
  (- sin theta) 0 (cos theta)

rotateZ :: Floating a => a -> Matrix3D a
rotateZ theta = Matrix3D
  (cos theta) (- sin theta) 0
  (sin theta) (cos theta) 0
  0 0 1

data Camera a = Camera
  { cameraPos :: Point3D a
  , cameraFoV :: a
  , cameraAspectRatio :: a
  , cameraAngleY :: a
  , cameraAngleX :: a
  }

viewRotateX :: Floating a => Camera a -> Matrix4D a
viewRotateX Camera{..} = matrix3Dto4D (rotateX cameraAngleX)

viewRotateY :: Floating a => Camera a -> Matrix4D a
viewRotateY Camera{..} = matrix3Dto4D (rotateY cameraAngleY)

viewTranslate :: Num a => Camera a -> Matrix4D a
viewTranslate Camera{..} = Matrix4D
  1 0 0 0
  0 1 0 0
  0 0 1 0
  (-x) (-y) (-z) 1
  where
    (x, y, z) = cameraPos

project2D :: Floating a => Camera a -> Matrix4D a
project2D Camera{..} = Matrix4D
  (2 * n / (r - l)) 0 ((r + l) / (r - l)) 0
  0 (2 * n / (t - b)) ((t + b) / (t - b)) 0
  0 0 (- (f + n) / (f - n)) (- 2 * f * n / (f - n))
  0 0 (-1) 0
  where
    n = 1
    f = 2
    r = n * tan (cameraFoV / 2)
    l = -r
    t = r * cameraAspectRatio
    b = -t


matrixVectorMult4D :: Num a => Matrix4D a -> Vector4D a -> Vector4D a
matrixVectorMult4D
  (Matrix4D
    a1 a2 a3 a4
    b1 b2 b3 b4
    c1 c2 c3 c4
    d1 d2 d3 d4)
  (Vector4D a b c d)
    = Vector4D a' b' c' d'
  where
    a' = sum (zipWith (*) [a1, b1, c1, d1] [a, b, c, d])
    b' = sum (zipWith (*) [a2, b2, c2, d2] [a, b, c, d])
    c' = sum (zipWith (*) [a3, b3, c3, d3] [a, b, c, d])
    d' = sum (zipWith (*) [a4, b4, c4, d4] [a, b, c, d])

matrix3Dto4D :: Num a => Matrix3D a -> Matrix4D a
matrix3Dto4D
  (Matrix3D
    a1 b1 c1
    a2 b2 c2
    a3 b3 c3) = Matrix4D
      a1 b1 c1 0
      a2 b2 c2 0
      a3 b3 c3 0
      0 0 0 1

fromAffine :: Fractional a => Vector4D a -> (Point2D a, a)
fromAffine (Vector4D a b c d) = ((x, y), zIndex)
  where
    x = a / d
    y = b / d
    zIndex = c / d

point3Dto2D :: Floating a => Camera a -> a -> Point3D a -> (Point2D a, a)
point3Dto2D camera rotY (x, y, z) = fromAffine $
  foldr matrixVectorMult4D (Vector4D x y z 1) $ reverse
    [ matrix3Dto4D (rotateY rotY)
    , viewTranslate camera
    , viewRotateY camera
    , viewRotateX camera
    , project2D camera
    ]

data RenderObjectData = RenderObjectData
  { renderObjectDataLabel :: String
  , renderObjectDataColor :: String
  }

renderCube
  :: (Floating a, Show a)
  => Camera a
  -> a
  -> (String -> Maybe RenderObjectData)
  -> String
renderCube camera rotY renderDataOf = unlines $ filter (not . null)
  [ "<svg class=\"zoom\" style=\"float: right\" viewBox=\"-175 -200 350 375\" width=\"150\" height=\"150\">"
  , intercalate "\n"
      [ "  <path d=\"M " <> show x1 <> " " <> show y1
                <> " L " <> show x2 <> " " <> show y2
                <> " L " <> show x3 <> " " <> show y3
                <> " Z\" style=\"fill: " <> renderObjectDataColor <> "; opacity: 0.5\"><title>" <> renderObjectDataLabel <> "</title></path>"
      | (faceId, (((x1, y1), (x2, y2), (x3, y3)), _)) <- faces
      , Just RenderObjectData{..} <- [renderDataOf faceId]]
  , intercalate "\n"
      [ "  <polyline points=\"" <> show x1 <> "," <> show y1 <> " " <> show x2 <> "," <> show y2
        <> "\" stroke=\"" <> renderObjectDataColor <> "\" stroke-width=\"3\" marker-end=\"url(#arrow)\"><title>" <> renderObjectDataLabel <> "</title></polyline>"
      | (edge, (((x1, y1), (x2, y2)), _)) <- edges
      , Just RenderObjectData{..} <- [renderDataOf edge]]
  , intercalate "\n"
      [ "  <text x=\"" <> show x <> "\" y=\"" <> show y <> "\">" <> renderObjectDataLabel <> "</text>"
      | (v, ((x, y), _)) <- vertices
      , Just RenderObjectData{..} <- [renderDataOf v]]
  , "</svg>" ]
  where
    vertices =
      [ (show x <> show y <> show z, ((500 * x'', 500 * y''), zIndex))
      | x <- [0,1]
      , y <- [0,1]
      , z <- [0,1]
      , let f c = 2 * fromInteger c - 1
      , let x' = f x
      , let y' = f (1-y)
      , let z' = f z
      , let ((x'', y''), zIndex) = point3Dto2D camera rotY (x', y', z') ]

    radius = 20

    mkEdge r (x1, y1) (x2, y2) = ((x1 + dx, y1 + dy), ((x2 - dx), (y2 - dy)))
      where
        d = sqrt ((x2 - x1)^2 + (y2 - y1)^2)
        dx = r * (x2 - x1) / d
        dy = r * (y2 - y1) / d

    scaleAround (cx, cy) s (x, y) = (cx + s * (x - cx), cy + s * (y - cy))

    mkFace (x1, y1) (x2, y2) (x3, y3) = (p1, p2, p3)
      where
        cx = (x1 + x2 + x3) / 3
        cy = (y1 + y2 + y3) / 3
        p1 = scaleAround (cx, cy) 0.85 (x1, y1)
        p2 = scaleAround (cx, cy) 0.85 (x2, y2)
        p3 = scaleAround (cx, cy) 0.85 (x3, y3)

    edges =
      [ (intercalate "-" [fromName, toName], (mkEdge radius from to, 0))
      | (fromName, (from, _)) : vs <- tails vertices
      , (toName, (to, _)) <- vs
      , and (zipWith (<=) fromName toName)
      ]

    faces =
      [ (intercalate "-" [name1, name2, name3], (mkFace v1 v2 v3, 0))
      | (name1, (v1, _)) : vs <- tails vertices
      , (name2, (v2, _)) : vs' <- tails vs
      , and (zipWith (<=) name1 name2)
      , (name3, (v3, _)) <- vs'
      , and (zipWith (<=) name2 name3)
      ]


defaultCamera :: Floating a => Camera a
defaultCamera = Camera
  { cameraPos = (0, 7, 10)
  , cameraAngleY = pi
  , cameraAngleX = pi/5
  , cameraFoV = pi/15
  , cameraAspectRatio = 1
  }
