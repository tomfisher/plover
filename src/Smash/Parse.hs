{-# LANGUAGE DeriveFunctor, DeriveFoldable, DeriveTraversable #-}
{-# LANGUAGE FlexibleInstances, TypeSynonymInstances #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE StandaloneDeriving #-}
module Smash.Parse where
import Smash.Parse.Types
import Smash.Parse.Tests

import Name (Name, runEnv, withEnv, names, Env)
import qualified Name as N (store, put, get)

import Data.Maybe (fromJust)
import Data.Either (isLeft, partitionEithers)
import Data.List (partition)
import qualified Data.Map.Strict as M

import Control.Applicative ((<$>))
import Control.Monad (foldM)
import Control.Monad.Trans.Either
import Control.Monad.Trans.Class
import Control.Monad.Free
import Control.Arrow (first, second)
import qualified Data.Traversable as T (mapM, Traversable, mapAccumR, sequence)
import Control.Monad.State (runState)

import Debug.Trace (trace)

store :: UValue -> UnMonad Name
store = N.store
get :: Name -> UnMonad UValue
get = N.get
put :: Name -> UValue -> UnMonad ()
put n v = N.put n v

newVar :: M Name
newVar = store UVar

-- Updates a context and the monad environment given a line.
-- Unification errors for the given line are passed over,
-- so context may be erroneous as well, but parsing can still continue.
parseLine :: Context -> Line -> OuterM (Context, Either UError (TypedLine Name))
parseLine context l@(var := expr) = do
  -- Type the RHS, check context for LHS, bind RHS to LHS, return type ref
  mtype <- runEitherT $ do
             rhs <- typeExpr context expr
             lhs <- lift $ case M.lookup var context of
               Nothing -> newVar
               Just n -> return n
             unifyBind lhs rhs
             return lhs
  -- Check result, update context if valid
  case mtype of
    Left err -> return (context, Left err)
    Right typeName -> do
      let context' = M.insert var typeName context
      return (context', Right $ TLine typeName l (M.toList context'))

--parseLine c0 (For loc var upperBound body) = do
--  (c1, mline)   <- parseLine  c0 (var := 0)
--  (c2, mresult) <- parseLines c1 body

-- TODO delete
--parseLine c l@(LStore LVoid (RHSExpr expr)) = do
--  mtype <- runEitherT $ typeExpr c expr
--  return $ (c, do
--    tp <- mtype
--    return (TLine tp l (M.toList c)))


parseLines :: Context -> [Line]
           -> OuterM (Context, [Either UError (TypedLine Name)])
parseLines c lines = do
  (c', lines') <- foldM step (c, []) lines
  return (c', reverse lines')
 where
  step (c, lines) line = do
    (c', line') <- parseLine c line
    return (c', line' : lines)

typeExpr :: Context -> ExprU -> InnerM Name
typeExpr context (Free expr) =
  case expr of
    ERef var -> lift $
      case M.lookup var context of
        Nothing -> newVar
        Just t -> return t
    EIntLit _ -> lift $ store $ UType (TLit Int)
    EMLit mat -> storeMat context mat
    EMul e1 e2 -> do
      t1 <- typeExpr context e1
      t2 <- typeExpr context e2
      prodName <- lift $ store (UProduct t1 t2)
      propagate prodName
      return prodName
    ESum e1 e2 -> do
      t1 <- typeExpr context e1
      t2 <- typeExpr context e2
      sumName <- lift $ store (USum t1 t2)
      propagate sumName
      return sumName
    ENeg e -> typeExpr context e

refine :: Name -> UValue -> InnerM ()
refine name val = do
  lift $ put name val
  --propagateAll

propagateAll :: InnerM ()
propagateAll = do
  ns <- lift names
  mapM_ propagate ns

propagate :: Name -> InnerM ()
propagate n = do
  val <- lift $ get n
  case val of
    UEq n' ->
      withValue n' $ \val' -> refine n val'
    UProduct n1 n2 -> do
      -- refine if n1 or n2 has a type
      withValue n1 $ \val' -> unifyProduct val' n n1 n2
      withValue n2 $ \val' -> unifyProduct val' n n1 n2
    USum n1 n2 -> do
      -- refine if n1 or n2 has a type
      withValue n1 $ \val' -> unifySum val' n n1 n2
      withValue n2 $ \val' -> unifySum val' n n1 n2
    _ -> return ()

withValue :: Name -> (UValue -> InnerM ()) -> InnerM ()
withValue name fn = do
  val <- lift (get name)
  case val of
    UVar -> return ()
    _ -> fn val

unifyBaseType :: Name -> Name -> InnerM ()
unifyBaseType n1 n2 = do
  -- TODO get rid of this list match
  TMatrix _ bt1 <- matchMatrix n1
  TMatrix _ bt2 <- matchMatrix n2
  unifyBind bt1 bt2

unifyLit :: BaseType -> Name -> InnerM ()
unifyLit bt name = do
  btn <- lift $ store $ UType $ TLit bt
  unifyBind name btn

unifyProduct :: UValue -> Name -> Name -> Name -> InnerM ()
unifyProduct (UType (TMatrix _ _)) product n1 n2 = 
  unifyMatrixProduct product n1 n2
unifyProduct (UType (TLit bt)) product n1 n2 =
  mapM_ (unifyLit bt) [product, n1, n2]
unifyProduct _ _ _ _ = return ()

unifySum :: UValue -> Name -> Name -> Name -> InnerM ()
unifySum (UType (TMatrix _ _)) sum n1 n2 = do
  unifyMatrixSum sum n1 n2
unifySum (UType (TLit bt)) sum n1 n2 =
  mapM_ (unifyLit bt) [sum, n1, n2]

-- Core Unification Functions
type Bindings = [(Name, Name)]

unifyBind :: Name -> Name -> InnerM ()
unifyBind n1 n2 = do
  bindings <- unify n1 n2
  mapM_ (uncurry update) bindings
 where
  update n1 n2 = do
    v2 <- lift $ get n2
    case v2 of
      -- TODO propagate substitutions?
      UVar -> refine n1 (UEq n2)
      _ -> refine n1 v2

unify :: Name -> Name -> InnerM Bindings
unify n1 n2 = do
  v1 <- lift $ get n1
  v2 <- lift $ get n2
  unifyOne n1 v1 n2 v2

unifyOne :: Name -> UValue -> Name -> UValue -> InnerM Bindings
unifyOne n1 UVar n2 _ = return $ [(n1, n2)]
unifyOne n1 t n2 UVar = unifyOne n2 UVar n1 t
-- The consequences of such a unification are handled elsewhere
unifyOne n1 (UProduct _ _) n2 _ = do
  return [(n1, n2)]
unifyOne n1 (USum _ _) n2 _ = do
  return [(n1, n2)]
unifyOne n1 (UType e1) n2 (UType e2) = do
  assert (tagEq e1 e2) [n1, n2] $
    "unifyOne. expr types don't match: " ++ show e1 ++ ", " ++ show e2
  bs <- unifyMany [n1, n2] (children e1) (children e2)
  return $ (n1, n2) : bs
unifyOne n1 (UExpr e1) n2 (UExpr e2) = do
  assert (tagEq e1 e2) [n1, n2] $
    "unifyOne. expr values don't match: " ++ show e1 ++ ", " ++ show e2
  bs <- unifyMany [n1, n2] (children e1) (children e2)
  return $ (n1, n2) : bs
unifyOne n1 v1 n2 v2 = left $ UError [n1, n2] $
  "unifyOne. value types don't match: " ++ show v1 ++ ", " ++ show v2

-- First argument: provenance (for error reporting)
-- second, third: list of names to unify
unifyMany :: [Name] -> [Name] -> [Name] -> InnerM Bindings
unifyMany from ns1 ns2 = do
  assert (length ns1 == length ns2) from $
    "unifyMany. type arg list lengths don't match: "
      ++ show ns1 ++ ", " ++ show ns2
  concat <$> mapM (uncurry unify) (zip ns1 ns2)

extend :: TypeContext -> [(Variable, Name)] -> TypeContext
extend context bindings = foldr (uncurry M.insert) context bindings

--applyBlock :: Block -> [Name] -> InnerM Name
--applyBlock (Block params body ret (blocks, context)) args = do
--  let bs' = extend context (zip params args)
--  (c2, lines) <- lift $ parseLines (blocks, bs') body
--  typeExpr c2 ret

-- Matrix Unification Utilities
matrixVar :: M Name
matrixVar = do
  -- TODO allow generic matrices
  typeVar <- store (UType (TLit Float))
  rowsVar <- store UVar
  colsVar <- store UVar
  store $ UType $ TMatrix (Dim rowsVar colsVar) typeVar

matchMatrix :: Name -> InnerM Type
matchMatrix name = do
  val <- lift $ get name
  case val of
    UVar -> do
      mvar <- lift $ matrixVar
      unifyBind name mvar
      matchMatrix name
    UProduct n1 n2 -> do
      mvar <- lift matrixVar
      unifyBind name mvar
      unifyMatrixProduct name n1 n2
      matchMatrix name
    USum n1 n2 -> do
      mvar <- lift matrixVar
      unifyBind name mvar
      unifyMatrixSum name n1 n2
      matchMatrix name
    UType t@(TMatrix _ _) ->
      return t
    _ -> left $ UError [name] "not a matrix"

getDim :: (Dim -> Name) -> Name -> InnerM Name
getDim fn name = do
  (TMatrix dim _) <- matchMatrix name
  return (fn dim)

unifyInner :: Name -> Name -> InnerM ()
unifyInner n1 n2 = do
  c1 <- getDim dimColumns n1
  r2 <- getDim dimRows n2
  unifyBind c1 r2

unifyRows :: Name -> Name -> InnerM ()
unifyRows n1 n2 = do
  r1 <- getDim dimRows n1
  r2 <- getDim dimRows n2
  unifyBind r1 r2

unifyCols :: Name -> Name -> InnerM ()
unifyCols n1 n2 = do
  c1 <- getDim dimColumns n1
  c2 <- getDim dimColumns n2
  unifyBind c1 c2

unifyMatrixProduct :: Name -> Name -> Name -> InnerM ()
unifyMatrixProduct prod t1 t2 = do
  unifyInner t1 t2
  unifyRows t1 prod
  unifyCols t2 prod

unifyMatrixSum :: Name -> Name -> Name -> InnerM ()
unifyMatrixSum sum n1 n2 = do
  unifyMatrixDim n1 n2
  unifyMatrixDim n1 sum

unifyMatrixDim :: Name -> Name -> InnerM ()
unifyMatrixDim n1 n2 = do
  unifyRows n1 n2
  unifyCols n1 n2
  unifyBaseType n1 n2

-- Unification Utilities
assert :: Bool -> [Name] -> String -> InnerM ()
assert True _ _ = return ()
assert False info str = left $ UError info ("assert failure: " ++ str)

tagEq :: (Functor f, Eq (f ())) => f a -> f a -> Bool
tagEq t1 t2 = fmap (const ()) t1 == fmap (const ()) t2

children :: (T.Traversable t) => t a -> [a]
children t = fst $ T.mapAccumR step [] t
 where
  step list child = (child : list, ())

-- Expression Flattening Utilities
storeMat :: Context -> Mat -> InnerM Name
storeMat c (Mat bt (Dim rows cols) _) = do
  typeVar <- lift $ store $ UType (TLit bt)
  rowsVar <- lift $ storeExpr rows
  colsVar <- lift $ storeExpr cols
  lift $ store $ UType (TMatrix (Dim rowsVar colsVar) typeVar)


-- Convert between trees and flat named trees
--
-- Flattening is easy
storeExpr :: ExprU -> M Name
storeExpr e = iterM (\f -> T.sequence f >>= (store . UExpr))
                    (fromFix e)

-- Rebuilding
buildExpr :: Name -> InnerM CExpr
buildExpr n = do
  val <- lift $ get n 
  case val of
    UExpr e -> do
      maybeTree <- T.mapM buildExpr e
      return (wrap maybeTree)
    _ -> left $ UError [n] "buildExpr. not resolved."

buildBaseType :: Name -> InnerM BaseType
buildBaseType n = do
  val <- lift $ get n
  case val of
    UType (TLit bt) -> return bt
    _ -> left $ UError [n] "buildBaseType. not resolved."

buildType :: Name -> InnerM CType
buildType n = do
  val <- lift $ get n 
  case val of
    UType (TLit bt) -> return $ TLit bt
    UType (TMatrix (Dim rows' cols') bt') -> do
      r <- buildExpr rows' 
      c <- buildExpr cols' 
      bt <- buildBaseType bt'
      return (TMatrix (Dim r c) bt)
    _ -> left $ UError [n] "buildType. not resolved."

toCType :: Name -> Env UValue -> Either UError CType
toCType name env =
  withEnv env . runEitherT $ buildType name

addType :: Env UValue -> TypedLine Name
        -> Either UError (TypedLine CType)
addType env (TLine name line c) = do
  ctype <- toCType name env
  c' <- mapM fixEntry c
  return (TLine ctype line c')
 where
  fixEntry (var, name) = do
    ctype <- toCType name env
    return (var, ctype)

typeCheck :: [Line] -> Either [UError] [(TypedLine CType)]
typeCheck program =
  let ((_, mlines), env) = runEnv (parseLines emptyContext program)
      mlines' = map (>>= addType env) mlines
      (errors, ok) = partitionEithers mlines'
  in
    case errors of
      [] -> Right ok
      _ -> Left errors

-- Testing
emptyContext :: Context
emptyContext = M.fromList []

chk :: [Line] -> IO ()
chk x = 
  let ((context, typedLines), vars) = runEnv $ parseLines emptyContext x
  in do
    mapM_ print typedLines
    putStrLn "-----------"
    mapM_ print (M.toList context)
    putStrLn "-----------"
    mapM_ print (M.toList vars)

ch x =
 case typeCheck x of
   Left errors -> putStrLn "ERROR:" >> mapM_ print errors
   Right lines -> putStrLn "okay:" >> mapM_ print lines