module Util where

data Success a = Yes a | No String deriving Show

instance Monad Success where
    fail        = No
    return      = Yes
    Yes x >>= f = f x
    No x  >>= f = No x

instance Functor Success where
    fmap f (Yes x) = Yes $ f x
    fmap _ (No s)  = No s
