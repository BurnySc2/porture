{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE QuasiQuotes #-}

-- | Follows the credential flows given at:
-- https://dev.twitch.tv/docs/authentication/getting-tokens-oauth/#client-credentials-grant-flow
module Horture.Authorize (authorize) where

import Control.Concurrent (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async (race)
import Data.ByteString.Builder (Builder, byteString, toLazyByteString)
import Data.ByteString.Char8 (drop)
import Data.ByteString.Lazy.Char8 (unpack)
import Data.Functor ((<&>))
import Data.Text (Text, pack)
import Data.Word (Word8)
import Horture.Config
import Network.HTTP.Types (status200, status400)
import Network.Wai
import Network.Wai.Handler.Warp
import Servant.Client (BaseUrl (..), showBaseUrl)
import System.Exit (exitFailure)
import System.Random.Stateful (globalStdGen, uniformListM)
import Text.RawString.QQ
import Twitch.Rest.Authorization
  ( AccessTokenScopes (..),
    AuthorizationErrorResponse (..),
    AuthorizationRequest (..),
    AuthorizationResponse (..),
    AuthorizationResponseType (Token),
  )
import Web.FormUrlEncoded (urlDecodeAsForm, urlEncodeAsForm)
import Prelude hiding (drop)

authorize :: FilePath -> IO ()
authorize pathToConfig = do
  cfg <-
    parseHortureClientConfig pathToConfig >>= \case
      Nothing -> print @String "invalid horture client config" >> exitFailure
      Just cfg -> return cfg
  res <-
    retrieveUserAccessToken
      ""
      (twitchAuthorizationEndpoint cfg)
      (AccessTokenScopes ["channel:redemptions:manage"])
  case res of
    Nothing -> print @String "Unable to authorize user"
    Just _ -> print @String "Success authorizing user, have fun horturing"

-- | retrieveUserAccessToken follows the implicit client-credentials flow,
-- where the user is directed to `https://id.twitch.tv/oauth2/authorize` and
-- redirected to `http://localhost:3000`. The fragment part of the redirection
-- (everything after `#`) contains the authorization response.
retrieveUserAccessToken :: Text -> BaseUrl -> AccessTokenScopes -> IO (Maybe Text)
retrieveUserAccessToken _ _ (AccessTokenScopes []) = do
  print @String "No scopes given to request from user, aborting..."
  return Nothing
retrieveUserAccessToken clientId twitchEndpoint scopes = do
  print @String
    "Please open the following authorization link in your browser to give horture access to interact with your account"
  xsrfState <- uniformListM 32 globalStdGen <&> pack . concatMap (show @Word8)
  accessTokenMVar <- newEmptyMVar
  let ar =
        AuthorizationRequest
          { authorizationrequestClientId = clientId,
            authorizationrequestForceVerify = Nothing,
            authorizationrequestRedirectUri = "http://localhost:3000",
            authorizationrequestScope = scopes,
            authorizationrequestResponseType = Token,
            authorizationrequestState = Just xsrfState
          }
  print $ showBaseUrl twitchEndpoint <> "?" <> unpack (urlEncodeAsForm ar)
  -- Wait for accessToken to be retrieved, if this never happens the user
  -- aborted the process and the thread will be cleaned up anyway.
  res <-
    race (takeMVar accessTokenMVar) $
      runSettings defaultSettings (userAccessTokenApp accessTokenMVar xsrfState)
  case res of
    Left mAccessToken -> return mAccessToken
    -- User either denied authorization or something else went wrong which
    -- killed the server.
    Right _ -> return Nothing

-- | userAccessTokenApp is a simple server waiting for a single redirection to
-- happen via the twitch API upon user authorization. Shuts down afterwards.
userAccessTokenApp :: MVar (Maybe Text) -> Text -> Application
userAccessTokenApp accessTokenMVar xsrfState req respondWith = do
  case pathInfo req of
    [] -> do
      case tryDecodeQueryString . rawQueryString $ req of
        -- User denied authorization, shutdown the server and clean up.
        Right err -> do
          print err
          putMVar accessTokenMVar Nothing
          respondWith (responseBuilder status200 [] informUserDeniedHTML)
        -- User authorized this application, serve JS to grab URI-fragment
        -- containing necessary data.
        Left _ -> respondWith (responseBuilder status200 [] grabFragmentPortionHTML)
    ["authorization"] -> do
      eitherAR <- getRequestBodyChunk req <&> urlDecodeAsForm @AuthorizationResponse . toLazyByteString . byteString
      case eitherAR of
        Right ar
          -- Everything went right, proceed.
          | authorizationresponseState ar == Just xsrfState -> do
            putMVar accessTokenMVar . Just . authorizationresponseAccessToken $ ar
          -- Received wrong state variable from Twitch, user can simply reload
          -- and try again.
          | otherwise -> do
            print @String "XSRF detected, not using twitch response. Try again."
            print @String "Simply try to reauthorize by clicking on the link again."
        -- Twitch sent ill-formatted tokens, user can reload and try again.
        Left err -> do
          print ("authorization failed: " <> err)
          print @String "Simply try to reauthorize by clicking on the link again."
      respondWith $ responseBuilder status200 [] "Check your CLI client for more steps"
    _otherwise -> respondWith $ responseBuilder status400 [] "something went wrong"
  where
    tryDecodeQueryString "" = Left "empty query string"
    tryDecodeQueryString qs = urlDecodeAsForm @AuthorizationErrorResponse . toLazyByteString . byteString . drop 1 $ qs

grabFragmentPortionHTML :: Builder
grabFragmentPortionHTML =
  [r|
<html>
  <script>
    // This script will only be run after a previous error check making sure
    // `document.location.hash` should not be empty.
    // `substr(1)` to remove preceeding `#` sign.
    const formBody = document.location.hash.substr(1);
    fetch(
        "http://localhost:3000/authorization",
        {
            method: 'POST',
            body: formBody,
            headers: {
               'Content-Type': 'application/x-www-form-urlencoded'
            }
        }
    );
  </script>
  <h1>
    Forwarded authorization token to client, check your CLI for more information.
  </h1>
</html>
  |]

informUserDeniedHTML :: Builder
informUserDeniedHTML =
  [r|
<html>
  <h1>User Denied Authorization, aborting...</h1>
</html>
  |]