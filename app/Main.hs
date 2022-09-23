{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}

module Main where

-- Horture
--
-- Initialize fullscreen transparent window without focus GLFW
-- Initialize X11 -> Continuously pull desktop image (excluding GLFW) with x11::GetImage
--                -> Upload image to GPU with OpenGL
--                -> Postprocess and draw to window

import Codec.Picture
import Codec.Picture.Gif
import Control.Monad.Except
import Data.Bits hiding (rotate)
import Data.ByteString (readFile)
import Data.List (elem, find)
import Data.Maybe
import Data.Vector.Storable (toList)
import Data.Word
import Foreign.C.Types
import Foreign.Marshal.Alloc
import Foreign.Marshal.Array
import Foreign.Ptr
import Foreign.Storable
import GHC.ForeignPtr
import Graphics.GLUtil as Util hiding (throwError)
import Graphics.GLUtil.Camera2D as Cam2D
import Graphics.GLUtil.Camera3D as Cam3D
import Graphics.Rendering.OpenGL as GL hiding (Color, flush, rotate)
import qualified Graphics.UI.GLFW as GLFW
import Graphics.X11
import Graphics.X11.Xlib.Extras
import Graphics.X11.Xlib.Types
import Horture
import Linear.Matrix
import Linear.Quaternion
import Linear.V2
import Linear.V3
import Linear.V4
import System.Clock
import System.Exit
import qualified System.Random as Random
import Text.RawString.QQ
import Prelude hiding (readFile)

main :: IO ()
main =
  x11UserGrabWindow >>= \case
    Nothing -> print "No window to horture yourself on selected 🤨, aborting" >> exitFailure
    Just w -> main' w

main' :: Window -> IO ()
main' w = do
  glW <- initGLFW
  (vao, vbo, veo, prog, gifProg) <- initResources
  dp <- openDisplay ""
  let ds = defaultScreen dp
      cm = defaultColormap dp ds
  root <- rootWindow dp ds

  Just (_, meW) <- findMe root dp hortureName
  allocaSetWindowAttributes $ \ptr -> do
    set_event_mask ptr noEventMask
    changeWindowAttributes dp meW cWEventMask ptr
    set_border_pixel ptr 0
    changeWindowAttributes dp meW cWBorderPixel ptr
  GLFW.setCursorInputMode glW GLFW.CursorInputMode'Hidden
  GLFW.setStickyKeysInputMode glW GLFW.StickyKeysInputMode'Disabled
  GLFW.setStickyMouseButtonsInputMode glW GLFW.StickyMouseButtonsInputMode'Disabled

  attr <- getWindowAttributes dp w
  allocaSetWindowAttributes $ \ptr -> do
    _ <- set_event_mask ptr structureNotifyMask
    changeWindowAttributes dp w cWEventMask ptr
  print "Set window attributes"

  res <- xCompositeQueryExtension dp
  when (isNothing res) $
    print "xCompositeExtension is missing!" >> exitFailure
  print "Queried composite extension"

  -- GIFs
  content <- readFile "/home/omega/Downloads/ricardoflick.gif"
  imgs <- case decodeGifImages content of
    Left err -> print ("decoding ricardogif: " <> err) >> exitFailure
    Right imgs -> return imgs
  delayms <- case getDelaysGifImages content of
    Left err -> print ("getting gif delays: " <> err) >> exitFailure
    Right ds -> return . head $ ds

  -- Set active texture slot.
  currentProgram $= Just gifProg
  texIndex <- uniformLocation gifProg "index"
  uniform texIndex $= (0 :: GLint)

  let gifUnit = TextureUnit 4
  activeTexture $= gifUnit
  texGif <- genObjectName @TextureObject
  textureBinding Texture2DArray $= Just texGif
  let imgsL = concatMap (\(ImageRGBA8 (Codec.Picture.Image _ _ v)) -> toList v) imgs
      (gifW, gifH) = case head imgs of
        ImageRGBA8 (Codec.Picture.Image w h _) -> (w, h)
        _ -> error "decoding gif image"
  withArray imgsL $ \ptr -> do
    let pixelData = PixelData RGBA UnsignedByte ptr
    texImage3D
      Texture2DArray
      NoProxy
      0
      RGBA8
      (TextureSize3D (fromIntegral gifW) (fromIntegral gifH) (fromIntegral . length $ imgs))
      0
      pixelData
    generateMipmap' Texture2DArray

  gifTexUni <- uniformLocation gifProg "gifTexture"
  uniform gifTexUni $= gifUnit

  activeTexture $= TextureUnit 0
  currentProgram $= Just prog
  --

  bindVertexArrayObject $= Just vao
  bindBuffer ArrayBuffer $= Just vbo
  withArray verts $ \ptr -> bufferData ArrayBuffer $= (fromIntegral planeVertsSize, ptr, StaticDraw)
  vertexAttribPointer (AttribLocation 0) $= (ToFloat, VertexArrayDescriptor 3 Float (fromIntegral $ 5 * floatSize) (plusPtr nullPtr 0))
  vertexAttribArray (AttribLocation 0) $= Enabled
  vertexAttribPointer (AttribLocation 1) $= (ToFloat, VertexArrayDescriptor 2 Float (fromIntegral $ 5 * floatSize) (plusPtr nullPtr (3 * floatSize)))
  vertexAttribArray (AttribLocation 1) $= Enabled
  bindBuffer ElementArrayBuffer $= Just veo
  withArray vertsElement $ \ptr -> bufferData ElementArrayBuffer $= (fromIntegral vertsElementSize, ptr, StaticDraw)

  GL.clearColor $= Color4 0.1 0.1 0.1 1

  tex01 <- genObjectName @TextureObject
  pm <- xCompositeNameWindowPixmap dp w
  print "Retrieved composite window pixmap"

  let ww = wa_width attr
      wh = wa_height attr
  GLFW.setFramebufferSizeCallback glW (Just resizeWindow')

  let !anyPixelData = PixelData BGRA UnsignedInt8888Rev nullPtr
  textureBinding Texture2D $= Just tex01
  texImage2D
    Texture2D
    NoProxy
    0
    RGBA'
    (TextureSize2D (fromIntegral ww) (fromIntegral wh))
    0
    anyPixelData

  let proj = curry projectionForAspectRatio (fromIntegral ww) (fromIntegral wh)
  projectionUniform <- uniformLocation prog "proj"
  m44ToGLmatrix proj >>= (uniform projectionUniform $=)

  let view = Cam3D.camMatrix (Cam3D.fpsCamera @Float)
  viewUniform <- uniformLocation prog "view"
  m44ToGLmatrix view >>= (uniform viewUniform $=)

  let model = curry scaleForAspectRatio (fromIntegral ww) (fromIntegral wh)
  modelUniform <- uniformLocation prog "model"
  m44ToGLmatrix model >>= (uniform modelUniform $=)

  GLFW.setWindowSize glW (fromIntegral . wa_width $ attr) (fromIntegral . wa_height $ attr)
  GLFW.setWindowPos glW (fromIntegral . wa_x $ attr) (fromIntegral . wa_y $ attr)

  timeUniform <- uniformLocation prog "dt"
  Just startTime <- GLFW.getTime
  uniform timeUniform $= (0 :: Float)
  let update pm (ww, wh) = do
        dt <-
          GLFW.getTime >>= \case
            Nothing -> exitFailure
            Just currentTime -> return $ currentTime - startTime
        uniform timeUniform $= realToFrac @Double @Float dt
        i <-
          getImage
            dp
            pm
            0
            0
            (fromIntegral ww)
            (fromIntegral wh)
            0xFFFFFFFF
            zPixmap

        src <- ximageData i
        let pixelData = PixelData BGRA UnsignedInt8888Rev src
        texSubImage2D
          Texture2D
          0
          (TexturePosition2D 0 0)
          (TextureSize2D (fromIntegral ww) (fromIntegral wh))
          pixelData

        generateMipmap' Texture2D

        -- Transformations.
        -- offset <- Random.randomIO @Float
        -- let view = Cam3D.camMatrix @Float ({-Cam2D.track (V2 (0 + offset) (0 - offset))-} Cam3D.fpsCamera)
        -- m44ToGLmatrix view >>= (uniform viewUniform $=)

        let posChange = V3 0 0 (negate $ fromIntegral (round dt `mod` 10) / 10)
            axis = V3 0 0 (-1) :: V3 Float
            rot = axisAngle axis 0
            trans = mkTransformation @Float rot posChange
            scale = scaleForAspectRatio (fromIntegral ww, fromIntegral wh)
            model = trans !*! scale
         in m44ToGLmatrix model >>= (uniform modelUniform $=)

        destroyImage i

        GL.clear [ColorBuffer]

        bindVertexArrayObject $= Just vao
        drawElements Triangles 6 UnsignedInt nullPtr

        -- Each program needs its own set of uniforms, which can be accessed in
        -- the vertex- and fragment shaders.
        -- For GIFs we define a plane which can be animated over time. At first
        -- it will be rather random and slow movement.
        -- Showing GIFs will then easily be achievable by instantiating a list
        -- of GIF-objects and calling `render` on them.
        -- `render` itself is part of a typeclass `class Renderable a where` a
        -- contains all necessary state information to handle its own
        -- rendering.
        currentProgram $= Just gifProg
        activeTexture $= gifUnit
        let elapsedms = round $ dt * (10 ^ 2)
            i = (elapsedms `div` (10 * delayms)) `mod` length imgs
        uniform texIndex $= fromIntegral @_ @GLint i
        drawElements Triangles 6 UnsignedInt nullPtr
        activeTexture $= TextureUnit 0
        currentProgram $= Just prog

        GLFW.swapBuffers glW
        GLFW.pollEvents

        (pm, (ww, wh)) <- allocaXEvent $ \evptr -> do
          doIt <- checkWindowEvent dp w structureNotifyMask evptr
          if doIt
            then do
              getEvent evptr >>= \case
                ConfigureEvent {..} -> do
                  -- Retrieve a new pixmap.
                  newPm <- xCompositeNameWindowPixmap dp w
                  -- Update reference, aspect ratio & destroy old pixmap.
                  freePixmap dp pm
                  -- Update overlay window with new aspect ratio.
                  let glw = fromIntegral ev_width
                      glh = fromIntegral ev_height
                  GLFW.setWindowSize glW glw glh
                  attr <- getWindowAttributes dp w
                  GLFW.setWindowPos glW (fromIntegral ev_x) (fromIntegral ev_y)
                  (glW, glH) <- GLFW.getFramebufferSize glW
                  let !anyPixelData = PixelData BGRA UnsignedInt8888Rev nullPtr
                  -- Update texture bindings!
                  textureBinding Texture2D $= Just tex01
                  texImage2D
                    Texture2D
                    NoProxy
                    0
                    RGBA'
                    (TextureSize2D (fromIntegral ev_width) (fromIntegral ev_height))
                    0
                    anyPixelData

                  let proj = curry projectionForAspectRatio (fromIntegral ww) (fromIntegral wh)
                  m44ToGLmatrix proj >>= (uniform projectionUniform $=)

                  let model = curry scaleForAspectRatio (fromIntegral ww) (fromIntegral wh)
                  m44ToGLmatrix model >>= (uniform modelUniform $=)

                  return (newPm, (ev_width, ev_height))
                _ -> return (pm, (ww, wh))
            else return (pm, (ww, wh))

        update pm (ww, wh)

  update pm (ww, wh)
  print "Done..."

findMe :: Window -> Display -> String -> IO (Maybe ([[Char]], Window))
findMe root dp me = do
  (root, parent, childs) <- queryTree dp root
  alloca $ \ptr -> do
    res <-
      mapM
        ( \c -> do
            xGetTextProperty dp c ptr wM_CLASS
            r <- peek ptr >>= wcTextPropertyToTextList dp
            if not . null $ r
              then print r >> return (Just (r, c))
              else return Nothing
        )
        childs
    return . join
      . find
        ( \case
            (Just (ns, c)) -> hortureName `elem` ns
            _ -> False
        )
      $ res

createGifTex :: DynamicImage -> IO ()
createGifTex (ImageRGBA8 i) = undefined
createGifTex _ = error "unhandled image type encountered when creating GIF texture"
