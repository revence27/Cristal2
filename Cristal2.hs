module Main where

import Client
import Conf
import Control.Concurrent
import Control.Exception as Except
import Data.Char
import qualified Data.List as DL
import qualified Data.Map as DM
import Data.Maybe (isJust, isNothing, fromJust)
import JSON
import Network
import Network.BSD (getHostName)
import Network.URI
import PDUs
import System.Cmd
import System.Exit
import System.IO
import System.Process
import System.Time
import Util

type Boxen = MVar (DM.Map String Inbox)
type F5Sig = SampleVar ()
type TLVs  = DM.Map Int String

data PPReq = PPReq Outbox [String] String (Either String String) (Chan String)
                   String (Maybe String) (Maybe CalendarTime) TLVs

data CristalConf = CC String Int String String String String URI Int Int Int
                        String Int String String

type PPChan = Chan PPReq
type SmallConf = (Socket, Socket, String, String)
type EithDat = Either ([String], String, String) ([String], String, String, Maybe String)

main :: IO ()
main = withSocketsDo $ do
    (CC hst prt usn pwd hus hpw hur cnp src ppt sht modp frs ini) <- confFrom stdin
    let auth = Auth usn pwd "smpp" 0 0 "" hus hpw hur
    die <- newEmptySampleVar
    csk <- listenOn $ PortNumber $ toEnum cnp
    let dft = Settings DM.empty DM.empty DM.empty
    mod' <- listenOn (PortNumber (toEnum modp))
    src' <- listenOn (PortNumber (toEnum src))
    ppt' <- listenOn (PortNumber (toEnum ppt))
    hn   <- getHostName
    xt   <- rawSystem ini
        [hn, show modp, show sht, show src, show ppt, show cnp]
    hdl <- connectTo hst (PortNumber $ toEnum prt)
    hSetBuffering hdl NoBuffering
    case xt of
        ExitSuccess -> do
            withConf dft csk (\cnf -> do
                got <- authenticate hdl auth die
                    (consProd (src', ppt', sht, frs) mod' cnf)
                closeThem =<< (activeMods cnf)
                return got)
        ExitFailure x -> hPutStrLn stderr (ini ++ ": Failed with " ++ (show x))
    putStrLn "Closing."
    sClose csk
    sClose mod'
    sClose src'
    sClose ppt'
    hClose hdl

confFrom :: Handle -> IO CristalConf
confFrom hdl = do
    got <- fmap toJSON (hGetContents hdl)
    case got of
        Yes x -> drawConf x
        No  y -> fail y
    
drawConf :: Monad m => JSONValue -> m CristalConf
drawConf got = case "/smsc/host" @@ got of
    Just (JStr hst) -> case "/smsc/port" @@ got of
        Just (JNum prt) -> case "/smsc/username" @@ got of
            Just (JStr usn) -> case "/smsc/password" @@ got of
                Just (JStr pwd) -> case "/mmsc/username" @@ got of
                    Just (JStr hus) -> case "/mmsc/password" @@ got of
                        Just (JStr hpw) -> case "/mmsc/url" @@ got of
                            Just (JStr h') -> do
                                case parseAbsoluteURI h' of
                                    Just hur -> do
                                        (cnp, src, prp, num, modp) <- modDat got
                                        frs <- friskCommand got
                                        ini <- initCommand got
                                        return (CC hst prt usn pwd hus hpw hur
                                            cnp src prp num modp frs ini)
                                    _        -> fail "Bad URL in /mmsc/url"
                        _               -> fail "/mmsc/password?"
                    _               -> fail "/mmsc/username?"
                _               -> fail "/smsc/password?"
            _               -> fail "/smsc/username?"
        _               -> fail "/smsc/port?"
    _               -> fail "/smsc/host?"

modDat :: Monad m => JSONValue -> m (Int, Int, Int, String, Int)
modDat doc = case "/modules/confport" @@ doc of
    Just (JNum cnf) -> case "/modules/re-entrance" @@ doc of
        Just (JNum ret) -> case "/modules/preprocessor" @@ doc of
            Just (JNum prp) -> case "/modules/shortcode" @@ doc of
                Just (JStr sht) -> case "/modules/port" @@ doc of
                    Just (JNum modp) -> return (cnf, ret, prp, sht, modp)
                    _                -> fail "/modules/port?"
                _               -> fail "/modules/shortcode?"
            _               -> fail "/modules/preprocessor?"
        _               -> fail "/modules/rentrance?"
    _               -> fail "/modules/conf?"

initCommand :: Monad m => JSONValue -> m String
initCommand doc = case "/modules/ignition" @@ doc of
    Just (JStr x) -> return x
    _             -> fail "/modules/ignition?"

friskCommand :: Monad m => JSONValue -> m String
friskCommand doc = case "/modules/sentry" @@ doc of
    Just (JStr x) -> return x
    _             -> fail "/modules/sentry?"

closeThem :: DM.Map String Handle -> IO ()
closeThem t = do
    sequence_ [hPutStrLn k "{\"facility\":\"finalise\"}" | k <- DM.elems t]

consProd :: SmallConf -> Socket -> Conf -> DieSig -> Inbox -> Outbox -> IO ()
consProd c@(src, prt, num', frs') sck cnf die inb outb = withSocketsDo $ do
    (outh, inh, _, pid) <- runInteractiveCommand frs'
    hSetBuffering outh LineBuffering
    bxn <- newMVar DM.empty
    f5  <- newEmptySampleVar
    pp1 <- newChan
    pp2 <- newChan
    ppt <- forkIO $ preprocessor pp1 pp2 prt
    fnu <- forkIO $ finishSending pp2
    dst <- forkIO $ do
        distributeThem inb bxn cnf outh inh
        killThread =<< myThreadId
    rec <- forkIO $ do
        reentrance src inb
        killThread =<< myThreadId
    mm  <- forkIO $ do
        manageModules sck cnf bxn outb f5 pp1 c
        killThread =<< myThreadId
    readSampleVar die
    killThread ppt
    killThread mm
    killThread dst
    killThread rec
    killThread fnu
    terminateProcess pid

preprocessor :: PPChan -> PPChan -> Socket -> IO ()
preprocessor pp1 pp2 sck = do
    t1 <- forkIO $ do
        returnToSender pp1 pp2
        killThread =<< myThreadId
    (hdl, _, _) <- accept sck
    hSetBuffering hdl LineBuffering
    killThread t1
    runPreproc pp1 pp2 hdl `Except.catch` ((\_ -> return ()) :: IOError -> IO ())
    hClose hdl
    preprocessor pp1 pp2 sck

returnToSender :: PPChan -> PPChan -> IO ()
returnToSender pp1 pp2 = do
    writeChan pp2 =<< readChan pp1
    returnToSender pp1 pp2

runPreproc :: PPChan -> PPChan -> Handle -> IO ()
runPreproc pp1 pp2 hdl = do
    i@(PPReq o t f m c k l w tv) <- readChan pp1
    m' <- hPutStrLn hdl (ppJS t f m k tv) >> hGetLine hdl
    writeChan pp2 (case toJSON m' of
        No  _ -> i
        Yes x -> case ("/params/to" @@ x, "/params/from" @@ x) of
                    (Just (JArr to), Just (JStr fro)) ->
                        case "/params/message" @@ x of
                            Just (JStr msg) ->
                                PPReq o (tos to) fro (Left msg) c k Nothing w
                                    tv
                            _               ->
                                case ("/params/smil" @@ x,
                                      "/params/linkid" @@ x) of
                                (Just (JStr sml), Just v) ->
                                    PPReq o (tos to) fro (Right sml) c k
                                        (case v of
                                            JStr lk -> Just lk
                                            JNum nm -> Just (show nm)
                                            _       -> Nothing) w tv
                                _               -> i
                    _                                 -> i)
    runPreproc pp1 pp2 hdl
    where
        tos :: [JSONValue] -> [String]
        tos = foldr (\x y -> case x of
            JStr z -> z:y
            JNum n -> (show n):y
            _      -> y) []

        ppJS :: [String] -> String -> (Either String String) -> String ->
            DM.Map Int String -> String
        ppJS t f m k tv = show (JObj (DM.fromList
            [("facility", JStr "preprocess"), ("params", JObj (DM.fromList [
                ("to", JArr [JStr x | x <- t]),
                ("from", JStr f), (case m of
                    Left  ms -> ("message", JStr ms)
                    Right ms -> ("smil", JStr ms)),
                ("keyword", JStr k),
                ("tlvs", JObj (DM.foldWithKey (\cle v p ->
                    DM.insert (show cle) (JStr v) p) DM.empty tv))]))]))

finishSending :: PPChan -> IO ()
finishSending pp2 = do
    PPReq o t f m c k l w tv <- readChan pp2
    treatMsg o t f m l w tv
    --  writeChan c "{\"facility\":\"proceed\"}"
    --  Confirmation seems like a bad idea, in theory and in practice!
    finishSending pp2

reentrance :: Socket -> Inbox -> IO ()
reentrance sck i@(Inbox inb) = do
    (hdl, _, _) <- accept sck
    hSetBuffering hdl LineBuffering
    forkIO $ do
        perpetua hdl i `Except.catch` ((\_ -> return ()) :: IOError -> IO ())
        hClose hdl
        killThread =<< myThreadId
    reentrance sck i
    where
        perpetua :: Handle -> Inbox -> IO ()
        perpetua hdl i@(Inbox inb) = do
            got <- pullInMsg hdl
            case got of
                Just x -> writeChan inb x
                _      -> return ()
            perpetua hdl i

pullInMsg :: Monad m => Handle -> IO (m InMsg)
pullInMsg hdl = do
    got <- fmap toJSON (hGetLine hdl)
    return (case got of
        Yes js -> case (     "/params/to" @@ js,
                            "/params/from" @@ js,
                         "/params/message" @@ js) of
            (Just (JStr t), Just (JStr f), Just (JStr m)) ->
            	return (InMsg f t m (fetchTLVs js))
            _                        ->
                fail "to? from? message?"
        No y   -> fail y)

findKwdDest :: Conf -> String -> IO String
findKwdDest cnf str = do
    akas <- kwdAliases cnf
    return $ case DM.lookup str akas of
        Just x -> x
        _      -> str

allKeywords :: DM.Map String a -> Conf -> IO [String]
allKeywords mp1 cnf = do
    akas <- fmap DM.keys (kwdAliases cnf)
    return ((DM.keys mp1) ++ akas)

distributeThem :: Inbox -> Boxen -> Conf -> Handle -> Handle -> IO ()
distributeThem inb bxn cnf outh inh = do
    receiveMsg inb $ \msp -> withMVar bxn $ \mp -> do
        sm  <- fmap (toSysMsg msp) (allKeywords mp cnf)
        msg <- friskMessage msp outh inh `Except.catch` ((\_ -> return msp) :: IOError -> IO InMsg)
        kw  <- findKwdDest cnf $ destinataire msg
        case DM.lookup kw mp of
            Just (Inbox x) -> writeChan x msg
            _              -> case DM.lookup "keyword_missing" mp of
                Just (Inbox x) -> writeChan x sm
                _              -> return ()
        case DM.lookup "always_gets" mp of
            Just (Inbox x) -> writeChan x sm
            _              -> return ()
    distributeThem inb bxn cnf outh inh

friskMessage :: InMsg -> Handle -> Handle -> IO InMsg
friskMessage x@(InMsg fr to msg tv)   outh inh = do
    hPutStrLn outh (show (JObj (DM.fromList [("facility", JStr "process"),
            ("params", JObj (DM.fromList [("to", JStr to),
                        ("from", JStr fr), ("message", JStr msg),
                        ("tlvs", JObj (DM.foldWithKey (\cle v p ->
                    DM.insert (show cle) (JStr v) p) DM.empty tv))]))])))
    got <- pullInMsg inh
    return $ case got of
        Just y -> y
        _      -> x
friskMessage x@(InMMS {})     _ _ = do
    hPutStrLn stderr "Not frisking MMS messages. Skipping ..."
    return x
friskMessage x@(Report {})    _ _ = return x
friskMessage x@(SysMsg {})    _ _ = return x
friskMessage x@(ReportMMS {}) _ _ = return x
friskMessage x@(InUSSD {})    _ _ = return x

manageModules :: Socket -> Conf -> Boxen -> Outbox -> F5Sig -> PPChan -> SmallConf -> IO ()
manageModules sck cnf bxn outb f5 pp1 c@(src, prt, num, frs) = do
    (mod, _, _) <- accept sck
    hSetBuffering mod LineBuffering
    yes <- (authMod mod cnf) `Except.catch`
                ((\_ -> return (fail "Authentication failed.")) :: Monad m => IOError -> IO (m String))
    case yes of
        Yes k -> do
            inb <- fmap Inbox newChan
            modifyMVar_ bxn $ \mp -> do
                hPutStrLn mod ("{\"facility\":\"proceed\", \"params\":{" ++
                               "\"shortcode\":" ++ (show num) ++ ", " ++
                               "\"reentrance\":" ++ (show src) ++ "}}")
                newActive cnf k mod
                writeSampleVar f5 ()
                return (DM.insert k inb mp)
            forkIO $ do
                (runMsgs mod k cnf inb outb pp1) `Except.catch` ((\_ -> return ()) :: IOError -> IO ())
                notActive cnf k
                modifyMVar_ bxn (return . (DM.delete k))
                putStrLn (k ++ " disconnected.")
                hClose mod
                killThread =<< myThreadId
            putStrLn (k ++ " connected.")
        No x  -> do
            hPutStrLn mod ("{\"facility\":\"error\", \"params\":{\"message\":"
                ++ (show x) ++ "}}")
            hClose mod
    manageModules sck cnf bxn outb f5 pp1 c

runMsgs :: Handle -> String -> Conf -> Inbox -> Outbox -> PPChan -> IO ()
runMsgs hdl nom cnf inb outb pp1 = do
    die <- newEmptySampleVar
    ch  <- newChan
    ecr <- forkIO $ ecrivain hdl ch
    wrt <- forkIO $ modWriter ch inb
    rdr <- forkIO $ do
        (modReader hdl ch nom cnf outb die pp1)
            `Except.catch` ((\_ -> return ()) :: IOError -> IO ())
        writeSampleVar die ()
        killThread wrt
        killThread =<< myThreadId
    readSampleVar die
    killThread ecr
    killThread rdr

ecrivain :: Handle -> Chan String -> IO ()
ecrivain hdl ch = do
    hPutStrLn hdl =<< readChan ch
    ecrivain hdl ch

modWriter :: Chan String -> Inbox -> IO ()
modWriter ch inb = do
    let re = receiveMsg inb $ \x -> do
        writeChan ch $ case x of
            InMsg f t m tl -> "{\"facility\":\"process\", \"params\":" ++ 
                "{\"from\":" ++ (show f) ++ ", \"to\":" ++ (show t) ++ 
                ", \"message\":" ++ (show m) ++ ", \"tlvs\":" ++ (tlvsToJS tl)
                ++ "}}"
            Report f t m r ->  "{\"facility\":\"report\", \"params\":" ++ 
                "{\"from\":" ++ (show f) ++ ", \"to\":" ++ (show t) ++ 
                ", \"message\":" ++ (show m) ++ ", \"ref\":" ++
                (show r) ++ "}}"
            SysMsg f t m lk l md -> "{\"facility\":\"process\", \"params\":" ++ 
                "{\"from\":" ++ (show f) ++ ", \"to\":" ++ (show t) ++ 
                ", \"message\":" ++ (show m) ++ ", \"keywords\":" ++
                (show l) ++ ", \"linkid\":" ++ (showLk lk) ++ ", \"media\":" ++
                (showMedia md) ++ "}}"
            InMMS f t m l md -> "{\"facility\":\"process\", \"params\":" ++
                "{\"from\":" ++ (show f) ++ ", \"to\":" ++ (show t) ++
                ", \"message\":" ++ (show m) ++ ", \"media\":" ++
                (showMedia md) ++ ", \"linkid\":" ++ (show l) ++ "}}"
            ReportMMS f t m r ->  "{\"facility\":\"report\", \"params\":" ++ 
                "{\"from\":" ++ (show f) ++ ", \"to\":" ++ (show t) ++ 
                ", \"message\":" ++ (show m) ++ ", \"msgid\":" ++
                (show r) ++ "}}"
            InUSSD f t m sv ses sqn ends tv -> "{\"facility\":\"ussd\", " ++
                "\"params\":{\"to\":" ++ (show t) ++ ", \"from\":" ++ (show m)
                ++ ", \"message\":" ++ (show m) ++ ", \"ussd_service_op\":" ++
                (show sv) ++ ", \"session\":" ++ (show ses) ++ ", \"seqence\":"
                ++ (show sqn) ++ ", \"end\":" ++ (show (JBool ends)) ++
                ", \"tlvs\":" ++ (tlvsToJS tv) ++ "}}"
    re `Except.catch` ((\_ -> return ()) :: IOError -> IO ())
    where
        showMedia :: [MMSFile] -> String
        showMedia them = show (map (\(MMSFile m s) -> "{\"mimetype\":" ++
            (show m) ++ ", \"sha1\":" ++ (show s) ++ "}") them)

        showLk :: Maybe String -> String
        showLk (Just x) = show x
        showLk _        = "null"

        tlvsToJS :: DM.Map Int String -> String
        tlvsToJS tlvs = show (DM.foldWithKey (\k v p ->
            ("{" ++ (show (show k)) ++ ":" ++ (show v) ++ "}"):p) [] tlvs)

modReader :: Handle -> Chan String -> String -> Conf -> Outbox -> DieSig -> PPChan -> IO ()
modReader hdl ch nom cnf outb die pp1 = do
    msg <- hGetLine hdl
    case toJSON msg of
        No x  -> writeChan ch (tellErr x)
        Yes x -> case "/facility" @@ x of
            (Just (JStr y)) -> case y of
                "logout" -> writeSampleVar die ()
                "send"   -> do
                    let tv = fetchTLVs x
                    case "/params" @@ x of
                        No g  -> writeChan ch (tellErr g)
                        Yes (JObj g) -> case fetchIt g of
                            No h -> writeChan ch (tellErr h)
                            Yes yc -> case "/params/when" @@ x of
                                Just (JObj wh) -> case fetchDate wh of
                                    No h 	-> writeChan ch (tellErr h)
                                    Yes wdt ->
                                        procSuccess cnf nom outb yc pp1 ch
                                            (Just wdt) tv
                                _ -> procSuccess cnf nom outb yc pp1 ch
                                        Nothing tv
                        _ -> writeChan ch (tellErr
                            "Params must be an object.")
                    modReader hdl ch nom cnf outb die pp1
                _        -> do
                    writeChan ch (tellErr "Unknown facility")
                    modReader hdl ch nom cnf outb die pp1
            _               -> do
                writeChan ch (tellErr "No facility field")
                modReader hdl ch nom cnf outb die pp1

fetchTLVs :: JSONValue -> DM.Map Int String
fetchTLVs js = case "/params/tlvs" @@ js of
    Just (JArr mp) -> foldr (\x p -> case ("/tag" @@ x, "/value" @@ x) of
        (Just (JStr tag), Just (JStr vl)) -> case getInt tag of
            Just tni -> DM.insert tni vl p
            _        -> p
        _                                 -> p) DM.empty mp
    _              -> DM.empty

procSuccess :: Conf -> String -> Outbox -> EithDat -> PPChan -> Chan String ->
    Maybe CalendarTime -> TLVs -> IO ()
procSuccess cnf nom outb (Left (i, j, k)) pp1 ch wh tv =
    passItOn cnf nom outb i j (Left k) Nothing pp1 ch wh tv
procSuccess cnf nom outb (Right (i, j, k, l)) pp1 ch wh tv =
    passItOn cnf nom outb i j (Right k) l pp1 ch wh tv

fetchIt :: Monad m => DM.Map String JSONValue ->
    m (Either ([String], String, String)
              ([String], String, String, Maybe String))
fetchIt mp = case (DM.lookup "to" mp, DM.lookup "from" mp) of
    (Just (JArr to), Just (JStr fro)) -> do
        got <- testNums to
        case DM.lookup "message" mp of
            Just (JStr msg) -> return (Left (got, fro, msg))
            _               -> case (DM.lookup "smil" mp,
                                     DM.lookup "linkid" mp) of
                (Just (JStr sml), Just vl) ->
                    return (Right (got, fro, sml, case vl of
                        JStr lks -> Just lks
                        JNum nm  -> Just (show nm)
                        _        -> Nothing))
                _               -> fail "You must have one of SMIL (with linkid, which can be null) and message."
    _   -> fail ("Bad format for send facility. (Use to (list), from, " ++
                "message/smil.)")

fetchDate :: Monad m => DM.Map String JSONValue -> m CalendarTime
fetchDate d = case DM.lookup "year" d of
    Just (JNum year) -> case DM.lookup "month" d of
        Just (JNum month) -> case DM.lookup "day" d of
            Just (JNum day) -> case DM.lookup "hour" d of
                Just (JNum hour) -> case DM.lookup "minute" d of
                    Just (JNum min) -> if month > 11 || month < 0 then
                            fail "bad month" else return $ 
                                CalendarTime year (toEnum month) day
                                    hour min 0 0 (toEnum 0) 0 "" 0 False
                    _  -> fail "minute?"
                Nothing   -> fail "hour?"
            Nothing  -> fail "day?"
        Nothing    -> fail "month?"
    Nothing -> fail "year?"

testNums :: Monad m => [JSONValue] -> m [String]
testNums = mapM (\x -> case x of
    JStr y -> return y
    _      -> fail "Only JSON strings in 'to' field.")

passItOn :: Conf -> String -> Outbox -> [String] -> String ->
    Either String String -> Maybe String -> PPChan -> Chan String ->
        Maybe CalendarTime -> TLVs -> IO ()
passItOn cnf nom outb to fro msg lk pp1 ch wh tv = do
    writeChan pp1 (PPReq outb to fro msg ch nom lk wh tv)

tellErr :: String -> String
tellErr err = "{\"facility\":\"error\", \"params\":{\"message\":" ++ (show err)
                ++ "}}"

treatMsg :: Outbox -> [String] -> String -> Either String String ->
    Maybe String -> Maybe CalendarTime -> TLVs -> IO ()
treatMsg outb to fro (Left msg) _ w tv = sendMsg outb (OutMsg fro to msg w tv)
treatMsg outb to fro (Right msg) l w _ = sendMsg outb (OutMMS fro to msg l w)

authMod :: Monad m => Handle -> Conf -> IO (m String)
authMod hdl cnf = do
    login <- hGetLine hdl
    case toJSON login of
        Yes j -> case "/params" @@ j of
            Yes _ -> do
                let kps = ("/params/keyword" @@ j, "/params/password" @@ j,
                           "/params/pwdscheme" @@ j)
                checkAuth hdl cnf kps
            No x -> do
                hPutStrLn hdl $ "{\"facility\":\"error\"," ++
                    "\"params\":{\"message\":"  ++ show x ++ "}}"
                authMod hdl cnf
        No x -> do
            hPutStrLn hdl $ "{\"facility\":\"error\"," ++
                "\"params\":{\"message\":" ++ show x ++ "}}"
            authMod hdl cnf

type AuthStuff = (Maybe JSONValue, Maybe JSONValue, Maybe JSONValue) 

checkAuth :: Monad m => Handle -> Conf -> AuthStuff -> IO (m String)
checkAuth hdl cnf kps = case kps of
    (Just (JStr k), Just (JStr p), Just (JStr s)) -> do
        known <- moduleMap cnf
        sso   <- fmap (DM.lookup k) $ activeMods cnf
        case DM.lookup k known of
            Just pwd -> case sso of
                Just _ -> return (fail "You'll Not Log In Twice.")
                _      -> if eqWithScheme pwd p s then
                    return (return k) else
                        return (fail "Bad password.")
            _        -> return (fail ("Keyword " ++ k ++ " is not known."))
    _ -> fail "Keyword, password, scheme."

eqWithScheme :: String -> String -> String -> Bool
eqWithScheme pwd1 pwd2 "pwd" = pwd1 == pwd2
eqWithScheme _ _ _           = False
