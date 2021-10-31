{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PatternSynonyms            #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
module Rzk.Free.Syntax.Example.PCF where

import qualified Bound.Scope                               as Scope
import qualified Bound.Var                                 as Bound
import           Control.Applicative
import           Data.Bifunctor
import           Data.Bifunctor.TH
import           Data.Char                                 (chr, isPrint,
                                                            isSpace, ord)
import qualified Data.HashSet                              as HashSet
import           Data.Maybe                                (fromMaybe)
import           Data.String                               (IsString (..))
import qualified Data.Text                                 as Text
import           Data.Text.Prettyprint.Doc                 as Doc
import           Data.Text.Prettyprint.Doc.Render.Terminal (putDoc)
import           System.IO.Unsafe                          (unsafePerformIO)
import           Text.Parser.Token                         ()
import           Text.Parser.Token.Style                   (emptyIdents)
import           Text.Trifecta                             (IdentifierStyle (..),
                                                            Parser,
                                                            TokenParsing,
                                                            symbol)
import qualified Text.Trifecta                             as Trifecta

import           Rzk.Free.Bound.Name
import           Rzk.Free.Syntax.FreeScoped
import           Rzk.Free.Syntax.FreeScoped.TypeCheck      (TypeCheck,
                                                            TypeError, TypeInfo,
                                                            assignType,
                                                            clarifyTypedTerm,
                                                            freshTypeMetaVar,
                                                            nonDep,
                                                            shouldHaveType,
                                                            typeOf,
                                                            typeOfScopedWith,
                                                            typecheckDist,
                                                            typecheckInScope,
                                                            unifyWithExpected,
                                                            untyped,
                                                            untypedScoped)
import qualified Rzk.Free.Syntax.FreeScoped.TypeCheck      as TypeCheck
import           Rzk.Free.Syntax.FreeScoped.Unification    (UVar (..))
import           Rzk.Free.Syntax.FreeScoped.Unification2   (HigherOrderUnifiable (..),
                                                            Unifiable (..))
import qualified Rzk.Free.Syntax.FreeScoped.Unification2   as Unification
import qualified Rzk.Syntax.Var                            as Rzk

-- * Generators

-- | Generating bifunctor for terms in simply typed lambda calculus.
data TermF scope term
  -- | Universe is the type of all types: \(\mathcal{U}\)
  = UniverseF

  -- | Type of functions: \(A \to B\)
  | FunF term term
  -- | Lambda function with an optional argument type: \(\lambda (x : A). t\)
  | LamF (Maybe term) scope
  -- | Application of one term to another: \((t_1) t_2\)
  | AppF term term

  -- | Non-recursive \(\mathsf{let}\)-expression:
  -- \(\mathsf{let\;} x = t_1 \mathsf{\;in\;} t_2\).
  | LetF term scope

  -- | Unit type: \(\mathsf{UNIT}\)
  | UnitTypeF
  -- | Unit (the only value of the unit type): \(\mathsf{unit}\)
  | UnitF

  -- | Fixpoint combinator: \(\mathsf{fix\;} t\)
  | FixF term

  -- | Type of natural numbers: \(\mathsf{NAT}\)
  | NatTypeF
  -- | Natural number literals: \(0, 1, 2, \ldots\)
  | NatLitF Integer
  -- | Multiplication of numbers: \(t_1 \times t_2\)
  | NatMultiplyF term term
  -- | Predecessor (decrement): \(\mathsf{pred\;} t\)
  | NatPredF term
  -- | Check if natural number is zero: \(\mathsf{isZero\;} t\)
  | NatIsZeroF term

  -- | Type of booleans: \(\mathsf{BOOL}\)
  | BoolTypeF
  -- | Boolean literal: \(\mathsf{true}\) or \(\mathsf{false}\)
  | BoolLitF Bool
  -- | \(\mathsf{if}\)-expression: \(\mathsf{if\;}t_{\text{cond}} \mathsf{\;them\;} t_1 \mathsf{\;else\;} t_2\)
  | BoolIfF term term term
  deriving (Show, Functor, Foldable, Traversable)

-- | Generating bifunctor for typed terms of simply typed lambda calculus.
type TypedTermF = TypeCheck.TypedF TermF

-- ** Useful type synonyms (could be generated by TH)

-- | An untyped/unchecked term of simply typed lambda calculus.
type Term b = TypeCheck.Term TermF b

-- | An untyped/unchecked term of simply typed lambda calculus
-- in one scope layer.
type TermInScope b a = TypeCheck.TermInScope TermF b a

-- | A 'Scope.Scope' with an untyped/unchecked term
-- of simply typed lambda calculus.
type ScopedTerm b = TypeCheck.ScopedTerm TermF b

type TypedTerm b = TypeCheck.TypedTerm TermF b
type TypedTermInScope b a = TypeCheck.TypedTermInScope TermF b a
type ScopedTypedTerm b = TypeCheck.ScopedTypedTerm TermF b

type UTypedTerm b a v = TypeCheck.UTypedTerm TermF b a v
type UTypedTermInScope b a v = TypeCheck.UTypedTermInScope TermF b a v
type UScopedTypedTerm b a v = TypeCheck.UScopedTypedTerm TermF b a v

type Term' = Term Rzk.Var Rzk.Var
type TermInScope' = TermInScope Rzk.Var Rzk.Var
type ScopedTerm' = ScopedTerm Rzk.Var Rzk.Var

type TypedTerm' = TypedTerm Rzk.Var Rzk.Var
type TypedTermInScope' = TypedTermInScope Rzk.Var Rzk.Var
type ScopedTypedTerm' = ScopedTypedTerm Rzk.Var Rzk.Var

type UTypedTerm' = UTypedTerm Rzk.Var Rzk.Var Rzk.Var
type UTypedTermInScope' = UTypedTermInScope Rzk.Var Rzk.Var Rzk.Var
type UScopedTypedTerm' = UScopedTypedTerm Rzk.Var Rzk.Var Rzk.Var

type InScope' = Bound.Var (Name Rzk.Var ())

type UTypedTerm'1 = UTypedTerm Rzk.Var (InScope' Rzk.Var) Rzk.Var
type UTypedTerm'2 = UTypedTerm Rzk.Var (InScope' (InScope' Rzk.Var)) Rzk.Var

type TypeInfo'2 = TypeInfo Rzk.Var UTypedTerm'2 (InScope' (InScope' Rzk.Var))

-- *** For typechecking

type TypeError' = TypeError UTypedTerm'

type TypeInfo' = TypeInfo Rzk.Var UTypedTerm' Rzk.Var
type TypeInfoInScope'
  = TypeInfo Rzk.Var UTypedTermInScope' (Bound.Var (Name Rzk.Var ()) Rzk.Var)

type TypeCheck' = TypeCheck UTypedTerm' Rzk.Var Rzk.Var
type TypeCheckInScope'
  = TypeCheck UTypedTermInScope' (Bound.Var (Name Rzk.Var ()) Rzk.Var) Rzk.Var

-- ** Pattern synonyms (should be generated with TH)

-- *** Untyped

-- | A variable.
pattern Var :: a -> Term b a
pattern Var x = PureScoped x

-- | Universe type \(\mathcal{U}_i\)
pattern Universe :: Term b a
pattern Universe = FreeScoped UniverseF

pattern Unit :: Term b a
pattern Unit = FreeScoped UnitF

pattern UnitType :: Term b a
pattern UnitType = FreeScoped UnitTypeF

pattern Let :: Term b a -> ScopedTerm b a -> Term b a
pattern Let u t = FreeScoped (LetF u t)

-- | A dependent product type (\(\Pi\)-type): \(\prod_{x : A} B(x)).
pattern Fun :: Term b a -> Term b a -> Term b a
pattern Fun a b = FreeScoped (FunF a b)

-- | A \(\lambda\)-abstraction.
pattern Lam :: Maybe (Term b a) -> ScopedTerm b a -> Term b a
pattern Lam ty body = FreeScoped (LamF ty body)

-- | An application of one term to another.
pattern App :: Term b a -> Term b a -> Term b a
pattern App t1 t2 = FreeScoped (AppF t1 t2)

pattern Fix :: Term b a -> Term b a
pattern Fix t = FreeScoped (FixF t)

pattern NatType :: Term b a
pattern NatType = FreeScoped NatTypeF

pattern NatLit :: Integer -> Term b a
pattern NatLit n = FreeScoped (NatLitF n)

pattern NatMultiply :: Term b a -> Term b a -> Term b a
pattern NatMultiply n m = FreeScoped (NatMultiplyF n m)

pattern NatPred :: Term b a -> Term b a
pattern NatPred n = FreeScoped (NatPredF n)

pattern NatIsZero :: Term b a -> Term b a
pattern NatIsZero n = FreeScoped (NatIsZeroF n)

pattern BoolType :: Term b a
pattern BoolType = FreeScoped BoolTypeF

pattern BoolLit :: Bool -> Term b a
pattern BoolLit b = FreeScoped (BoolLitF b)

pattern BoolIf :: Term b a -> Term b a -> Term b a -> Term b a
pattern BoolIf c t f = FreeScoped (BoolIfF c t f)

{-# COMPLETE
   Var, Universe,
   Fun, Lam, App,
   Let, Fix,
   UnitType, Unit,
   NatType, NatLit, NatMultiply, NatPred, NatIsZero,
   BoolType, BoolLit, BoolIf #-}

-- *** Typed

-- | A variable.
pattern VarT :: a -> TypedTerm b a
pattern VarT x = PureScoped x

-- | Universe type \(\mathcal{U}_i\)
pattern UniverseT :: Maybe (TypedTerm b a) -> TypedTerm b a
pattern UniverseT ty = TypeCheck.TypedT ty UniverseF

pattern UnitTypeT :: Maybe (TypedTerm b a) -> TypedTerm b a
pattern UnitTypeT ty = TypeCheck.TypedT ty UnitTypeF

pattern UnitT :: Maybe (TypedTerm b a) -> TypedTerm b a
pattern UnitT ty = TypeCheck.TypedT ty UnitF

-- | A dependent product type (\(\Pi\)-type): \(\prod_{x : A} B(x)).
pattern FunT :: Maybe (TypedTerm b a) -> TypedTerm b a -> TypedTerm b a -> TypedTerm b a
pattern FunT ty a b = TypeCheck.TypedT ty (FunF a b)

-- | A \(\lambda\)-abstraction.
pattern LamT :: Maybe (TypedTerm b a) -> Maybe (TypedTerm b a) -> ScopedTypedTerm b a -> TypedTerm b a
pattern LamT ty argType body = TypeCheck.TypedT ty (LamF argType body)

-- | An application of one term to another.
pattern AppT :: Maybe (TypedTerm b a) -> TypedTerm b a -> TypedTerm b a -> TypedTerm b a
pattern AppT ty t1 t2 = TypeCheck.TypedT ty (AppF t1 t2)

pattern LetT :: Maybe (TypedTerm b a) -> TypedTerm b a -> ScopedTypedTerm b a -> TypedTerm b a
pattern LetT ty term scope = TypeCheck.TypedT ty (LetF term scope)

pattern FixT :: Maybe (TypedTerm b a) -> TypedTerm b a -> TypedTerm b a
pattern FixT ty term = TypeCheck.TypedT ty (FixF term)

pattern NatTypeT :: Maybe (TypedTerm b a) -> TypedTerm b a
pattern NatTypeT ty = TypeCheck.TypedT ty NatTypeF

pattern NatLitT :: Maybe (TypedTerm b a) -> Integer -> TypedTerm b a
pattern NatLitT ty n = TypeCheck.TypedT ty (NatLitF n)

pattern NatMultiplyT :: Maybe (TypedTerm b a) -> TypedTerm b a -> TypedTerm b a -> TypedTerm b a
pattern NatMultiplyT ty n m = TypeCheck.TypedT ty (NatMultiplyF n m)

pattern NatPredT :: Maybe (TypedTerm b a) -> TypedTerm b a -> TypedTerm b a
pattern NatPredT ty n = TypeCheck.TypedT ty (NatPredF n)

pattern NatIsZeroT :: Maybe (TypedTerm b a) -> TypedTerm b a -> TypedTerm b a
pattern NatIsZeroT ty n = TypeCheck.TypedT ty (NatIsZeroF n)

pattern BoolTypeT :: Maybe (TypedTerm b a) -> TypedTerm b a
pattern BoolTypeT ty = TypeCheck.TypedT ty BoolTypeF

pattern BoolLitT :: Maybe (TypedTerm b a) -> Bool -> TypedTerm b a
pattern BoolLitT ty b = TypeCheck.TypedT ty (BoolLitF b)

pattern BoolIfT :: Maybe (TypedTerm b a) -> TypedTerm b a -> TypedTerm b a -> TypedTerm b a -> TypedTerm b a
pattern BoolIfT ty c t f = TypeCheck.TypedT ty (BoolIfF c t f)

{-# COMPLETE
   VarT, UniverseT,
   FunT, LamT, AppT,
   LetT, FixT,
   UnitTypeT, UnitT,
   NatTypeT, NatLitT, NatMultiplyT, NatPredT, NatIsZeroT,
   BoolTypeT, BoolLitT, BoolIfT #-}

-- ** Smart constructors

-- | Universe (type of types).
--
-- >>> universeT :: TypedTerm'
-- U : U
universeT :: TypedTerm b a
universeT = TypeCheck.TypedT Nothing UniverseF

natTypeT :: TypedTerm b a
natTypeT = NatTypeT (Just universeT)

boolTypeT :: TypedTerm b a
boolTypeT = BoolTypeT (Just universeT)

-- | Abstract over one variable in a term.
--
-- >>> lam Nothing "x" (App (Var "f") (Var "x")) :: Term'
-- λx₁ → f x₁
-- >>> lam Nothing "f" (App (Var "f") (Var "x")) :: Term'
-- λx₁ → x₁ x
-- >>> lam (Just (Var "A")) "x" (App (Var "f") (Var "x")) :: Term'
-- λ(x₁ : A) → f x₁
-- >>> lam (Just (Fun (Var "A") (Var "B"))) "f" (App (Var "f") (Var "x")) :: Term'
-- λ(x₁ : A → B) → x₁ x
lam :: Eq a => Maybe (Term a a) -> a -> Term a a -> Term a a
lam ty x body = Lam ty (abstract1Name x body)

-- | Abstract over one variable in a term (without type).
--
-- >>> lam_ "x" (App (Var "f") (Var "x")) :: Term'
-- λx₁ → f x₁
lam_ :: Eq a => a -> Term a a -> Term a a
lam_ x body = Lam Nothing (abstract1Name x body)

-- | Non-recursive \(\mathsf{let}\)-expression with one bound variable.
--
-- >>> let_ (App (Var "f") (Var "x")) "y" (App (Var "g") (Var "y")) :: Term'
-- let x₁ = f x in g x₁
let_ :: Eq a => Term a a -> a -> Term a a -> Term a a
let_ u x body = Let u (abstract1Name x body)

-- ** Evaluation

whnfUntyped :: Term b a -> Term b a
whnfUntyped = untyped . whnf . TypeCheck.pseudoTyped

nfUntyped :: Term b a -> Term b a
nfUntyped = untyped . nf . TypeCheck.pseudoTyped

-- | Evaluate a term to its weak head normal form (WHNF).
whnf :: TypedTerm b a -> TypedTerm b a
whnf = \case
  AppT ty f x ->
    case whnf f of
      LamT _ty _typeOfArg body ->
        whnf (Scope.instantiate1 x body)
      f' -> AppT ty f' x

  LetT _type term body -> whnf (Scope.instantiate1 term body)

  FixT ty term -> whnf (AppT ty term (FixT ty term))

  NatMultiplyT ty t1 t2 ->
    case whnf t1 of
      t1'@(NatLitT _ n) ->
        case whnf t2 of
          NatLitT _ m ->
            NatLitT ty (n * m)
          t2' -> NatMultiplyT ty t1' t2'
      t1' -> NatMultiplyT ty t1' t2

  NatPredT ty t ->
    case whnf t of
      NatLitT _ n -> NatLitT ty (n - 1)
      t'          -> NatPredT ty t'

  NatIsZeroT ty t ->
    case whnf t of
      NatLitT _ n -> BoolLitT (Just (BoolTypeT (Just universeT))) (n == 0)
      t'          -> NatIsZeroT ty t'

  BoolIfT ty c t f ->
    case whnf c of
      BoolLitT _ True  -> whnf t
      BoolLitT _ False -> whnf f
      c'               -> BoolIfT ty c' t f

  t@LamT{} -> t
  t@UniverseT{} -> t
  t@UnitTypeT{} -> t
  t@UnitT{} -> t
  t@VarT{} -> t
  t@FunT{} -> t
  t@NatTypeT{} -> t
  t@NatLitT{} -> t
  t@BoolTypeT{} -> t
  t@BoolLitT{} -> t

nf :: TypedTerm b a -> TypedTerm b a
nf = \case
  AppT ty f x ->
    case whnf f of
      LamT _ty _typeOfArg body ->
        nf (Scope.instantiate1 x body)
      f' -> AppT (nf <$> ty) (nf f') (nf x)

  LetT _type term body -> nf (Scope.instantiate1 term body)

  FixT ty term -> nf (AppT ty term (FixT ty term))

  NatMultiplyT ty t1 t2 ->
    case whnf t1 of
      t1'@(NatLitT _ n) ->
        case whnf t2 of
          NatLitT _ m ->
            NatLitT (nf <$> ty) (n * m)
          t2' -> NatMultiplyT (nf <$> ty) (nf t1') (nf t2')
      t1' -> NatMultiplyT (nf <$> ty) (nf t1') (nf t2)

  NatPredT ty t ->
    case whnf t of
      NatLitT _ n -> NatLitT (nf <$> ty) (n - 1)
      t'          -> NatPredT (nf <$> ty) (nf t')

  NatIsZeroT ty t ->
    case whnf t of
      NatLitT _ n -> BoolLitT (Just (BoolTypeT (Just universeT))) (n == 0)
      t'          -> NatIsZeroT (nf <$> ty) (nf t')

  BoolIfT ty c t f ->
    case whnf c of
      BoolLitT _ True  -> nf t
      BoolLitT _ False -> nf f
      c'               -> BoolIfT (nf <$> ty) (nf c') (nf t) (nf f)

  LamT ty typeOfArg body -> LamT (nf <$> ty) (nf <$> typeOfArg) (nfScope body)
  UniverseT ty -> UniverseT (nf <$> ty)
  UnitTypeT ty -> UnitTypeT (nf <$> ty)
  UnitT ty -> UnitT (nf <$> ty)
  FunT ty a b -> FunT (nf <$> ty) (nf a) (nf b)
  NatTypeT ty -> NatTypeT (nf <$> ty)
  NatLitT ty n -> NatLitT (nf <$> ty) n
  BoolTypeT ty -> BoolTypeT (nf <$> ty)
  BoolLitT ty n -> BoolLitT (nf <$> ty) n

  t@VarT{} -> t
  where
    nfScope = Scope.toScope . nf . Scope.fromScope

-- ** Unification

-- | Should be derived with TH or Generics.
instance Unifiable TermF where
  zipMatch (AppF f1 x1) (AppF f2 x2)
    = Just (AppF (Right (f1, f2)) (Right (x1, x2)))

  zipMatch (LamF argTy1 body1) (LamF argTy2 body2)
    = Just (LamF argTy (Right (body1, body2)))
    where
      argTy =
        case (argTy1, argTy2) of
          (Nothing, _)     -> Left <$> argTy2
          (_, Nothing)     -> Left <$> argTy1
          (Just x, Just y) -> Just (Right (x, y))

  zipMatch (FunF arg1 body1) (FunF arg2 body2)
    = Just (FunF (Right (arg1, arg2)) (Right (body1, body2)))

  zipMatch UniverseF UniverseF = Just UniverseF

  zipMatch UnitTypeF UnitTypeF = Just UnitTypeF
  zipMatch UnitF UnitF = Just UnitF

  zipMatch (LetF u1 t1) (LetF u2 t2)
    = Just (LetF (Right (u1, u2)) (Right (t1, t2)))

  zipMatch (FixF t1) (FixF t2)
    = Just (FixF (Right (t1, t2)))

  zipMatch NatTypeF NatTypeF = Just NatTypeF
  zipMatch (NatLitF n1) (NatLitF n2)
    | n1 == n2 = Just (NatLitF n1)
    | otherwise = Nothing
  zipMatch (NatMultiplyF n1 m1) (NatMultiplyF n2 m2)
    = Just (NatMultiplyF (Right (n1, n2)) (Right (m1, m2)))
  zipMatch (NatPredF n1) (NatPredF n2)
    = Just (NatPredF (Right (n1, n2)))
  zipMatch (NatIsZeroF n1) (NatIsZeroF n2)
    = Just (NatIsZeroF (Right (n1, n2)))

  zipMatch BoolTypeF BoolTypeF = Just BoolTypeF
  zipMatch (BoolLitF b1) (BoolLitF b2)
    | b1 == b2 = Just (BoolLitF b1)
    | otherwise = Nothing
  zipMatch (BoolIfF c1 t1 f1) (BoolIfF c2 t2 f2)
    = Just (BoolIfF (Right (c1, c2)) (Right (t1, t2)) (Right (f1, f2)))

  zipMatch FunF{} _ = Nothing
  zipMatch LamF{} _ = Nothing
  zipMatch UniverseF{} _ = Nothing
  zipMatch AppF{} _ = Nothing
  zipMatch UnitTypeF{} _ = Nothing
  zipMatch UnitF{} _ = Nothing
  zipMatch LetF{} _ = Nothing
  zipMatch FixF{} _ = Nothing
  zipMatch NatTypeF{} _ = Nothing
  zipMatch NatLitF{} _ = Nothing
  zipMatch NatMultiplyF{} _ = Nothing
  zipMatch NatPredF{} _ = Nothing
  zipMatch NatIsZeroF{} _ = Nothing
  zipMatch BoolTypeF{} _ = Nothing
  zipMatch BoolLitF{} _ = Nothing
  zipMatch BoolIfF{} _ = Nothing

instance HigherOrderUnifiable TermF where
  appSome _ []     = error "cannot apply to zero arguments"
  appSome f (x:xs) = (AppF f x, xs)

  unAppSome (AppF f x) = Just (f, [x])
  unAppSome _          = Nothing

  abstract = LamF Nothing

unifyTerms
  :: (Eq v, Eq a)
  => [v]
  -> UTypedTerm b a v
  -> UTypedTerm b a v
  -> [([(v, UTypedTerm b a v)], [(UTypedTerm b a v, UTypedTerm b a v)])]
unifyTerms mvars t1 t2 = Unification.driver mvars whnf (t1, t2)

unifyTerms_
  :: (Eq v, Eq a)
  => [v]
  -> UTypedTerm b a v
  -> UTypedTerm b a v
  -> [(v, UTypedTerm b a v)]
unifyTerms_ mvars t1 t2 = fst (head (unifyTerms mvars t1 t2))

unifyTerms'
  :: UTypedTerm'
  -> UTypedTerm'
  -> [([(Rzk.Var, UTypedTerm')], [(UTypedTerm', UTypedTerm')])]
unifyTerms' = unifyTerms (iterate succ "?")

-- | Unify two typed terms with meta-variables.
unifyTerms'_
  :: UTypedTerm'
  -> UTypedTerm'
  -> [(Rzk.Var, UTypedTerm')]
unifyTerms'_ t1 t2 = fst (head (unifyTerms' t1 t2))


-- ** Typechecking and inference

instance TypeCheck.TypeCheckable TermF where
  inferTypeFor = inferTypeForTermF
  whnfT = whnf
  universeT = TypeCheck.TypedT Nothing UniverseF

inferTypeForTermF
  :: (Eq a, Eq v)
  => TermF
        (TypeCheck (UTypedTermInScope b a v) (Bound.Var (Name b ()) a) v
            (UScopedTypedTerm b a v))
        (TypeCheck (UTypedTerm b a v) a v (UTypedTerm b a v))
  -> TypeCheck (UTypedTerm b a v) a v
        (TypedTermF (UScopedTypedTerm b a v) (UTypedTerm b a v))
inferTypeForTermF term = case term of
  UniverseF -> pure (TypeCheck.TypedF UniverseF (Just universeT))
  -- a -> b
  FunF inferA inferB -> do
    a <- inferA
    _ <- a `shouldHaveType` universeT
    b <- inferB
    _ <- b `shouldHaveType` universeT
    pure (TypeCheck.TypedF (FunF a b) (Just universeT))

  LamF minferTypeOfArg inferBody -> do
    typeOfArg <- case minferTypeOfArg of
      Just inferTypeOfArg -> inferTypeOfArg
      Nothing             -> VarT . UMetaVar <$> freshTypeMetaVar
    typeOfArg' <- typeOfArg `shouldHaveType` universeT
    scopedTypedBody <- typecheckInScope $ do
      assignType (Bound.B (Name Nothing ())) (fmap Bound.F typeOfArg') -- FIXME: unnamed?
      inferBody
    typeOfBody <- typeOfScopedWith typeOfArg' scopedTypedBody >>= nonDep
    typeOfBody' <- typeOfBody `shouldHaveType` universeT
    pure $ TypeCheck.TypedF
      (LamF (typeOfArg <$ minferTypeOfArg) scopedTypedBody)
      (Just (FunT (Just universeT) typeOfArg' typeOfBody'))

  AppF infer_f infer_x -> do
    f <- infer_f
    x <- infer_x
    TypeCheck.TypedF (AppF f x) . Just <$> do
      typeOf f >>= \case
        FunT _ argType bodyType -> do
          _ <- x `shouldHaveType` argType
          bodyType `shouldHaveType` universeT
        t@(VarT _) -> do
          bodyType <- VarT . UMetaVar <$> freshTypeMetaVar
          typeOf_x <- typeOf x
          _ <- t `unifyWithExpected` FunT (Just universeT) typeOf_x bodyType
          clarifyTypedTerm bodyType
        _ -> fail "inferTypeForF: application of a non-function"

  UnitTypeF -> pure (TypeCheck.TypedF UnitTypeF (Just universeT))
  UnitF -> pure (TypeCheck.TypedF UnitF (Just (UnitTypeT (Just universeT))))
  LetF inferArg inferBody -> do
    arg <- inferArg
    typeOfArg <- typeOf arg
    typeOfArg' <- typeOfArg `shouldHaveType` universeT
    scopedTypedBody <- typecheckInScope $ do
      assignType (Bound.B (Name Nothing ())) (fmap Bound.F typeOfArg')
      inferBody
    typeOfBody <- typeOfScopedWith typeOfArg' scopedTypedBody >>= nonDep
    typeOfBody' <- typeOfBody `shouldHaveType` universeT
    pure $ TypeCheck.TypedF
      (LetF arg scopedTypedBody)
      (Just typeOfBody')

  FixF inferTerm -> do
    f <- inferTerm
    TypeCheck.TypedF (FixF f) . Just <$> do
      typeOf f >>= \case
        FunT _ argType bodyType -> do
          bodyType `unifyWithExpected` argType
        t@(VarT _) -> do
          resultType <- VarT . UMetaVar <$> freshTypeMetaVar
          _ <- t `unifyWithExpected` FunT (Just universeT) resultType resultType
          clarifyTypedTerm resultType
        _ -> fail "inferTypeForF: fix used with a non-function"

  NatTypeF -> pure (TypeCheck.TypedF NatTypeF (Just universeT))
  NatLitF n -> pure (TypeCheck.TypedF (NatLitF n) (Just (NatTypeT (Just universeT))))
  NatMultiplyF inferN inferM -> do
    n <- inferN
    n' <- n `shouldHaveType` natTypeT
    m <- inferM
    m' <- m `shouldHaveType` natTypeT
    return (TypeCheck.TypedF (NatMultiplyF n' m') (Just natTypeT))
  NatPredF inferN -> do
    n <- inferN >>= (`shouldHaveType` natTypeT)
    return (TypeCheck.TypedF (NatPredF n) (Just natTypeT))
  NatIsZeroF inferN -> do
    n <- inferN >>= (`shouldHaveType` natTypeT)
    return (TypeCheck.TypedF (NatIsZeroF n) (Just boolTypeT))

  BoolTypeF -> pure (TypeCheck.TypedF BoolTypeF (Just universeT))
  BoolLitF b -> pure (TypeCheck.TypedF (BoolLitF b) (Just (BoolTypeT (Just universeT))))

  BoolIfF inferCond inferTrue inferFalse -> do
    cond <- inferCond >>= (`shouldHaveType` boolTypeT)
    true <- inferTrue
    typeOfTrue <- typeOf true
    false <- inferFalse >>= (`shouldHaveType` typeOfTrue)
    pure (TypeCheck.TypedF (BoolIfF cond true false) (Just typeOfTrue))

execTypeCheck' :: TypeCheck' a -> Either TypeError' a
execTypeCheck' = TypeCheck.execTypeCheck defaultFreshMetaVars

runTypeCheckOnce' :: TypeCheck' a -> Either TypeError' (a, TypeInfo')
runTypeCheckOnce' = TypeCheck.runTypeCheckOnce defaultFreshMetaVars

infer' :: Term' -> TypeCheck' UTypedTerm'
infer' = TypeCheck.infer

typecheck' :: Term' -> Term' -> TypeCheck' UTypedTerm'
typecheck' = TypeCheck.typecheckUntyped

inferScoped' :: ScopedTerm' -> TypeCheck' UScopedTypedTerm'
inferScoped' = TypeCheck.inferScoped

inferInScope' :: TermInScope' -> TypeCheck' UTypedTermInScope'
inferInScope' = fmap (fmap TypeCheck.dist') . typecheckInScope . typecheckDist . TypeCheck.infer

unsafeInfer' :: Term' -> UTypedTerm'
unsafeInfer' = unsafeUnpack . execTypeCheck' . infer'
  where
    unsafeUnpack (Right typedTerm) = typedTerm
    unsafeUnpack _ = error "unsafeInfer': failed to extract term with inferred type"

-- ** Pretty-printing

instance (Pretty n, Pretty b) => Pretty (Name n b) where
  pretty (Name Nothing b)     = pretty b
  pretty (Name (Just name) b) = "<" <> pretty name <> " " <> pretty b <> ">"

instance (Pretty b, Pretty a) => Pretty (Bound.Var b a) where
  pretty (Bound.B b) = "<bound " <> pretty b <> ">"
  pretty (Bound.F x) = "<free " <> pretty x <> ">"

instance IsString a => IsString (Bound.Var b a) where
  fromString = Bound.F . fromString

-- | Uses 'Pretty' instance.
instance (Pretty a, Pretty b, IsString a) => Show (Term b a) where
  show = show . pretty

-- | Uses default names (@x@ with a positive integer subscript) for bound variables:
instance (Pretty a, Pretty b, IsString a) => Pretty (Term b a) where
  pretty = ppTerm defaultFreshVars

defaultFreshVars :: IsString a => [a]
defaultFreshVars = mkDefaultFreshVars "x"

defaultFreshMetaVars :: IsString a => [a]
defaultFreshMetaVars = mkDefaultFreshVars "M"

mkDefaultFreshVars :: IsString a => String -> [a]
mkDefaultFreshVars prefix = [ fromString (prefix <> toIndex i) | i <- [1..] ]
  where
    toIndex n = index
      where
        digitToSub c = chr ((ord c - ord '0') + ord '₀')
        index = map digitToSub (show n)

instance (Pretty a, Pretty b, IsString a) => Show (TypedTerm b a) where
  show = \case
    FreeScoped (TypeCheck.TypedF term ty) -> show (FreeScoped (bimap untypedScoped untyped term)) <> " : " <> show (untyped (fromMaybe universeT ty))
    t -> show (untyped t)

ppTypedTerm :: (Pretty a, Pretty b) => [a] -> TypedTerm b a -> Doc ann
ppTypedTerm vars = ppTerm vars . untyped

-- | Pretty-print an untyped term.
ppTerm :: (Pretty a, Pretty b) => [a] -> Term b a -> Doc ann
ppTerm vars = \case
  Var x -> pretty x

  Universe -> "U"

  Fun a b -> ppTermFun vars a <+> "→" <+> ppTerm vars b
  Lam Nothing body -> ppScopedTerm vars body $ \x body' ->
    "λ" <> pretty x <+> "→" <+> body'
  Lam (Just ty) body -> ppScopedTerm vars body $ \x body' ->
    "λ" <> parens (pretty x <+> ":" <+> ppTerm vars ty) <+> "→" <+> body'
  App f x -> ppTermFun vars f <+> ppTermArg vars x

  Fix f -> "fix" <+> ppTermArg vars f

  UnitType -> "UNIT"
  Unit -> "unit"
  Let u t -> ppScopedTerm vars t $ \x t' ->
    align (hsep ["let" <+> pretty x <+> "=" <+> ppTerm vars u <+> "in", t'])

  NatType -> "NAT"
  NatLit n -> pretty n
  NatMultiply n m -> ppTermArg vars n <+> "*" <+> ppTermArg vars m
  NatPred n -> "pred" <+> ppTermArg vars n
  NatIsZero n -> "isZero" <+> ppTermArg vars n

  BoolType -> "BOOL"
  BoolLit True -> "true"
  BoolLit False -> "false"
  BoolIf c t f -> "if" <+> ppTermArg vars c <+> "then" <+> ppTermArg vars t <+> "else" <+> ppTermArg vars f

ppElimWithArgs :: (Pretty a, Pretty b) => [a] -> Doc ann -> [Term b a] -> Doc ann
ppElimWithArgs vars name args = name <> tupled (map (ppTermFun vars) args)

-- | Pretty-print an untyped in a head position.
ppTermFun :: (Pretty a, Pretty b) => [a] -> Term b a -> Doc ann
ppTermFun vars = \case
  t@Var{} -> ppTerm vars t
  t@App{} -> ppTerm vars t
  t@Universe{} -> ppTerm vars t
  t@Unit{} -> ppTerm vars t
  t@UnitType{} -> ppTerm vars t
  t@Fix{} -> ppTerm vars t
  t@NatType{} -> ppTerm vars t
  t@NatLit{} -> ppTerm vars t
  t@BoolType{} -> ppTerm vars t
  t@BoolLit{} -> ppTerm vars t

  t@Lam{} -> Doc.parens (ppTerm vars t)
  t@Fun{} -> Doc.parens (ppTerm vars t)
  t@Let{} -> Doc.parens (ppTerm vars t)
  t@NatMultiply{} -> Doc.parens (ppTerm vars t)
  t@NatPred{} -> Doc.parens (ppTerm vars t)
  t@NatIsZero{} -> Doc.parens (ppTerm vars t)
  t@BoolIf{} -> Doc.parens (ppTerm vars t)


-- | Pretty-print an untyped in an argument position.
ppTermArg :: (Pretty a, Pretty b) => [a] -> Term b a -> Doc ann
ppTermArg vars = \case
  t@Var{} -> ppTerm vars t
  t@Universe{} -> ppTerm vars t
  t@Unit{} -> ppTerm vars t
  t@UnitType{} -> ppTerm vars t
  t@NatType{} -> ppTerm vars t
  t@NatLit{} -> ppTerm vars t
  t@BoolType{} -> ppTerm vars t
  t@BoolLit{} -> ppTerm vars t

  t@App{} -> Doc.parens (ppTerm vars t)
  t@Fix{} -> Doc.parens (ppTerm vars t)
  t@Lam{} -> Doc.parens (ppTerm vars t)
  t@Fun{} -> Doc.parens (ppTerm vars t)
  t@Let{} -> Doc.parens (ppTerm vars t)
  t@NatMultiply{} -> Doc.parens (ppTerm vars t)
  t@NatPred{} -> Doc.parens (ppTerm vars t)
  t@NatIsZero{} -> Doc.parens (ppTerm vars t)
  t@BoolIf{} -> Doc.parens (ppTerm vars t)

ppScopedTerm
  :: (Pretty a, Pretty b)
  => [a] -> ScopedTerm b a -> (a -> Doc ann -> Doc ann) -> Doc ann
ppScopedTerm [] _ _            = error "not enough fresh names"
ppScopedTerm (x:xs) t withScope = withScope x (ppTerm xs (Scope.instantiate1 (Var x) t))

-- ** Examples

-- | Each example presents:
--
-- * an untyped term
-- * a typed term (with inferred type)
-- * extra type information (inferred types of free variables, known information about meta-variables, unresolved constraints, etc.)
--
-- @
-- Example #1:
-- fix (λx₁ → λx₂ → if (isZero x₂) then 1 else (x₂ * (x₁ (pred x₂))))
-- fix (λx₁ → λx₂ → if (isZero x₂) then 1 else (x₂ * (x₁ (pred x₂)))) : NAT → NAT
-- TypeInfo
--   { knownFreeVars = []
--   , knownMetaVars = [(M₃,U : U),(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = [(M₃,NAT : U),(M₁,NAT → ?M₃ : U),(M₂,NAT : U)]
--   , constraints   = []
--   , freshMetaVars = [M₄,M₅,M₆,M₇,M₈,...]
--   }
--
--
-- Example #2:
-- λ(x₁ : (λx₁ → x₁) A) → (λx₂ → x₂) x₁
-- λ(x₁ : (λx₁ → x₁) A) → (λx₂ → x₂) x₁ : (λx₁ → x₁) A → (λx₁ → x₁) A
-- TypeInfo
--   { knownFreeVars = [(A,U : U)]
--   , knownMetaVars = [(M₃,U : U),(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = [(M₃,(λx₁ → x₁) A : U),(M₁,U : U),(M₂,?M₁)]
--   , constraints   = []
--   , freshMetaVars = [M₄,M₅,M₆,M₇,M₈,...]
--   }
--
--
-- Example #3:
-- let x₁ = λx₁ → λx₂ → x₂ in let x₂ = λx₂ → λx₃ → λx₄ → x₃ (x₂ x₃ x₄) in x₂ (x₂ x₁)
-- let x₁ = λx₁ → λx₂ → x₂ in let x₂ = λx₂ → λx₃ → λx₄ → x₃ (x₂ x₃ x₄) in x₂ (x₂ x₁) : (?M₇ → ?M₇) → ?M₇ → ?M₇
-- TypeInfo
--   { knownFreeVars = []
--   , knownMetaVars = [(M₈,U : U),(M₇,U : U),(M₆,U : U),(M₅,U : U),(M₄,U : U),(M₃,U : U),(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = [(M₈,?M₇),(M₅,?M₇),(M₁,?M₇ → ?M₈ : U),(M₂,?M₇),(M₂,?M₅),(M₁,?M₇ → ?M₈ : U),(M₄,?M₇ → ?M₈ : U),(M₆,?M₅ → ?M₇ : U),(M₃,?M₄ → ?M₆ : U)]
--   , constraints   = []
--   , freshMetaVars = [M₉,M₁₀,M₁₁,M₁₂,M₁₃,...]
--   }
--
--
-- Example #4:
-- let x₁ = λx₁ → λx₂ → x₂ in x₁
-- let x₁ = λx₁ → λx₂ → x₂ in x₁ : ?M₁ → ?M₂ → ?M₂
-- TypeInfo
--   { knownFreeVars = []
--   , knownMetaVars = [(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = []
--   , constraints   = []
--   , freshMetaVars = [M₃,M₄,M₅,M₆,M₇,...]
--   }
--
--
-- Example #5:
-- (λx₁ → x₁) (λx₁ → λx₂ → x₂)
-- (λx₁ → x₁) (λx₁ → λx₂ → x₂) : ?M₂ → ?M₃ → ?M₃
-- TypeInfo
--   { knownFreeVars = []
--   , knownMetaVars = [(M₃,U : U),(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = [(M₁,?M₂ → ?M₃ → ?M₃ : U)]
--   , constraints   = []
--   , freshMetaVars = [M₄,M₅,M₆,M₇,M₈,...]
--   }
--
--
-- Example #6:
-- let x₁ = unit in unit
-- let x₁ = unit in unit : UNIT
-- TypeInfo
--   { knownFreeVars = []
--   , knownMetaVars = []
--   , knownSubsts   = []
--   , constraints   = []
--   , freshMetaVars = [M₁,M₂,M₃,M₄,M₅,...]
--   }
--
--
-- Example #7:
-- let x₁ = unit in x₁
-- let x₁ = unit in x₁ : UNIT
-- TypeInfo
--   { knownFreeVars = []
--   , knownMetaVars = []
--   , knownSubsts   = []
--   , constraints   = []
--   , freshMetaVars = [M₁,M₂,M₃,M₄,M₅,...]
--   }
--
--
-- Example #8:
-- λx₁ → λx₂ → x₁ x₂
-- λx₁ → λx₂ → x₁ x₂ : (?M₂ → ?M₃) → ?M₂ → ?M₃
-- TypeInfo
--   { knownFreeVars = []
--   , knownMetaVars = [(M₃,U : U),(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = [(M₁,?M₂ → ?M₃ : U)]
--   , constraints   = []
--   , freshMetaVars = [M₄,M₅,M₆,M₇,M₈,...]
--   }
--
--
-- Example #9:
-- λ(x₁ : UNIT → UNIT) → λ(x₂ : UNIT) → x₁ x₂
-- λ(x₁ : UNIT → UNIT) → λ(x₂ : UNIT) → x₁ x₂ : (UNIT → UNIT) → UNIT → UNIT
-- TypeInfo
--   { knownFreeVars = []
--   , knownMetaVars = []
--   , knownSubsts   = []
--   , constraints   = []
--   , freshMetaVars = [M₁,M₂,M₃,M₄,M₅,...]
--   }
--
--
-- Example #10:
-- λ(x₁ : A → B) → λ(x₂ : A) → x₁ x₂
-- λ(x₁ : A → B) → λ(x₂ : A) → x₁ x₂ : (A → B) → A → B
-- TypeInfo
--   { knownFreeVars = [(B,U : U),(A,U : U)]
--   , knownMetaVars = [(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = [(M₂,U : U),(M₁,U : U)]
--   , constraints   = []
--   , freshMetaVars = [M₃,M₄,M₅,M₆,M₇,...]
--   }
--
--
-- Example #11:
-- λx₁ → λx₂ → x₂
-- λx₁ → λx₂ → x₂ : ?M₁ → ?M₂ → ?M₂
-- TypeInfo
--   { knownFreeVars = []
--   , knownMetaVars = [(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = []
--   , constraints   = []
--   , freshMetaVars = [M₃,M₄,M₅,M₆,M₇,...]
--   }
--
--
-- Example #12:
-- λx₁ → λx₂ → x₁
-- λx₁ → λx₂ → x₁ : ?M₁ → ?M₂ → ?M₁
-- TypeInfo
--   { knownFreeVars = []
--   , knownMetaVars = [(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = []
--   , constraints   = []
--   , freshMetaVars = [M₃,M₄,M₅,M₆,M₇,...]
--   }
--
--
-- Example #13:
-- λ(x₁ : A → B) → λx₂ → x₁ x₂
-- λ(x₁ : A → B) → λx₂ → x₁ x₂ : (A → B) → A → B
-- TypeInfo
--   { knownFreeVars = [(B,U : U),(A,U : U)]
--   , knownMetaVars = [(M₃,U : U),(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = [(M₃,A),(M₂,U : U),(M₁,U : U)]
--   , constraints   = []
--   , freshMetaVars = [M₄,M₅,M₆,M₇,M₈,...]
--   }
--
--
-- Example #14:
-- λx₁ → x₁
-- λx₁ → x₁ : ?M₁ → ?M₁
-- TypeInfo
--   { knownFreeVars = []
--   , knownMetaVars = [(M₁,U : U)]
--   , knownSubsts   = []
--   , constraints   = []
--   , freshMetaVars = [M₂,M₃,M₄,M₅,M₆,...]
--   }
--
--
-- Example #15:
-- λ(x₁ : A) → x₁
-- λ(x₁ : A) → x₁ : A → A
-- TypeInfo
--   { knownFreeVars = [(A,U : U)]
--   , knownMetaVars = [(M₁,U : U)]
--   , knownSubsts   = [(M₁,U : U)]
--   , constraints   = []
--   , freshMetaVars = [M₂,M₃,M₄,M₅,M₆,...]
--   }
--
--
-- Example #16:
-- λ(x₁ : A → B) → x₁
-- λ(x₁ : A → B) → x₁ : (A → B) → A → B
-- TypeInfo
--   { knownFreeVars = [(B,U : U),(A,U : U)]
--   , knownMetaVars = [(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = [(M₂,U : U),(M₁,U : U)]
--   , constraints   = []
--   , freshMetaVars = [M₃,M₄,M₅,M₆,M₇,...]
--   }
--
--
-- Example #17:
-- λx₁ → x₁ x₁
-- Type Error: TypeErrorOther "unable to unify ..."
--
-- Example #18:
-- λx₁ → x₁ unit
-- λx₁ → x₁ unit : (UNIT → ?M₂) → ?M₂
-- TypeInfo
--   { knownFreeVars = []
--   , knownMetaVars = [(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = [(M₁,UNIT → ?M₂ : U)]
--   , constraints   = []
--   , freshMetaVars = [M₃,M₄,M₅,M₆,M₇,...]
--   }
--
--
-- Example #19:
-- A → UNIT
-- A → UNIT : U
-- TypeInfo
--   { knownFreeVars = [(A,U : U)]
--   , knownMetaVars = [(M₁,U : U)]
--   , knownSubsts   = [(M₁,U : U)]
--   , constraints   = []
--   , freshMetaVars = [M₂,M₃,M₄,M₅,M₆,...]
--   }
--
--
-- Example #20:
-- A → B
-- A → B : U
-- TypeInfo
--   { knownFreeVars = [(B,U : U),(A,U : U)]
--   , knownMetaVars = [(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = [(M₂,U : U),(M₁,U : U)]
--   , constraints   = []
--   , freshMetaVars = [M₃,M₄,M₅,M₆,M₇,...]
--   }
--
--
-- Example #21:
-- λx₁ → λ(x₂ : UNIT) → x₁ (x₁ x₂)
-- λx₁ → λ(x₂ : UNIT) → x₁ (x₁ x₂) : (UNIT → UNIT) → UNIT → UNIT
-- TypeInfo
--   { knownFreeVars = []
--   , knownMetaVars = [(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = [(M₂,UNIT : U),(M₁,UNIT → ?M₂ : U)]
--   , constraints   = []
--   , freshMetaVars = [M₃,M₄,M₅,M₆,M₇,...]
--   }
--
--
-- Example #22:
-- unit
-- unit : UNIT
-- TypeInfo
--   { knownFreeVars = []
--   , knownMetaVars = []
--   , knownSubsts   = []
--   , constraints   = []
--   , freshMetaVars = [M₁,M₂,M₃,M₄,M₅,...]
--   }
--
--
-- Example #23:
-- unit unit
-- Type Error: TypeErrorOther "inferTypeForF: application of a non-function"
--
-- Example #24:
-- UNIT
-- UNIT : U
-- TypeInfo
--   { knownFreeVars = []
--   , knownMetaVars = []
--   , knownSubsts   = []
--   , constraints   = []
--   , freshMetaVars = [M₁,M₂,M₃,M₄,M₅,...]
--   }
--
--
-- Example #25:
-- x
-- x
-- TypeInfo
--   { knownFreeVars = [(x,?M₁)]
--   , knownMetaVars = [(M₁,U : U)]
--   , knownSubsts   = []
--   , constraints   = []
--   , freshMetaVars = [M₂,M₃,M₄,M₅,M₆,...]
--   }
--
--
-- Example #26:
-- f unit
-- f unit : ?M₂
-- TypeInfo
--   { knownFreeVars = [(f,UNIT → ?M₂ : U)]
--   , knownMetaVars = [(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = [(M₁,UNIT → ?M₂ : U)]
--   , constraints   = [(?M₂,?M₂)]
--   , freshMetaVars = [M₃,M₄,M₅,M₆,M₇,...]
--   }
--
--
-- Example #27:
-- f (f unit)
-- f (f unit) : UNIT
-- TypeInfo
--   { knownFreeVars = [(f,UNIT → UNIT : U)]
--   , knownMetaVars = [(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = [(M₂,UNIT : U),(M₁,UNIT → ?M₂ : U)]
--   , constraints   = []
--   , freshMetaVars = [M₃,M₄,M₅,M₆,M₇,...]
--   }
--
--
-- Example #28:
-- unit → unit
-- Type Error: TypeErrorOther "unable to unify ..."
--
-- Example #29:
-- UNIT → UNIT
-- UNIT → UNIT : U
-- TypeInfo
--   { knownFreeVars = []
--   , knownMetaVars = []
--   , knownSubsts   = []
--   , constraints   = []
--   , freshMetaVars = [M₁,M₂,M₃,M₄,M₅,...]
--   }
--
--
-- Example #30:
-- x
-- x
-- TypeInfo
--   { knownFreeVars = [(x,?M₁)]
--   , knownMetaVars = [(M₁,U : U)]
--   , knownSubsts   = []
--   , constraints   = []
--   , freshMetaVars = [M₂,M₃,M₄,M₅,M₆,...]
--   }
--
--
-- Example #31:
-- f x
-- f x : ?M₃
-- TypeInfo
--   { knownFreeVars = [(x,?M₂),(f,?M₂ → ?M₃ : U)]
--   , knownMetaVars = [(M₃,U : U),(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = [(M₁,?M₂ → ?M₃ : U)]
--   , constraints   = [(?M₂,?M₂),(?M₃,?M₃)]
--   , freshMetaVars = [M₄,M₅,M₆,M₇,M₈,...]
--   }
--
--
-- Example #32:
-- λ(x₁ : unit) → x₁
-- Type Error: TypeErrorOther "unable to unify ..."
--
-- Example #33:
-- λ(x₁ : unit) → y
-- Type Error: TypeErrorOther "unable to unify ..."
--
-- Example #34:
-- λ(x₁ : A) → x₁
-- λ(x₁ : A) → x₁ : A → A
-- TypeInfo
--   { knownFreeVars = [(A,U : U)]
--   , knownMetaVars = [(M₁,U : U)]
--   , knownSubsts   = [(M₁,U : U)]
--   , constraints   = []
--   , freshMetaVars = [M₂,M₃,M₄,M₅,M₆,...]
--   }
--
--
-- Example #35:
-- λ(x₁ : A → B) → x₁
-- λ(x₁ : A → B) → x₁ : (A → B) → A → B
-- TypeInfo
--   { knownFreeVars = [(B,U : U),(A,U : U)]
--   , knownMetaVars = [(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = [(M₂,U : U),(M₁,U : U)]
--   , constraints   = []
--   , freshMetaVars = [M₃,M₄,M₅,M₆,M₇,...]
--   }
--
--
-- Example #36:
-- λ(x₁ : (λx₁ → λx₂ → x₁ (x₁ (x₁ (x₁ (x₁ x₂))))) (λx₁ → λx₂ → x₁ (x₁ (x₁ (x₁ (x₁ (x₁ x₂)))))) (λx₁ → x₁) A) → (λx₂ → x₂) x₁
-- λ(x₁ : (λx₁ → λx₂ → x₁ (x₁ (x₁ (x₁ (x₁ x₂))))) (λx₁ → λx₂ → x₁ (x₁ (x₁ (x₁ (x₁ (x₁ x₂)))))) (λx₁ → x₁) A) → (λx₂ → x₂) x₁ : (λx₁ → λx₂ → x₁ (x₁ (x₁ (x₁ (x₁ x₂))))) (λx₁ → λx₂ → x₁ (x₁ (x₁ (x₁ (x₁ (x₁ x₂)))))) (λx₁ → x₁) A → (λx₁ → λx₂ → x₁ (x₁ (x₁ (x₁ (x₁ x₂))))) (λx₁ → λx₂ → x₁ (x₁ (x₁ (x₁ (x₁ (x₁ x₂)))))) (λx₁ → x₁) A
-- TypeInfo
--   { knownFreeVars = [(A,U : U)]
--   , knownMetaVars = [(M₉,U : U),(M₈,U : U),(M₇,U : U),(M₆,U : U),(M₅,U : U),(M₄,U : U),(M₃,U : U),(M₂,U : U),(M₁,U : U)]
--   , knownSubsts   = [(M₉,(λx₁ → λx₂ → x₁ (x₁ (x₁ (x₁ (x₁ x₂))))) (λx₁ → λx₂ → x₁ (x₁ (x₁ (x₁ (x₁ (x₁ x₂)))))) (λx₁ → x₁) A : U),(M₅,U : U),(M₈,?M₅),(M₇,?M₅),(M₇,?M₅),(M₂,?M₅ → ?M₅ : U),(M₂,?M₅ → ?M₅ : U),(M₂,?M₅ → ?M₅ : U),(M₆,?M₅),(M₄,?M₅ → ?M₆ : U),(M₃,?M₂),(M₁,?M₂ → ?M₃ : U)]
--   , constraints   = []
--   , freshMetaVars = [M₁₀,M₁₁,M₁₂,M₁₃,M₁₄,...]
--   }
-- @
examples :: IO ()
examples = mapM_ runExample . zip [1..] $
  [ ex_factorial

  , lam (Just (App (lam_ "x" (Var "x")) (Var "A"))) "x" (App (lam_ "y" (Var "y")) (Var "x")) -- ok (fixed)

  , let_ (lam_ "f" $ lam_ "z" $ Var "z") "zero" $
    let_ (lam_ "n" $ lam_ "f" $ lam_ "z" $ App (Var "f") (App (App (Var "n") (Var "f")) (Var "z"))) "succ" $
      App (Var "succ") (App (Var "succ") (Var "zero"))

  , let_ (lam_ "f" $ lam_ "z" $ Var "z") "zero" $
      Var "zero"

  , App (lam_ "x" (Var "x")) $
      lam_ "f" $ lam_ "z" $ Var "z"

  , let_ Unit "x" Unit

  , let_ Unit "x" (Var "x")


  , lam Nothing "f" $
      lam Nothing "x" $
        App (Var "f") (Var "x") -- ok (fixed)

  , lam (Just (Fun UnitType UnitType)) "f" $
      lam (Just UnitType) "x" $
        App (Var "f") (Var "x") -- ok

  , lam (Just (Fun (Var "A") (Var "B"))) "f" $
      lam (Just (Var "A")) "x" $
        App (Var "f") (Var "x") -- ok (fixed)

  , lam Nothing "x" $
      lam Nothing "x" $
        Var "x" -- ok

  , lam Nothing "x" $
      lam Nothing "y" $
        Var "x" -- ok (fixed)

  , lam (Just (Fun (Var "A") (Var "B"))) "f" $
      lam Nothing "x" $
        App (Var "f") (Var "x") -- ok

  , lam Nothing "x" $
      Var "x" -- ok

  , lam (Just (Var "A")) "x" $
      Var "x" -- ok

  , lam (Just (Fun (Var "A") (Var "B"))) "f" $
      Var "f" -- ok

  , lam Nothing "f" $
      App (Var "f") (Var "f")  -- ok: type error

  , lam Nothing "f" $
      App (Var "f") Unit -- ok

  , Fun (Var "A") UnitType -- ok (looped because of unsafeCoerce)
  , Fun (Var "A") (Var "B") -- ok (looped because of unsafeCoerce)

  , lam Nothing "f" $
      lam (Just UnitType) "x" $
        App (Var "f") (App (Var "f") (Var "x"))
        -- ok

  , Unit                  -- ok
  , App Unit Unit         -- type error
  , UnitType              -- ok
  , Var "x"               -- ok-ish
  , App (Var "f") Unit    -- ambiguous

  , App (Var "f") (App (Var "f") Unit) -- ok (fixed)

  , Fun Unit Unit         -- type error
  , Fun UnitType UnitType -- ok

  , Var "x"
  , App (Var "f") (Var "x")
  , lam (Just Unit) "x" (Var "x")
  , lam (Just Unit) "x" (Var "y")
  , lam (Just (Var "A")) "x" (Var "x")
  , lam (Just (Fun (Var "A") (Var "B"))) "x" (Var "x")

  , lam (Just (App (App (App (ex_nat 5) (ex_nat 6)) (lam_ "x" (Var "x"))) (Var "A"))) "x" (App (lam_ "z" (Var "z")) (Var "x")) -- FIXME: optimize to avoid recomputation of whnf

  ]

runExample :: (Int, Term') -> IO ()
runExample (n, term) = do
  putStrLn ("Example #" <> show n <> ":")
  -- putStr   "[input term]:          "
  print term
  -- _ <- getLine
  -- putStr   "[with inferred types]: "
  case runTypeCheckOnce' (TypeCheck.infer term) of
    Left err -> putStrLn ("Type Error: " <> show err)
    Right (typedTerm, typeInfo) -> do
      print typedTerm
      print typeInfo
  putStrLn ""
  -- _ <- getLine
  return ()

-- *** Church numerals

-- |
-- >>> ex_zero
-- λx₁ → λx₂ → x₂
--
-- >>> execTypeCheck' (infer' ex_zero)
-- Right λx₁ → λx₂ → x₂ : ?M₁ → ?M₂ → ?M₂
ex_zero :: Term'
ex_zero = lam_ "s" (lam_ "z" (Var "z"))

-- |
-- >>> ex_nat 3
-- λx₁ → λx₂ → x₁ (x₁ (x₁ x₂))
--
-- >>> execTypeCheck' (infer' (ex_nat 3))
-- Right λx₁ → λx₂ → x₁ (x₁ (x₁ x₂)) : (?M₂ → ?M₂) → ?M₂ → ?M₂
ex_nat :: Int -> Term'
ex_nat n = lam_ "s" (lam_ "z" (iterate (App (Var "s")) (Var "z") !! n))

-- |
-- >>> ex_add
-- λx₁ → λx₂ → λx₃ → λx₄ → x₁ x₃ (x₂ x₃ x₄)
--
-- >>> unsafeInfer' ex_add
-- λx₁ → λx₂ → λx₃ → λx₄ → x₁ x₃ (x₂ x₃ x₄) : (?M₃ → ?M₇ → ?M₈) → (?M₃ → ?M₄ → ?M₇) → ?M₃ → ?M₄ → ?M₈
ex_add :: Term'
ex_add = lam_ "n" (lam_ "m" (lam_ "s" (lam_ "z"
  (App (App (Var "n") (Var "s")) (App (App (Var "m") (Var "s")) (Var "z"))))))

-- |
-- >>> ex_mul
-- λx₁ → λx₂ → λx₃ → x₁ (x₂ x₃)
-- >>> unsafeInfer' ex_mul
-- λx₁ → λx₂ → λx₃ → x₁ (x₂ x₃) : (?M₄ → ?M₅) → (?M₃ → ?M₄) → ?M₃ → ?M₅
ex_mul :: Term'
ex_mul = lam_ "n" (lam_ "m" (lam_ "s"
  (App (Var "n") (App (Var "m") (Var "s")))))

-- |
-- >>> ex_mkPair (Var "x") (Var "y")
-- λx₁ → x₁ x y
ex_mkPair :: Term' -> Term' -> Term'
ex_mkPair t1 t2 = lam_ "_ex_mkPair" (App (App (Var "_ex_mkPair") t1) t2)

-- |
-- >>> ex_fst
-- λx₁ → x₁ (λx₂ → λx₃ → x₂)
-- >>> unsafeInfer' ex_fst
-- λx₁ → x₁ (λx₂ → λx₃ → x₂) : ((?M₂ → ?M₃ → ?M₂) → ?M₄) → ?M₄
ex_fst :: Term'
ex_fst = lam_ "p" (App (Var "p") (lam_ "f" (lam_ "s" (Var "f"))))

-- |
-- >>> ex_snd
-- λx₁ → x₁ (λx₂ → λx₃ → x₃)
-- >>> unsafeInfer' ex_snd
-- λx₁ → x₁ (λx₂ → λx₃ → x₃) : ((?M₂ → ?M₃ → ?M₃) → ?M₄) → ?M₄
ex_snd :: Term'
ex_snd = lam_ "p" (App (Var "p") (lam_ "f" (lam_ "s" (Var "s"))))

-- |
-- >>> ex_pred
-- λx₁ → (λx₂ → x₂ (λx₃ → λx₄ → x₃)) (x₁ (λx₂ → λx₃ → x₃ ((λx₄ → x₄ (λx₅ → λx₆ → x₆)) x₂) ((λx₄ → λx₅ → λx₆ → λx₇ → x₄ x₆ (x₅ x₆ x₇)) ((λx₄ → x₄ (λx₅ → λx₆ → x₆)) x₂) (λx₄ → λx₅ → x₄ x₅))) (λx₂ → x₂ (λx₃ → λx₄ → x₄) (λx₃ → λx₄ → x₄)))
-- >>> unsafeInfer' ex_pred
-- λx₁ → (λx₂ → x₂ (λx₃ → λx₄ → x₃)) (x₁ (λx₂ → λx₃ → x₃ ((λx₄ → x₄ (λx₅ → λx₆ → x₆)) x₂) ((λx₄ → λx₅ → λx₆ → λx₇ → x₄ x₆ (x₅ x₆ x₇)) ((λx₄ → x₄ (λx₅ → λx₆ → x₆)) x₂) (λx₄ → λx₅ → x₄ x₅))) (λx₂ → x₂ (λx₃ → λx₄ → x₄) (λx₃ → λx₄ → x₄))) : ((((?M₂₂ → ?M₂₃ → ?M₂₃) → (?M₁₆ → ?M₁₉) → ?M₁₉ → ?M₂₀) → (((?M₁₆ → ?M₁₉) → ?M₁₉ → ?M₂₀) → ((?M₁₆ → ?M₁₉) → ?M₁₆ → ?M₂₀) → ?M₂₈) → ?M₂₈) → (((?M₃₁ → ?M₃₂ → ?M₃₂) → (?M₃₄ → ?M₃₅ → ?M₃₅) → ?M₃₆) → ?M₃₆) → (?M₃ → ?M₄ → ?M₃) → ?M₅) → ?M₅
ex_pred :: Term'
ex_pred = lam_ "n" (App ex_fst (App (App (Var "n") (lam_ "p" (ex_mkPair (App ex_snd (Var "p")) (App (App ex_add (App ex_snd (Var "p"))) (ex_nat 1))))) (ex_mkPair ex_zero ex_zero)))

-- |
-- >>> ex_factorial_church
-- fix (λx₁ → λx₂ → x₂ (λx₃ → (λx₄ → λx₅ → λx₆ → x₄ (x₅ x₆)) x₂ (x₁ ((λx₄ → (λx₅ → x₅ (λx₆ → λx₇ → x₆)) (x₄ (λx₅ → λx₆ → x₆ ((λx₇ → x₇ (λx₈ → λx₉ → x₉)) x₅) ((λx₇ → λx₈ → λx₉ → λx₁₀ → x₇ x₉ (x₈ x₉ x₁₀)) ((λx₇ → x₇ (λx₈ → λx₉ → x₉)) x₅) (λx₇ → λx₈ → x₇ x₈))) (λx₅ → x₅ (λx₆ → λx₇ → x₇) (λx₆ → λx₇ → x₇)))) x₂))) (λx₃ → λx₄ → x₃ x₄))
--
-- >>> nfUntyped (App ex_factorial_church (ex_nat 3))
-- λx₁ → λx₂ → x₁ (x₁ (x₁ (x₁ (x₁ (x₁ x₂)))))
--
-- Note: we cannot typecheck this term in STC (FIXME: double check), we need church numerals to have polymorphic type or union type.
ex_factorial_church :: Term'
ex_factorial_church = Fix $ lam_ "f" $ lam_ "n" $
  App (App (Var "n") (lam_ "m" $ App (App ex_mul (Var "n")) (App (Var "f") (App ex_pred (Var "n"))))) (ex_nat 1)

-- *** Examples using built-in types

-- |
-- >>> ex_factorial
-- fix (λx₁ → λx₂ → if (isZero x₂) then 1 else (x₂ * (x₁ (pred x₂))))
-- >>> unsafeInfer' ex_factorial
-- fix (λx₁ → λx₂ → if (isZero x₂) then 1 else (x₂ * (x₁ (pred x₂)))) : NAT → NAT
--
-- >>> nf (unsafeInfer' (App ex_factorial (NatLit 10)))
-- 3628800 : NAT
ex_factorial :: Term'
ex_factorial = Fix $ lam_ "f" $ lam_ "n" $
  BoolIf (NatIsZero (Var "n"))
    (NatLit 1)
    (NatMultiply (Var "n") (App (Var "f") (NatPred (Var "n"))))

-- * Parsing

pTerm :: (TokenParsing m, Monad m) => m Term'
pTerm = Trifecta.choice
  [ NatMultiply <$> Trifecta.try (pNotAppTerm <* symbol "*") <*> pTerm
  , pApps
  , Trifecta.parens pTerm ]

pApps :: (TokenParsing m, Monad m) => m Term'
pApps = do
  f <- pNotAppTerm
  args <- many pNotAppTerm
  return (Unification.mkApps f args)

pNotAppTerm :: (TokenParsing m, Monad m) => m Term'
pNotAppTerm = Trifecta.choice
  [ pLet
  , UnitType <$ symbol "UNIT"
  , Unit <$ symbol "unit"
  , lam_ "x" (Fix (Var "x")) <$ symbol "fix"

  , NatType <$ symbol "NAT"
  , NatLit <$> Trifecta.integer
  , lam_ "x" (lam_ "y" (NatMultiply (Var "x") (Var "y"))) <$ symbol "mul"
  , lam_ "x" (NatPred (Var "x")) <$ symbol "pred"
  , lam_ "x" (NatIsZero (Var "x")) <$ symbol "isZero"

  , BoolType <$ symbol "BOOL"
  , BoolLit False <$ symbol "false"
  , BoolLit True  <$ symbol "true"
  , BoolIf <$ symbol "if" <*> pTerm <* symbol "then" <*> pTerm <* symbol "else" <*> pTerm

  , pVar
  , pLam
  , Trifecta.parens pTerm
  ]

pVar :: (TokenParsing m, Monad m) => m Term'
pVar = Var <$> pIdent

pIdent :: (TokenParsing m, Monad m) => m Rzk.Var
pIdent = Rzk.Var . Text.pack <$> Trifecta.ident pIdentStyle

pIdentStyle :: (TokenParsing m, Monad m) => IdentifierStyle m
pIdentStyle = (emptyIdents @Parser)
  { _styleStart     = Trifecta.satisfy isIdentChar
  , _styleLetter    = Trifecta.satisfy isIdentChar
  , _styleReserved  = HashSet.fromList [ "λ", "\\", "→", "->"
                                       , "let", "in"
                                       , "fix"
                                       , "UNIT", "unit"
                                       , "NAT"
                                       , "BOOL", "false", "true"
                                       , "if", "then", "else"
                                       , "--", ":=", ":" ]
  }

pLam :: (TokenParsing m, Monad m) => m Term'
pLam = do
  _ <- symbol "λ" <|> symbol "\\"
  x <- pIdent
  _ <- symbol "->" <|> symbol "→"
  t <- pTerm
  return (Lam Nothing (abstract1Name x t))

pLet :: (TokenParsing m, Monad m) => m Term'
pLet = do
  _ <- symbol "let"
  x <- pIdent
  _ <- symbol "="
  a <- pTerm
  _ <- symbol "in"
  t <- pTerm
  return (let_ a x t)

-- ** Char predicates

isIdentChar :: Char -> Bool
isIdentChar c = isPrint c && not (isSpace c) && not (isDelim c)

isDelim :: Char -> Bool
isDelim c = c `elem` ("()[]{},\\λ→#" :: String)

-- * Orphan 'IsString' instances

instance IsString Term' where
  fromString = unsafeParseTerm

unsafeParseTerm :: String -> Term'
unsafeParseTerm = unsafeParseString pTerm

unsafeParseString :: Parser a -> String -> a
unsafeParseString parser input =
  case Trifecta.parseString parser mempty input of
    Trifecta.Success x       -> x
    Trifecta.Failure errInfo -> unsafePerformIO $ do
      putDoc (Trifecta._errDoc errInfo <> "\n")
      error "Parser error while attempting unsafeParseString"

deriveBifunctor ''TermF
deriveBifoldable ''TermF
deriveBitraversable ''TermF
