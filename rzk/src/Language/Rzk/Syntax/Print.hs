-- File generated by the BNF Converter (bnfc 2.9.4.1).

{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
#if __GLASGOW_HASKELL__ <= 708
{-# LANGUAGE OverlappingInstances #-}
#endif

-- | Pretty-printer for Language.

module Language.Rzk.Syntax.Print where

import Prelude
  ( ($), (.)
  , Bool(..), (==), (<)
  , Int, Integer, Double, (+), (-), (*)
  , String, (++)
  , ShowS, showChar, showString
  , all, elem, foldr, id, map, null, replicate, shows, span
  )
import Data.Char ( Char, isSpace )
import qualified Language.Rzk.Syntax.Abs

-- | The top-level printing method.

printTree :: Print a => a -> String
printTree = render . prt 0

type Doc = [ShowS] -> [ShowS]

doc :: ShowS -> Doc
doc = (:)

render :: Doc -> String
render d = rend 0 False (map ($ "") $ d []) ""
  where
  rend
    :: Int        -- ^ Indentation level.
    -> Bool       -- ^ Pending indentation to be output before next character?
    -> [String]
    -> ShowS
  rend i p = \case
      "["      :ts -> char '[' . rend i False ts
      "("      :ts -> char '(' . rend i False ts
      "{"      :ts -> onNewLine i     p . showChar   '{'  . new (i+1) ts
      "}" : ";":ts -> onNewLine (i-1) p . showString "};" . new (i-1) ts
      "}"      :ts -> onNewLine (i-1) p . showChar   '}'  . new (i-1) ts
      [";"]        -> char ';'
      ";"      :ts -> char ';' . new i ts
      t  : ts@(s:_) | closingOrPunctuation s
                   -> pending . showString t . rend i False ts
      t        :ts -> pending . space t      . rend i False ts
      []           -> id
    where
    -- Output character after pending indentation.
    char :: Char -> ShowS
    char c = pending . showChar c

    -- Output pending indentation.
    pending :: ShowS
    pending = if p then indent i else id

  -- Indentation (spaces) for given indentation level.
  indent :: Int -> ShowS
  indent i = replicateS (2*i) (showChar ' ')

  -- Continue rendering in new line with new indentation.
  new :: Int -> [String] -> ShowS
  new j ts = showChar '\n' . rend j True ts

  -- Make sure we are on a fresh line.
  onNewLine :: Int -> Bool -> ShowS
  onNewLine i p = (if p then id else showChar '\n') . indent i

  -- Separate given string from following text by a space (if needed).
  space :: String -> ShowS
  space t s =
    case (all isSpace t', null spc, null rest) of
      (True , _   , True ) -> []              -- remove trailing space
      (False, _   , True ) -> t'              -- remove trailing space
      (False, True, False) -> t' ++ ' ' : s   -- add space if none
      _                    -> t' ++ s
    where
      t'          = showString t []
      (spc, rest) = span isSpace s

  closingOrPunctuation :: String -> Bool
  closingOrPunctuation [c] = c `elem` closerOrPunct
  closingOrPunctuation _   = False

  closerOrPunct :: String
  closerOrPunct = ")],;"

parenth :: Doc -> Doc
parenth ss = doc (showChar '(') . ss . doc (showChar ')')

concatS :: [ShowS] -> ShowS
concatS = foldr (.) id

concatD :: [Doc] -> Doc
concatD = foldr (.) id

replicateS :: Int -> ShowS -> ShowS
replicateS n f = concatS (replicate n f)

-- | The printer class does the job.

class Print a where
  prt :: Int -> a -> Doc

instance {-# OVERLAPPABLE #-} Print a => Print [a] where
  prt i = concatD . map (prt i)

instance Print Char where
  prt _ c = doc (showChar '\'' . mkEsc '\'' c . showChar '\'')

instance Print String where
  prt _ = printString

printString :: String -> Doc
printString s = doc (showChar '"' . concatS (map (mkEsc '"') s) . showChar '"')

mkEsc :: Char -> Char -> ShowS
mkEsc q = \case
  s | s == q -> showChar '\\' . showChar s
  '\\' -> showString "\\\\"
  '\n' -> showString "\\n"
  '\t' -> showString "\\t"
  s -> showChar s

prPrec :: Int -> Int -> Doc -> Doc
prPrec i j = if j < i then parenth else id

instance Print Integer where
  prt _ x = doc (shows x)

instance Print Double where
  prt _ x = doc (shows x)

instance Print Language.Rzk.Syntax.Abs.VarIdent where
  prt _ (Language.Rzk.Syntax.Abs.VarIdent i) = doc $ showString i
instance Print Language.Rzk.Syntax.Abs.HoleIdent where
  prt _ (Language.Rzk.Syntax.Abs.HoleIdent i) = doc $ showString i
instance Print Language.Rzk.Syntax.Abs.Module where
  prt i = \case
    Language.Rzk.Syntax.Abs.Module languagedecl commands -> prPrec i 0 (concatD [prt 0 languagedecl, prt 0 commands])

instance Print Language.Rzk.Syntax.Abs.LanguageDecl where
  prt i = \case
    Language.Rzk.Syntax.Abs.LanguageDecl language -> prPrec i 0 (concatD [doc (showString "#lang"), prt 0 language, doc (showString ";")])

instance Print Language.Rzk.Syntax.Abs.Language where
  prt i = \case
    Language.Rzk.Syntax.Abs.Rzk1 -> prPrec i 0 (concatD [doc (showString "rzk-1")])
    Language.Rzk.Syntax.Abs.Rzk2 -> prPrec i 0 (concatD [doc (showString "rzk-2")])

instance Print Language.Rzk.Syntax.Abs.Command where
  prt i = \case
    Language.Rzk.Syntax.Abs.CommandDefine varident term1 term2 -> prPrec i 0 (concatD [doc (showString "#def"), prt 0 varident, doc (showString ":"), prt 0 term1, doc (showString ":="), prt 0 term2, doc (showString ";")])

instance Print [Language.Rzk.Syntax.Abs.Command] where
  prt _ [] = concatD []
  prt _ (x:xs) = concatD [prt 0 x, prt 0 xs]

instance Print Language.Rzk.Syntax.Abs.Pattern where
  prt i = \case
    Language.Rzk.Syntax.Abs.PatternWildcard -> prPrec i 0 (concatD [doc (showString "_")])
    Language.Rzk.Syntax.Abs.PatternVar varident -> prPrec i 0 (concatD [prt 0 varident])
    Language.Rzk.Syntax.Abs.PatternPair pattern_1 pattern_2 -> prPrec i 0 (concatD [doc (showString "("), prt 0 pattern_1, doc (showString ","), prt 0 pattern_2, doc (showString ")")])

instance Print Language.Rzk.Syntax.Abs.Param where
  prt i = \case
    Language.Rzk.Syntax.Abs.ParamPattern pattern_ -> prPrec i 0 (concatD [prt 0 pattern_])
    Language.Rzk.Syntax.Abs.ParamPatternType pattern_ term -> prPrec i 0 (concatD [doc (showString "("), prt 0 pattern_, doc (showString ":"), prt 0 term, doc (showString ")")])
    Language.Rzk.Syntax.Abs.ParamPatternShape pattern_ term1 term2 -> prPrec i 0 (concatD [doc (showString "{"), prt 0 pattern_, doc (showString ":"), prt 0 term1, doc (showString "|"), prt 0 term2, doc (showString "}")])

instance Print [Language.Rzk.Syntax.Abs.Param] where
  prt _ [] = concatD []
  prt _ [x] = concatD [prt 0 x]
  prt _ (x:xs) = concatD [prt 0 x, prt 0 xs]

instance Print Language.Rzk.Syntax.Abs.ParamDecl where
  prt i = \case
    Language.Rzk.Syntax.Abs.ParamType term -> prPrec i 0 (concatD [prt 6 term])
    Language.Rzk.Syntax.Abs.ParamWildcardType term -> prPrec i 0 (concatD [doc (showString "("), doc (showString "_"), doc (showString ":"), prt 0 term, doc (showString ")")])
    Language.Rzk.Syntax.Abs.ParamVarType varident term -> prPrec i 0 (concatD [doc (showString "("), prt 0 varident, doc (showString ":"), prt 0 term, doc (showString ")")])
    Language.Rzk.Syntax.Abs.ParamVarShape pattern_ term1 term2 -> prPrec i 0 (concatD [doc (showString "{"), doc (showString "("), prt 0 pattern_, doc (showString ":"), prt 0 term1, doc (showString ")"), doc (showString "|"), prt 0 term2, doc (showString "}")])

instance Print Language.Rzk.Syntax.Abs.Restriction where
  prt i = \case
    Language.Rzk.Syntax.Abs.Restriction term1 term2 -> prPrec i 0 (concatD [prt 0 term1, doc (showString "|->"), prt 0 term2])

instance Print [Language.Rzk.Syntax.Abs.Restriction] where
  prt _ [] = concatD []
  prt _ [x] = concatD [prt 0 x]
  prt _ (x:xs) = concatD [prt 0 x, doc (showString ","), prt 0 xs]

instance Print Language.Rzk.Syntax.Abs.Term where
  prt i = \case
    Language.Rzk.Syntax.Abs.Universe -> prPrec i 7 (concatD [doc (showString "U")])
    Language.Rzk.Syntax.Abs.UniverseCube -> prPrec i 7 (concatD [doc (showString "CUBE")])
    Language.Rzk.Syntax.Abs.UniverseTope -> prPrec i 7 (concatD [doc (showString "TOPE")])
    Language.Rzk.Syntax.Abs.CubeUnit -> prPrec i 7 (concatD [doc (showString "1")])
    Language.Rzk.Syntax.Abs.CubeUnitStar -> prPrec i 7 (concatD [doc (showString "*_1")])
    Language.Rzk.Syntax.Abs.Cube2 -> prPrec i 7 (concatD [doc (showString "2")])
    Language.Rzk.Syntax.Abs.Cube2_0 -> prPrec i 7 (concatD [doc (showString "0_2")])
    Language.Rzk.Syntax.Abs.Cube2_1 -> prPrec i 7 (concatD [doc (showString "1_2")])
    Language.Rzk.Syntax.Abs.CubeProduct term1 term2 -> prPrec i 5 (concatD [prt 5 term1, doc (showString "*"), prt 6 term2])
    Language.Rzk.Syntax.Abs.TopeTop -> prPrec i 7 (concatD [doc (showString "TOP")])
    Language.Rzk.Syntax.Abs.TopeBottom -> prPrec i 7 (concatD [doc (showString "BOT")])
    Language.Rzk.Syntax.Abs.TopeEQ term1 term2 -> prPrec i 4 (concatD [prt 5 term1, doc (showString "==="), prt 5 term2])
    Language.Rzk.Syntax.Abs.TopeLEQ term1 term2 -> prPrec i 4 (concatD [prt 5 term1, doc (showString "<="), prt 5 term2])
    Language.Rzk.Syntax.Abs.TopeAnd term1 term2 -> prPrec i 3 (concatD [prt 4 term1, doc (showString "/\\"), prt 3 term2])
    Language.Rzk.Syntax.Abs.TopeOr term1 term2 -> prPrec i 2 (concatD [prt 3 term1, doc (showString "\\/"), prt 2 term2])
    Language.Rzk.Syntax.Abs.RecBottom -> prPrec i 7 (concatD [doc (showString "recBOT")])
    Language.Rzk.Syntax.Abs.RecOr restrictions -> prPrec i 7 (concatD [doc (showString "recOR"), doc (showString "("), prt 0 restrictions, doc (showString ")")])
    Language.Rzk.Syntax.Abs.TypeFun paramdecl term -> prPrec i 1 (concatD [prt 0 paramdecl, doc (showString "->"), prt 1 term])
    Language.Rzk.Syntax.Abs.TypeSigma pattern_ term1 term2 -> prPrec i 1 (concatD [doc (showString "Sigma"), doc (showString "("), prt 0 pattern_, doc (showString ":"), prt 0 term1, doc (showString ")"), doc (showString ","), prt 1 term2])
    Language.Rzk.Syntax.Abs.TypeId term1 term2 term3 -> prPrec i 1 (concatD [prt 2 term1, doc (showString "=_{"), prt 0 term2, doc (showString "}"), prt 2 term3])
    Language.Rzk.Syntax.Abs.TypeIdSimple term1 term2 -> prPrec i 1 (concatD [prt 2 term1, doc (showString "="), prt 2 term2])
    Language.Rzk.Syntax.Abs.TypeRestricted term restriction -> prPrec i 0 (concatD [prt 1 term, doc (showString "["), prt 0 restriction, doc (showString "]")])
    Language.Rzk.Syntax.Abs.App term1 term2 -> prPrec i 6 (concatD [prt 6 term1, prt 7 term2])
    Language.Rzk.Syntax.Abs.Lambda params term -> prPrec i 1 (concatD [doc (showString "\\"), prt 0 params, doc (showString "->"), prt 1 term])
    Language.Rzk.Syntax.Abs.Pair term1 term2 -> prPrec i 7 (concatD [doc (showString "("), prt 0 term1, doc (showString ","), prt 0 term2, doc (showString ")")])
    Language.Rzk.Syntax.Abs.First term -> prPrec i 6 (concatD [doc (showString "first"), prt 7 term])
    Language.Rzk.Syntax.Abs.Second term -> prPrec i 6 (concatD [doc (showString "second"), prt 7 term])
    Language.Rzk.Syntax.Abs.Refl -> prPrec i 7 (concatD [doc (showString "refl")])
    Language.Rzk.Syntax.Abs.ReflTerm term -> prPrec i 7 (concatD [doc (showString "refl_{"), prt 0 term, doc (showString "}")])
    Language.Rzk.Syntax.Abs.ReflTermType term1 term2 -> prPrec i 7 (concatD [doc (showString "refl_{"), prt 0 term1, doc (showString ":"), prt 0 term2, doc (showString "}")])
    Language.Rzk.Syntax.Abs.IdJ term1 term2 term3 term4 term5 term6 -> prPrec i 7 (concatD [doc (showString "idJ"), doc (showString "("), prt 0 term1, doc (showString ","), prt 0 term2, doc (showString ","), prt 0 term3, doc (showString ","), prt 0 term4, doc (showString ","), prt 0 term5, doc (showString ","), prt 0 term6, doc (showString ")")])
    Language.Rzk.Syntax.Abs.Hole holeident -> prPrec i 7 (concatD [prt 0 holeident])
    Language.Rzk.Syntax.Abs.Var varident -> prPrec i 7 (concatD [prt 0 varident])
    Language.Rzk.Syntax.Abs.TypeAsc term1 term2 -> prPrec i 0 (concatD [prt 2 term1, doc (showString "as"), prt 1 term2])

instance Print [Language.Rzk.Syntax.Abs.Term] where
  prt _ [] = concatD []
  prt _ [x] = concatD [prt 0 x]
  prt _ (x:xs) = concatD [prt 0 x, doc (showString ","), prt 0 xs]
