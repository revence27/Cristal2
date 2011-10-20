module Client where

import Control.Concurrent
import Data.Bits
import Data.Char
import qualified Data.List as DL
import qualified Data.Map as DM
import MMSClient
import Network
import Network.HTTP
import Network.URI
import PDUs
import System.IO
import System.Time

data Enum a => Auth a = Auth {username, password, stype :: String,
                              numtype, numplan :: a, addrange,
                              mmsUsername, mmsPassword :: String,
                              mmsURL :: URI}

newtype StdGen = StdGen Int

instance MonGen StdGen where
    next (StdGen x) = (x, StdGen (x + 1))

toSysMsg :: InMsg -> [String] -> InMsg
toSysMsg (InMsg f t m _) em = SysMsg f t m Nothing em []
toSysMsg (Report f t m _) em = toSysMsg (InMsg f t m DM.empty) em
toSysMsg (SysMsg f t m l k md) _ = SysMsg f t m l k md
toSysMsg (InMMS f t m l md) em  = SysMsg f t m (Just l) em md
toSysMsg (ReportMMS f t m _) em = toSysMsg (InMsg f t m DM.empty) em
toSysMsg (InUSSD f t m srv ses sq ed _) em = toSysMsg (InMsg f t m DM.empty) em

receiveMsg :: Inbox -> (InMsg -> IO ()) -> IO ()
receiveMsg i@(Inbox ch) hdlr = do
    got <- readChan ch
    forkIO $ do
        hdlr got
        killThread =<< myThreadId
    receiveMsg i hdlr

destinataire :: InMsg -> String
destinataire (InMsg _ _ m _)      = map toLower (head ((words m) ++ [""]))
destinataire (Report t f m _)     = destinataire (InMsg t f m DM.empty)
destinataire (SysMsg t f m _ _ _) = destinataire (InMsg t f m DM.empty)
destinataire (InMMS t f m l md)   = destinataire (InMsg t f m DM.empty)
destinataire (ReportMMS t f m _)  = destinataire (InMsg t f m DM.empty)
destinataire (InUSSD f t m _ _ _ _ _) = destinataire (InMsg f t m DM.empty)

sendMsg :: Outbox -> OutMsg -> IO ()
sendMsg (Outbox ch) = writeChan ch

authenticate :: Enum a => Handle -> Auth a -> DieSig -> (DieSig -> Inbox ->
    Outbox -> IO ()) -> IO ()
authenticate hdl (Auth usn pwd stp nt np adr husn hpwd hurl) die user = do
    inb  <- newChan >>= (return . Inbox)
    outb <- newChan >>= (return . Outbox)
    chn  <- newChan
    sc   <- forkIO $ do
        scribe hdl (StdGen 0) chn
        killThread =<< myThreadId
    let attempt = do
        bindTRX chn usn pwd stp nt np adr
        br <- bindTRXResp hdl
        case br of
            Nothing -> fail "Authentication failed."
            Just x  -> return x
    x  <- attempt `catch` (\_ -> fail "TRX authentication failed.")
    dv <- forkIO $ do
        post chn outb husn hpwd hurl
        killThread =<< myThreadId
    io <- forkIO $ do
        user die inb outb
        killThread =<< myThreadId
    pm <- forkIO ((postMan hdl die chn inb (DM.empty :: TransPcs))
        `catch` (\_ -> writeSampleVar die ()))
    mc <- forkIO $ receiveMMS 8765 inb
    let fin = do
        killThread mc
        killThread pm
        killThread io
        killThread sc
        killThread dv
        unbindTRX chn
        unbindTRXResp hdl
    (readSampleVar die >> fin) `catch` (\_ -> return ())

postMan :: Handle -> SampleVar () -> Chan Payload -> Inbox -> TransPcs -> IO ()
postMan hdl die chn i@(Inbox chi) ps = do
    got <- (withPDU hdl $ \x -> do
        let n4 = take 4 x
        let sq = take 4 $ drop 8 x
        (if "\x00\x00\x00\x15" == n4 then do
            sendPDU chn (WithSeq ("\x80\x00\x00\x15\x00\x00\x00\x00" ++ sq))
            return ps
            else (if "\x00\x00\x00\x05" == n4 then do
                sendPDU chn
                    (WithSeq ("\x80\x00\x00\x05\x00\x00\x00\x00" ++ sq))
                intoInbox ps (drop 12 x) i
                else return ps))) `catch` (\_ -> fail "Can't read PDU in!")
    postMan hdl die chn i =<< got

scribe :: MonGen mg => Handle -> mg -> Chan Payload -> IO ()
scribe hdl sq chn = do
    got <- readChan chn
    let (ans, n) = case got of {
        WithSeq g -> (withLen g, sq);
        NoSeq   g -> let ((h, t), (c, n)) = (br8k g, next sq) in
            (withLen (h ++ (packBigEndian c) ++ t), n)}
    hPutStr hdl ans
    hFlush hdl
    putStrLn ("C->S: " ++ show ans)
    scribe hdl n chn
    where
        br8k :: String -> (String, String)
        br8k str = (take 8 str, drop 8 str)

destURLInfo :: Monad m => OutMsg -> m (URI, String, String)
destURLInfo (OutMsg  fr t m _ _)         = turnToTriple t fr m
destURLInfo (OutUSSD fr t m _ _ _ _ _ _) = turnToTriple [t] fr m
destURLInfo (OutMMS  fr t m _ _)         = turnToTriple t fr m

turnToTriple :: Monad m => [String] -> String -> String -> m (URI, String, String)
turnToTriple []  f m = fail "No destination?"
turnToTriple [t] f m = case parseAbsoluteURI t of
    Just u -> return (u, f, m)
    _      -> fail "No absolute URI receiving message."
turnToTriple (t:_) f m = turnToTriple [t] f m

post :: Chan Payload -> Outbox -> String -> String -> URI -> IO ()
post chn o@(Outbox c) husn hpwd hurl = do
    readChan c >>= (\m -> case destURLInfo m of
        Just (u, de, msg) -> do
            let that = ("message=" ++ (escapeURIString isAllowedInURI msg))
            simpleHTTP (Request u POST
                [Header HdrReferer de,
                 Header HdrContentLength (show (length that)),
                 Header HdrContentType "application/x-www-form-urlencoded"]
                that)
            return ()
        _                 -> sendAll chn m husn hpwd hurl)
    post chn o husn hpwd hurl
    where
        sendAll :: Chan Payload -> OutMsg -> String -> String -> URI -> IO ()
        sendAll chn o@(OutMsg fr t ms wh tlv) h1 h2 h3 = do
            if longerThan 255 ms then
                sendAll chn (OutMsg fr t "" wh
                    (DM.insert 0x0424 ms tlv)) h1 h2 h3
                else mapM_ (sendPDU chn) [NoSeq 
                    ("\x00\x00\x00\x04\x00\x00\x00\x00\x00\x02\x01" ++
                    (cstr (take 20 fr)) ++ "\x02\x01" ++ (cstr (take 20 z)) ++
                        "\x03\x00\x03" ++ (when4PDU wh) ++
                            "\x00\x00\x00\x00\x00" ++ [chr (length ms)] ++
                                ms ++ (DM.foldWithKey (\k v p ->
                                    (keep2 k) ++ (keep2 (length v)) ++ v ++
                                        p) "" tlv)) | z <- t]
        sendAll chn o@(OutUSSD fr t ms wh tlv srv ses sqn ends) h1 h2 h3 = do
            let stf  = [ses, ((254 .&. (sqn `shiftL` 1)) .&. (fromEnum ends))]
            let tl'v = DM.insert 0x0501 [chr $ fromEnum srv] tlv
            let str' = [chr (255 .&. z) | z <- stf]
            let tlv' = DM.insert 0x1383 str' tl'v
            sendAll chn (OutMsg fr [t] ms wh tlv') h1 h2 h3
        sendAll _ (OutMMS fr t ms lk wh) husn hpwd hurl = do
            got <- sendMMS (fr, t, ms, lk, wh) (husn, hpwd) hurl
            case got of
                Left (MMSError h d) -> putStrLn (h ++ ": " ++ d)
                Right str           -> putStrLn str

        pieces :: String -> [String]
        pieces str =
            let (one, more) = breakAt 255 str in
                one:(if null more then [] else pieces more)

when4PDU :: Maybe CalendarTime -> String
when4PDU Nothing = "\x00"
when4PDU (Just (CalendarTime y m d h m' s _ _ _ _ t _)) =
    let qs = abs (t `div` 900) in
    let mp = [if qs < 0 then '-' else '+'] in
    (e2 $ show y) ++ (e2 $ show $ (1 + (fromEnum m))) ++ (e2 $ show d)
        ++ (e2 $ show h) ++ (e2 $ show m') ++ (e2 $ show s) ++ "\x00"
            ++ (e2 $ show qs) ++ mp
    where
        e2 :: String -> String
        e2 str = reverse $ take 2 $ ((reverse str) ++ "\x00\x00")

longerThan :: Integer -> [a] -> Bool
longerThan 0 []     = False
longerThan 0 _      = True
longerThan n []     = False
longerThan n (_:xs) = longerThan (n - 1) xs

intoInbox :: TransPcs -> String -> Inbox -> IO TransPcs
intoInbox pcs str (Inbox chn) = do
    let src' = drop 2 $ d0 str
    let src  = t0 src'
    let dst' = drop 2 $ d0 src'
    let dst  = t0 dst'
    let del  = esmClass $ d0 dst'
    case pullMsg pcs del $ drop 3 $ d0 dst' of
        Right (pcs2, msg, tlv) -> (writeChan chn (case del of
            DeliveryReport -> 
                (Report {rto = dst, rfrom = src, rmsg = msg, ref = 0})
            _              -> case DM.lookup 0x0501 tlv of
                    Just x  -> let sv = toEnum (ord (head (x ++ "\0"))) in
                        case DM.lookup 0x1383 tlv of
                            Just x' -> let (ses, sqn, nds) = peelTriple x' in
                                InUSSD {uto = dst, ufrom = src, umsg = msg,
                                    userv = sv, usess = ses, seqNum = sqn,
                                        endSess = nds, utlvs = tlv}
                            Nothing -> InUSSD {uto = dst, ufrom = src,
                                umsg = msg, userv = sv, usess = 0, seqNum = 0,
                                    endSess = True, utlvs = tlv}
                    Nothing -> InMsg {ito = dst, ifrom = src, imsg =
                        case DM.lookup 0x0424 tlv of
                            Nothing -> msg
                            Just m' -> m', itlvs = tlv})) >> return pcs2
        Left pcs'              -> return pcs'
    where
        peelTriple :: String -> (Int, Int, Bool)
        peelTriple [x, y] = let y' = ord y in
            (ord x, 254 .&. (y' `shiftR` 1), toEnum (1 .&. y'))
        peelTriple _      = (0, 0, False)
        
        pullMsg :: TransPcs -> ESMClass -> String ->
            Either TransPcs (TransPcs, String, DM.Map Int String)
        pullMsg pcs PieceMeal str =
            case pullMsg pcs OtherESM str of
                Left  em          -> Left em
                Right (_, m, tvs) -> case m of
                    (f':m') -> let (hds, rst)  = breakAt (ord f') m' in
                        case hds of
                            [hi, lo, mid, tot, pos] ->
                                case orderedInsert (ord tot) (ord pos) mid rst
                                    pcs of
                                    Left  np  -> Left np
                                    Right fin -> Right (DM.delete mid pcs,
                                        concat fin, tvs)
                            _                       -> Right (pcs, rst, tvs)
        pullMsg pcs _ str = case drop 4 $ d0 $ d0 str of
            []     -> Right (pcs, "", DM.empty)
            (x:xs) -> let (msg, tlv) = breakAt (ord x) xs in
                Right (pcs, msg, tlvsToMap tlv)

        orderedInsert :: Int -> Int -> Char -> String -> TransPcs ->
            Either TransPcs [String]
        orderedInsert tot pos mid met pcs = case DM.lookup mid pcs of
            Nothing       -> orderedInsert tot pos mid met
                (DM.insert mid (0, (take tot $ repeat met)) pcs)
            Just (sf, em) -> let rez = insertAt (pos - 1) em met in
                let sf' = sf + 1 in if sf' == tot then Right rez else
                    Left (DM.insert mid (sf', rez) pcs)

        insertAt :: Int -> [a] -> a -> [a]
        insertAt 0 (_:xs) met = met:xs
        insertAt n (x:xs) met = x:(insertAt (n - 1) xs met)
        insertAt _ []     met = [met]

        d0, t0 :: String -> String
        d0 = (drop 1) . (dropWhile (/= '\x00'))
        t0 = takeWhile (/= '\x00')

        esmClass :: String -> ESMClass
        esmClass []    = OtherESM
        esmClass (x:_) = case (ord x) of
            16 -> DeliveryReport
            64 -> PieceMeal
            _  -> OtherESM

        getLen :: String -> Int
        getLen []    = 0
        getLen (x:_) = ord x
