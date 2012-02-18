{-
Copyright (C) 2008-2010 John MacFarlane <jgm@berkeley.edu>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module      : Text.Pandoc.Writers.PseudoPod 
   Copyright   : Copyright (C) 2012 Jess Robinson
   License     : GNU GPL, version 2 or above 

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

Conversion of 'Pandoc' documents to PseudoPod markup.

PseudoPod:  <http://www.mediawiki.org/wiki/PseudoPod>
-}
module Text.Pandoc.Writers.PseudoPod ( writePseudoPod ) where
import Text.Pandoc.Definition
import Text.Pandoc.Shared 
import Text.Pandoc.Templates (renderTemplate)
import Text.Pandoc.XML ( escapeStringForXML )
import Data.List ( intersect, intercalate )
import Network.URI ( isURI )
import Control.Monad.State

data WriterState = WriterState {
    stNotes     :: Bool            -- True if there are notes
  , stListLevel :: [Char]          -- String at beginning of list items, e.g. "**"
  , stUseTags   :: Bool            -- True if we should use HTML tags because we're in a complex list
  }

-- | Convert Pandoc to PseudoPod.
writePseudoPod :: WriterOptions -> Pandoc -> String
writePseudoPod opts document = 
  evalState (pandocToPseudoPod opts document) 
            (WriterState { stNotes = False, stListLevel = [], stUseTags = False }) 

-- | Return PseudoPod representation of document.
pandocToPseudoPod :: WriterOptions -> Pandoc -> State WriterState String
pandocToPseudoPod opts (Pandoc _ blocks) = do
  body <- blockListToPseudoPod opts blocks
  notesExist <- get >>= return . stNotes
  let notes = if notesExist
                 then "\n<references />"
                 else "" 
  let main = body ++ notes
  let context = writerVariables opts ++
                [ ("body", main) ] ++
                [ ("toc", "yes") | writerTableOfContents opts ]
  if writerStandalone opts
     then return $ renderTemplate context $ writerTemplate opts
     else return main

-- | Escape special characters for PseudoPod.
escapeString :: String -> String
escapeString =  escapeStringForXML

-- | Convert Pandoc block element to PseudoPod. 
blockToPseudoPod :: WriterOptions -- ^ Options
                -> Block         -- ^ Block element
                -> State WriterState String 

blockToPseudoPod _ Null = return ""

blockToPseudoPod opts (Plain inlines) = 
  inlineListToPseudoPod opts inlines

blockToPseudoPod opts (Para [Image txt (src,tit)]) = do
  capt <- inlineListToPseudoPod opts txt 
  let opt = if null txt
               then ""
               else "|alt=" ++ if null tit then capt else tit ++
                    "|caption " ++ capt
  return $ "[[Image:" ++ src ++ "|frame|none" ++ opt ++ "]]\n"

blockToPseudoPod opts (Para inlines) = do
  useTags <- get >>= return . stUseTags
  listLevel <- get >>= return . stListLevel
  contents <- inlineListToPseudoPod opts inlines
  return $ if useTags
              then  "<p>" ++ contents ++ "</p>"
              else contents ++ if null listLevel then "\n" else ""

blockToPseudoPod _ (RawBlock "mediawiki" str) = return str
blockToPseudoPod _ (RawBlock "html" str) = return str
blockToPseudoPod _ (RawBlock _ _) = return ""

blockToPseudoPod _ HorizontalRule = return "\n-----\n"

-- | =head X <content> - DONE
blockToPseudoPod opts (Header level inlines) = do
  contents <- inlineListToPseudoPod opts inlines
  return $ "=head" ++ show level ++ " "  ++ contents ++ "\n"

-- | C<> or indented ?
blockToPseudoPod _ (CodeBlock (_,classes,_) str) = do
  let at  = classes `intersect` ["actionscript", "ada", "apache", "applescript", "asm", "asp",
                       "autoit", "bash", "blitzbasic", "bnf", "c", "c_mac", "caddcl", "cadlisp", "cfdg", "cfm",
                       "cpp", "cpp-qt", "csharp", "css", "d", "delphi", "diff", "div", "dos", "eiffel", "fortran",
                       "freebasic", "gml", "groovy", "html4strict", "idl", "ini", "inno", "io", "java", "java5",
                       "javascript", "latex", "lisp", "lua", "matlab", "mirc", "mpasm", "mysql", "nsis", "objc",
                       "ocaml", "ocaml-brief", "oobas", "oracle8", "pascal", "perl", "php", "php-brief", "plsql",
                       "python", "qbasic", "rails", "reg", "robots", "ruby", "sas", "scheme", "sdlbasic",
                       "smalltalk", "smarty", "sql", "tcl", "", "thinbasic", "tsql", "vb", "vbnet", "vhdl", 
                       "visualfoxpro", "winbatch", "xml", "xpp", "z80"]
  let (beg, end) = if null at
                      then ("<pre" ++ if null classes then ">" else " class=\"" ++ unwords classes ++ "\">", "</pre>")
                      else ("<source lang=\"" ++ head at ++ "\">", "</source>")
  return $ beg ++ escapeString str ++ end

blockToPseudoPod opts (BlockQuote blocks) = do
  contents <- blockListToPseudoPod opts blocks
  return $ "<blockquote>" ++ contents ++ "</blockquote>" 

blockToPseudoPod opts (Table capt aligns widths headers rows') = do
  let alignStrings = map alignmentToString aligns
  captionDoc <- if null capt
                   then return ""
                   else do
                      c <- inlineListToPseudoPod opts capt
                      return $ "<caption>" ++ c ++ "</caption>\n"
  let percent w = show (truncate (100*w) :: Integer) ++ "%"
  let coltags = if all (== 0.0) widths
                   then ""
                   else unlines $ map
                         (\w -> "<col width=\"" ++ percent w ++ "\" />") widths
  head' <- if all null headers
              then return ""
              else do
                 hs <- tableRowToPseudoPod opts alignStrings 0 headers
                 return $ "<thead>\n" ++ hs ++ "\n</thead>\n"
  body' <- zipWithM (tableRowToPseudoPod opts alignStrings) [1..] rows'
  return $ "<table>\n" ++ captionDoc ++ coltags ++ head' ++
            "<tbody>\n" ++ unlines body' ++ "</tbody>\n</table>\n"

blockToPseudoPod opts x@(BulletList items) = do
  oldUseTags <- get >>= return . stUseTags
  let useTags = oldUseTags || not (isSimpleList x)
  if useTags
     then do
        modify $ \s -> s { stUseTags = True }
        contents <- mapM (listItemToPseudoPod opts) items
        modify $ \s -> s { stUseTags = oldUseTags }
        return $ "<ul>\n" ++ vcat contents ++ "</ul>\n"
     else do
        modify $ \s -> s { stListLevel = stListLevel s ++ "*" }
        contents <- mapM (listItemToPseudoPod opts) items
        modify $ \s -> s { stListLevel = init (stListLevel s) }
        return $ vcat contents ++ "\n"

blockToPseudoPod opts x@(OrderedList attribs items) = do
  oldUseTags <- get >>= return . stUseTags
  let useTags = oldUseTags || not (isSimpleList x)
  if useTags
     then do
        modify $ \s -> s { stUseTags = True }
        contents <- mapM (listItemToPseudoPod opts) items
        modify $ \s -> s { stUseTags = oldUseTags }
        return $ "<ol" ++ listAttribsToString attribs ++ ">\n" ++ vcat contents ++ "</ol>\n"
     else do
        modify $ \s -> s { stListLevel = stListLevel s ++ "#" }
        contents <- mapM (listItemToPseudoPod opts) items
        modify $ \s -> s { stListLevel = init (stListLevel s) }
        return $ vcat contents ++ "\n"

blockToPseudoPod opts x@(DefinitionList items) = do
  oldUseTags <- get >>= return . stUseTags
  let useTags = oldUseTags || not (isSimpleList x)
  if useTags
     then do
        modify $ \s -> s { stUseTags = True }
        contents <- mapM (definitionListItemToPseudoPod opts) items
        modify $ \s -> s { stUseTags = oldUseTags }
        return $ "<dl>\n" ++ vcat contents ++ "</dl>\n"
     else do
        modify $ \s -> s { stListLevel = stListLevel s ++ ";" }
        contents <- mapM (definitionListItemToPseudoPod opts) items
        modify $ \s -> s { stListLevel = init (stListLevel s) }
        return $ vcat contents ++ "\n"

-- Auxiliary functions for lists:

-- | Convert ordered list attributes to HTML attribute string
listAttribsToString :: ListAttributes -> String
listAttribsToString (startnum, numstyle, _) =
  let numstyle' = camelCaseToHyphenated $ show numstyle
  in  (if startnum /= 1
          then " start=\"" ++ show startnum ++ "\""
          else "") ++
      (if numstyle /= DefaultStyle
          then " style=\"list-style-type: " ++ numstyle' ++ ";\""
          else "")

-- | Convert bullet or ordered list item (list of blocks) to PseudoPod.
listItemToPseudoPod :: WriterOptions -> [Block] -> State WriterState String
listItemToPseudoPod opts items = do
  contents <- blockListToPseudoPod opts items
  useTags <- get >>= return . stUseTags
  if useTags
     then return $ "<li>" ++ contents ++ "</li>"
     else do
       marker <- get >>= return . stListLevel
       return $ marker ++ " " ++ contents

-- | Convert definition list item (label, list of blocks) to PseudoPod.
definitionListItemToPseudoPod :: WriterOptions
                             -> ([Inline],[[Block]]) 
                             -> State WriterState String
definitionListItemToPseudoPod opts (label, items) = do
  labelText <- inlineListToPseudoPod opts label
  contents <- mapM (blockListToPseudoPod opts) items
  useTags <- get >>= return . stUseTags
  if useTags
     then return $ "<dt>" ++ labelText ++ "</dt>\n" ++
           (intercalate "\n" $ map (\d -> "<dd>" ++ d ++ "</dd>") contents)
     else do
       marker <- get >>= return . stListLevel
       return $ marker ++ " " ++ labelText ++ "\n" ++
           (intercalate "\n" $ map (\d -> init marker ++ ": " ++ d) contents)

-- | True if the list can be handled by simple wiki markup, False if HTML tags will be needed.
isSimpleList :: Block -> Bool
isSimpleList x =
  case x of
       BulletList items                 -> all isSimpleListItem items
       OrderedList (num, sty, _) items  -> all isSimpleListItem items &&
                                            num == 1 && sty `elem` [DefaultStyle, Decimal]
       DefinitionList items             -> all isSimpleListItem $ concatMap snd items 
       _                                -> False

-- | True if list item can be handled with the simple wiki syntax.  False if
--   HTML tags will be needed.
isSimpleListItem :: [Block] -> Bool
isSimpleListItem []  = True
isSimpleListItem [x] =
  case x of
       Plain _           -> True
       Para  _           -> True
       BulletList _      -> isSimpleList x
       OrderedList _ _   -> isSimpleList x
       DefinitionList _  -> isSimpleList x
       _                 -> False
isSimpleListItem [x, y] | isPlainOrPara x =
  case y of
       BulletList _      -> isSimpleList y
       OrderedList _ _   -> isSimpleList y
       DefinitionList _  -> isSimpleList y
       _                 -> False
isSimpleListItem _ = False

isPlainOrPara :: Block -> Bool
isPlainOrPara (Plain _) = True
isPlainOrPara (Para  _) = True
isPlainOrPara _         = False

-- | Concatenates strings with line breaks between them.
vcat :: [String] -> String
vcat = intercalate "\n"

-- Auxiliary functions for tables:

tableRowToPseudoPod :: WriterOptions
                    -> [String]
                    -> Int
                    -> [[Block]]
                    -> State WriterState String
tableRowToPseudoPod opts alignStrings rownum cols' = do
  let celltype = if rownum == 0 then "th" else "td"
  let rowclass = case rownum of
                      0                  -> "header"
                      x | x `rem` 2 == 1 -> "odd"
                      _                  -> "even"
  cols'' <- sequence $ zipWith 
            (\alignment item -> tableItemToPseudoPod opts celltype alignment item) 
            alignStrings cols'
  return $ "<tr class=\"" ++ rowclass ++ "\">\n" ++ unlines cols'' ++ "</tr>"

alignmentToString :: Alignment -> [Char]
alignmentToString alignment = case alignment of
                                 AlignLeft    -> "left"
                                 AlignRight   -> "right"
                                 AlignCenter  -> "center"
                                 AlignDefault -> "left"

tableItemToPseudoPod :: WriterOptions
                     -> String
                     -> String
                     -> [Block]
                     -> State WriterState String
tableItemToPseudoPod opts celltype align' item = do
  let mkcell x = "<" ++ celltype ++ " align=\"" ++ align' ++ "\">" ++
                    x ++ "</" ++ celltype ++ ">"
  contents <- blockListToPseudoPod opts item
  return $ mkcell contents

-- | Convert list of Pandoc block elements to PseudoPod.
blockListToPseudoPod :: WriterOptions -- ^ Options
                    -> [Block]       -- ^ List of block elements
                    -> State WriterState String 
blockListToPseudoPod opts blocks =
  mapM (blockToPseudoPod opts) blocks >>= return . vcat

-- | Convert list of Pandoc inline elements to PseudoPod.
inlineListToPseudoPod :: WriterOptions -> [Inline] -> State WriterState String
inlineListToPseudoPod opts lst =
  mapM (inlineToPseudoPod opts) lst >>= return . concat

-- | Convert Pandoc inline element to PseudoPod.
inlineToPseudoPod :: WriterOptions -> Inline -> State WriterState String

-- | B< > - DONE
inlineToPseudoPod opts (Emph lst) = do 
  contents <- inlineListToPseudoPod opts lst
  return $ "B<" ++ contents ++ ">" 

-- | B< > - FIXME
inlineToPseudoPod opts (Strong lst) = do
  contents <- inlineListToPseudoPod opts lst
  return $ "B<" ++ contents ++ ">"

-- | - FIXME
inlineToPseudoPod opts (Strikeout lst) = inlineListToPseudoPod opts lst
{-
inlineToPseudoPod opts (Strikeout lst) = do
  contents <- inlineListToPseudoPod opts lst
  return $ "strike<" ++ contents ++ "> FIXME"
-}

-- | G<> - DONE
inlineToPseudoPod opts (Superscript lst) = do
  contents <- inlineListToPseudoPod opts lst
  return $ "G<" ++ contents ++ ">"

-- | H<> - DONE
inlineToPseudoPod opts (Subscript lst) = do
  contents <- inlineListToPseudoPod opts lst
  return $ "H<" ++ contents ++ ">"

-- | - FIXME
inlineToPseudoPod opts (SmallCaps lst) = inlineListToPseudoPod opts lst

-- | preserve quotes
inlineToPseudoPod opts (Quoted SingleQuote lst) = do
  contents <- inlineListToPseudoPod opts lst
  return $ "\8216" ++ contents ++ "\8217"

inlineToPseudoPod opts (Quoted DoubleQuote lst) = do
  contents <- inlineListToPseudoPod opts lst
  return $ "\8220" ++ contents ++ "\8221"

-- | T<> - DONE
inlineToPseudoPod opts (Cite _ lst) = do
  contents <- inlineListToPseudoPod opts lst
  return $ "T<" ++ contents ++ ">"

-- | C<< content >> - DONE
inlineToPseudoPod _ (Code _ str) =
  return $ "C<< " ++ (escapeString str) ++ " >>"

inlineToPseudoPod _ (Str str) = return $ escapeString str

-- | Math? C<> ? - FIXME
inlineToPseudoPod _ (Math _ str) = return $ "<math>" ++ str ++ "</math>"
                                 -- note:  str should NOT be escaped

-- | ??? FIXME
inlineToPseudoPod _ (RawInline "mediawiki" str) = return str 
inlineToPseudoPod _ (RawInline "html" str) = return str 
inlineToPseudoPod _ (RawInline _ _) = return ""

-- | newline
inlineToPseudoPod _ (LineBreak) = return "\n"

inlineToPseudoPod _ Space = return " "

-- | L<>, L<label|name/"section"> - FIXME, ignoring some cases ? no sections?
inlineToPseudoPod opts (Link txt (src, _)) = do
  label <- inlineListToPseudoPod opts txt
  return $ "L<" ++ label ++ "|" ++ src ++ ">"


inlineToPseudoPod opts (Image alt (source, tit)) = do
  alt' <- inlineListToPseudoPod opts alt
  let txt = if (null tit)
               then if null alt
                       then ""
                       else "|" ++ alt'
               else "|" ++ tit
  return $ "[[Image:" ++ source ++ txt ++ "]]"

inlineToPseudoPod opts (Note contents) = do 
  contents' <- blockListToPseudoPod opts contents
  modify (\s -> s { stNotes = True })
  return $ "<ref>" ++ contents' ++ "</ref>"
  -- note - may not work for notes with multiple blocks