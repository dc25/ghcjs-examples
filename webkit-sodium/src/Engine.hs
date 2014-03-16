{-# LANGUAGE CPP #-}
module Engine where

import Prelude hiding ((!!))
import GHCJS.DOM.Document
       (documentCreateElement, documentGetElementById, documentGetBody,
        documentGetDocumentElement)
import GHCJS.DOM.HTMLElement
       (htmlElementInsertAdjacentElement, htmlElementSetInnerHTML,
        htmlElementInsertAdjacentHTML)
import GHCJS.DOM (WebView, webViewGetDomDocument)
import GHCJS.DOM.Types
       (castToHTMLElement, castToElement, Document,
        HTMLElement, IsElement, IsMouseEvent, gTypeElement)
import Control.Applicative ((<$>))
import Control.Arrow
import Control.Monad.Trans ( liftIO )
import GHCJS.DOM.Element
import GHCJS.DOM.EventM
import GHCJS.DOM.MouseEvent hiding (MouseEvent)
import GHCJS.DOM.Node
import Control.Monad
import Control.Monad.State.Strict
import Data.IORef
import Data.Maybe

import FRP.Sodium
import Game
import Control.Monad.Reader (ReaderT(..))
#ifdef MIN_VERSION_jsaddle
import Language.Javascript.JSaddle
        (js2, js1, js0, js, jsg, (!!), (#), (<#), fun,
         deRefVal, JSValue(..), runJSaddle)
import Control.Lens ((^.))
#endif

-- Convert (game) world to/from screen co-ordinates.
-- World co-ordinates are x = -1400..1400, y = -1000 to 1000
-- Screen co-ordinates are x = 0..700, y = 0..500
-- Y is inverted
scale = 1/4
worldLeft = -1400
worldTop  = 1000
toWorld :: (Int, Int) -> (Double, Double)
toWorld (x,y) = (fromIntegral x / scale + worldLeft, worldTop - fromIntegral y / scale)
fromWorldRect :: Rect -> ((Int,Int),(Int,Int))
fromWorldRect ((xOrig,yOrig),(wid,hei)) = (
        (
            round $ (left - worldLeft) * scale,
            round $ (worldTop - top) * scale
        ),
        (
            round $ wid * scale * 2,
            round $ hei * scale * 2
        )
    )
  where
    left = xOrig - wid
    top  = yOrig + hei

-- | Get the mouse position relative to the top-left corner of the specified
-- HTML element.
getXYRelativeTo :: (IsElement elt, IsMouseEvent e, IsElement t) =>
                   Document -> elt -> EventM e t (Int, Int)
getXYRelativeTo doc container = do
    (px, py) <- mousePageXY doc container
    (cx, cy) <- liftIO $ elementPageXY doc container
    return (px - cx, py - cy)

mousePageXY :: (IsElement elt, IsMouseEvent e, IsElement t) =>
               Document -> elt -> EventM e t (Int, Int)
mousePageXY doc container = do
    (x, y) <- mouseClientXY
    liftIO $ do
	Just body <- documentGetBody doc     -- doc.body
        bodyScrollLeft <- elementGetScrollLeft body
        bodyScrollTop  <- elementGetScrollTop body
        Just docElt <- documentGetDocumentElement doc
        docEltScrollLeft <- elementGetScrollLeft docElt
        docEltScrollTop <- elementGetScrollTop docElt
        return (x + bodyScrollLeft + docEltScrollLeft, y + bodyScrollTop + docEltScrollTop)

-- | Get the top/left position of this element relative to the page.
elementPageXY :: IsElement elt => Document -> elt -> IO (Int, Int)
elementPageXY doc elt = do
    Just body <- documentGetBody doc
    traverse body (castToElement elt) (0,0)
  where
    traverse body elt (x, y) = do
        eq <- nodeIsEqualNode elt (Just body)
        if eq
            then return (x, y)
            else do
                ox <- elementGetOffsetLeft elt
                oy <- elementGetOffsetTop elt
                Just parent <- elementGetOffsetParent elt
                traverse body parent (x + ox, y + oy)

-- The game logic expects alternating down-up-down-up, but the browser can produce
-- bad sequences like down-up-down-down-up. So we sanitize the input.
mkSanitize :: Eq state =>
              state          -- ^ Initial state
           -> IO (state -> IO () -> IO ())
mkSanitize initialState = do
    stateRef <- newIORef initialState
    return $ \newState action -> do
        oldState <- readIORef stateRef
        when (oldState /= newState) $ do
            writeIORef stateRef newState
            action

data ButtonState = Up | Down deriving Eq

-- | Instantiate the game, handling mouse events and drawing the output.
-- Returns an \'unlisten\' action to de-register listeners.
engine :: WebView -> String -> (Event MouseEvent -> Reactive (BehaviorTree [Sprite])) -> IO (IO ())
engine webView containerId game = do
    putStrLn "Haskell Freecell"

    Just doc <- webViewGetDomDocument webView
    Just container <- fmap castToHTMLElement <$> documentGetElementById doc containerId
    -- Construct a mouse event that lives in FRP land, and a push action
    -- that allows us to push values into it from IO land.
    (eMouse, pushMouse) <- sync newEvent

    sanitize <- mkSanitize Up

    -- Listen to mouse events from WebKit
    elementOnmousedown container $ do
        xy <- getXYRelativeTo doc container
        liftIO . sanitize Down . sync . pushMouse . MouseDown . toWorld $ xy
    elementOnmousemove container $ do
        xy <- getXYRelativeTo doc container
        liftIO . sync . pushMouse . MouseMove . toWorld $ xy
    elementOnmouseup container $ do
        xy <- getXYRelativeTo doc container
        liftIO . sanitize Up . sync . pushMouse . MouseUp . toWorld $ xy

    (cx, cy) <- elementPageXY doc container
#ifdef MIN_VERSION_jsaddle
    runJSaddle webView $ do
        document <- jsg "document"
        let getElementById = js1 "getElementById"
            preventDefault = js0 "preventDefault"
            touches        = js "touches"
            changedTouches = js "changedTouches"
            jsLength       = js "length"
            pageX          = js "pageX"
            pageY          = js "pageY"
            addEventListener = js2 "addEventListener"

        c <- document ^. getElementById containerId
        c ^. addEventListener "touchstart" (fun $ \f this [e] -> do
          e ^. preventDefault
          n <- e ^. touches . jsLength >>= deRefVal
          when (n == ValNumber 1) $ do
              t <- (e ^. touches) !! 0
              vx <- t ^. pageX >>= deRefVal
              vy <- t ^. pageY >>= deRefVal
              case (vx, vy) of
                (ValNumber x, ValNumber y) ->
                  liftIO . sanitize Down . sync . pushMouse . MouseDown . toWorld $ ((floor x)-cx, (floor y)-cy)
                _ -> return ())
        c ^. addEventListener "touchmove" (fun $ \f this [e] -> do
          e ^. preventDefault
          n <- e ^. touches . jsLength >>= deRefVal
          when (n == ValNumber 1) $ do
              t <- (e ^. touches) !! 0
              vx <- t ^. pageX >>= deRefVal
              vy <- t ^. pageY >>= deRefVal
              case (vx, vy) of
                (ValNumber x, ValNumber y) ->
                  liftIO . sync . pushMouse . MouseMove . toWorld $ ((floor x)-cx, (floor y)-cy)
                _ -> return ())
        c ^. addEventListener "touchend" (fun $ \f this [e] -> do
          e ^. preventDefault
          n <- e ^. changedTouches . jsLength >>= deRefVal
          when (n == ValNumber 1) $ do
              t <- (e ^. changedTouches) !! 0
              vx <- t ^. pageX >>= deRefVal
              vy <- t ^. pageY >>= deRefVal
              case (vx, vy) of
                (ValNumber x, ValNumber y) ->
                  liftIO . sanitize Up . sync . pushMouse . MouseUp . toWorld $ ((floor x)-cx, (floor y)-cy)
                _ -> return ())
#endif

    -- Instantiate the FRP logic: We give it our mouse event, and it gives us back the
    -- sprite behaviours that tell us what to draw on the screen.
    sprites <- sync (game eMouse)

    -- Add listeners to the sprite behaviours so the FRP output gets drawn on the
    -- web page.
    showAll doc container sprites

showAll :: IsElement elt =>
             Document -> elt -> BehaviorTree [Sprite] -> IO (IO ())
showAll doc container sprites =
    -- Pass the zIndex through as state. The order of the FRP's output determines
    -- what overlaps what. Later elements overlap earlier ones. In CSS this is
    -- drawn correctly by setting the zIndex.
    evalStateT (showEach sprites) (-1000000)
  where
    showEach :: BehaviorTree [Sprite] -> StateT Int IO (IO ())
    showEach (left :++ right) = do
        -- Traverse the tree structure
        unlisten1 <- showEach left
        unlisten2 <- showEach right
        -- Collect event unlisteners.
        return (unlisten1 >> unlisten2)
    showEach (BehaviorNode beh) = do
        -- Each behaviour outputs a list of sprites. For each behaviour we
        -- pre-allocate 1000 zIndex numbers to allow for expansion of the
        -- sprite list per behaviour.
        zIxRoot <- get
        modify (1000+)
        liftIO $ do
            -- Remember the behaviour's last value
            lastRef <- newIORef []
            -- Listen to changes in the value of the behaviour (a list of sprites)
            unlisten <- sync $ listen (values beh) $ \these -> do
                last <- readIORef lastRef
                let toAdd = drop (length last) these
                    toRemove = drop (length these) (map fst last)
                    toModify = zip these last
                    keptImgs = map (\(_, (elt, _)) -> elt) toModify
                    noOfKeptImgs = length keptImgs
                -- If there are fewer elements than last time, we delete the excess ones.
                mapM_ (nodeRemoveChild container . Just) toRemove
                -- If the first n sprites exist in both the old and new list, we
                -- re-use them, and just modify their position and appearance as necessary
                sequence_ $ zipWith (\zIx (newSprite, (elt, oldSprite)) -> do
                        let (oldRect, oldFn) = oldSprite
                            (newRect, newFn) = newSprite
                        when (oldRect /= newRect) $ position  elt newRect zIx
                        when (oldFn /= newFn)     $ associate elt newFn
                    ) [zIxRoot..] toModify
                -- If there are more elements than last time, we create the new ones
                addedImgs <- sequence $ zipWith (\zIx sprite@(rect, fn) -> do
                        Just elt <- fmap castToHTMLElement <$> documentCreateElement doc "img"
                        position elt rect zIx
                        associate elt fn
                        elementSetAttribute elt "ondragstart" "return false"
                        nodeAppendChild container (Just elt)
                        return elt
                    ) [zIxRoot + noOfKeptImgs..] toAdd
                writeIORef lastRef (zip (keptImgs ++ addedImgs) these)
            return unlisten
    -- Set the necessary attributes to position the image according to the specified
    -- rectangle
    position elt rect zIx = do
        elementSetAttribute elt "style" (style origin zIx)
        elementSetAttribute elt "width" (show wid)
        elementSetAttribute elt "height" (show hei)
      where
        (origin, (wid, hei)) = fromWorldRect rect
        style (x, y) zIx = "position:absolute;top:"++show y
                                    ++"px;left:"++show x
                                  ++"px;zIndex:"++show zIx
                                  ++disableTextSelection
        -- See http://stackoverflow.com/questions/826782/css-rule-to-disable-text-selection-highlighting
        disableTextSelection =
            "-webkit-touch-callout:none;"++
            "-webkit-user-select: none;"++
            "-khtml-user-select: none;"++
            "-moz-user-select: none;"++
            "-ms-user-select: none;"++
            "user-select: none"
    -- Associate the image element with a URL, i.e. set its appearance.
    associate elt fn =
        elementSetAttribute elt "src" ("http://ghcjs.github.com/"++fn)

