{-# LANGUAGE LambdaCase #-}

{- |
    A set of queries that can be implemented by any indexer

    See "Marconi.Core.Experiment" for documentation.
-}
module Marconi.Core.Experiment.Query (
  EventAtQuery (EventAtQuery),
  EventsMatchingQuery (EventsMatchingQuery),
  allEvents,
) where

import Control.Lens qualified as Lens
import Control.Lens.Operators ((^.), (^..), (^?))
import Control.Monad (when)
import Control.Monad.Except (MonadError (catchError, throwError))
import Data.Maybe (mapMaybe)
import Marconi.Core.Experiment.Class (AppendResult (appendResult), Queryable (query), isAheadOfSync)
import Marconi.Core.Experiment.Indexer.ListIndexer (ListIndexer, events)
import Marconi.Core.Experiment.Type (
  Point,
  QueryError (AheadOfLastSync, NotStoredAnymore),
  Result,
  Timed,
  event,
  point,
 )

-- | Get the event stored by the indexer at a given point in time
data EventAtQuery event = EventAtQuery
  deriving (Eq, Ord, Show)

{- | The result of EventAtQuery is always an event.
 The error cases are handled by the query interface.
 in time
-}
type instance Result (EventAtQuery event) = Maybe event

instance
  (MonadError (QueryError (EventAtQuery event)) m)
  => Queryable m event (EventAtQuery event) ListIndexer
  where
  query p EventAtQuery ix = do
    let isAtPoint e p' = e ^. point == p'
    aHeadOfSync <- isAheadOfSync p ix
    when aHeadOfSync $
      throwError $
        AheadOfLastSync Nothing
    pure $ ix ^? events . Lens.folded . Lens.filtered (`isAtPoint` p) . event

instance
  (MonadError (QueryError (EventAtQuery event)) m)
  => AppendResult m event (EventAtQuery event) ListIndexer
  where
  appendResult p q indexer result =
    result `catchError` \case
      -- If we didn't find a result in the 1st indexer, try in memory
      _inDatabaseError -> query p q indexer

{- | Query an indexer to find all events that match a given predicate

 The result should return the most recent first
-}
newtype EventsMatchingQuery event = EventsMatchingQuery {predicate :: event -> Maybe event}

-- | Get all the events that are stored in the indexer
allEvents :: EventsMatchingQuery event
allEvents = EventsMatchingQuery Just

-- | The result of an @EventMatchingQuery@
type instance Result (EventsMatchingQuery event) = [Timed (Point event) event]

instance
  (MonadError (QueryError (EventsMatchingQuery event)) m)
  => Queryable m event (EventsMatchingQuery event) ListIndexer
  where
  query p q ix = do
    let isBefore p' e = p' >= e ^. point
    let result =
          mapMaybe (traverse $ predicate q) $
            ix ^.. events . Lens.folded . Lens.filtered (isBefore p)

    aheadOfSync <- isAheadOfSync p ix
    when aheadOfSync $
      throwError . AheadOfLastSync . Just $
        result
    pure result

instance
  (MonadError (QueryError (EventsMatchingQuery event)) m)
  => AppendResult m event (EventsMatchingQuery event) ListIndexer
  where
  appendResult p q indexer result =
    let extractDbResult =
          result `catchError` \case
            -- If we find an incomplete result in the first indexer, complete it
            AheadOfLastSync (Just r) -> pure r
            -- For any other error, forward it
            inDatabaseError -> throwError inDatabaseError

        extractMemoryResult =
          query p q indexer `catchError` \case
            -- If we find an incomplete result in the first indexer, complete it
            NotStoredAnymore -> pure []
            -- For any other error, forward it
            inMemoryError -> throwError inMemoryError
     in do
          dbResult <- extractDbResult
          memoryResult <- extractMemoryResult
          pure $ memoryResult <> dbResult
