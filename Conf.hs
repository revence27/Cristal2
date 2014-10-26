module Conf (Settings (Settings), mods, Conf (), closeConf, openConf,
       withConf, moduleMap, activeMods, newActive, notActive, kwdAliases) where

import Control.Concurrent
import Control.Exception as Except
import Data.Char
import qualified Data.Map as DM
import JSON
import Network
import System.IO
import Util

data Settings = Settings {mods :: DM.Map String String,
                        active :: DM.Map String Handle,
                       aliases :: DM.Map String String}

data Conf = Conf {info :: MVar Settings, thd :: ThreadId}

instance Show PortID where
    show (PortNumber x) = show (fromEnum x)
    show _              = ""

openConf :: Settings -> Socket -> IO Conf
openConf dft sck = do
    sts <- newMVar dft
    th  <- forkIO (maintainConf sts sck)
    return (Conf sts th)

closeConf :: Conf -> IO ()
closeConf (Conf _ th) = killThread th

withConf :: Settings -> Socket -> (Conf -> IO a) -> IO a
withConf dft sck app = do
    cnf <- openConf dft sck
    got <- app cnf
    closeConf cnf
    return got

newActive :: Conf -> String -> Handle -> IO ()
newActive (Conf st _) str hdl = do
    modifyMVar_ st (\(Settings m a al) ->
        return $ Settings m (DM.insert str hdl a) al)

notActive :: Conf -> String -> IO ()
notActive (Conf st _) str = do
    modifyMVar_ st (\(Settings m a al) ->
        return $ Settings m (DM.delete str a) al)

maintainConf :: MVar Settings -> Socket -> IO ()
maintainConf sts sck = do
    (hdl, _, _) <- accept sck
    hSetBuffering hdl LineBuffering
    modifyMVar_ sts (\x -> (do
        hPutStrLn hdl ("{\"modules\":" ++ (mods2JSON (mods x)) ++
            ", \"active\":" ++ (show (DM.keys (active x))) ++
            ", \"aliases\":" ++ (mods2JSON (aliases x)) ++ "}")
        hFlush hdl
        got <- fmap toJSON (hGetLine hdl)
        case got of
            No x' -> do
                hPutStrLn hdl ("{\"error\":" ++ (show x') ++ "}")
                return x
            Yes y  -> case "/modules" @@ y of
                    No x' -> do
                        hPutStrLn hdl
                            ("{\"error\":" ++ (show x') ++ "}")
                        return (Settings (mods x) (active x) (aliases x))
                    Yes (JObj mor) -> case "/aliases" @@ y of
                        No z' -> do
                            hPutStrLn hdl ("{\"error\":" ++ (show z') ++ "}")
                            return (Settings (json2Mods mor) (active x)
                                    (aliases x))
                        Yes (JObj alz) -> do
                            return (Settings (json2Mods mor) (active x)
                                             (json2Mods alz))
                        _              -> do
                            hPutStrLn hdl
                                ("{\"error\":\"aliases should be object\"}")
                            return (Settings (json2Mods mor) (active x)
                                    (aliases x))
                    _              -> do
                        hPutStrLn hdl
                            ("{\"error\":\"modules should be object\"}")
                        return (Settings (mods x) (active x)
                                (aliases x)))) `Except.catch`
                                        ((\_ -> return ()) :: IOError -> IO ())
    hClose hdl
    maintainConf sts sck

json2Mods :: DM.Map String JSONValue -> DM.Map String String
json2Mods m = foldr (\k y ->
    case DM.lookup k m of
        Just (JStr v) -> DM.insert (lwr k) (lwr v) y
        _             -> y
    ) DM.empty (DM.keys m)
    where
        lwr :: String -> String
        lwr s = [toLower x | x <- s]

mods2JSON :: DM.Map String String -> String
mods2JSON mds = show (JObj (DM.map JStr mds))

moduleMap :: Conf -> IO (DM.Map String String)
moduleMap (Conf inf _) = do
    withMVar inf (\(Settings m a al) -> return m)

activeMods :: Conf -> IO (DM.Map String Handle)
activeMods (Conf inf _) = do
    withMVar inf (\(Settings m a al) -> return a)

kwdAliases :: Conf -> IO (DM.Map String String)
kwdAliases (Conf inf _) = do
    withMVar inf (\(Settings m a al) -> return al)
