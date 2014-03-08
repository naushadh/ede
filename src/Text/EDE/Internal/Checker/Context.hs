{-# LANGUAGE GADTs #-}

-- Module      : Text.EDE.Internal.Checker.Context
-- Copyright   : (c) 2013-2014 Brendan Hay <brendan.g.hay@gmail.com>
-- License     : This Source Code Form is subject to the terms of
--               the Mozilla Public License, v. 2.0.
--               A copy of the MPL can be found in the LICENSE file or
--               you can obtain it at http://mozilla.org/MPL/2.0/.
-- Maintainer  : Brendan Hay <brendan.g.hay@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)

-- | Operations on typechecking contexts.
module Text.EDE.Internal.Checker.Context where

import Data.Maybe
import Data.Monoid
import Text.EDE.Internal.Pretty
import Text.EDE.Internal.Types

-- | Snoc
(>:) :: Context -> Elem -> Context
Context gamma >: x = Context $ x : gamma

-- | Context & list of elems append
(>++) :: Context -> [Elem] -> Context
gamma >++ elems = gamma <> context elems

context :: [Elem] -> Context
context = Context . reverse

dropMarker :: Elem -> Context -> Context
dropMarker m (Context gamma) = Context $ tail $ dropWhile (/= m) gamma

breakMarker :: Elem -> Context -> (Context, Context)
breakMarker m (Context xs) = let (r, _:l) = break (== m) xs in (Context l, Context r)

existentials :: Context -> [TVar]
existentials (Context gamma) = aux =<< gamma
  where
    aux (CExists alpha)         = [alpha]
    aux (CExistsSolved alpha _) = [alpha]
    aux _                       = []

unsolved :: Context -> [TVar]
unsolved (Context gamma) = [alpha | CExists alpha <- gamma]

vars :: Context -> [Var]
vars (Context gamma) = [x | CVar x _ <- gamma]

foralls :: Context -> [TVar]
foralls (Context gamma) = [alpha | CForall alpha <- gamma]

markers :: Context -> [TVar]
markers (Context gamma) = [alpha | CMarker alpha <- gamma]

-- | Well-formedness of contexts
--   wf Γ <=> Γ ctx
wf :: Context -> Bool
wf (Context gamma) = case gamma of
    -- EmptyCtx
    []   -> True
    c:cs -> let gamma' = Context cs in wf gamma' && case c of
        -- UvarCtx
        CForall alpha -> alpha `notElem` foralls gamma'
        -- VarCtx
        CVar x a -> x `notElem` vars gamma' && typewf gamma' a
        -- EvarCtx
        CExists alpha -> alpha `notElem` existentials gamma'
        -- SolvedEvarCtx
        CExistsSolved alpha tau -> alpha `notElem` existentials gamma'
                                && typewf gamma' tau
        -- MarkerCtx
        CMarker alpha -> alpha `notElem` markers gamma'
                      && alpha `notElem` existentials gamma'

-- | Well-formedness of types
--   typewf Γ A <=> Γ |- A
typewf :: Context -> Type b -> Bool
typewf gamma typ = case typ of
    TCon _          -> True
    -- UvarWF
    TVar alpha      -> alpha `elem` foralls gamma
    -- ArrowWF
    TFun a b        -> typewf gamma a && typewf gamma b
    -- ForallWF
    TForall alpha a -> typewf (gamma >: CForall alpha) a
    -- EvarWF and SolvedEvarWF
    TExists alpha   -> alpha `elem` existentials gamma

-- | findSolved (ΓL,α^ = τ,ΓR) α = Just τ
findSolved :: Context -> TVar -> Maybe Monotype
findSolved (Context gamma) v = listToMaybe [t | CExistsSolved v' t <- gamma, v == v']

-- | findVarType (ΓL,x : A,ΓR) x = Just A
findVarType :: Context -> Var -> Maybe Polytype
findVarType (Context gamma) v = listToMaybe [t | CVar v' t <- gamma, v == v']

-- | solve (ΓL,α^,ΓR) α τ = (ΓL,α = τ,ΓR)
solve :: Context -> TVar -> Monotype -> Maybe (Context)
solve gamma alpha tau
    | typewf gammaL tau = Just gamma'
    | otherwise         = Nothing
  where
    (gammaL, gammaR) = breakMarker (CExists alpha) gamma

    gamma' = gammaL >++ [CExistsSolved alpha tau] <> gammaR

-- | insertAt (ΓL,c,ΓR) c Θ = ΓL,Θ,ΓR
insertAt :: Context -> Elem -> Context -> Context
insertAt gamma c theta = gammaL <> theta <> gammaR
  where
    (gammaL, gammaR) = breakMarker c gamma

-- | apply Γ A = [Γ]A
apply :: Context -> Polytype -> Polytype
apply gamma typ = case typ of
    TCon c      -> TCon c
    TVar v      -> TVar v
    TForall v t -> TForall v (apply gamma t)
    TExists v   -> maybe (TExists v) (apply gamma . polytype) $ findSolved gamma v
    TFun t1 t2  -> apply gamma t1 `TFun` apply gamma t2

-- | ordered Γ α β = True <=> Γ[α^][β^]
ordered :: Context -> TVar -> TVar -> Bool
ordered gamma alpha beta =
    let gammaL = dropMarker (CExists beta) gamma
     in alpha `elem` existentials gammaL

-- Assert-like functionality to make sure that contexts and types are
-- well-formed
checkwf :: Context -> x -> x
checkwf gamma x
    | wf gamma  = x
    | otherwise = error $ "Malformed context: " ++ pp gamma

checkwftype :: Context -> Polytype -> x -> x
checkwftype gamma a x
    | typewf gamma a = checkwf gamma x
    | otherwise      = error $ "Malformed type: "
                       ++ pp (a, gamma)
