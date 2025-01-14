{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies #-}

module Horture.Backend.X11.LinuxX11 where

import Control.Lens
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Foreign.C.Types
import Foreign.Ptr
import Graphics.Rendering.OpenGL as GL
import qualified Graphics.UI.GLFW as GLFW
import Graphics.X11
import Graphics.X11.Xlib.Extras
import Horture.Backend.X11.X11
import Horture.GL
import Horture.Asset
import Horture.Horture
import Horture.Logging
import Horture.Program
import Horture.State
import Horture.WindowGrabber

type CaptureHandle = (Display, Window, Bool)

instance
  (CaptureHandle ~ hdl, HortureLogger (Horture l hdl)) =>
  WindowPoller hdl (Horture l hdl)
  where
  pollWindowEnvironment = pollXEvents
  nextFrame = captureApplicationFrame

-- | Updates currently bound texture with the pixeldata of the frame for the
-- captured application.
captureApplicationFrame :: Horture l CaptureHandle ()
captureApplicationFrame =
  gets (^. envHandle) >>= \case
    (dp, xWin, True) -> do
      dim <- gets (^. dim)
      liftIO $ getWindowImage dp xWin dim >>= updateWindowTexture dim
    -- The captured X11 window is currently not shown/unmapped, we cannot draw
    -- anything, so we have to abort.
    _otherwise -> return ()

-- | getWindowImage fetches the image of the currently captured application
-- window.
getWindowImage :: Display -> Window -> (Int, Int) -> IO Image
getWindowImage dp xWin (w, h) =
  getImage
    dp
    xWin
    1
    1
    (fromIntegral w)
    (fromIntegral h)
    0xFFFFFFFF
    zPixmap

-- | updateWindowTexture updates the OpenGL texture for the captured window
-- using the given dimensions together with the source image as a data source.
updateWindowTexture :: (Int, Int) -> Image -> IO ()
updateWindowTexture (w, h) i = do
  src <- ximageData i
  let pd = PixelData BGRA UnsignedInt8888Rev src
  texSubImage2D
    Texture2D
    0
    (TexturePosition2D 0 0)
    (TextureSize2D (fromIntegral w) (fromIntegral h))
    pd
  destroyImage i

pollXEvents :: Horture l CaptureHandle ()
pollXEvents = do
  glWin <- asks _glWin
  modelUniform <- asks (^. screenProg . modelUniform)
  projectionUniform <- asks (^. screenProg . projectionUniform)
  backTexObj <- asks (^. screenProg . backTextureObject)
  screenTexObj <- asks (^. screenProg . textureObject)
  screenTexUnit <- asks (^. screenProg . textureUnit)
  (dp, xWin, isMapped) <- gets (^. envHandle)
  pm <- gets _capture
  (oldW, oldH) <- gets _dim
  ((xWin, isMapped), pm, (newW, newH)) <- liftIO $
    allocaXEvent $ \evptr -> do
      doIt <- checkWindowEvent dp xWin structureNotifyMask evptr
      if doIt
        then do
          getEvent evptr >>= \case
            ConfigureEvent {..} ->
              handleConfigureEvent
                dp
                xWin
                glWin
                pm
                screenTexUnit
                screenTexObj
                backTexObj
                (projectionUniform, modelUniform)
                (ev_width, ev_height)
                (ev_x, ev_y)
            UnmapEvent {} -> handleUnmapEvent xWin dp pm
            MapNotifyEvent {} -> do
              (pos, dim) <- handleMapEvent dp xWin
              handleConfigureEvent
                dp
                xWin
                glWin
                pm
                screenTexUnit
                screenTexObj
                backTexObj
                (projectionUniform, modelUniform)
                dim
                pos
            _otherwise -> do
              print _otherwise
              return ((xWin, isMapped), pm, (oldW, oldH))
        else return ((xWin, isMapped), pm, (oldW, oldH))
  modify $ \hs ->
    hs
      { _dim = (newW, newH),
        _capture = pm,
        _envHandle = (dp, xWin, isMapped)
      }

handleMapEvent :: Display -> Window -> IO ((CInt, CInt), (CInt, CInt))
handleMapEvent dp xWin = do
  winAttr <- getWindowAttributes dp xWin
  let pos = (wa_x winAttr, wa_y winAttr)
      dim = (wa_width winAttr, wa_height winAttr)
  return (pos, dim)

handleConfigureEvent ::
  Display ->
  Window ->
  GLFW.Window ->
  Maybe Pixmap ->
  TextureUnit ->
  TextureObject ->
  TextureObject ->
  (UniformLocation, UniformLocation) ->
  (CInt, CInt) ->
  (CInt, CInt) ->
  IO ((Window, Bool), Maybe Pixmap, (Int, Int))
handleConfigureEvent
  dp
  xWin
  glWin
  pm
  screenTexUnit
  screenTexObj
  backTexObj
  (projectionUniform, modelUniform)
  (ev_width, ev_height)
  (ev_x, ev_y) =
    do
      -- Retrieve a new pixmap
      newPm <- xCompositeNameWindowPixmap dp xWin
      -- Update reference, aspect ratio & destroy old pixmap if existent.
      forM_ pm (freePixmap dp)
      -- Update overlay window with new aspect ratio.
      let newWInt = fromIntegral ev_width
          newHInt = fromIntegral ev_height
          newWFloat = fromIntegral ev_width
          newHFloat = fromIntegral ev_height
      GLFW.setWindowSize glWin newWInt newHInt
      GLFW.setWindowPos glWin (fromIntegral ev_x) (fromIntegral ev_y)
      let !anyPixelData = PixelData BGRA UnsignedInt8888Rev nullPtr
      -- Update texture bindings!
      activeTexture $= screenTexUnit
      textureBinding Texture2D $= Just screenTexObj
      texImage2D
        Texture2D
        NoProxy
        0
        RGBA'
        (TextureSize2D (fromIntegral ev_width) (fromIntegral ev_height))
        0
        anyPixelData
      generateMipmap' Texture2D
      textureBinding Texture2D $= Just backTexObj
      texImage2D
        Texture2D
        NoProxy
        0
        RGBA'
        (TextureSize2D (fromIntegral ev_width) (fromIntegral ev_height))
        0
        anyPixelData
      generateMipmap' Texture2D

      -- TODO: WHY does this have no effect?
      let proj = projectionForAspectRatio (newWFloat, newHFloat)
      m44ToGLmatrix proj >>= (uniform projectionUniform $=)

      let model = scaleForAspectRatio (newWInt, newHInt)
      m44ToGLmatrix model >>= (uniform modelUniform $=)

      return ((xWin, True), Just newPm, (newWInt, newHInt))

handleUnmapEvent :: Window -> Display -> Maybe Pixmap -> IO ((Window, Bool), Maybe Pixmap, (Int, Int))
handleUnmapEvent xWin dp pm = do
  forM_ pm (freePixmap dp)
  return ((xWin, False), Nothing, (0, 0))
