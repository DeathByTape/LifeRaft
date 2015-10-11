---------------------------------------------------------                                                                                                                                                                                                                           ------ Module      : Network.LifeRaft.Raft
---- Copyright   : (c) 2015 Yahoo, Inc.
---- License     : BSD3
---- Maintainer  : Dennis J. McWherter, Jr. (dennis@deathbytape.com)
---- Stability   : Experimental
---- Portability : non-portable
----
---- Hlint configuration for build process
----
-----------------------------------------------------------

module Main (main) where

import Language.Haskell.HLint (hlint)
import System.Exit (exitFailure, exitSuccess)

arguments :: [String]
arguments =
  [ "app"
  , "src"
  --, "test" -- Eventually...
  ]

main :: IO ()
main = do
  hints <- hlint arguments
  if null hints then exitSuccess else exitFailure
