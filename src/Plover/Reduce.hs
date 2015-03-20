{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE OverloadedStrings #-}
module Plover.Reduce
   -- TODO
   -- ( compile, reduceArith
   -- )
    where

import Data.List (intercalate)
import Data.Monoid hiding (Sum)
import qualified Data.Foldable as F (Foldable, fold)
import qualified Data.Traversable as T (Traversable, mapAccumR, sequence, mapM, traverse)
import Control.Applicative ((<$>))
import Control.Monad.Free
import Control.Monad.Trans.Either
import Control.Monad.State
import Data.String
import Data.Maybe (fromJust)
import Data.Function (on)

import Debug.Trace (trace)

import qualified Smash.Simplify as S
import Plover.Types
import Plover.Generics
import Plover.Print
import Plover.Macros (seqList, generatePrinter, newline)

reduceArith = mvisit toExpr step
  where
    scale 1 x = x
    scale x (Lit 1) = Lit x
    scale x y = (Lit x) * y

    step = S.simplify scale

    toExpr :: CExpr -> Maybe (S.Expr CExpr Int)
    toExpr (a :+ b) = do
      a' <- toExpr a
      b' <- toExpr b
      return $ S.Sum [a', b']
    toExpr (a :* b) = do
      a' <- toExpr a
      b' <- toExpr b
      return $ S.Mul [a', b']
    toExpr (Lit i) = return $ S.Prim i
    toExpr (Neg x) = do
      x' <- toExpr x
      return $ S.Mul [S.Prim (-1), x']
    toExpr e@(R v) = return $ S.Atom e
    --toExpr e@(a :! b) = return $ S.Atom e
    toExpr x = Nothing

typeSize :: Type -> CExpr
typeSize (ExprType l) = product l

topTypeSize :: Type -> CExpr
topTypeSize (ExprType (l :_)) = l

-- Type Checking
varType :: Variable -> M Type
varType var = do
  (_, env) <- get
  case lookup var env of
    -- TODO infer types?
    Nothing -> left $ "undefined var: " ++ var ++ "\n" ++ show env
    --Nothing -> return numType
    Just t -> return t

assert :: Bool -> Error -> M ()
assert cond msg = if cond then return () else left msg

withBinding :: Variable -> Type -> M a -> M a
withBinding var t m = do
  (_, env0) <- get
  extend var t
  a <- m
  modify $ \(c, _) -> (c, env0)
  return a
-- --

-- Attempts to simplify numeric expressions
numericEquiv :: CExpr -> CExpr -> Bool
numericEquiv = (==) `on` reduceArith

typeEq :: Type -> Type -> Bool
typeEq Void Void = True
typeEq (ExprType as) (ExprType bs) = and $ zipWith numericEquiv as bs
-- TODO other case

-- Unify, for type variables
type Bindings = [(Variable, CExpr)]
unifyTypes :: Type -> Type -> M Bindings
unifyTypes t1 t2 = unifyT [] t1 t2

walk :: Bindings -> CExpr -> CExpr
walk bs (TV v) =
  case lookup v bs of
    Nothing -> TV v
    Just (TV v') -> walk bs (TV v')
    Just val -> val
walk bs e = e

--unifyStep :: Bindings -> Type -> Type -> M Bindings
--unifyStep bs = unifyT bs `on` walk bs

unifyExpr :: Bindings -> CExpr -> CExpr -> M Bindings
unifyExpr bs = unifyExpr' bs `on` walk bs
unifyExpr' bs (TV v) x = return $ (v, x) : bs
unifyExpr' bs x y = do
  assert (x `numericEquiv` y) $ "unifyExpr failure:\n" ++ sep x y
  return bs

unifyT :: Bindings -> Type -> Type -> M Bindings
unifyT bs (ExprType d1) (ExprType d2) =
  unifyMany bs (map Dimension d1) (map Dimension d2)
unifyT bs Void Void = return bs
unifyT bs StringType StringType = return bs
unifyT bs IntType IntType = return bs
unifyT bs (FnType (FT _ params1 out1)) (FnType (FT _ params2 out2)) = do
  bs' <- unifyT bs out1 out2
  unifyMany bs' params1 params2
unifyT bs (Dimension d1) (Dimension d2) = do
  unifyExpr bs d1 d2
unifyT bs e1 e2 = left $ "unification failure:\n" ++ sep e1 e2

unifyMany :: Bindings -> [Type] -> [Type] -> M Bindings
unifyMany bs ts1 ts2 = do
  assert (length ts1 == length ts2) $ "unifyMany failure:\n" ++ sep ts1 ts2
  foldM (\bs -> uncurry $ unifyT bs) bs $ zip ts1 ts2

-- takes fn, args, returns fn applied to correct implict arguments
getImplicits :: CExpr -> [CExpr] -> M [CExpr]
getImplicits fn args = do
  FnType (FT implicits params out) <- typeCheck fn
  argTypes <- mapM typeCheck args
  bindings <- unifyMany [] params argTypes
  let 
    fix t = foldl (\term (var, val) -> substTV var val term) t bindings
    implicits' = map fix implicits
  return implicits'

-- Typecheck --
typeCheck :: CExpr -> M Type
typeCheck ((R var) := b) = do
  t <- typeCheck b
  extend var t
  return Void
typeCheck (a := b) = return Void
typeCheck (a :< b) = return Void
typeCheck (Declare t var) = do
  extend var t
  return Void
typeCheck (a :> b) = do
  typeCheck a
  typeCheck b
typeCheck e@(a :# b) = do
  ta <- typeCheck a
  tb <- typeCheck b
  case (ta, tb) of
    (ExprType (a0 : as), ExprType (b0 : bs)) -> do
      assert (as == bs) $ "expr concat mismatch: " ++ show e ++ " !! " ++ sep as bs
      return $ ExprType ((a0 + b0) : as)
    _ -> error $ "typeCheck :#. " ++ sep ta tb ++ "\n" ++ sep a b
typeCheck e@(a :+ b) = do
  typeA <- typeCheck a
  typeB <- typeCheck b
  case (typeA, typeB) of
    -- TODO check lengths
    -- These are for pointer offsets
    (ExprType (_ : _), ExprType []) -> return typeA
    (ExprType [], ExprType (_ : _)) -> return typeB
    _ -> do
      assert (typeEq typeA typeB) $ "vector sum mismatch:\n" ++ sep typeA typeB ++ "\n" ++ sep a b
      return typeA
typeCheck e@(a :/ b) = do
  typeA <- typeCheck a
  typeB <- typeCheck b
  assert (typeB == numType) $ "denominator must be a number: " ++ show e
  return typeA
typeCheck e@(a :* b) = do
  typeA <- typeCheck a
  typeB <- typeCheck b
  case (typeA, typeB) of
    (ExprType [], _) -> return typeB
    (_, ExprType []) -> return typeA
    (ExprType [a0, a1], ExprType [b0, b1]) -> do
      assert (a1 `numericEquiv` b0) $ "matrix product mismatch: " ++ show e
      return $ ExprType [a0, b1]
    (ExprType [a0], ExprType [b0]) -> do
      assert (a0 `numericEquiv` b0) $ "vector product mismatch: " ++ show e
      return $ ExprType [a0]
    (ExprType [a0, a1], ExprType [b0]) -> do
      assert (a1 `numericEquiv` b0) $ "matrix/vector product mismatch:\n" ++
        sep (reduceArith a1) (reduceArith b0) ++ "\n" ++ sep a b
      return $ ExprType [a0]
    (ExprType [a1], ExprType [b0, b1]) -> do
      assert (a1 `numericEquiv` b0) $ "vector/matrix product mismatch: " ++ show e
      return $ ExprType [b1]
    _ -> error ("product:\n" ++ sep typeA typeB ++ "\n" ++ sep a b)
typeCheck (Lam var bound body) = do
  -- withBinding discards any inner bindings
  mt <- withBinding var numType (typeCheck body)
  case mt of
    ExprType btype -> 
      return $ ExprType (bound : btype)
    Void -> return Void
typeCheck (R var) = varType var
typeCheck (Free (IntLit _)) = return numType
typeCheck (a :! b) = do
  ExprType [] <- typeCheck b
  ta <- typeCheck a
  case ta of
    ExprType (_ : as) ->
      return $ ExprType as
    _ -> error $ "LOOK: " ++ sep a b
typeCheck (Free (Sigma body)) = do
  ExprType (_ : as) <- typeCheck body
  return $ ExprType as
typeCheck (Neg x) = typeCheck x
typeCheck (Free (Unary "transpose" m)) = do
  ExprType [rs, cs] <- typeCheck m
  return $ ExprType [cs, rs]
typeCheck e@(Free (Unary "inverse" m)) = do
  ExprType [rs, cs] <- typeCheck m
  assert (rs `numericEquiv` cs) $ "typeCheck. inverse applied to non-square matrix: " ++ show e
  return $ ExprType [cs, rs]
-- TODO allow implicits?
typeCheck e@(Free (FunctionDecl var (FD params output) body)) = do
  extend var (FnType (FT [] (map snd params) output))
  return Void
typeCheck e@(Free (Extern var t)) = do
  extend var t
  return Void
typeCheck e@(Free (App f args)) = do
  FnType (FT implicits params out) <- typeCheck f
  argTypes <- mapM typeCheck args
  bindings <- unifyMany [] params argTypes
  let out' = foldl (\term (var, val) -> fmap (substTV var val) term) out bindings
  return $ out'
-- TODO be smarter
typeCheck (Free (AppImpl f _ args)) = typeCheck (Free (App f args))
typeCheck (Str _) = return stringType
typeCheck x = error ("typeCheck: " ++ ppExpr Lax x)


-- Compilation Utils --
-- TODO capture
subst :: Variable -> CExpr -> CExpr -> CExpr
subst var val v = visit fix v
  where
    fix (R v) | v == var = val
    fix v = v
substTV :: Variable -> CExpr -> CExpr -> CExpr
substTV var val v = visit fix v
  where
    fix (TV v) | v == var = val
    fix v = v

compileMMMul :: CExpr -> (CExpr, CExpr) -> CExpr -> (CExpr, CExpr) -> M CExpr
compileMMMul x (r1, c1) y (r2, c2) = do
  i <- freshName
  inner <- freshName
  j <- freshName
  x' <- flattenTerm x
  y' <- flattenTerm y
  xb <- body x' (R i) (R inner)
  yb <- body y' (R inner) (R j)
  return $
    Lam i r1 $ Lam j c2 $ Free $ Sigma $ 
      Lam inner c1 (xb * yb)
  where
    body vec v1 v2 = return ((vec :! v1) :! v2)

flattenTerm :: CExpr -> M CExpr
flattenTerm e | not (compoundVal e) = return e
flattenTerm e = do
  n <- freshName
  return $ (R n := e :> R n)

compileMVMul :: CExpr -> (CExpr, CExpr) -> CExpr -> CExpr -> M CExpr
compileMVMul x (r1, c1) y rows = do
  i <- freshName
  inner <- freshName
  return $
    Lam i rows $ Free $ Sigma $
      Lam inner c1 (((x :! (R i)) :! (R inner)) * (y :! (R inner)))

compileFunctionArgs f args = do
  (cont, fn, rargs) <- foldM step (id, f, []) args
  implicits <- getImplicits f args
  return $ cont (Free $ AppImpl fn implicits (reverse rargs))
  where
    --step :: (CExpr -> CExpr, CExpr, [CExpr]) -> CExpr -> M (...)
    step (cont, fn, args) arg =
      if compoundVal arg
      then do
        n <- freshName
        return (\e -> (R n := arg) :> e, fn, (R n) : args)
      else return (cont, fn, arg : args)

compoundVal (R _) = False
compoundVal (Free (IntLit _)) = False
compoundVal (Free (StrLit _)) = False
compoundVal (a :! b) = compoundVal a || compoundVal b
compoundVal (a :+ b) = compoundVal a || compoundVal b
compoundVal (a :* b) = compoundVal a || compoundVal b
compoundVal (a :/ b) = compoundVal a || compoundVal b
-- TODO ok?
compoundVal (a :> b) = compoundVal b
compoundVal _ = True

-- Term Reduction --
compile :: CExpr -> M [CExpr]
-- Iterate compileStep to convergence
compile expr =
  if debugFlag
  then do
    iterateM step expr
  else do
    _ <- typeCheck expr
    expr' <- fixM step expr
    return [expr']
  where
    sep = "\n------------\n"
    debugFlag = False

    step expr =
     let
        printStep =
          if debugFlag
          then
            case flatten expr of
              Right e' -> trace (sep ++ ppLine Lax "" e' ++ sep)
              Left _ -> id
          else id
     in printStep $ compileStep Top expr

-- TODO remove dependence on context?
data Context = Top | LHS | RHS
  deriving (Show)

-- TODO is this confluent? how could we prove it?
-- Each case has a symbolic explanation
compileStep :: Context -> CExpr -> M CExpr

-- Initialization -> Declaration; Assignment
-- var := b  -->  (Decl type var); (a :< b)
compileStep _ e@((R var) := b) = do
  t <- typeCheck b
  _ <- typeCheck e
  -- TODO remove
  let debugFlag = False
  let notGenVar ('v' : 'a' : 'r' : _) = False
      notGenVar _ = True
  post <- case t of
            ExprType _ | debugFlag && notGenVar var ->
              do 
                let pname = "printf" :$ Str (var ++ "\n")
                p <- generatePrinter var t
                return [pname, p, newline ""]
            _ -> return []

  return $ seqList $
    [ Declare t var
    , (R var) :< b
    ] ++ post

-- Keep type environment "current" while compiling
compileStep _ e@(Declare t var) = do
  extend var t
  return e
compileStep Top e@(Free (Extern var t)) = do
  extend var t
  return e

compileStep Top e@(Free (FunctionDecl var t@(FD params _) body)) = do
  _ <- mapM_ (uncurry extend) params
  body' <- compileStep Top body
  return $ Free (FunctionDecl var t body')

compileStep _ e@(Free (Unary "transpose" m)) = do
  ExprType [rows, cols] <- typeCheck m
  i <- freshName
  j <- freshName
  return $ Lam i cols $ Lam j rows $ ((m :! (R j)) :! (R i))

compileStep _ e@(Free (Unary "inverse" m)) = do
  ExprType [dim, _] <- typeCheck m
  inv <- freshName
  return $ seqList [
    Declare (ExprType [dim, dim]) inv,
    Free $ App "inverse" [m, R inv],
    R inv]

-- Arithmetic: +, *, /  --
-- TODO combine these
compileStep ctxt e@(x :+ y) = do
  tx <- typeCheck x
  ty <- typeCheck y
  case (tx, ty) of
    -- pointwise add
    (ExprType (len1 : _), ExprType (len2 : _)) -> do
      assert (len1 `numericEquiv` len2) $ "sum length mismatch: " ++ show e
      i <- freshName
      return $ Lam i len1 (x :! (R i) + y :! (R i))
    (_, _) | compoundVal x -> do
      a <- freshName
      return $ (R a := x) :> (R a :+ y)
    (_, _) | compoundVal y -> do
      b <- freshName
      return $ (R b := y) :> (x :+ R b)
    (ExprType [], ExprType []) | Lit a <- x, Lit b <- y -> return $ Lit (a + b)
    (ExprType [], ExprType []) -> do
      x' <- compileStep ctxt x
      y' <- compileStep ctxt y
      return $ x' + y'
    -- TODO this handles adding ptr to int; does it allow anything else?
    _ -> return e
    --_ -> error $ "compileStep. +.\n" ++ sep tx ty ++ "\n" ++ show e
    --(ExprType [], ExprType []) -> return e

compileStep _ ((a :> b) :* c) = return $ a :> (b :* c)
compileStep _ (c :* (a :> b)) = return $ a :> (c :* b)

compileStep ctxt e@(x :* y) = do
  tx <- typeCheck x
  ty <- typeCheck y
  case (tx, ty) of
    -- Matrix product
    -- m × n  -->  Vec i (Vec j (∑ (Vec k (m i k * n k j))))
    (ExprType [r1, c1], ExprType [r2, c2]) ->
      compileMMMul x (r1, c1) y (r2, c2)
    -- matrix/vector vector/matrix products
    (ExprType [r1, c1], ExprType [r2]) ->
      compileMVMul x (r1, c1) y r2
    --(ExprType [c1], ExprType [r2, c2]) ->
    --  compileMMMul x (r1, c1) y (r2, c2)
    -- pointwise multiply
    (ExprType (len1 : _), ExprType (len2 : _)) -> do
      assert (len1 == len2) $ "product length mismatch: " ++ show e
      i <- freshName
      return $ Lam i len1 (x :! (R i) :* y :! (R i))
    (ExprType [], v@(ExprType (len : _))) -> scale x y len
    (v@(ExprType (len : _)), ExprType []) -> scale y x len
    --(ExprType [], ExprType []) | compoundVal x -> do
    --  a <- freshName
    --  return $ (R a := x) :> (R a :* y)
    --(ExprType [], ExprType []) | compoundVal y -> do
    --  b <- freshName
    --  return $ (R b := y) :> (x :* R b)
    (_, _) | compoundVal x -> do
      a <- freshName
      return $ (R a := x) :> (R a :* y)
    (_, _) | compoundVal y -> do
      b <- freshName
      return $ (R b := y) :> (x :* R b)
    (ExprType [], ExprType []) | Lit a <- x, Lit b <- y -> return $ Lit (a * b)
    (ExprType [], ExprType []) -> do
      x' <- compileStep ctxt x
      y' <- compileStep ctxt y
      return $ x' * y'
  where
    scale s vec len = do
      i <- freshName
      return $ Lam i len (s :* vec :! (R i))

compileStep ctxt e@(x :/ y) = do
  tx <- typeCheck x
  ty <- typeCheck y
  case (tx, ty) of
    -- pointwise div
    (ExprType (len : _), ExprType []) -> do
      i <- freshName
      return $ Lam i len ((x :! (R i)) :/ y)
    (ExprType [], ExprType []) | compoundVal x -> do
      a <- freshName
      return $ (R a := x) :> (R a :/ y)
    (ExprType [], ExprType []) | compoundVal y -> do
      b <- freshName
      return $ (R b := y) :> (x :/ R b)
    (ExprType [], ExprType []) -> do
      x' <- compileStep ctxt x
      y' <- compileStep ctxt y
      return $ x' / y'
    p -> error ("compileStep: " ++ show p ++ "\n" ++ show x ++ "\n" ++ show y)

-- Juxtaposition
-- a :< u # v  -->  (a :< u); (a + size u :< v)
-- TODO check this interaction with [ ]
compileStep _ (a :< u :# v) = do
  offset <- topTypeSize <$> typeCheck u
  -- TODO (a + offset) will always be wrapped by an index operation?
  return $ (a :< u) :> ((a + offset) :< v)
  --return $ (a :< u) :> ((DR $ a + offset) :< v)

-- Sequence assignment
-- a :< (u; v)  --> u; (a :< v)
compileStep _ (a :< (u :> v)) = do
  return $
    u :>
    a :< v

-- Summation
-- a :< ∑ (Vec i y_i)  -->  (a :< 0); (Vec i (a :< a + y_i))
compileStep _ (a :< (Sig vec)) = do
  i <- freshName
  ExprType (len : _) <- typeCheck vec
  let body = a :< a + (vec :! (R i))
  return $
    (a :< 0) :>
    (Lam i len $ body)

-- Vector assignment
-- a :< Vec i b_i  -->  Vec (a + i :< b_i)
compileStep ctxt (a :< (Lam var r body)) = do
  let lhs = a :! (R var)
  rhs <- withBinding var numType $ compileStep RHS body
  return $ Lam var r (lhs :< rhs)
  --return $ Lam var r (lhs :< body)

compileStep _ (a :< (b :* c)) | compoundVal b = do
  n <- freshName
  return $ (R n := b) :> (a :< R n :* c)

compileStep _ (a :< (b :* c)) | compoundVal c = do
  n <- freshName
  return $ (R n := c) :> (a :< b :* R n)

-- Vector assignment, reduction on RHS
compileStep ctxt (a :< b) = do
  bt <- typeCheck b
  case bt of
    ExprType (len : _) -> do
      i <- freshName
      let lhs = (a :! (R i))
      return $ Lam i len (lhs :< b :! (R i))
    _ -> do
      a' <- compileStep LHS a
      b' <- compileStep RHS b
      return $ a' :< b'

compileStep ctxt e@(Neg x) = do
  tx <- typeCheck x
  case tx of
    ExprType [] | compoundVal x -> do
      a <- freshName
      return $ (R a := x) :> (Neg (R a))
    ExprType [] -> do
      x' <- compileStep ctxt x
      return $ Neg x'
    ExprType (len : _) -> do
      i <- freshName
      return $ Lam i len (- (x :! (R i)))

-- Reduces function args and lifts compound ones
compileStep _ e@(Free (App f args)) = do
  compileFunctionArgs f args

-- Reduction of an application
compileStep _ ((Lam var b body) :! ind) =
  return $ subst var ind body
compileStep RHS ((a :+ b) :! ind) = return $ (a :! ind) + (b :! ind)
compileStep ctxt@RHS (e@(a :* b) :! ind) = do
  ta <- typeCheck a
  tb <- typeCheck b
  case (ta, tb) of
    (ExprType [len1], ExprType [len2]) -> return $ (a :! ind) * (b :! ind)
    (ExprType [], ExprType []) -> return $ (a :! ind) * (b :! ind)
    _ -> do
      e' <- compileStep ctxt e
      return $ e' :! ind
compileStep ctrxt ((a :> b) :! c) = return $ a :> (b :! c)
compileStep ctxt (a :! b) = do
  a' <- compileStep ctxt a
  b' <- compileStep ctxt b
  return (a' :! b')

-- Single-iteration loop unrolling
compileStep _ e@(Lam var (Lit 1) body) = do
  t <- typeCheck e
  case t of
    Void -> return $ subst var (Lit 0) body
    _ -> return e

-- Reduction within a Vec
-- Vec i x  -->  Vec i x
compileStep ctxt (Lam var r body) = do
  body' <- withBinding var numType $ compileStep ctxt body
  return $ Lam var r body'

-- Sequencing
-- a :> b  -->  a :> b
compileStep ctxt (a :> b) = do
  a' <- compileStep ctxt a
  b' <- compileStep ctxt b
  return (a' :> b')

-- id
-- x  -->  x
compileStep _ x = return x
