module Main (main) where

import Spec.Marconi.Sidechain.Api.Query.Indexers.Utxo qualified as Api.Query.Indexers.Utxo
import Spec.Marconi.Sidechain.CLI qualified as CLI
import Test.Tasty (TestTree, defaultMain, localOption, testGroup)
import Test.Tasty.Hedgehog (HedgehogTestLimit (HedgehogTestLimit))

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = localOption (HedgehogTestLimit $ Just 200) $
    testGroup "marconi-sidechain"
        [ Api.Query.Indexers.Utxo.tests
        , CLI.tests
        ]