{-# LANGUAGE OverloadedStrings #-}
{- |
HTML writing helpers using lucid.
-}

module Hledger.Write.Html.Lucid (
    Html,
    L.toHtml,
    styledTableHtml,
    titledTableHtml,
    formatRow,
    formatCell,
    formatTitleRow,
    ) where

import           Control.Monad (unless)
import           Data.Foldable (traverse_)
import           Data.List (intersperse)
import           Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Lucid.Base qualified as L
import Lucid qualified as L

import Hledger.Write.Html.Attribute qualified as Attr
import           Hledger.Write.Html.HtmlCommon
import           Hledger.Write.Spreadsheet (Type(..), Style(..), Emphasis(..), Cell(..))
import Hledger.Write.Spreadsheet qualified as Spr


type Html = L.Html ()

-- | Export spreadsheet table data as HTML table.
-- This is derived from <https://hackage.haskell.org/package/classify-frog-0.2.4.3/src/src/Spreadsheet/Format.hs>
styledTableHtml :: (Lines border) => [[Cell border Html]] -> Html
styledTableHtml = titledTableHtml Text.empty

-- | Like 'styledTableHtml', but with the given report title, if non-empty,
-- as a heading row above the table.
titledTableHtml :: (Lines border) => Text.Text -> [[Cell border Html]] -> Html
titledTableHtml title table = do
    -- the builtin styles, then the optional user stylesheet so it can override them
    L.style_ Attr.tableStylesheet
    L.link_ [L.rel_ "stylesheet", L.href_ "hledger.css"]
    L.table_ $ do
        unless (Text.null title) $
            formatTitleRow (maybe 0 length $ listToMaybe table) title
        traverse_ formatRow table

formatRow:: (Lines border) => [Cell border Html] -> Html
formatRow = L.tr_ . traverse_ formatCell

-- | Render a report title as a table heading row spanning the given number of columns.
formatTitleRow :: Int -> Text.Text -> Html
formatTitleRow numcolumns title =
    L.tr_ $ L.th_ [L.colspan_ $ Text.pack $ show numcolumns, L.style_ Attr.alignleft] $
        L.h2_ $ L.toHtml title

formatCell :: (Lines border) => Cell border Html -> Html
formatCell cell =
    -- Wrap amounts in <span class="amount">, one per amount,
    -- so eg wrapping within amounts can be prevented with css.
    let amountSpan = L.span_ [L.class_ "amount"] in
    let str =
            case cellParts cell of
                [] -> case cellType cell of
                    TypeAmount _ -> amountSpan $ cellContent cell
                    _            -> cellContent cell
                parts ->
                    mconcat $ intersperse (L.toHtml (", "::Text.Text)) $
                    map amountSpan parts in
    let content =
            if Text.null $ cellAnchor cell
                then str
                else L.a_ [L.href_ $ cellAnchor cell] str in
    let style =
            case borderStyles cell of
                [] -> []
                ss -> [L.style_ $ Attr.concatStyles ss] in
    -- Mark date cells with a "date" class, so eg wrapping within dates
    -- can be prevented with css.
    let class_ =
            map (L.class_ . Text.unwords) $
            filter (not . null) $
            [filter (not . Text.null) $
             Spr.textFromClass (cellClass cell) :
             ["date" | cellType cell == TypeDate]] in
    let span_ makeCell attrs cont =
            case Spr.cellSpan cell of
                Spr.NoSpan -> makeCell attrs cont
                Spr.Covered -> pure ()
                Spr.SpanHorizontal n ->
                    makeCell (L.colspan_ (Text.pack $ show n) : attrs) cont
                Spr.SpanVertical n ->
                    makeCell (L.rowspan_ (Text.pack $ show n) : attrs) cont
            in
    case cellStyle cell of
        Head -> span_ L.th_ (style++class_) content
        Body emph ->
            let align =
                    case cellType cell of
                        TypeString -> []
                        TypeDate -> []
                        _ -> [L.makeAttribute "align" "right"]
                valign =
                    case Spr.cellSpan cell of
                        Spr.SpanVertical n ->
                            if n>1
                                then [L.makeAttribute "valign" "top"]
                                else []
                        _ -> []
                withEmph =
                    case emph of
                        Item -> id
                        Total -> L.b_
            in  span_ L.td_ (style++align++valign++class_) $
                withEmph content

