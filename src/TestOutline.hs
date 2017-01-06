{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module TestOutline where

import           Control.Concurrent       (threadDelay)
import           Control.Concurrent.Async (Async, cancel, poll)
import           Control.Concurrent.MVar  (MVar, readMVar, newEmptyMVar, putMVar, takeMVar)
import           Control.Exception        (throwIO)
import           Control.Monad            (zipWithM)
import           Control.Monad.Managed    (MonadManaged)
import           Control.Monad.Reader     (ReaderT (runReaderT), MonadReader)
import           Data.List                (unzip4)
import           Data.Monoid              (Last (Last))
import           Data.Monoid.Same         (Same (NotSame, Same), allSame)
import           Data.Text                (Text, pack)
import qualified Data.Text.IO             as T
import           Data.Time                (getZonedTime, formatTime, defaultTimeLocale)
import qualified IpTables                 as IPT
import qualified PacketFilter             as PF
import           System.Info
import           Turtle

import Cluster
import ClusterAsync

newtype TestNum = TestNum { unTestNum :: Int } deriving (Enum, Num)
newtype NumNodes = NumNodes { unNumNodes :: Int }

data FailureReason
  = WrongOrder (Last Block) (Last Block)
  | NoBlockFound
  | DidPanic
  deriving Show

data Validity
  = Verified
  | Falsified FailureReason
  deriving Show

second :: Int
second = 10 ^ (6 :: Int)

failedTestCode :: ExitCode
failedTestCode = ExitFailure 1

verifySameLastBlock :: [Either NodeTerminated (Last Block)] -> Validity
verifySameLastBlock results = case allSame results of
  NotSame a b -> Falsified $ case (a, b) of
    (Left NodeTerminated, _) -> DidPanic
    (_, Left NodeTerminated) -> DidPanic
    (Right b1, Right b2)     -> WrongOrder b1 b2
  Same (Left NodeTerminated)  -> Falsified DidPanic
  Same (Right (Last Nothing)) -> Falsified NoBlockFound
  _                           -> Verified

data ShouldTerminate
  = DoTerminateSuccess
  | DoTerminateFailure
  | DontTerminate

instance Monoid ShouldTerminate where
  mempty = DontTerminate
  mappend DoTerminateSuccess _ = DoTerminateSuccess
  mappend DoTerminateFailure _ = DoTerminateFailure
  mappend DontTerminate      t = t

type TestPredicate = TestNum -> Validity -> ShouldTerminate

-- | Run this test up to @TestNum@ times or until it fails
tester
  :: TestPredicate
  -> NumNodes
  -> ([Geth] -> ReaderT ClusterEnv Shell ())
  -> IO ()
tester p numNodes cb = foldr go mempty [0..] >>= \case
  DoTerminateSuccess -> exit ExitSuccess
  DoTerminateFailure -> exit failedTestCode
  DontTerminate      -> putStrLn "all successful!"

  where
    go :: TestNum -> IO ShouldTerminate -> IO ShouldTerminate
    go testNum runMoreTests = do
      putStrLn $ "test #" ++ show (unTestNum testNum)
      resultVar <- liftIO newEmptyMVar

      sh $ flip runReaderT defaultClusterEnv $ do
        let geths = [1..GethId (unNumNodes numNodes)]
        _ <- when (os == "darwin") PF.acquirePf

        nodes <- setupNodes geths
        (readyAsyncs, terminatedAsyncs, lastBlockMs, _lastRafts) <-
          unzip4 <$> traverse runNode nodes

        -- wait for geth to launch, then start raft and run the test body
        awaitAll readyAsyncs
        startRaftAcross nodes
        cb nodes

        liftIO $ do
          -- pause a second before checking last block
          td 1

          result1 <- verify lastBlockMs terminatedAsyncs

          -- wait an extra five seconds to guarantee raft has a chance to converge
          case result1 of
            Falsified (WrongOrder _ _) -> td 5
            Falsified NoBlockFound -> td 5
            _ -> return ()

          result2 <- verify lastBlockMs terminatedAsyncs
          putMVar resultVar result2

      result <- takeMVar resultVar
      print result
      case p testNum result of
        DontTerminate -> runMoreTests
        term -> pure term

testOnce :: NumNodes -> ([Geth] -> ReaderT ClusterEnv Shell ()) -> IO ()
testOnce numNodes =
  let predicate _ Verified = DoTerminateSuccess
      predicate _ _        = DoTerminateFailure
  in tester predicate numNodes

-- | Verify that every node has the same last block and none have terminated.
verify :: [MVar (Last Block)] -> [Async NodeTerminated] -> IO Validity
verify lastBlockMs terminatedAsyncs = do
  -- verify that all have consistent logs
  lastBlocks <- traverse readMVar lastBlockMs
  meEarlyTerms <- traverse poll terminatedAsyncs

  results <- zipWithM (curry $ \case
                        (Just (Left ex), _)     -> throwIO ex
                        (Just (Right panic), _) -> pure $ Left panic
                        (Nothing, lastBlock)    -> pure $ Right lastBlock)
                      meEarlyTerms
                      lastBlocks

  return (verifySameLastBlock results)

partition :: (MonadManaged m, HasEnv m) => Millis -> GethId -> m ()
partition millis node =
  if os == "darwin"
  then PF.partition millis node >> PF.flushPf
  else IPT.partition millis node

startRaftAcross
  :: (Traversable t, MonadIO m, MonadReader ClusterEnv m)
  => t Geth
  -> m ()
startRaftAcross gs = void $ forConcurrently' gs startRaft

-- TODO make this not callback-based
-- spammer :: MonadManaged m =>
withSpammer :: (MonadIO m, MonadReader ClusterEnv m) => [Geth] -> m () -> m ()
withSpammer geths action = do
  spammer <- clusterAsync $ spamTransactions geths
  action
  liftIO $ cancel spammer

td :: MonadIO m => Int -> m ()
td = liftIO . threadDelay . (* second)

timestampedMessage :: MonadIO m => Text -> m ()
timestampedMessage msg = liftIO $ do
  zonedTime <- getZonedTime
  let locale = defaultTimeLocale
      formattedTime = pack $ formatTime locale "%I:%M:%S.%q" zonedTime
  T.putStrLn $ formattedTime <> ": " <> msg
