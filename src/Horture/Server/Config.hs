module Horture.Server.Config (HortureServerConfig (..)) where

import Network.Wai.Handler.Warp
import Servant.Client.Core (BaseUrl (..))
import Data.Text (Text)

data HortureServerConfig = HortureServerConfig
  { _port :: !Port,
    _callback :: !BaseUrl,
    _appToken :: !Text
  }
  deriving (Show)
