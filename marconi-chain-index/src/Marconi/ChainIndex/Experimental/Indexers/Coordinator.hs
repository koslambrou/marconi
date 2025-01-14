{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}

-- | Helper to create a worker for a Coordinator
module Marconi.ChainIndex.Experimental.Indexers.Coordinator (
  coordinatorWorker,
  standardCoordinator,
) where

import Control.Concurrent (MVar)
import Control.Monad.Cont (MonadIO (liftIO))

import Cardano.BM.Tracing (Trace)
import Data.Text (Text)
import Marconi.ChainIndex.Experimental.Extract.WithDistance (WithDistance)
import Marconi.ChainIndex.Experimental.Indexers.Orphans qualified ()
import Marconi.Core.Experiment qualified as Core

standardCoordinator
  :: (Ord (Core.Point event))
  => Trace IO (Core.IndexerEvent (Core.Point event))
  -> [Core.Worker event (Core.Point event)]
  -> IO (Core.WithTrace IO Core.Coordinator event)
standardCoordinator logger = Core.withTraceM logger . Core.mkCoordinator

coordinatorWorker
  :: (MonadIO m, Ord (Core.Point b))
  => Text
  -> Trace IO (Core.IndexerEvent (Core.Point b))
  -> (WithDistance a -> IO (Maybe b))
  -> [Core.Worker b (Core.Point b)]
  -> m (MVar (Core.WithTrace IO Core.Coordinator b), Core.Worker (WithDistance a) (Core.Point b))
coordinatorWorker name logger extract workers = liftIO $ do
  coordinator <- standardCoordinator logger workers
  Core.createWorker name extract coordinator
