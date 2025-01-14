module Horture.State where

import Control.Concurrent (MVar)
import Control.Concurrent.Chan.Synchronous
import Control.Concurrent.STM
import Control.Lens.TH
import Data.Text (Text)
import Graphics.Rendering.OpenGL hiding (get)
import qualified Graphics.UI.GLFW as GLFW
import Graphics.X11
import Horture.Audio.Recorder
import Horture.Event
import Horture.Program

data HortureStatic = HortureStatic
  { _screenProg :: !HortureScreenProgram,
    _dynamicImageProg :: !HortureDynamicImageProgram,
    _backgroundProg :: !HortureBackgroundProgram,
    _fontProg :: !HortureFontProgram,
    _eventChan :: !(Chan Event),
    _logChan :: !(Maybe (Chan Text)),
    _glWin :: !GLFW.Window,
    _backgroundColor :: !(Color4 Float)
  }

data HortureState hdl = HortureState
  { _envHandle :: !hdl,
    _audioRecording :: !(Maybe (MVar ())),
    _audioStorage :: !(TVar (Maybe FFTSnapshot)),
    _mvgAvg :: ![FFTSnapshot],
    _capture :: !(Maybe Drawable),
    _dim :: !(Int, Int)
  }

makeLenses ''HortureStatic
makeLenses ''HortureState
