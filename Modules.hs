module Modules where

import Conf
import Control.Concurrent
import Control.Monad
import qualified Data.Map as DM
import JSON
import Maybe (isJust, fromJust)
import Network
import System.IO
import Util

type DieSig  = SampleVar ()
type NH      = MVar (DM.Map String Handle)
type KywdMem = MVar (DM.Map String String)

manageModules :: Conf -> Inbox -> Outbox -> DieSig -> IO ()
manageModules conf inb outb die = do
    --  Open modules socket.
    --  On connection:
    --  Auth connection.
    --  Thread: Give unto caesar what is caesar's.
    --  Thread: Take from modules some things.
    --  Close off on die signal.
    return ()

getModConns :: Inbox -> Outbox -> Conf -> Socket -> NH -> IO ()
getModConns inb outb conf sck ch = do
    (tsm, hst, prt) <- accept sck
    hSetBuffering tsm NoBuffering
    forkIO $ do
        login <- hReadLine tsm
        case toJSON login of
            Yes j -> case "/params" @@ j of
                Yes _ -> do
                    let kps = ("/params/keyword" @@ j, "/params/password" @@ j,
                               "/params/pwdscheme" @@ j)
                    checkAndStart kps inb outb conf tsm ch
                No x -> hPutStrLn tsm $ "{\"facility\":\"error\"," ++
                    "\"params\":{\"message\":"  ++ show x ++ "}}"
            No x -> hPutStrLn tsm $ "{\"facility\":\"error\"," ++
                "\"params\":{\"message\":" ++ show x ++ "}}"
    getModConns inb outb conf sck ch

type AuthStuff = (Maybe JSONValue, Maybe JSONValue, Maybe JSONValue) 

checkAndStart :: AuthStuff -> Inbox -> Outbox -> Conf -> Handle -> NH -> IO ()
checkAndStart kps inb outb conf hdl ch = case kps of
    (Just (JStr k), Just (JStr p), Just (JStr s)) -> do
        known <- pickSetField mods conf
        sso   <- fmap (DM.lookup k) $ readMVar ch
        let got = DM.lookup k known
        let np  = (not $ null got) && eqWithScheme (head got) p s
        if (null sso) && np  then do
            hPutStrLn hdl "{\"facility\":\"proceed\"}"
            modifyMVar_ ch (return . DM.insert k hdl)
            forkIO $ getAndMail hdl k ch inb outb
            else badDetails hdl k "Check keyword, password or scheme"
    _ -> hPutStrLn hdl $ "{\"facility\":\"error\", \"params\":{\"message\":"
        ++ "\"keyword, password, and scheme, please\"}}"

--  Authentication will only later include cryptography and multiple phases.
eqWithScheme :: String -> String -> String -> Bool
eqWithScheme pwd1 pwd2 "pwd" = pwd1 == pwd2
eqWithScheme _ _ _           = False

badDetails :: Handle -> String -> String -> IO ()
badDetails hdl key err = do
    hPutStrLn hdl $ "{\"facility\":\"error\", \"params\":{\"message\":" ++
        show err ++ "}}\n{\"facility\":\"finalise\"}"
    hFlush hdl
    hJustClose hdl 

getAndMail :: Handle -> String -> NH -> Inbox -> Outbox -> IO ()
getAndMail hdl nom ch inb outb = do
    str <- getSMSJSON nom ch hdl
    case readOutboundSMS str of
        No x -> do
            hPutStrLn hdl $ "{\"facility\":\"error\", \"params\":" ++
                    "{\"message\":" ++ (show x) ++ "}}"
        Yes x -> do
            sendMsg outb x
            hPutStrLn hdl "{\"facility\":\"proceed\"}"
    getAndMail hdl nom ch inb outb
    where
        getSMSJSON :: String -> NH -> Handle -> IO JSONValue
        getSMSJSON nom ch hdl = do
            l <- hReadLine hdl
            case toJSON l of
                Yes j -> case "/facility" @@ j of
                    Just (JStr x) -> do
                        case x of
                            "logout" -> do
                                hJustClose hdl
                                modifyMVar_ ch (return . DM.delete nom)
                                (killThread =<< myThreadId) >> undefined
                            "send"  -> case "/params" @@ j of
                                Yes s -> return s
                                No  e -> do
                                    hPutStrLn hdl $
                                        "{\"facility\":\"error\", \"params\"" ++
                                            ":{\"message\":" ++ show e ++ "}}"
                                    getSMSJSON nom ch hdl
                            "proxy" -> {- TODO -} getSMSJSON nom ch hdl
                            _       -> do
                                    hPutStrLn hdl $
                                        "{\"facility\":\"error\", \"params\"" ++
                                            ":{\"message\":\"Unknown " ++
                                            "facility `" ++ x ++ "'\"}}"
                                    getSMSJSON nom ch hdl
                    _             -> do
                        hPutStrLn hdl $ "{\"facility\":\"error\"," ++
                            "\"params\":{\"message\":\"No facility?\"}}"
                        getSMSJSON nom ch hdl
                No e  -> do
                    if null l then return () else hPutStrLn hdl $
                        "{\"facility\":\"error\", \"params\":{\"message\":" ++
                            show e ++ "}}"
                    getSMSJSON nom ch hdl

postmanPat :: Handle -> Inbox -> Outbox -> Conf -> Handle -> IO ()
postmanPat tx outb conf ads = do
    got <- readChan outb
    let msg = fst got
    our <- pickSetField num conf
    exm <- pickSetField exempt conf
    ad  <- if (snd got) `elem` exm then return ""
        else do
            hPutStrLn ads $ "{\"facility\":\"advert\", \"params\":{\"text\":" ++
                (show $ omsg msg) ++ "}}"
            resp <- fmap toJSON $ hGetLine ads
            case resp of
                Yes js -> case "/params/ad" @@ js of
                    Yes (JStr x) -> return $
                            if null x then "" else "\n[advert: " ++ x ++ "]"
                    _            -> return ""
                _      -> return ""
    logThis $ (show $ ofrom msg) ++ " sends to " ++ (show $ unwords $ oto msg)
        ++ ": " ++ (show $ omsg msg)
    them <- sequence $ [(\y -> return $ PDU (makeHeader Submit y) x) =<<
        (getNextMonotonic mon) | x <- smsToTransmission our msg ad]
    mapM_ (hPutStr tx . dump) them
    postmanPat tx outb mon conf ads

--  TODO: Throw message into DB.
distributeMessages :: Chan InboundSMS -> NH -> KywdMem -> IO ()
distributeMessages inbox conns kwm = do
    msg  <- readChan inbox
    let for = meantFor msg
    let fro = ifrom msg
    withMVar conns $ \m -> case DM.lookup for m of
        Nothing -> do
            withMVar kwm $ \k -> case DM.lookup fro k of
                Nothing -> logThis $ "Message for module " ++ show for ++
                    " undelivered"
                Just gt -> case DM.lookup gt m of
                    Nothing -> logThis "This shouldn't happen. Ever."
                    Just hd -> deliverMe hd (SMSI fro (ito msg) 
                        (gt ++ " " ++ imsg msg)) kwm
        Just h  -> deliverMe h msg kwm
    distributeMessages inbox conns kwm where

        deliverMe :: TSH -> InboundSMS -> KywdMem -> IO ()
        deliverMe hdl sms kwd = do
            let pr = "{\"facility\":\"process\", \"params\":" ++
                    (show sms) ++ "}"
            hPutStrLn hdl pr
            modifyMVar_ kwd $ \m ->
                return $ DM.insert (ifrom sms) (meantFor sms) m
