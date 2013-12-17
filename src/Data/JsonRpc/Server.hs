{-# LANGUAGE MultiParamTypeClasses,
             FunctionalDependencies,
             FlexibleInstances,
             UndecidableInstances,
             Rank2Types,
             TypeOperators,
             OverloadedStrings #-}

-- | Functions for implementing the server side of JSON RPC 2.0.
--   Here is an example of a simple Happstack server with three methods:
--   
--   
module Data.JsonRpc.Server ( RpcResult
                           , RpcError
                           , Parameter(..)
                           , (:+:) (..)
                           , MethodParams
                           , Method
                           , toMethod
                           , Methods
                           , toMethods
                           , call
                           , callWithBatchStrategy
                           , rpcError
                           , rpcErrorWithData) where

import Data.String
import Data.Text (Text, append, unpack)
import Data.Maybe (catMaybes)
import qualified Data.ByteString.Lazy as B
import Data.Aeson
import Data.Aeson.Types (Parser, emptyObject)
import qualified Data.Vector as V
import qualified Data.HashMap.Strict as H
import Data.Attoparsec.Number (Number)
import Control.Applicative ((<$>), (<*>), (<|>), empty)
import Control.Monad (liftM)
import Control.Monad.Identity (runIdentity)
import Control.Monad.Error (Error, ErrorT, runErrorT, throwError, strMsg, noMsg)
import Prelude hiding (length)

-- | Parameter expected by a method.
data Parameter a
    -- | Required parameter with a name.
    = Required Text
    -- | Optional parameter with a name and default value.
    | Optional Text a

-- | A node in a type-level linked list of 'Parameter' types.  It is right associative.
data a :+: ps = (Parameter a) :+: ps
infixr :+:

-- | Return type of a method. A method call can either fail with an 'RpcError'
--   or succeed with a result of type 'r'.
type RpcResult m r = ErrorT RpcError m r

apply :: MethodParams f p m r => f -> p -> Args -> RpcResult m r
apply f p (Left hm) = mpApplyNamed f p hm
apply f p (Right vec) = mpApplyUnnamed f p vec

-- | Relationship between a method's function ('f'), parameters ('p'),
--   monad ('m'), and return type ('r'). 'p' has one 'Parameter' for
--   every argument of 'f' and is terminated by @()@. The return type
--   of 'f' is @RpcResult m r@. This class is treated as closed.
class (Monad m, Functor m, ToJSON r) => MethodParams f p m r | f -> p m r where
    mpApplyNamed :: f -> p -> Object -> RpcResult m r
    mpApplyUnnamed :: f -> p -> Array -> RpcResult m r

instance (Monad m, Functor m, ToJSON r) => MethodParams (RpcResult m r) () m r where
    mpApplyNamed r _ _ = r
    mpApplyUnnamed r _ _ = r

instance (FromJSON a, MethodParams f p m r) => MethodParams (a -> f) (a :+: p) m r where
    mpApplyNamed = applyNamed
    mpApplyUnnamed = applyUnnamed

applyNamed :: (FromJSON a, MethodParams f p m r)
              => (a -> f)
              -> a :+: p
              -> Object
              -> RpcResult m r
applyNamed f (param :+: ps) args = arg >>= \a -> mpApplyNamed (f a) ps args
    where arg = (lookupM name args >>= parseArg name) <|> paramDefault param
          name = paramName param

lookupM :: Monad m => Text -> Object -> m Value
lookupM k hm = case H.lookup k hm of
                 Nothing -> fail "not in map"
                 Just v -> return v

applyUnnamed :: (FromJSON a, MethodParams f p m r)
              => (a -> f)
              -> a :+: p
              -> Array
              -> RpcResult m r
applyUnnamed f (param :+: ps) args = arg >>= \a -> mpApplyUnnamed (f a) ps (tailOrEmpty args)
    where arg = (V.headM args >>= parseArg name) <|> paramDefault param
          name = paramName param

tailOrEmpty :: V.Vector a -> V.Vector a
tailOrEmpty vec = if V.null vec then V.empty else V.tail vec

parseArg :: (Monad m, FromJSON r) => Text -> Value -> RpcResult m r
parseArg name val = case fromJSON val of
                      Error msg -> throwError $ rpcErrorWithData (-32602) ("Wrong type for argument: " `append` name) (Just msg)
                      Success x -> return x

paramDefault :: Monad m => Parameter a -> RpcResult m a
paramDefault (Optional _ d) = return d
paramDefault (Required name) = throwError $ RpcError (-32602) ("Cannot find required argument: " `append` name) Nothing

paramName :: Parameter a -> Text
paramName (Optional n _) = n
paramName (Required n) = n

-- | Error to be returned to the client.
data RpcError = RpcError Int Text (Maybe Value)
              deriving Show

instance Error RpcError where
    noMsg = strMsg "unknown error"
    strMsg msg = RpcError (-32000) (fromString msg) Nothing

instance ToJSON RpcError where
    toJSON (RpcError code msg data') = object pairs
        where pairs = [codeKey .= toJSON code, msgKey .= toJSON msg] ++ dataPair
              dataPair = maybe [] (\d -> [dataKey .= toJSON d]) data'

data Response = Response { rspId :: Id
                         , rspResult :: Either RpcError Value }

instance ToJSON Response where
    toJSON r = object ["jsonrpc" .= jsonRpcVersion, result, "id" .= toJSON (rspId r)]
        where result = either (("error" .=) . toJSON) ("result" .=) (rspResult r)

jsonRpcVersion :: Text
jsonRpcVersion = "2.0"

data Id = IdString Text | IdNumber Number | IdNull

instance FromJSON Id where
    parseJSON (String x) = return $ IdString x
    parseJSON (Number x) = return $ IdNumber x
    parseJSON Null = return IdNull
    parseJSON _ = empty

instance ToJSON Id where
    toJSON i = case i of
                 IdString x -> toJSON x
                 IdNumber x -> toJSON x
                 IdNull -> Null

data Request = Request Text Args (Maybe Id)

instance FromJSON Request where
    parseJSON (Object x) = Request <$>
                           x .: methodKey <*>
                           (parseParams =<< x .:? paramsKey .!= emptyObject) <*>
                           x .:? idKey
        where parseParams :: Value -> Parser Args
              parseParams v = withObject (unpack paramsKey) (return . Left) v <|>
                              withArray (unpack paramsKey) (return . Right) v
    parseJSON _ = empty

-- | Creates an 'RpcError' with the given error code and message.
--   Server error codes should be in the range -32000 to -32099.
rpcError :: Int -> Text -> RpcError
rpcError code msg = RpcError code msg Nothing

-- | Creates an 'RpcError' with the given code, message, and additional data.
--   Server error codes should be in the range -32000 to -32099.
rpcErrorWithData :: ToJSON a => Int -> Text -> a -> RpcError
rpcErrorWithData code msg errorData = RpcError code msg $ Just $ toJSON errorData

codeKey :: Text
codeKey = "code"

msgKey :: Text
msgKey = "message"

dataKey :: Text
dataKey = "data"

methodKey :: Text
methodKey = "method"

paramsKey :: Text
paramsKey = "params"

idKey :: Text
idKey = "id"

-- | Single method.
data Method m = Method Text (Args -> RpcResult m Value)

type Args = Either Object Array

-- | Multiple methods.
newtype Methods m = Methods (H.HashMap Text (Method m))

-- | Creates a method from a name, function, and parameter description.
toMethod :: (MethodParams f p m r, ToJSON r, Monad m) => Text -> f -> p -> Method m
toMethod name f params = Method name (\args -> toJSON `liftM` apply f params args)

-- | Creates a set of methods to be called by name. The names must be unique.
toMethods :: [Method m] -> Methods m
toMethods fs = Methods $ H.fromList $ map (\f@(Method n _) -> (n, f)) fs

-- | Handles one JSON RPC request. It is the same as
--   @callWithBatchStrategy sequence@.
call :: Monad m => Methods m -- ^ Choice of methods to call.
     -> B.ByteString               -- ^ JSON RPC request.
     -> m (Maybe B.ByteString)     -- ^ The response wrapped in 'Just', or
                                   --   'Nothing' in the case of a notification,
                                   --   all wrapped in the given monad.
call = callWithBatchStrategy sequence

-- | Handles one JSON RPC request.
callWithBatchStrategy :: Monad m =>
                         (forall a . [m a] -> m [a]) -- ^ Function specifying the
                                                     --   evaluation strategy.
                      -> Methods m             -- ^ Choice of methods to call.
                      -> B.ByteString                -- ^ JSON RPC request.
                      -> m (Maybe B.ByteString)      -- ^ The response wrapped in 'Just', or
                                                     --   'Nothing' in the case of a notification,
                                                     --   all wrapped in the given monad.
callWithBatchStrategy strategy fs input = response2 response
    where response = runIdentity $ runErrorT $ do
                       val <- parseJson input
                       case val of
                                obj@(Object _) -> return ((toJSON <$>) `liftM` singleCall fs obj)
                                (Array vector) -> return ((toJSON <$>) `liftM` batchCall strategy fs (V.toList vector))
                                _ -> throwError $ invalidJsonRpc (Just ("Not a JSON object or array" :: String))
          response2 r = case r of
                          Left err -> return $ Just $ encode $ toJSON $ toResponse (Just IdNull) (Left err :: Either RpcError ())
                          Right maybeVal -> (encode <$>) `liftM` maybeVal
          parseJson = maybe invalidJson return . decode
          invalidJson = throwError $ rpcError (-32700) "Invalid JSON"

singleCall :: Monad m => Methods m -> Value -> m (Maybe Response)
singleCall (Methods fs) val = case fromJSON val of
                                      Error msg -> return $ toResponse (Just IdNull) ((Left $ invalidJsonRpc $ Just msg) :: Either RpcError ())
                                      Success (Request name params i) -> (toResponse i `liftM`) $ runErrorT $ do
                                                                                   Method _ f <- lookupMethod name
                                                                                   f params
    where lookupMethod name = maybe (methodNotFound name) return $ H.lookup name fs
          methodNotFound name = throwError $ rpcError (-32601) ("Method not found: " `append` name)

invalidJsonRpc :: Maybe String -> RpcError
invalidJsonRpc = rpcErrorWithData (-32600) "Invalid JSON RPC 2.0 request"

batchCall :: Monad m => (forall a. [m a] -> m [a]) -> Methods m -> [Value] -> m (Maybe [Response])
batchCall f gs vals = filterJust `liftM` results
    where results = f $ map (singleCall gs) vals
          filterJust rs = case catMaybes rs of
                            [] -> Nothing
                            xs -> Just xs

toResponse :: ToJSON a => Maybe Id -> Either RpcError a -> Maybe Response
toResponse Nothing _ = Nothing
toResponse (Just i) r = Just $ Response i (either Left (Right . toJSON) r)
