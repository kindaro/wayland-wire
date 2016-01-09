{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Test.Socket
where

import Control.Applicative
import Control.Concurrent
import Control.Exception
import Control.Monad
import Control.Monad.Reader
import Data.Maybe
import Data.List
import Graphics.Wayland.Wire.Message
import Graphics.Wayland.Wire.Socket
import Prelude
import System.Posix
import Test.Fd
import Test.Message
import Test.QuickCheck
import Test.QuickCheck.Monadic

server :: MVar () -> Message -> IO ()
server fence msg =
    bracket (listen Nothing) close $ \ls -> do
    putMVar fence ()
    bracket (accept ls) close (`send` msg)

client :: MessageLookup -> MVar () -> IO Message
client lf fence = do
    liftIO $ takeMVar fence
    s <- connect Nothing
    m <- recv lf s
    close s
    return m

runSockets :: IO a -> IO b -> IO (Maybe a, Maybe b)
runSockets a b = do
    ma <- newEmptyMVar
    mb <- newEmptyMVar
    _  <- forkFinally a (finalizer ma)
    _  <- forkFinally b (finalizer mb)
    ra <- takeMVar ma
    rb <- takeMVar mb
    return (ra, rb)
    where
        finalizer mvar (Left  e) = putStrLn ("exception in thread: " ++ show e) >> putMVar mvar Nothing
        finalizer mvar (Right x) = putMVar mvar (Just x)

msgFds :: Message -> [Fd]
msgFds = mapMaybe argToFd . msgArgs
    where
        argToFd (ArgFd f) = Just f
        argToFd _         = Nothing

cmpArg :: MsgArg -> MsgArg -> IO Bool
cmpArg (ArgFd fdA) (ArgFd fdB) = compareFds fdA fdB
cmpArg a           b           = return $ a == b

cmpMsg :: Message -> Message -> IO Bool
cmpMsg (Message opA objA argsA) (Message opB objB argsB) =
    ( and
    . ( [ opA  == opB
        , objA == objB
        , length argsA == length argsB
        ] ++)
    ) <$> zipWithM cmpArg argsA argsB

-- | Verify that the message sent is equal to the one that's received.
prop_sendRecv :: Message -> Property
prop_sendRecv msg =
    monadicIO $ do
        pre =<< (not . or) <$> mapM (run . fdExists) (msgFds msg)
        (eq, res) <- run $ do
            let lf  = testMsgLookup msg
                fds = msgFds msg
            paths <- createFds $ nub fds
            fence <- newEmptyMVar
            (_, res) <- runSockets (server fence msg) (client lf fence)
            eq <- case res of
                       Nothing -> return False
                       Just m  -> cmpMsg msg m
            closeFds $ nub fds
            mapM_ removeLink paths
            return (eq, res)
        stop (counterexample (show (Just msg) ++ " /= " ++ show res) eq)

return []
socketTests :: IO Bool
socketTests = $quickCheckAll
