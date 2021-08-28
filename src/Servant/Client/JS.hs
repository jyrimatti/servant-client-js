{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE ExtendedDefaultRules       #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PackageImports             #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeSynonymInstances       #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE ViewPatterns               #-}
{-# OPTIONS_GHC -Wunused-imports        #-}
{-# OPTIONS_GHC -Wincomplete-patterns   #-}


module Servant.Client.JS
  ( module Servant.Client.Core.Reexport
  , AbortController (..)
  , abort
  , newAbortController
  , fetch
  , ClientEnv (..)
  , ClientM (..)
  , runClientM
  , client
  , withStreamingRequestJSM
  ) where


import           Control.Concurrent                    (newEmptyMVar, putMVar,
                                                        takeMVar)
import           Control.Exception                     hiding (catch)
import           Control.Monad                         (forM, forM_)
import           Control.Monad.Base                    (MonadBase (..))
import           Control.Monad.Catch                   hiding (catch)
import           Control.Monad.Error.Class             (MonadError (..))
import           Control.Monad.Reader                  (MonadIO (..),
                                                        MonadReader,
                                                        ReaderT (..), fix)
import           Control.Monad.Trans.Control           (MonadBaseControl (..))
import           Control.Monad.Trans.Except            (ExceptT (..),
                                                        runExceptT)
import           Data.Binary.Builder                   (toLazyByteString)
import qualified Data.ByteString.Char8                 as BS
import qualified Data.ByteString.Lazy                  as BL
import           Data.CaseInsensitive                  (mk, original)
import           Data.Functor.Alt                      (Alt (..))
import           Data.Maybe                            (fromMaybe)
import           Data.Proxy                            (Proxy (Proxy))
import qualified Data.Sequence                         as Seq
import           Data.Text                             (Text, intercalate, pack)
import           Data.Text.Encoding                    (decodeUtf8, encodeUtf8)
import           GHC.Conc                              (atomically, newTVarIO,
                                                        readTVar, readTVarIO,
                                                        writeTVar)
import           GHC.Generics                          (Generic)
import           GHCJS.Buffer                          (byteLength,
                                                        createFromArrayBuffer,
                                                        freeze, fromByteString,
                                                        getArrayBuffer,
                                                        toByteString)
import           GHCJS.Marshal.Internal                (pFromJSVal, pToJSVal)
#ifdef ghcjs_HOST_OS
import           GHCJS.Prim                            hiding (JSException,
                                                        fromJSString, getProp)
import           Language.Javascript.JSaddle           (fromJSString)
#else
import           "jsaddle" GHCJS.Prim                  hiding (JSException,
                                                        fromJSString)
#endif
import qualified JavaScript.TypedArray.ArrayBuffer     as ArrayBuffer
import           Language.Javascript.JSaddle           (JSM (..), JSString (..),
                                                        MonadJSM, catch,
                                                        fromJSVal, fun,
                                                        ghcjsPure, isTruthy,
                                                        jsg, liftJSM,
                                                        makeObject, new, obj,
                                                        toJSVal, (!), (#), (<#))
import           Language.Javascript.JSaddle.Exception (JSException (JSException))
import           Network.HTTP.Media                    (renderHeader)
import           Network.HTTP.Types                    (Header, HttpVersion,
                                                        Status, http11)
import           Servant.Client.Core                   (Request,
                                                        RequestBody (RequestBodyBS, RequestBodyLBS, RequestBodySource),
                                                        RequestF (Request),
                                                        ResponseF (Response),
                                                        RunClient (..),
                                                        RunStreamingClient (..),
                                                        clientIn)
import           Servant.Client.Core.Reexport
import qualified Servant.Types.SourceT                 as S

default (Text)


newtype ClientEnv = ClientEnv { baseUrl :: BaseUrl }
  deriving (Eq, Show)


newtype ClientM a = ClientM
  { runClientM' :: ReaderT ClientEnv (ExceptT ClientError JSM) a }
  deriving ( Functor, Applicative, Monad, MonadIO
#ifndef ghcjs_HOST_OS
           , MonadJSM
#endif
           , Generic, MonadReader ClientEnv, MonadError ClientError
           , MonadThrow, MonadCatch )

client :: HasClient ClientM api => Proxy api -> Client ClientM api
client api = api `clientIn` (Proxy :: Proxy ClientM)

runClientM :: ClientM a -> ClientEnv -> JSM (Either ClientError a)
runClientM m env = runExceptT $ runReaderT (runClientM' m) env

#ifndef ghcjs_HOST_OS
deriving instance MonadBase IO JSM
deriving instance MonadBaseControl IO JSM
#endif

instance MonadBase IO ClientM where
  liftBase = ClientM . liftBase

instance MonadBaseControl IO ClientM where
  type StM ClientM a = Either ClientError a

  liftBaseWith f = ClientM (liftBaseWith (\g -> f (g . runClientM')))

  restoreM st = ClientM (restoreM st)

instance Alt ClientM where
  a <!> b = a `catchError` const b

instance RunClient ClientM where
  runRequest = fetch Nothing
  throwClientError = throwError

instance RunStreamingClient ClientM where
  withStreamingRequest req handler = withStreamingRequestJSM Nothing req (liftIO . handler)


newtype AbortController = AbortController JSVal

newAbortController :: JSM AbortController
newAbortController = do
  ctor <- jsg "AbortController"
  AbortController <$> (new ctor ([] :: [JSVal]))

abort :: AbortController -> JSM ()
abort (AbortController o) = do
  _ <- o # "abort" $ ([] :: [JSVal])
  return ()


#ifdef ghcjs_HOST_OS
unJSString :: JSString -> Text
unJSString = fromJSString
#else
unJSString :: JSString -> Text
unJSString (JSString s) = s
#endif


getFetchArgs :: ClientEnv -> Request -> Maybe AbortController -> JSM [JSVal]
getFetchArgs (ClientEnv (BaseUrl urlScheme host port basePath))
             (Request reqPath reqQs reqBody reqAccept reqHdrs _reqVer reqMethod)
             abortController = do
  self <- jsg "self"
  let schemeStr :: Text
      schemeStr = case urlScheme of
                    Http  -> "http://"
                    Https -> "https://"
  url <- toJSVal $ schemeStr <> pack host <> ":" <> pack (show port) <> pack basePath
                             <> decodeUtf8 (BL.toStrict (toLazyByteString reqPath))
                             <> (if Prelude.null reqQs then "" else "?" ) <> (intercalate "&"
                                        $ (\(k,v) -> decodeUtf8 k <> "="
                                                           <> maybe "" decodeUtf8 v)
                                         <$> Prelude.foldr (:) [] reqQs)
  init <- obj
  methodStr <- toJSVal $ decodeUtf8 reqMethod
  init <# "method" $ methodStr
  headers <- obj
  forM_  reqHdrs $ \(original -> k, v) -> do
    v' <- toJSVal (decodeUtf8 v)
    headers <# decodeUtf8 k $ v'
  forM_ reqAccept $ \mt -> do
    mt' <- toJSVal (decodeUtf8 (renderHeader mt))
    headers <# "Accept" $ mt'
  init <# "headers" $ headers
  case abortController of
    Nothing -> return ()
    Just (AbortController abortController') -> do
      signal <- abortController' ! "signal"
      init <# "signal" $ signal
      return ()
  case reqBody of
    Just (RequestBodyLBS x, mt) -> do
      (init <# "body") =<< getBody (BL.toStrict x)
      mt' <- toJSVal (decodeUtf8 (renderHeader mt))
      headers <# "Content-Type" $ mt'
    Just (RequestBodyBS x, mt) -> do
      (init <# "body") =<< getBody x
      mt' <- toJSVal (decodeUtf8 (renderHeader mt))
      headers <# "Content-Type" $ mt'
    Just (RequestBodySource _, _) -> error "Servant.Client.JS.withStreamingRequest(JSM) does not (yet) support RequestBodySource"
    Nothing -> return ()
  init' <- toJSVal init
  return [url, init']


getBody :: BS.ByteString -> JSM JSVal
getBody bs = do
  (buf, _, len) <- ghcjsPure $ fromByteString bs
  abuf <- ArrayBuffer.thaw =<< ghcjsPure (getArrayBuffer buf)
  blob <- new (jsg "Blob") . (:[]) =<< toJSVal [pToJSVal abuf]
  blob # "slice" $ [0, len]


getResponseMeta :: JSVal -> JSM (Status, Seq.Seq Header, HttpVersion)
getResponseMeta res = do
  status <- toEnum . fromMaybe 200
            <$> (fromJSVal =<< res ! ("status" :: Text))
  resHeadersObj <- makeObject =<< res ! ("headers" :: Text)
  resHeaderNames <- (resHeadersObj # ("keys" :: Text) $ ([] :: [JSVal]))
    >>= fix (\go names ->
      do x <- names # ("next" :: Text) $ ([] :: [JSVal])
         isDone <- fromJSVal =<< (x ! ("done" :: Text))
         if isDone == Just True || isDone == Nothing
           then return []
           else do
             rest <- go names
             v <- fromJSVal =<< x ! "value"
             case v of
               Just k  -> return (k : rest)
               Nothing -> return rest)
  resHeaders <- fmap (Prelude.foldr (Seq.:<|) Seq.Empty)
             .  forM resHeaderNames $ \headerName -> do
    headerValue <- fmap (fromMaybe "") . fromJSVal
                   =<< (resHeadersObj # ("get" :: Text) $ [headerName])
    return (mk (encodeUtf8 (unJSString headerName)), encodeUtf8 headerValue)
  return (status, resHeaders, http11) -- http11 is made up


uint8arrayToByteString :: JSVal -> JSM BS.ByteString
uint8arrayToByteString val = do
  abuf <- val ! "buffer"
  buf  <- ghcjsPure (createFromArrayBuffer (pFromJSVal abuf)) >>= freeze
  len  <- ghcjsPure (byteLength buf)
  ghcjsPure $ toByteString 0 (Just len) buf


parseChunk :: JSVal -> JSM (Maybe BS.ByteString)
parseChunk chunk = do
  isDone <- ghcjsPure =<< isTruthy
              <$> (chunk ! ("done" :: Text))
  case isDone of
    True  -> return Nothing
    False -> Just <$> (uint8arrayToByteString =<< chunk ! ("value" :: Text))


fetch :: Maybe AbortController -> Request -> ClientM Response
fetch abortController req = ClientM . ReaderT $ \env -> do
  self <- liftJSM $ jsg ("self" :: Text)
  args <- liftJSM $ getFetchArgs env req abortController
  result <- liftIO newEmptyMVar
  promise <- liftJSM $
    catch (self # ("fetch" :: Text) $ args)
          (\(JSException jsEx) -> jsNull <$ (liftIO . putMVar result $ Left jsEx))
  contents <- liftIO $ newTVarIO (mempty :: BS.ByteString)
  promiseHandler <- liftJSM . toJSVal . fun $ \_ _ args -> do
    case args of
      [res] -> do
        meta <- getResponseMeta res
        stream <- res ! ("body" :: Text)
        rdr <- stream # ("getReader" :: Text) $ ([] :: [JSVal])
        _ <- fix $ \go -> do
          rdrPromise <- rdr # ("read" :: Text) $ ([] :: [JSVal])
          rdrHandler <- toJSVal . fun $ \_ _ args -> do
            case args of
              [chunk] -> do
                next <- parseChunk chunk
                case next of
                  Nothing -> liftIO $ putMVar result . Right . (meta,) =<< readTVarIO contents
                  Just x -> do
                    liftIO . atomically $ writeTVar contents . (<> x) =<< readTVar contents
                    go
              _ -> do
                error "fetch read promise handler received wrong number of arguments"
          _ <- rdrPromise # ("then" :: Text) $ [rdrHandler]
          return ()
        return ()
      _ -> error "fetch promise handler received wrong number of arguments"
  promiseExceptionHandler <- liftJSM . toJSVal . fun $ \_ _ args ->
    case args of
      [jsEx] -> liftIO $ putMVar result (Left jsEx)
      _      -> error "fetch catch handler received wrong number of arguments"
  liftJSM $ (promise # ("then" :: Text) $ [promiseHandler])
        >>= (\p -> p # ("catch" :: Text) $ [promiseExceptionHandler])
  result' <- liftIO $ takeMVar result
  case result' of
    Right ((status, hdrs, ver), body) ->
      return $ Response status hdrs ver (BL.fromStrict body)
    Left jsException -> do
      liftJSM $ do
        console <- liftJSM $ jsg "console"
        console # ("log" :: Text) $ [jsException]
      throwError . ConnectionError . SomeException $ JSException jsException


-- | A variation on @Servant.Client.Core.withStreamingRequest@ where the continuation / callback
--   passed as the second argument is in the JSM monad as opposed to the IO monad.
--   Executes the given request and passes the response data stream to the provided continuation / callback.
withStreamingRequestJSM :: Maybe AbortController -> Request -> (StreamingResponse -> JSM a) -> ClientM a
withStreamingRequestJSM abortController req handler =
  ClientM . ReaderT $ \env -> do
    self <- liftJSM $ jsg "self"
    console <- liftJSM $ jsg "console"
    result <- liftIO newEmptyMVar
    fetchArgs <- liftJSM $ getFetchArgs env req abortController
    fetchPromise <- liftJSM $
      catch (self # "fetch" $ fetchArgs)
            (\(JSException jsEx) -> jsNull <$ (liftIO . putMVar result $ Left jsEx))
    push <- liftIO newEmptyMVar
    fetchPromiseHandler <- liftJSM . toJSVal . fun $ \_ _ args ->
      case args of
        [res] -> do
          (status, hdrs, ver) <- getResponseMeta res
          stream <- res ! ("body" :: Text)
          rdr <- stream # ("getReader" :: Text) $ ([] :: [JSVal])
          _ <- catch
            (fix $ \go -> do
              rdrPromise <- rdr # ("read" :: Text) $ ([] :: [JSVal])
              rdrHandler <- toJSVal . fun $ \_ _ args ->
                case args of
                  [chunk] -> do
                    next <- parseChunk chunk
                    case next of
                      Just bs -> do
                        liftIO $ putMVar push (Just bs)
                        go
                      Nothing -> liftIO $ putMVar push Nothing
                  _ -> error "wrong number of arguments to rdrHandler"
              rdrExHandler <- toJSVal . fun $ \_ _ args ->
                case args of
                  [jsEx] -> do
                    console # ("log" :: Text) $ [jsEx]
                    liftIO $ putMVar push Nothing
                  _ -> error "wrong number of arguments to rdrExHandler"
              _ <- (rdrPromise # ("then" :: Text) $ [rdrHandler])
               >>= (\p -> p # ("catch" :: Text) $ [rdrExHandler])
              return ()
            )
            (\(JSException jsEx) -> do
              console # ("log" :: Text) $ [jsEx]
              liftIO $ putMVar push Nothing
            )
          let out :: forall b. (S.StepT IO BS.ByteString -> IO b) -> IO b
              out handler' = handler' .  S.Effect . fix $ \go -> do
                next <- takeMVar push
                case next of
                  Nothing -> return S.Stop
                  Just x  -> return $ S.Yield x (S.Effect go)
          liftIO . putMVar result . Right . Response status hdrs ver $ S.SourceT @IO out
        _ -> error "wrong number of arguments to Promise.then() callback"
    promiseExceptionHandler <- liftJSM . toJSVal . fun $ \_ _ args ->
      case args of
        [jsEx] -> liftIO . putMVar result $ Left jsEx
        _ -> error "fetch catch handler in withStreamingRequestJSM received wrong number of arguments"
    liftJSM $ (fetchPromise # "then" $ [fetchPromiseHandler])
          >>= (\p -> p # "catch" $ [promiseExceptionHandler])
    result' <- liftIO $ takeMVar result
    case result' of
      Right x -> liftJSM $ handler x
      Left jsException -> do
        liftJSM $ do
          console <- liftJSM $ jsg "console"
          console # ("log" :: Text) $ [jsException]
        throwError . ConnectionError . SomeException $ JSException jsException
