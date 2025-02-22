{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Spec.Marconi.ChainIndex.Experimental.Indexers.Datum (
  tests,
  getDatumsEvents,
) where

import Control.Lens ((^.), (^..))
import Data.Maybe (mapMaybe)

import Marconi.ChainIndex.Experimental.Indexers.Datum qualified as Datum
import Marconi.Core.Experiment qualified as Core

import Cardano.Api qualified as C
import Control.Lens qualified as Lens
import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Gen.Marconi.ChainIndex.Mockchain qualified as Gen
import Hedgehog ((===))
import Hedgehog qualified
import Hedgehog.Gen qualified
import Test.Gen.Cardano.Api.Typed qualified as CGen
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testPropertyNamed)

tests :: TestTree
tests =
  testGroup
    "Spec.Marconi.ChainIndex.Experimental.Indexers.Datum"
    [ testGroup
        "Indexer"
        [ testPropertyNamed
            "DatumIndexer can retrieve all the data it stores"
            "propResolveDatum"
            propResolveDatum
        ]
    , testPropertyNamed
        "JSON event tripping test"
        "propTrippingDatumJSON"
        propTrippingDatumJSON
    ]

-- | We can retrieve datum by hash if we query at its insertion slot
propResolveDatum :: Hedgehog.Property
propResolveDatum = Hedgehog.property $ do
  events <- Hedgehog.forAll $ getDatumsEvents <$> Gen.genMockchain
  event <-
    Hedgehog.forAll $
      Hedgehog.Gen.element
        =<< Hedgehog.Gen.filter (not . null) (pure $ mapMaybe sequenceA events)
  datumInfo <- Hedgehog.forAll $ Hedgehog.Gen.element $ event ^.. Core.event . Lens.folded
  emptyIndexer <- Hedgehog.evalExceptT $ Datum.mkDatumIndexer ":memory:"
  indexer <- Hedgehog.evalExceptT $ Core.indexAll events emptyIndexer
  retrievedEvents <-
    Hedgehog.evalExceptT $
      Core.query
        (event ^. Core.point)
        (Datum.ResolveDatumQuery $ datumInfo ^. Datum.datumHash)
        indexer
  Just (datumInfo ^. Datum.datum) === retrievedEvents

-- | Standard tripping property for JSON
propTrippingDatumJSON :: Hedgehog.Property
propTrippingDatumJSON = Hedgehog.property $ do
  event <- Hedgehog.forAll genDatumInfo
  Hedgehog.tripping event Aeson.encode Aeson.eitherDecode

genDatumInfo :: Hedgehog.Gen Datum.DatumInfo
genDatumInfo =
  Datum.DatumInfo
    <$> CGen.genHashScriptData
    <*> (C.getScriptData <$> CGen.genHashableScriptData)

-- | Generate a list of events from a mock chain
getDatumsEvents
  :: Gen.Mockchain era
  -> [Core.Timed C.ChainPoint (Maybe (NonEmpty Datum.DatumInfo))]
getDatumsEvents =
  let getChainPoint :: Gen.BlockHeader -> C.ChainPoint
      getChainPoint (Gen.BlockHeader slotNo blockHeaderHash _blockNo) =
        C.ChainPoint slotNo blockHeaderHash

      getBlockDatumsEvent
        :: Gen.MockBlock era
        -> Core.Timed C.ChainPoint (Maybe (NonEmpty Datum.DatumInfo))

      getBlockDatumsEvent block =
        Core.Timed (getChainPoint $ Gen.mockBlockChainPoint block)
          . NonEmpty.nonEmpty
          . (Datum.getDataFromTxBody . C.getTxBody =<<)
          $ Gen.mockBlockTxs block
   in fmap getBlockDatumsEvent
