{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveFunctor, DeriveFoldable, DeriveTraversable #-}
{-# LANGUAGE FlexibleInstances, TypeSynonymInstances #-}
{-# LANGUAGE PatternSynonyms #-}

module Language.Plover.UsedNames
       where

import Language.Plover.Types
import Data.List
import Control.Monad.State

-- Facility to get all names from a program so that gensym can be sure
-- variables do not come from this set.

allToplevelNames :: [DefBinding] -> [Variable]
allToplevelNames dbs = nub $ allNames dbs

class NameContainer a where
  allNames :: a -> [Variable]

instance NameContainer a => NameContainer [a] where
  allNames xs = xs >>= allNames

instance NameContainer DefBinding where
  allNames db = [binding db] ++ allNames (definition db)

instance NameContainer Definition where
  allNames def = case def of
    FunctionDef cexpr ft -> maybe [] allNames cexpr ++ allNames ft
    StructDef defs -> map fst defs
    ValueDef cexpr t -> maybe [] allNames cexpr ++ allNames t

instance NameContainer CExpr where
  allNames ex = case ex of
    Vec _ v rng x -> [v] ++ allNames rng ++ allNames x
    For _ v rng x -> [v] ++ allNames rng ++ allNames x
    Return _ ty x -> allNames ty ++ allNames x
    Assert _ x -> allNames x
    RangeVal _ rng -> allNames rng
    If _ a b c -> allNames [a, b, c]
    VecLit _ ty xs -> allNames ty ++ allNames xs
    TupleLit _ xs -> allNames xs
    Let _ v d x -> [v] ++ allNames d ++ allNames x
    Uninitialized _ ty -> allNames ty
    Seq _ a b -> allNames [a, b]
    App _ f args -> let unarg (Arg x) = x
                        unarg (ImpArg x) = x
                    in allNames f ++ allNames (map unarg args)
    ConcreteApp _ f args rty -> allNames f ++ allNames args ++ allNames rty
    HoleJ _ v -> [v]
    Get _ loc -> allNames loc
    Addr _ loc -> allNames loc
    Set _ loc v -> allNames loc ++ allNames v
    AssertType _ v t -> allNames v ++ allNames t
    Unary _ op x -> allNames x
    Binary _ op x y -> allNames x ++ allNames y
    _ -> []

instance NameContainer (Range CExpr) where
  allNames rng = allNames [rangeFrom rng, rangeTo rng, rangeStep rng]

instance NameContainer (Location CExpr) where
  allNames loc = case loc of
    Ref t v -> allNames t ++ [v]
    Index v idxs -> allNames v ++ allNames idxs
    Field v _ -> allNames v
    Deref v -> allNames v

instance NameContainer Type where
  allNames ty = case ty of
    VecType st idxs t -> allNames st ++ allNames idxs ++ allNames t
    TupleType tys -> allNames tys
    FnType ft -> allNames ft
    PtrType t -> allNames t
    TypedefType v -> [v]
    StructType v _ -> [v]
    TypeHole (Just v) -> [v]
    _ -> []

instance NameContainer FunctionType where
  allNames ft = let ((FnT args rt), _) = getEffectiveFunType ft
                in (args >>= \(_, v, _, _, t) -> [v] ++ allNames t) ++ allNames rt

instance NameContainer StorageType where
  allNames st = []
