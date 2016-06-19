module Halogen.Driver
  ( Driver
  , runUI
  ) where

import Prelude

import Control.Bind ((=<<))
import Control.Coroutine (await)
import Control.Coroutine.Stalling (($$?))
import Control.Coroutine.Stalling as SCR
import Control.Monad (when)
import Control.Monad.Aff (Aff, forkAff, forkAll)
import Control.Monad.Aff.AVar (AVar, makeVar, makeVar', putVar, takeVar, modifyVar)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Free (runFreeM)
import Control.Monad.Rec.Class (forever, tailRecM)
import Control.Monad.State (runState)
import Control.Monad.Trans (lift)
import Control.Plus (empty)

import Data.Either (Either(..))
import Data.Foldable (class Foldable, foldr)
import Data.List (List(Nil), (:))
import Data.Maybe (Maybe(..), maybe, isJust, isNothing)
import Data.Tuple (Tuple(..))

import DOM.HTML.Types (HTMLElement, htmlElementToNode)
import DOM.Node.Node (appendChild)

import Halogen.Component (Component, ComponentDSL, renderComponent, queryComponent, initializeComponent)
import Halogen.Component.Hook (Hook(..), Finalized, runFinalized)
import Halogen.Effects (HalogenEffects)
import Halogen.HTML.Renderer.VirtualDOM (renderTree)
import Halogen.Internal.VirtualDOM (VTree, createElement, diff, patch)
import Halogen.Query (HalogenF, HalogenFP(..))
import Halogen.Query.HalogenF (RenderPending(..))
import Halogen.Query.EventSource (runEventSource)
import Halogen.Query.StateF (StateF(..), stateN)

-- | Type alias for driver functions generated by `runUI` - a driver takes an
-- | input of the query algebra (`f`) and returns an `Aff` that returns when
-- | query has been fulfilled.
type Driver f eff = f ~> (Aff (HalogenEffects eff))

-- | Type alias used internally to track the driver's persistent state.
type DriverState s =
  { node :: HTMLElement
  , vtree :: VTree
  , state :: s
  , renderPending :: Boolean
  , renderPaused :: Boolean
  }


-- | This function is the main entry point for a Halogen based UI, taking a root
-- | component, initial state, and HTML element to attach the rendered component
-- | to.
-- |
-- | The returned "driver" function can be used to send actions and requests
-- | into the component hierarchy, allowing the outside world to communicate
-- | with the UI.
runUI
  :: forall s f eff
   . Component s f (Aff (HalogenEffects eff))
  -> s
  -> HTMLElement
  -> Aff (HalogenEffects eff) (Driver f eff)
runUI c s element = _.driver <$> do
  ref <- makeVar
  let rc = renderComponent c s
      dr = driver ref :: Driver f eff
      vtree = renderTree dr rc.tree
      node = createElement vtree
  putVar ref
    { node: node
    , vtree: vtree
    , state: rc.state
    , renderPending: false
    , renderPaused: true
    }
  liftEff $ appendChild (htmlElementToNode node) (htmlElementToNode element)
  forkAll $ onInitializers dr rc.hooks
  forkAff $ maybe (pure unit) dr (initializeComponent c)
  modifyVar _ { renderPaused = false } ref
  flushRender ref
  pure { driver: dr }

  where

  driver :: AVar (DriverState s) -> Driver f eff
  driver ref q = do
    rpRef <- makeVar' Nothing
    x <- runFreeM (eval ref rpRef) (queryComponent c q)
    rp <- takeVar rpRef
    when (isJust rp) $ render ref
    pure x

  eval
    :: AVar (DriverState s)
    -> AVar (Maybe RenderPending)
    -> (HalogenF s f (Aff (HalogenEffects eff))) ~> (Aff (HalogenEffects eff))
  eval ref rpRef h =
    case h of
      StateHF i -> do
        ds <- takeVar ref
        case i of
          Get k -> do
            putVar ref ds
            pure (k ds.state)
          Modify f next -> do
            rp <- takeVar rpRef
            putVar ref $ ds { state = f ds.state }
            putVar rpRef $ Just Pending
            pure next
      SubscribeHF es next -> do
        let producer = runEventSource es
            consumer = forever (lift <<< driver ref =<< await)
        forkAff $ SCR.runStallingProcess (producer $$? consumer)
        pure next
      RenderHF p next -> do
        modifyVar (const p) rpRef
        when (isNothing p) $ render ref
        pure next
      RenderPendingHF k -> do
        rp <- takeVar rpRef
        putVar rpRef rp
        pure $ k rp
      QueryHF q -> do
        rp <- takeVar rpRef
        when (isJust rp) $ render ref
        putVar rpRef Nothing
        q
      HaltHF -> empty

  driver'
    :: forall s' f'
     . f' ~> (ComponentDSL s' f' (Aff (HalogenEffects eff)))
    -> s'
    -> f' Unit
    -> Aff (HalogenEffects eff) Unit
  driver' e s i = do
    ref <- makeVar' s
    flip runFreeM (e i) \h ->
      case h of
        StateHF i -> do
          ds <- takeVar ref
          case runState (stateN i) ds of
            Tuple i' s' -> do
              putVar ref s'
              pure i'
        SubscribeHF _ next -> pure next
        RenderHF p next -> pure next
        RenderPendingHF k -> pure $ k Nothing
        QueryHF q -> q
        HaltHF -> empty

  render :: AVar (DriverState s) -> Aff (HalogenEffects eff) Unit
  render ref = do
    ds <- takeVar ref
    if ds.renderPaused
      then putVar ref $ ds { renderPending = true }
      else do
        let rc = renderComponent c ds.state
            vtree' = renderTree (driver ref) rc.tree
        node' <- liftEff $ patch (diff ds.vtree vtree') ds.node
        putVar ref
          { node: node'
          , vtree: vtree'
          , state: rc.state
          , renderPending: false
          , renderPaused: true
          }
        forkAll $ onFinalizers (runFinalized driver') rc.hooks
        forkAll $ onInitializers (driver ref) rc.hooks
        modifyVar _ { renderPaused = false } ref
        flushRender ref

  flushRender :: AVar (DriverState s) -> Aff (HalogenEffects eff) Unit
  flushRender = tailRecM \ref -> do
    ds <- takeVar ref
    putVar ref ds
    if not ds.renderPending
      then pure (Right unit)
      else do
        render ref
        pure (Left ref)

onInitializers
  :: forall m f g r
   . (Foldable m)
  => (f Unit -> r)
  -> m (Hook f g)
  -> List r
onInitializers f = foldr go Nil
  where
  go (PostRender a) as = f a : as
  go _              as = as

onFinalizers
  :: forall m f g r
   . (Foldable m)
  => (Finalized g -> r)
  -> m (Hook f g)
  -> List r
onFinalizers f = foldr go Nil
  where
  go (Finalized a)  as = f a : as
  go _              as = as
