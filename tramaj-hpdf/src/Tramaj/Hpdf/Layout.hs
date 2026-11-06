-- | The pure half of the PDF fold: a tramaj 'Node' becomes a list of pages,
-- each a list of text runs and rules at absolute positions. Nothing here
-- knows about HPDF; font metrics come in as a 'Metrics' record, so the layout
-- can be tested with any width function and drawn by any backend.
--
-- The fold has two steps:
--
-- 1. 'nodeBlocks' reads the tree as a document: a fixed set of tags
--    ('blockTags', 'inlineTags') get a meaning, and any other tag is a plain
--    block container, so an unknown element still shows its content rather
--    than vanishing. Attributes and actions are ignored: a PDF page has no
--    handler to wire an action to.
--
-- 2. 'layoutPages' breaks each paragraph into lines (greedy, at spaces) and
--    the lines into pages.
module Tramaj.Hpdf.Layout
  ( -- * Styles
    Face (..)
  , Style (..)
  , bodyStyle

    -- * Document blocks
  , Inline (..)
  , Block (..)
  , nodeBlocks
  , blockTags
  , inlineTags
  , renderScalar

    -- * Placing blocks on pages
  , Metrics (..)
  , PageSpec (..)
  , a4
  , Placed (..)
  , layoutPages
  , replaceUnencodable
  ) where

import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Tramaj.Json (Json (..), formatFloat, formatInteger, stringify)
import Tramaj.Node (Node (..))

-- Styles ---------------------------------------------------------------------

-- | The six faces the fold uses, each one of the PDF standard 14 fonts
-- (Helvetica and Courier families) in "Tramaj.Hpdf".
data Face = Regular | Bold | Italic | BoldItalic | Mono | MonoBold
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | A face at a size in points. HPDF sizes fonts in whole points.
data Style = Style {styleFace :: Face, styleSize :: Int}
  deriving stock (Eq, Ord, Show)

bodyStyle :: Style
bodyStyle = Style Regular 11

-- Blocks ---------------------------------------------------------------------

-- | A styled run of inline text. A run may hold @\\n@, a forced line break
-- (from @br@, or a newline in @pre@).
data Inline = Inline Style Text
  deriving stock (Eq, Show)

data Block
  = -- | A paragraph: runs wrapped into lines.
    Para
      { paraIndent :: Double
      -- ^ left indent, in points from the left margin
      , paraBefore :: Double
      -- ^ vertical space above, dropped at the top of a page
      , paraAfter :: Double
      -- ^ vertical space below
      , paraMarker :: Maybe Inline
      -- ^ a list bullet or number, set in the gutter left of the indent
      , paraPre :: Bool
      -- ^ preformatted: spaces kept, lines break only at @\\n@ (and at the
      -- right margin, by character, when a line does not fit)
      , paraRuns :: [Inline]
      }
  | -- | A horizontal rule from the indent to the right margin.
    Rule Double
  deriving stock (Eq, Show)

-- | Tags read as blocks with a meaning of their own. Any tag in neither
-- this list nor 'inlineTags' is a block container with no styling.
blockTags :: [Text]
blockTags = ["h1", "h2", "h3", "h4", "h5", "h6", "p", "ul", "ol", "li", "pre", "blockquote", "hr"]

-- | Tags read as inline: their content flows within the surrounding
-- paragraph. @br@ is a forced line break.
inlineTags :: [Text]
inlineTags =
  [ "span", "a", "strong", "b", "em", "i", "code", "kbd", "samp", "var"
  , "small", "sub", "sup", "u", "s", "mark", "abbr", "cite", "q", "time"
  , "label", "button", "br"
  ]

data Ctx = Ctx {ctxStyle :: Style, ctxIndent :: Double, ctxPre :: Bool}

rootCtx :: Ctx
rootCtx = Ctx bodyStyle 0 False

listIndent :: Double
listIndent = 18

-- | Reads a node as a document. A fragment contributes its children with no
-- wrapper; inline content that sits directly in a container is gathered
-- into paragraphs between its block siblings.
nodeBlocks :: Node -> [Block]
nodeBlocks n = containerBlocks rootCtx [n]

-- What one node contributes to its container: inline runs, or whole blocks.
data Piece = PInline Inline | PBlocks [Block]

pieces :: Ctx -> Node -> [Piece]
pieces ctx = \case
  NText v _ -> [PInline (Inline (ctxStyle ctx) (renderScalar v))]
  NFragment cs _ -> concatMap (pieces ctx) cs
  NElement tag _ val cs _
    | tag == "br" -> [PInline (Inline (ctxStyle ctx) "\n")]
    | tag `elem` inlineTags -> concatMap (pieces (inlineCtx tag ctx)) (withValue val cs)
    | otherwise -> [PBlocks (elementBlocks ctx tag (withValue val cs))]

-- | An element with a value slot and no children shows that value as its
-- text, as @tramaj-react@ does; one with both keeps its children.
withValue :: Json -> [Node] -> [Node]
withValue JNull cs = cs
withValue v [] = [NText v Map.empty]
withValue _ cs = cs

inlineCtx :: Text -> Ctx -> Ctx
inlineCtx tag ctx = ctx {ctxStyle = restyle (ctxStyle ctx)}
  where
    restyle st@(Style face size) = case tag of
      t | t `elem` ["strong", "b"] -> Style (bolder face) size
      t | t `elem` ["em", "i", "cite", "var"] -> Style (italic face) size
      t | t `elem` ["code", "kbd", "samp"] -> Style (if face `elem` [Bold, BoldItalic, MonoBold] then MonoBold else Mono) size
      t | t `elem` ["small", "sub", "sup"] -> Style face (max 6 (size - 2))
      _ -> st
    bolder = \case
      Regular -> Bold
      Italic -> BoldItalic
      Mono -> MonoBold
      f -> f
    italic = \case
      Regular -> Italic
      Bold -> BoldItalic
      f -> f

elementBlocks :: Ctx -> Text -> [Node] -> [Block]
elementBlocks ctx tag cs = case tag of
  "hr" -> [Rule (ctxIndent ctx)]
  "p" -> spaced 0 6 (containerBlocks ctx cs)
  "pre" -> spaced 0 6 (containerBlocks ctx {ctxStyle = Style Mono 10, ctxPre = True} cs)
  "blockquote" -> spaced 0 6 (containerBlocks ctx {ctxIndent = ctxIndent ctx + listIndent, ctxStyle = italicOf (ctxStyle ctx)} cs)
  "ul" -> spaced 0 6 (listItems ctx (const "\x2022") cs)
  "ol" -> spaced 0 6 (listItems ctx (\i -> T.pack (show (i :: Int)) <> ".") cs)
  "li" -> item ctx {ctxIndent = ctxIndent ctx + listIndent} "\x2022" cs
  _ | Just size <- lookup tag headingSizes ->
        let s = fromIntegral size
         in spaced (s * 0.6) (s * 0.3) (containerBlocks ctx {ctxStyle = Style Bold size} cs)
  _ -> containerBlocks ctx cs
  where
    italicOf (Style f s) = Style (if f == Bold then BoldItalic else if f == Regular then Italic else f) s

headingSizes :: [(Text, Int)]
headingSizes = [("h1", 22), ("h2", 18), ("h3", 15), ("h4", 13), ("h5", 12), ("h6", 11)]

-- | The children of @ul@\/@ol@. Each @li@ child is an item with the next
-- marker; anything else in the list (text, a nested list not wrapped in a
-- @li@) is laid out at the list's indent without a marker. Fragments are
-- looked through, so a list built with @map@ numbers its items in order.
listItems :: Ctx -> (Int -> Text) -> [Node] -> [Block]
listItems ctx marker = go 1 . concatMap flatten
  where
    inner = ctx {ctxIndent = ctxIndent ctx + listIndent}
    flatten (NFragment cs _) = concatMap flatten cs
    flatten n = [n]
    go _ [] = []
    go i (NElement "li" _ val cs _ : rest) = item inner (marker i) (withValue val cs) ++ go (i + 1) rest
    go i (n : rest) = containerBlocks inner [n] ++ go i rest

-- | A list item: its blocks, with the marker on the first line of the first
-- one (or on an empty line of its own when the item opens with a rule).
item :: Ctx -> Text -> [Node] -> [Block]
item ctx marker cs = case containerBlocks ctx cs of
  p@Para {} : rest -> p {paraMarker = Just m} : rest
  bs -> emptyPara {paraMarker = Just m} : bs
  where
    m = Inline (ctxStyle ctx) marker
    emptyPara = Para (ctxIndent ctx) 0 0 Nothing False []

-- | Space above the first block and below the last.
spaced :: Double -> Double -> [Block] -> [Block]
spaced before after bs = case bs of
  [] -> []
  _ -> onLast (onFirst bs)
  where
    onFirst (p@Para {} : rest) = p {paraBefore = max before (paraBefore p)} : rest
    onFirst other = other
    onLast xs = case reverse xs of
      (p@Para {} : rest) -> reverse (p {paraAfter = max after (paraAfter p)} : rest)
      _ -> xs

-- | Lays out a sequence of sibling nodes: consecutive inline pieces become
-- one paragraph, block pieces stand as they are.
containerBlocks :: Ctx -> [Node] -> [Block]
containerBlocks ctx = flush . foldl' step ([], []) . concatMap (pieces ctx)
  where
    step (done, pending) = \case
      PInline r -> (done, r : pending)
      PBlocks bs -> (reverse bs ++ paraOf pending ++ done, [])
    flush (done, pending) = reverse (paraOf pending ++ done)
    paraOf [] = []
    paraOf rs
      | not (ctxPre ctx) && all blank rs = []
      | otherwise = [Para (ctxIndent ctx) 0 0 Nothing (ctxPre ctx) (reverse rs)]
    blank (Inline _ t) = T.all (`elem` [' ', '\t', '\r']) t

-- | How a value in text position becomes characters: a string is itself,
-- @null@ is nothing, a boolean is @true@\/@false@, an integer is its digits
-- and a float always has a fraction or an exponent (@3.0@), as @str@ writes
-- them. Anything structured is compact JSON.
renderScalar :: Json -> Text
renderScalar = \case
  JString s -> s
  JNull -> ""
  JBool b -> if b then "true" else "false"
  JInt i -> formatInteger i
  JFloat d -> formatFloat d
  other -> stringify other

-- Pages ----------------------------------------------------------------------

-- | Font metrics, supplied by the backend.
data Metrics = Metrics
  { textWidth :: Style -> Text -> Double
  -- ^ advance width of a run, in points
  , encodable :: Style -> Char -> Bool
  -- ^ whether the face can show the character; others are replaced by
  -- 'replaceUnencodable' before measuring
  }

-- | Page size and margins, in points.
data PageSpec = PageSpec
  { pageWidth :: Double
  , pageHeight :: Double
  , pageMargin :: Double
  }
  deriving stock (Eq, Show)

-- | A4 portrait with 2 cm margins.
a4 :: PageSpec
a4 = PageSpec 595.28 841.89 56.69

-- | Something drawn on a page, at absolute coordinates with the origin at
-- the bottom left, as PDF has it. Text is placed by its baseline's start.
data Placed
  = PlacedText Style Double Double Text
  | PlacedRule Double Double Double
  -- ^ from x, to x, at y
  deriving stock (Eq, Show)

-- | The substitute for a character the font cannot show.
replaceUnencodable :: Metrics -> Style -> Text -> Text
replaceUnencodable m st = T.map (\c -> if c == '\n' || encodable m st c then c else '?')

lineHeight :: Style -> Double
lineHeight st = 1.25 * fromIntegral (styleSize st)

data Cursor = Cursor {curPages :: [[Placed]], curPage :: [Placed], curY :: Double, curFresh :: Bool}

-- | Breaks blocks into lines and lines into pages. Always at least one page,
-- possibly empty.
layoutPages :: Metrics -> PageSpec -> [Block] -> [[Placed]]
layoutPages m spec blocks = finish (foldl' block start blocks)
  where
    top = pageHeight spec - pageMargin spec
    bottom = pageMargin spec
    left = pageMargin spec
    right = pageWidth spec - pageMargin spec
    start = Cursor [] [] top True
    finish c = reverse (reverse (curPage c) : curPages c)

    newPage c = c {curPages = reverse (curPage c) : curPages c, curPage = [], curY = top, curFresh = True}
    -- Moves down by h, starting a new page first if h does not fit.
    room h c = if curY c - h < bottom && not (curFresh c) then newPage c else c
    skip h c = if curFresh c then c else c {curY = curY c - h}
    put ps c = c {curPage = reverse ps ++ curPage c, curFresh = False}

    block c = \case
      Rule indent ->
        let c' = room 12 (skip 0 c)
            y = curY c' - 6
         in (put [PlacedRule (left + indent) right y] c') {curY = y - 6}
      p@Para {} ->
        let x0 = left + paraIndent p
            ls = breakLines m (paraPre p) (right - x0) [Inline st (replaceUnencodable m st t) | Inline st t <- paraRuns p]
            -- An empty paragraph that carries a marker still takes one line.
            ls' = if null ls && isJust (paraMarker p) then [Line [] (lineHeight (markerStyle p))] else ls
            c1 = skip (paraBefore p) c
            c2 = foldl' (placeLine x0) c1 (zip [0 :: Int ..] ls')
         in if null ls' then c1 else skip (paraAfter p) c2
        where
          markerStyle q = maybe bodyStyle (\(Inline st _) -> st) (paraMarker q)
          placeLine x0 c (i, Line frags h) =
            let c' = room h c
                baseline = curY c' - 0.8 * h
                marker = case paraMarker p of
                  Just (Inline st t) | i == 0 ->
                    let t' = replaceUnencodable m st t
                     in [PlacedText st (x0 - textWidth m st t' - 4) baseline t']
                  _ -> []
                texts = [PlacedText st (x0 + dx) baseline t | (st, dx, t) <- frags]
             in (put (marker ++ texts) c') {curY = curY c' - h}

-- A laid-out line: fragments at x offsets from the paragraph's left edge,
-- and the line's height.
data Line = Line [(Style, Double, Text)] Double

-- One unit of line breaking.
data Tok = TWord Style Text | TSpace Style | TBreak Style

tokens :: Bool -> [Inline] -> [Tok]
tokens pre = concatMap tok
  where
    tok (Inline st t) = intercalate [TBreak st] (map (line st) (T.splitOn "\n" t))
    -- Preformatted text keeps a line whole; otherwise a line is words and
    -- spaces, and a run of whitespace is one space.
    line st l
      | pre = [TWord st l]
      | otherwise = [if T.head g == ' ' then TSpace st else TWord st g | g <- T.groupBy sameKind (T.map tab l)]
    tab c = if c == '\t' || c == '\r' then ' ' else c
    sameKind a b = (a == ' ') == (b == ' ')

-- | Greedy line breaking within @avail@ points.
breakLines :: Metrics -> Bool -> Double -> [Inline] -> [Line]
breakLines m pre avail runs = done (foldl' step (St [] [] 0 Nothing Nothing) (tokens pre runs))
  where
    w = textWidth m
    step s = \case
      TBreak st -> endLine (s {stLast = Just (fromMaybe st (stLast s))})
      TSpace st -> if null (stCur s) then s else s {stSpace = Just st}
      TWord st t
        | fits s st t -> addWord s st t
        | not (null (stCur s)) -> step (endLine s) (TWord st t)
        | otherwise -> splitLong s st t
    spaceW s = maybe 0 (\st -> w st " ") (stSpace s)
    fits s st t = stX s + spaceW s + w st t <= avail
    addWord s st t =
      let s' = case stSpace s of
            Just sp -> s {stCur = (sp, stX s, " ") : stCur s, stX = stX s + w sp " "}
            Nothing -> s
       in s' {stCur = (st, stX s', t) : stCur s', stX = stX s' + w st t, stSpace = Nothing, stLast = Just st}
    -- A word wider than a whole line is cut by character.
    splitLong s st t =
      let n = max 1 (length (takeWhile (\k -> w st (T.take k t) <= avail) [1 .. T.length t]))
          (h, rest) = T.splitAt n t
          s' = addWord s {stSpace = Nothing} st h
       in if T.null rest then s' else step (endLine s') (TWord st rest)
    endLine s =
      let frags = merge (reverse (stCur s))
          h = case [lineHeight st | (st, _, _) <- frags] of
            [] -> lineHeight (fromMaybe bodyStyle (stLast s))
            hs -> maximum hs
       in s {stLines = Line frags h : stLines s, stCur = [], stX = 0, stSpace = Nothing}
    done s
      | null (stCur s) = reverse (stLines s)
      | otherwise = reverse (stLines (endLine s))
    -- Adjacent fragments in one style are drawn as one run.
    merge = \case
      (a@(sa, xa, ta) : b@(sb, _, tb) : rest)
        | sa == sb -> merge ((sa, xa, ta <> tb) : rest)
        | otherwise -> a : merge (b : rest)
      xs -> xs

data St = St
  { stLines :: [Line]
  , stCur :: [(Style, Double, Text)]
  , stX :: Double
  , stSpace :: Maybe Style
  , stLast :: Maybe Style
  }
