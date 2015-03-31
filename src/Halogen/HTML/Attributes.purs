-- | This module enumerates some common HTML attributes, and provides additional
-- | helper functions for working with CSS classes.

module Halogen.HTML.Attributes 
  ( ClassName()
  , className
  , runClassName
  
  , AttributeName()
  , attributeName
  , runAttributeName
  
  , EventName()
  , eventName
  , runEventName
  
  , Styles()
  , styles
  , runStyles
  
  , IsAttribute
  , toAttrString
  
  , AttrRepr
  , Attr()
  , runAttr
  
  , attr
  , handler
  
  , alt
  , charset
  , class_
  , classes
  , content
  , for
  , height
  , href
  , httpEquiv
  , id_
  , name
  , rel
  , src
  , target
  , title
  , type_
  , value
  , width
  , disabled
  , enabled
  , checked
  , selected
  , placeholder
  , style
  ) where

import DOM

import Data.Maybe
import Data.Tuple
import Data.Either (either)
import Data.Foreign
import Data.StrMap (StrMap(), toList)
import Data.Monoid (mempty)
import Data.Array (map)
import Data.String (joinWith)
import Data.Traversable (mapAccumL)

import Control.Monad.Eff
import Control.Monad.ST

import Halogen.Internal.VirtualDOM
import Halogen.HTML.Events.Types
import Halogen.HTML.Events.Handler

-- | A wrapper for strings which are used as CSS classes
newtype ClassName = ClassName String

-- Create a class name
className :: String -> ClassName
className = ClassName

-- | Unpack a class name
runClassName :: ClassName -> String
runClassName (ClassName s) = s

-- | A type-safe wrapper for attribute names
-- |
-- | The phantom type `value` describes the type of value which this attribute requires.
newtype AttributeName value = AttributeName String

-- Create an attribute name
attributeName :: forall value. String -> AttributeName value
attributeName = AttributeName

-- | Unpack an attribute name
runAttributeName :: forall value. AttributeName value -> String
runAttributeName (AttributeName s) = s

-- | A type-safe wrapper for event names.
-- |
-- | The phantom type `fields` describes the event type which we can expect to exist on events
-- | corresponding to this name.
newtype EventName (fields :: # *) = EventName String

-- Create an event name
eventName :: forall fields. String -> EventName fields
eventName = EventName

-- | Unpack an event name
runEventName :: forall fields. EventName fields -> String
runEventName (EventName s) = s

-- | A newtype for CSS styles
newtype Styles = Styles (StrMap String)

-- Create CSS styles
styles :: StrMap String -> Styles
styles = Styles

-- | Unpack CSS styles
runStyles :: Styles -> StrMap String
runStyles (Styles m) = m

-- | This type class captures those types which can be used as attribute values.
-- |
-- | `toAttrString` is an alternative to `show`, and is needed by `attr` in the string renderer.
class IsAttribute a where
  toAttrString :: AttributeName a -> a -> String
  
instance stringIsAttribute :: IsAttribute String where
  toAttrString _ s = s
  
instance numberIsAttribute :: IsAttribute Number where
  toAttrString _ n = show n
  
instance booleanIsAttribute :: IsAttribute Boolean where
  toAttrString name true = runAttributeName name
  toAttrString _ false = "" 
  
instance stylesIsAttribute :: IsAttribute Styles where
  toAttrString _ (Styles m) = joinWith "; " $ (\(Tuple key value) -> key <> ": " <> value) <$> toList m

-- | This type class encodes _representations_ of HTML attributes
class (Functor attr) <= AttrRepr attr where
  attr :: forall value i. (IsAttribute value) => AttributeName value -> value -> attr i
  handler :: forall fields i. EventName fields -> (Event fields -> EventHandler (Maybe i)) -> attr i

-- | `Attr` represents an abstract attribute
newtype Attr i = Attr (forall attr. (AttrRepr attr) => attr i)

runAttr :: forall i attr. (AttrRepr attr) => Attr i -> attr i
runAttr (Attr f) = f

instance attrRepr :: AttrRepr Attr where
  attr name value = Attr (attr name value)
  handler name f = Attr (handler name f)

instance functorAttr :: Functor Attr where
  (<$>) f (Attr x) = Attr (f <$> x)

-- Smart constructors

alt :: forall i. String -> Attr i
alt = attr $ attributeName "alt"
     
charset :: forall i. String -> Attr i
charset = attr $ attributeName "charset"

class_ :: forall i. ClassName -> Attr i
class_ = attr (attributeName "className") <<< runClassName

classes :: forall i. [ClassName] -> Attr i
classes ss = attr (attributeName "className") (joinWith " " $ map runClassName ss)

content :: forall i. String -> Attr i
content = attr $ attributeName "content"

for :: forall i. String -> Attr i
for = attr $ attributeName "for"

height :: forall i. Number -> Attr i
height = attr (attributeName "height") <<< show

href :: forall i. String -> Attr i
href = attr $ attributeName "href"

httpEquiv :: forall i. String -> Attr i
httpEquiv = attr $ attributeName "http-equiv"

id_ :: forall i. String -> Attr i
id_ = attr $ attributeName "id"
   
name :: forall i. String -> Attr i
name = attr $ attributeName "name"
       
rel :: forall i. String -> Attr i
rel = attr $ attributeName "rel"
    
src :: forall i. String -> Attr i
src = attr $ attributeName "src"
   
target :: forall i. String -> Attr i
target = attr $ attributeName "target"
   
title :: forall i. String -> Attr i
title = attr $ attributeName "title"
   
type_ :: forall i. String -> Attr i
type_ = attr $ attributeName "type"
   
value :: forall i. String -> Attr i
value = attr $ attributeName "value"
   
width :: forall i. Number -> Attr i
width = attr (attributeName "width") <<< show
   
disabled :: forall i. Boolean -> Attr i
disabled = attr $ attributeName "disabled"
   
enabled :: forall i. Boolean -> Attr i
enabled = disabled <<< not
   
checked :: forall i. Boolean -> Attr i
checked = attr $ attributeName "checked"
   
selected :: forall i. Boolean -> Attr i
selected = attr $ attributeName "selected"
   
placeholder :: forall i. String -> Attr i
placeholder = attr $ attributeName "placeholder"

style :: forall i. Styles -> Attr i
style = attr $ attributeName "style"
