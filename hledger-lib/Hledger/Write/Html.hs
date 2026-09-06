{- |
HTML writing helpers.
This module would ideally hide the details of which HTML library is used, but it doesn't yet.

Currently hledger-web uses blaze-html, but hledger CLI reports use lucid.
lucid has a more usable API than blaze-html (https://chrisdone.com/posts/lucid).
lucid2's is even better.
lucid* has no pretty-printing renderer, so for human readability
we inject raw newlines between elements (see 'nl').

-}

{-# LANGUAGE OverloadedStrings #-}

module Hledger.Write.Html (
  L.toHtml,
  Html,
  formatRow,
  formatTitle,
  htmlAsText,
  htmlAsLazyText,
  nl,
  styledTableHtml,
  titledTableHtml,
  tests_Hledger_Write_Html
  ) where

import Data.Text qualified as T (Text)
import Data.Text.Lazy qualified as TL (Text, toStrict)
import Lucid qualified as L (renderText, toHtml)
import Test.Tasty (testGroup)

import Hledger.Write.Html.Lucid (Html, formatRow, formatTitle, nl, styledTableHtml, titledTableHtml)


htmlAsText :: Html -> T.Text
htmlAsText = TL.toStrict . L.renderText

htmlAsLazyText :: Html -> TL.Text
htmlAsLazyText = L.renderText

tests_Hledger_Write_Html = testGroup "Write.Html" [
  ]
