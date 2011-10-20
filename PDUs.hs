module PDUs where

import Control.Concurrent
import Data.Bits
import Data.Char
import Data.List
import qualified Data.Map as DM
import System.IO
import System.Time

instance Show USSDService where
    show PSSD = "\"pssd\""
    show PSSR = "\"pssr\""
    show USSR = "\"ussr\""
    show USSN = "\"ussn\""
    show PSSDResp = "\"pssdr\""
    show PSSRResp = "\"pssrr\""
    show USSRConfirm = "\"ussnc\""
    show USSNConfirm = "\"ussnc\""
    show (OtherService x) = show x

instance Enum USSDService where
    fromEnum PSSD = 0
    fromEnum PSSR = 1
    fromEnum USSR = 2
    fromEnum USSN = 3
    fromEnum PSSDResp = 16
    fromEnum PSSRResp = 17
    fromEnum USSRConfirm = 18
    fromEnum USSNConfirm = 19
    fromEnum (OtherService x) = x

    toEnum  0 = PSSD
    toEnum  1 = PSSR
    toEnum  2 = USSR
    toEnum  3 = USSN
    toEnum 16 = PSSDResp
    toEnum 17 = PSSRResp
    toEnum 18 = USSRConfirm
    toEnum 19 = USSNConfirm
    toEnum  x = OtherService x

data InMsg  = InMsg  {ifrom, ito, imsg :: String, itlvs :: DM.Map Int String} |
              Report {rfrom, rto, rmsg :: String, ref :: Int} |
              SysMsg {sfrom, sto, smsg :: String, slink :: Maybe String,
                      kwds :: [String], smedia :: [MMSFile]} |
              InMMS  {mfrom, mto, mmsg, mlink :: String, media :: [MMSFile]} |
              ReportMMS {rmfrom, rmto, rmmsg, rmmsid :: String} |
              InUSSD {ufrom, uto, umsg :: String, userv :: USSDService,
                      usess, seqNum :: Int, endSess :: Bool,
                        utlvs :: DM.Map Int String}
                deriving Show

data OutMsg = OutMsg {ofrom :: String, oto :: [String], omsg :: String,
                      when :: Maybe CalendarTime, otlvs :: DM.Map Int String} |
              OutMMS {mmfrom :: String, mmto :: [String], msmil :: String,
                      linkID :: Maybe String, mwhen :: Maybe CalendarTime} |
             OutUSSD {oufrom, outo, oumsg :: String, ouw :: Maybe CalendarTime,
                      outlvs :: DM.Map Int String, ouserv :: USSDService,
                      ousess, ouseqNum :: Int, ouendSess :: Bool}
                deriving Show

data Payload = WithSeq String | NoSeq String

class MonGen a where
    next :: a -> (Int, a)

data MMSFile = MMSFile {mimet, sha1 :: String} deriving Show

data USSDService = PSSD | PSSR | USSR | USSN | PSSDResp | PSSRResp |
                   USSRConfirm | USSNConfirm | OtherService Int

data ESMClass = DeliveryReport | PieceMeal | OtherESM deriving Show

type TransPcs = DM.Map Char (Int, [String])

newtype Inbox  = Inbox (Chan InMsg)

newtype Outbox = Outbox (Chan OutMsg)

type DieSig = SampleVar ()

tlvsToMap :: String -> DM.Map Int String
tlvsToMap = DM.fromList . (unfoldr (\x ->
    if null x then Nothing else
        let (tag, lv) = breakAt 2 x  in
        let (len, vl) = breakAt 2 lv in
        let (dat, nx) = breakAt (bigEndian ("\0\0" ++ len)) vl in
            Just ((bigEndian ("\0\0" ++ tag), dat), nx)))

breakAt :: Int -> [a] -> ([a], [a])
breakAt = ba_ []
    where
        ba_ :: [a] -> Int -> [a] -> ([a], [a])
        ba_ x _ []     = (x, [])
        ba_ x 0 y      = (x, y)
        ba_ x n (y:ys) = ba_ (x ++ [y]) (n - 1) ys


fetchPDU :: Handle -> IO String
fetchPDU hdl = do
    len <- getN 4 hdl
    got <- getN ((bigEndian len) - 4) hdl
    putStrLn ("S->C: " ++ show (len ++ got))
    return got

withPDU :: Monad m => Handle -> (String -> IO a) -> IO (m a)
withPDU hdl f = do
    pdu <- fetchPDU hdl
    if "\x80\x00\x00\x00" == (take 4 pdu) then return (fail "Generic NACK") else do
        let n4 = take 4 $ drop 4 pdu
        if "\x00\x00\x00\x00" == n4 then do
            got <- f pdu
            return (return got)
            else return (fail ("Error #" ++ (show $ bigEndian n4)))

getN :: Int -> Handle -> IO String
getN 0   _ = return ""
getN x hdl = do
    c <- hGetChar hdl
    s <- getN (x - 1) hdl
    return (c:s)

bigEndian :: String -> Int
bigEndian [i, j, k, l] = foldr (.|.) (ord l) [ord i `shiftL` 24,
                                              ord j `shiftL` 16,
                                              ord k `shiftL` 8]
bigEndian _            = error "Only four-byte integers, please."

packBigEndian :: Int -> String
packBigEndian n = map (chr . (.&. 255))
    [n `shiftR` 24, n `shiftR` 16, n `shiftR` 8, n]

keep2 :: Int -> String
keep2 = (drop 2) . packBigEndian

use2 :: String -> Int
use2 i@(x:y:_) = bigEndian ("\0\0" ++ i)
use2 i@[x]     = use2 ("\0" ++ i)
use2 ""        = 0

sendPDU :: Chan Payload -> Payload -> IO ()
sendPDU chn (WithSeq str) = writeChan chn (WithSeq str)
sendPDU chn (NoSeq str)   = writeChan chn (NoSeq str)

withLen :: String -> String
withLen str = let l = packBigEndian (4 + (length str)) in l ++ str

bindTRX :: Enum a => Chan Payload -> String -> String -> String -> a -> a -> String -> IO ()
bindTRX chn usn pwd stp nt np adr =
    sendPDU chn (NoSeq ("\x00\x00\x00\x09\x00\x00\x00\x00" ++ (cstr usn) ++
        (cstr pwd) ++ (cstr stp) ++ "\x34" ++ [chr (fromEnum x) | x <- [nt, np]] ++ (cstr (take 40 adr))))

cstr :: String -> String
cstr str = str ++ "\x00"

bindTRXResp :: Monad m => Handle -> IO (m String)
bindTRXResp hdl = withPDU hdl $ \x -> return $ drop 16 x

unbindTRX :: Chan Payload -> IO ()
unbindTRX chn = sendPDU chn $ NoSeq "\x00\x00\x00\x06\x00\x00\x00\x00"

unbindTRXResp :: Handle -> IO ()
unbindTRXResp hdl = do
    (withPDU hdl $ \_ -> return ()) :: IO (Maybe ())
    return ()
