{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StrictData #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

{- |
    A transformer that delay insertion of events into an indexer.

    See "Marconi.Core.Experiment" for documentation.
-}
module Marconi.Core.Experiment.Transformer.WithDelay (
  WithDelay,
  withDelay,
  HasDelayConfig (delayCapacity),
) where

import Control.Lens (Lens', makeLenses, view)
import Control.Lens.Operators ((%~), (&), (+~), (.~), (^.))
import Data.Sequence (Seq (Empty, (:|>)), (<|))
import Data.Sequence qualified as Seq

import Marconi.Core.Experiment.Class (
  Closeable,
  IsIndex (index, rollback),
  IsSync,
  Queryable,
  Resetable (reset),
 )
import Marconi.Core.Experiment.Indexer.SQLiteAggregateQuery (HasDatabasePath)
import Marconi.Core.Experiment.Transformer.Class (IndexerMapTrans (unwrapMap))
import Marconi.Core.Experiment.Transformer.IndexTransformer (
  IndexTransformer (IndexTransformer),
  IndexerTrans (Config, unwrap, wrap),
  indexVia,
  resetVia,
  rollbackVia,
  wrappedIndexer,
  wrapperConfig,
 )
import Marconi.Core.Experiment.Type (Point, Timed, point)

data DelayConfig event = DelayConfig
  { _configDelayCapacity :: Word
  , _configDelayLength :: Word
  , _configDelayBuffer :: Seq (Timed (Point event) (Maybe event))
  }

makeLenses 'DelayConfig

{- | When indexing computation is expensive, you may want to delay it to avoid expensive rollback
 'WithDelay' buffers events before sending them to the underlying indexer.
 Buffered events are sent when the buffers overflows.

 An indexer wrapped in 'WithDelay' won't interact nicely with a coordinator at the moment,
 as 'WithDelay' acts as it's processing an event while it only postpones the processing.

 As a consequence, 'WithDelay' is preferably used at the top of the hierarchy.
-}
newtype WithDelay indexer event = WithDelay {_delayWrapper :: IndexTransformer DelayConfig indexer event}

-- | A smart constructor for 'WithDelay'
withDelay
  :: Word
  -- ^ capacity
  -> indexer event
  -> WithDelay indexer event
withDelay c = WithDelay . IndexTransformer (DelayConfig c 0 Seq.empty)

makeLenses 'WithDelay

deriving via
  (IndexTransformer DelayConfig indexer)
  instance
    (IsSync m event indexer) => IsSync m event (WithDelay indexer)

deriving via
  (IndexTransformer DelayConfig indexer)
  instance
    (HasDatabasePath indexer) => HasDatabasePath (WithDelay indexer)

deriving via
  (IndexTransformer DelayConfig indexer)
  instance
    (Closeable m indexer) => Closeable m (WithDelay indexer)

deriving via
  (IndexTransformer DelayConfig indexer)
  instance
    (Queryable m event query indexer) => Queryable m event query (WithDelay indexer)

instance IndexerTrans WithDelay where
  type Config WithDelay = DelayConfig

  wrap cfg = WithDelay . IndexTransformer cfg

  unwrap = delayedIndexer

delayedIndexer :: Lens' (WithDelay indexer event) (indexer event)
delayedIndexer = delayWrapper . wrappedIndexer

{- | Provide accces to the delay size of a 'WithDelay' transformer.
The provided instance ensure that access is granted even if other indexer transformers are used
on top of this one
-}
class HasDelayConfig indexer where
  delayCapacity :: Lens' (indexer event) Word

instance {-# OVERLAPPING #-} HasDelayConfig (WithDelay indexer) where
  delayCapacity =
    delayWrapper . wrapperConfig . configDelayCapacity

instance
  {-# OVERLAPPABLE #-}
  (IndexerTrans t, HasDelayConfig indexer)
  => HasDelayConfig (t indexer)
  where
  delayCapacity = unwrap . delayCapacity

instance
  {-# OVERLAPPABLE #-}
  (IndexerMapTrans t, HasDelayConfig indexer)
  => HasDelayConfig (t indexer output)
  where
  delayCapacity = unwrapMap . delayCapacity

delayBuffer :: Lens' (WithDelay indexer event) (Seq (Timed (Point event) (Maybe event)))
delayBuffer = delayWrapper . wrapperConfig . configDelayBuffer

delayLength :: Lens' (WithDelay indexer event) Word
delayLength = delayWrapper . wrapperConfig . configDelayLength

instance
  (Monad m, IsIndex m event indexer)
  => IsIndex m event (WithDelay indexer)
  where
  index timedEvent indexer =
    let bufferIsFull b = (b ^. delayLength) >= (b ^. delayCapacity)

        bufferEvent = (delayLength +~ 1) . (delayBuffer %~ (timedEvent <|))

        pushAndGetOldest = \case
          Empty -> (timedEvent, Empty)
          (buffer' :|> e') -> (e', timedEvent <| buffer')

        doWhenFull = do
          let b = indexer ^. delayBuffer
              (oldest, buffer') = pushAndGetOldest b
          res <- indexVia delayedIndexer oldest indexer
          pure $ res & delayBuffer .~ buffer'
     in do
          if bufferIsFull indexer
            then doWhenFull
            else pure $ bufferEvent indexer

  rollback p indexer =
    let rollbackWrappedIndexer p' = rollbackVia delayedIndexer p' indexer

        before = Seq.dropWhileL ((> p) . view point) $ indexer ^. delayBuffer
     in if Seq.null before
          then -- if we empty the delay buffer,
          -- some events in the wrapped indexer may need a rewrite
            resetBuffer <$> rollbackWrappedIndexer p
          else
            pure $
              indexer
                & delayBuffer .~ before
                & delayLength .~ fromIntegral (Seq.length before)

resetBuffer :: WithDelay indexer event -> WithDelay indexer event
resetBuffer = (delayLength .~ 0) . (delayBuffer .~ Seq.empty)

instance
  ( Applicative m
  , Resetable m event indexer
  )
  => Resetable m event (WithDelay indexer)
  where
  reset indexer = do
    indexer' <- resetVia delayedIndexer indexer
    pure $ resetBuffer indexer'
