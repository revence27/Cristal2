module API (CristalConn (), connect, get, send, shortcode, reentrance) where

import qualified Data.Map as DM
import Data.Maybe (isJust, fromJust)
import JSON
import Network
import System.IO
import Util

type Keywd  = String
type Passwd = String
type Sender    = String
type Recipient = String
type Hostname  = String

data CristalConn = CristalConn {handle :: Handle,
                                shortcode :: String,
                                reentrance :: Int}

connect :: Monad m => Hostname -> Int -> Keywd -> Passwd ->
    (CristalConn -> IO a) -> IO (m (IO a))
connect hst prt kwd pwd f = withSocketsDo $ do
    hdl <- connectTo hst $ PortNumber $ toEnum prt
    hSetBuffering hdl LineBuffering
    hPutStrLn hdl ("{\"facility\":\"login\", \"params\":{\"keyword\":" ++
        (show kwd) ++ ", \"password\":" ++ (show pwd) ++
            ", \"pwdscheme\":\"pwd\"}}")
    rsp  <- hGetLine hdl
    return $ case toJSON rsp of
        No x    -> fail x
        Yes got -> case "/facility" @@ got of
            Just (JStr "error") -> case "/params/message" @@ got of
                Just (JStr msg) -> fail msg
                _               -> fail "Error logging in; no reason given."
            Just (JStr "proceed") -> return $ do
                case ("/params/shortcode" @@ got,
                      "/params/reentrance" @@ got) of
                    (Just (JStr shtc), Just (JNum rec)) -> do
                        act <- f (CristalConn hdl shtc rec)
                        hPutStrLn hdl "{\"facility\":\"logout\"}"
                        return act
                    _  -> fail ("Cristal returned terrible JSON: " ++ rsp)
            _                     -> fail "Unknown facility."

send :: CristalConn -> Sender -> [Recipient] -> String -> IO ()
send (CristalConn hdl shtc rec) snd rcp msg = do
    hPutStrLn hdl ("{\"facility\":\"send\", \"params\":{\"to\":"
        ++ (show rcp) ++ ", \"from\":" ++ (show snd) ++ ", \"message\":"
        ++ (show msg) ++ "}}")
    resp <- fmap toJSON $ hGetLine hdl
    case resp of
        No z  -> fail z
        Yes y -> do
            case "/facility" @@ y of
                Just (JStr "proceed") -> return ()
                _                     -> case "/params/message" @@ y of
                    Just (JStr x) -> fail x
                    _             -> fail ("Strange JSON: " ++ show y)

get :: Monad m => CristalConn -> IO (m JSONValue)
get (CristalConn hdl shtc rec) = do
    json <- fmap toJSON $ hGetLine hdl
    return $ case json of
        No x        -> fail x
        i@(Yes got) -> (case "/facility" @@ got of
            No y                  -> fail "No facility requested?"
            Yes (JStr "finalise") -> fail "Logging out"
            _                     -> return got)
