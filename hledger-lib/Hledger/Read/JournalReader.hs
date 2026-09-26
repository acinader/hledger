--- * -*- outline-regexp:"--- *"; -*-
--- ** doc
-- In Emacs, use TAB on lines beginning with "-- *" to collapse/expand sections.
{-|

A reader for hledger's journal file format
(<http://hledger.org/hledger.html#the-journal-file>).  hledger's journal
format is a compatible subset of c++ ledger's
(<http://ledger-cli.org/3.0/doc/ledger3.html#Journal-Format>), so this
reader should handle many ledger files as well. Example:

@
2012\/3\/24 gift
    expenses:gifts  $10
    assets:cash
@

Journal format supports the include directive which can read files in
other formats, so the other file format readers need to be importable
and invocable here.

Some important parts of journal parsing are therefore kept in
Hledger.Read.Common, to avoid import cycles.

-}

--- ** language

{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE NoMonoLocalBinds    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PackageImports      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiWayIf #-}

--- ** exports
module Hledger.Read.JournalReader (

  -- * Reader-finding utils
  findReader,
  splitReaderPrefix,

  -- * Reader
  reader,

  -- * Parsing utils
  parseAndFinaliseJournal,
  runJournalParser,
  rjp,
  runErroringJournalParser,
  rejp,

  -- * Parsers used elsewhere
  getParentAccount,
  journalp,
  directivep,
  defaultyeardirectivep,
  marketpricedirectivep,
  datetimep,
  datep,
  modifiedaccountnamep,
  tmpostingrulep,
  statusp,
  emptyorcommentlinep,
  followingcommentp,
  accountaliasp

  -- * Tests
  ,tests_JournalReader
)
where

--- ** imports
import Control.Exception qualified as C
import Control.Monad (forM_, when, void, unless, filterM, forM, guard)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Except (ExceptT(..), runExceptT)
import Control.Monad.State.Strict (evalStateT,get,modify',put)
import Control.Monad.Trans.Class (lift)
import Data.Char (isDigit, isSpace, toLower)
import Data.Either (isRight, lefts)
import Data.Functor ((<&>))
import Data.Map.Strict qualified as M
import Data.Text (Text)
import Data.String
import Data.List
import Data.Maybe
import Data.Text qualified as T
import Data.Time.Calendar
import Data.Time.LocalTime
import Safe
import Text.Megaparsec hiding (parse)
import Text.Megaparsec.Char
import Text.Printf
import System.Directory (canonicalizePath, doesFileExist, makeAbsolute)
import System.Environment (lookupEnv)
import System.FilePath
import System.IO.Unsafe (unsafePerformIO)
import "Glob" System.FilePath.Glob hiding (match)
-- import "filepattern" System.FilePattern.Directory

import Hledger.Data
import Hledger.Read.Common
import Hledger.Utils

import Hledger.Read.CsvReader qualified as CsvReader (reader)
import Hledger.Read.RulesReader qualified as RulesReader (reader)
import Hledger.Read.TimeclockReader qualified as TimeclockReader (reader)
import Hledger.Read.TimedotReader qualified as TimedotReader (reader)
import Data.Function ((&))

--- ** doctest setup
-- $setup
-- >>> :set -XOverloadedStrings
--
--- ** parsing utilities

-- | Run a journal parser in some monad. See also: parseWithState.
runJournalParser, rjp
  :: Monad m
  => JournalParser m a -> Text -> m (Either HledgerParseErrors a)
runJournalParser p = runParserT (evalStateT p nulljournal) ""
rjp = runJournalParser

-- | Run an erroring journal parser in some monad. See also: parseWithState.
runErroringJournalParser, rejp
  :: Monad m
  => ErroringJournalParser m a
  -> Text
  -> m (Either FinalParseError (Either HledgerParseErrors a))
runErroringJournalParser p t =
  runExceptT $ runParserT (evalStateT p nulljournal) "" t
rejp = runErroringJournalParser


--- ** reader finding utilities
-- Defined here rather than Hledger.Read so that we can use them in includedirectivep below.

-- The available journal readers, each one handling a particular data format.
readers' :: MonadIO m => [Reader m]
readers' = [
  reader
 ,TimeclockReader.reader
 ,TimedotReader.reader
 ,RulesReader.reader
 ,CsvReader.reader Csv
 ,CsvReader.reader Tsv
 ,CsvReader.reader Ssv
--  ,LedgerReader.reader
 ]

readerNames :: [String]
readerNames = map (show . rFormat) (readers'::[Reader IO])

-- | @findReader mformat mpath@
--
-- Find the reader named by @mformat@, if provided.
-- ("ssv" and "tsv" are recognised as alternate names for the csv reader,
-- which also handles those formats.)
-- Or, if a file path is provided, find the first reader that handles
-- its file extension, if any.
findReader :: MonadIO m => Maybe StorageFormat -> Maybe FilePath -> Maybe (Reader m)
findReader Nothing Nothing     = Nothing
findReader (Just fmt) _        = headMay [r | r <- readers', let rname = rFormat r, rname == fmt]
findReader Nothing (Just path) =
  case prefix of
    Just fmt -> headMay [r | r <- readers', rFormat r == fmt]
    Nothing  -> headMay [r | r <- readers', ext `elem` rExtensions r]
  where
    (prefix,path') = splitReaderPrefix path
    ext            = map toLower $ drop 1 $ takeExtension path'

-- | Separate a file path and its reader prefix, if any.
--
-- >>> splitReaderPrefix "csv:-"
-- (Just csv,"-")
splitReaderPrefix :: PrefixedFilePath -> (Maybe StorageFormat, FilePath)
splitReaderPrefix f =
  let 
    candidates = [(Just r, drop (length r + 1) f) | r <- readerNames ++ ["ssv","tsv"], (r++":") `isPrefixOf` f]
    (strPrefix, newF) = headDef (Nothing, f) candidates
  in case strPrefix of
    Just "csv" -> (Just (Sep Csv), newF)
    Just "tsv" -> (Just (Sep Tsv), newF)
    Just "ssv" -> (Just (Sep Ssv), newF)
    Just "journal" -> (Just Journal', newF)
    Just "timeclock" -> (Just Timeclock, newF)
    Just "timedot" -> (Just Timedot, newF)
    _ -> (Nothing, f)

-- -- | Does this file path have a reader prefix ?
-- hasReaderPrefix :: PrefixedFilePath -> Bool
-- hasReaderPrefix = isJust . fst. splitReaderPrefix

-- -- | Add a reader prefix to a file path, unless it already has one.
-- -- The argument should be a valid reader name.
-- --
-- -- >>> addReaderPrefix "csv" "a.txt"
-- -- >>> "csv:a.txt"
-- -- >>> addReaderPrefix "csv" "timedot:a.txt"
-- -- >>> "timedot:a.txt"
-- addReaderPrefix :: ReaderPrefix -> FilePath -> PrefixedFilePath
-- addReaderPrefix readername f
--   | hasReaderPrefix f = f
--   | otherwise = readername <> ":" <> f

--- ** reader

reader :: MonadIO m => Reader m
reader = Reader
  {rFormat     = Journal'
  ,rExtensions = ["journal", "j", "hledger", "ledger"]
  ,rReadFn     = handleReadFnToTextReadFn parse
  ,rParser    = journalp  -- no need to add command line aliases like journalp'
                           -- when called as a subparser I think
  }

-- | Parse and post-process a "Journal" from hledger's journal file
-- format, or give an error.
parse :: InputOpts -> FilePath -> Text -> ExceptT String IO Journal
parse iopts f = parseAndFinaliseJournal journalp' iopts f
  where
    journalp' = do
      -- reverse parsed aliases to ensure that they are applied in order given on commandline
      mapM_ addAccountAlias (reverse $ aliasesFromOpts iopts)
      journalp iopts

--- ** parsers
--- *** journal

-- | A journal parser. Accumulates and returns a "ParsedJournal",
-- which should be finalised/validated before use.
--
-- >>> rejp (journalp definputopts <* eof) "2015/1/1\n a  0\n"
-- Right (Right Journal (unknown) with 1 transactions, 1 accounts)
--
journalp :: MonadIO m => InputOpts -> ErroringJournalParser m ParsedJournal
journalp iopts = do
  many $ addJournalItemP iopts
  eof
  modify' $ \j -> j{jparsepos = Nothing, jparseamountstyles = mempty, jparsetexts = mempty}  -- drop parse-time state that is only meaningful during parsing
  get

-- | A side-effecting parser; parses any kind of journal item
-- and updates the parse state accordingly.
-- Every item is also recorded in jitems, so the file can be reproduced.
addJournalItemP :: MonadIO m => InputOpts -> ErroringJournalParser m ()
addJournalItemP iopts = (<?> "transaction or directive") $ do
  -- Journal item types can be told apart by their first character. Where that
  -- is unambiguous, go straight to the right parser: trying every alternative
  -- for every item (mostly transactions and blank lines) was a large parsing cost.
  -- The fallbacks keep the error messages the same as before.
  c <- lookAhead anySingle
  if | isDigit c                         -> transactionitem
     | c == 'P'                          -> priceitem <|> anyitem
     | isSpace c || isLineCommentStart c -> blankorcommentitem <|> anyitem
     | otherwise                         -> anyitem
  where
    transactionitem    = transactionOrFastp >>= modify' . addTransactionItem
    priceitem          = recordItem JIDirective marketpriceOrFastp >>= modify' . addPriceDirective
    blankorcommentitem = recordItem commentOrBlankItem $ lift emptyorcommentlinep
    anyitem = choice [
        directivep iopts
      , transactionitem
      , recordItem JIDirective transactionmodifierp  >>= modify' . addTransactionModifier
      , recordItem JIDirective periodictransactionp  >>= modify' . addPeriodicTransaction
      , priceitem
      , blankorcommentitem
      , recordItem JICommentBlock $ lift multilinecommentp
      ]
    commentOrBlankItem txt = if T.all isSpace txt then JIBlank else JIComment txt

-- | Run a parser, also recording the text it consumed as a journal item of the given kind.
recordItem :: (Text -> JournalItem) -> JournalParser m a -> JournalParser m a
recordItem mkitem p = do
  -- This is like megaparsec's `match`, but written out; `match` was found to allocate
  -- ~20KB per item here, costing ~9% of total run time on a 100k-transaction journal.
  -- Note T.take does not copy bytes: it returns a small Text value (array pointer, offset, length)
  -- viewing the same byte array as the remaining input, which is the whole file's text, already
  -- kept in jfiles. So each jitems entry costs a few words, however long its text is,
  -- and jitems adds little memory even though it holds every directive and comment line verbatim.
  o <- getOffset
  s <- getInput
  a <- p
  o' <- getOffset
  modify' $ addJournalItem $ mkitem $ T.take (o' - o) s
  return a

--- *** directives

-- | Parse any journal directive and update the parse state accordingly,
-- and record it as a journal item (exported or not by print --export).
-- Cf http://hledger.org/hledger.html#directives,
-- http://ledger-cli.org/3.0/doc/ledger3.html#Command-Directives
directivep :: MonadIO m => InputOpts -> ErroringJournalParser m ()
directivep iopts = (do
  optional $ oneOf ['!','@']
  choice [
    includedirectivep iopts
   -- directives which print --export reproduces
   ,recordItem JIDirective $ choice [
     accountdirectivep
    ,commoditydirectivep
    ,decimalmarkdirectivep
    ,defaultyeardirectivep
    ,defaultcommoditydirectivep
    ,payeedirectivep
    ,tagdirectivep
    ]
   -- directives which print --export does not reproduce:
   -- those whose effect is already applied to the parsed data,
   -- and the Ledger directives which hledger ignores.
   -- (endtagdirectivep consumes "end" before failing, so it must come after the other end directives.)
   ,recordItem JINonExportedDirective $ choice [
     aliasdirectivep
    ,endaliasesdirectivep
    ,applyaccountdirectivep
    ,endapplyaccountdirectivep
    ,applyfixeddirectivep
    ,applytagdirectivep
    ,assertdirectivep
    ,bucketdirectivep
    ,capturedirectivep
    ,checkdirectivep
    ,commandlineflagdirectivep
    ,commodityconversiondirectivep
    ,definedirectivep
    ,endapplyfixeddirectivep
    ,endapplytagdirectivep
    ,endapplyyeardirectivep
    ,endtagdirectivep
    ,evaldirectivep
    ,exprdirectivep
    ,ignoredpricecommoditydirectivep
    ,pythondirectivep
    ,valuedirectivep
    ]
   ]
  ) <?> "directive"

-- | Parse an include directive, and the file(s) it refers to, possibly recursively.
-- Input options are required since they may affect parsing (of timeclock files, specifically).
-- include's argument is a file path or glob pattern (see findMatchedFiles for details),
-- optionally with a file type prefix. Relative paths are relative to the current file.
includedirectivep :: MonadIO m => InputOpts -> ErroringJournalParser m ()
includedirectivep iopts = do
  -- save the position at start of include directive, for error messages
  eoff <- getOffset
  pos <- getSourcePos'
  let errorNoArg = customFailure $ parseErrorAt eoff "include needs a file path or glob pattern argument"

  -- parse the directive, and record it as a journal item (before the included files' items)
  prefixedglob <- recordItem JIInclude $ do
    string "include"
    -- notFollowedBy newline <?> "a file path or glob pattern argument"
    (do
      lift skipNonNewlineSpaces1
      prefixedglob <- rstrip . T.unpack <$> takeWhileP Nothing (`notElem` [';','\n'])
      lift followingcommentp
      return prefixedglob
      ) <|> errorNoArg

  let (mprefix,path) = splitReaderPrefix prefixedglob
  parentf <- sourcePosFilePath pos
  when (null $ dbg6 (parentf <> " include: path ") path) errorNoArg

  -- Find the file or glob-matched files (just the ones from this include directive), with some IO error checking.
  paths <- findMatchedFiles eoff parentf path
  -- Also report whether a glob pattern was used, and not just a literal file path.
  -- (paths, isglob) <- findMatchedFiles off pos glb

  -- XXX worth the trouble ? no
  -- Comprehensively exclude files already processed. Some complexities here:
  -- If this include directive uses a glob pattern, remove duplicates. 
  -- Ie if this glob pattern matches any files we have already processed (or the current file),
  -- due to multiple includes in sequence or in a cycle, exclude those files so they're not processed again.
  -- If this include directive uses a literal file path, don't remove duplicates.
  -- Multiple includes in sequence will cause the included file to be processed multiple times.
  -- Multiple includes forming a cycle will be detected and reported as an error in parseIncludedFile.
  -- let paths' = if isglob then filter (...) paths else paths

  -- if there was a reader prefix, apply it to all the file paths
  let prefixedpaths = case mprefix of
        Nothing  -> paths
        Just fmt -> map ((show fmt++":")++) paths

  -- Parse each one, as if inlined here.
  forM_ prefixedpaths $ parseIncludedFile iopts eoff

  where

    -- | Find the files matched by a literal path or a glob pattern.
    -- Examples: foo.j, ../foo/bar.j, timedot:/foo/2020*, *.journal, **.journal.
    --
    -- Uses the current parse context for detecting the current directory and for error messages.
    -- Expands a leading tilde to the user's home directory.
    -- Converts ** without a slash to **/*, like zsh's GLOB_STAR_SHORT, so ** also matches file name parts.
    -- Checks if any matched paths are directories and excludes those.
    -- Converts all matched paths to their canonical form.
    -- Note * and ** mostly won't implicitly match dot files or dot directories,
    -- but ** will implicitly search non-top-level dot directories (see #2498, Glob#49).

    findMatchedFiles :: (MonadIO m) => Int -> FilePath -> FilePath -> JournalParser m [FilePath]
    findMatchedFiles off parentf path = do

      -- Some notes about the Glob library that we use (related: https://github.com/Deewiant/glob/issues/49):
      -- It does not expand tilde.
      -- It does not canonicalise paths.
      -- The results are not in any particular order.
      -- The results can include directories.
      -- DIRPAT/ is equivalent to DIRPAT, except results will end with // (double slash).
      -- A . or .. path component can match the current or parent directories (including them in the results).
      -- * matches zero or more characters in a file or directory name.
      -- * at the start of a file name ignores dot-named files and directories, by default.
      -- ** (or zero or more consecutive *'s) not followed by slash is equivalent to *.
      -- A **/ component matches any number of directory parts.
      -- A **/ does not implicitly search top-level dot directories or implicitly match do files,
      -- but it does search non-top-level dot directories. Eg ** will find the c file in a/.b/c.
      -- It tends to get attributes of all files in a directory.

      -- expand a tilde at the start of the glob pattern, or throw an error
      expandedpath <- lift $ expandHomePath path & handleIOError off "failed to expand ~"

      -- get the directory of the including file
      -- need to canonicalise a symlink parentf so takeDirectory works correctly [#2503]
      cwd <- fmap takeDirectory <$> liftIO $ canonicalizePath parentf

      -- Don't allow 3 or more stars.
      when ("***" `isInfixOf` expandedpath) $
        customFailure $ parseErrorAt off $ "Invalid glob pattern: too many stars, use * or **"

      -- Make ** also match file name parts like zsh's GLOB_STAR_SHORT.
      let
        finalpath =
          -- ** without a slash is equivalent to **/*
          case regexReplace (toRegex' $ T.pack "\\*\\*([^/\\])") "**/*\\1" expandedpath of
            Right s -> s
            Left  _ -> expandedpath   -- ignore any error, there should be none

      -- Compile as a Pattern. Can throw an error.
      pat <- case tryCompileWith compDefault{errorRecovery=False} finalpath of
        Left e  -> customFailure $ parseErrorAt off $ "Invalid glob pattern: " ++ e
        Right x -> pure x

      -- Find all paths matched by the glob pattern.
      -- If it is a literal (non-glob) path, don't use the Glob lib, because it gets attributes
      -- of all files in the directory, which confuses build systems like tup.
      paths <-
        if isLiteral pat
        then return $ if isAbsolute finalpath then [finalpath] else [cwd </> finalpath]
        else liftIO $ globDir1 pat cwd

      -- Exclude any directories or symlinks to directories, and canonicalise, and sort.
      files <- liftIO $
        filterM doesFileExist paths
        >>= mapM makeAbsolute
        <&> sort

      -- Throw an error if one of these files is among the grandparent files, forming a cycle.
      -- Though, ignore the immediate parent file for convenience. XXX inconsistent - should it ignore all cyclic includes ?
      -- Use canonical paths for cycle detection, show nominal absolute paths in error messages.
      parentj <- get
      let parentfiles = jparseincludefilestack parentj
          cparentfiles = map snd parentfiles
          cparentf = take 1 cparentfiles
      files2 <- forM files $ \f -> do
        cf <- liftIO $ canonicalizePath f
        if
          | [cf] == cparentf -> return cf  -- current file - return canonicalised, will be excluded later
          | cf `elem` drop 1 cparentfiles -> customFailure $ parseErrorAt off $ "This included file forms a cycle: " ++ f
          | otherwise -> return f

      -- Throw an error if no files were matched.
      when (null files2) $ customFailure $ parseErrorAt off $ "No files were matched by: " ++ path

      -- If the current file got included, ignore it (last, to avoid triggering the error above).
      let
        files3 =
          dbg6 (parentf <> " include: matched files (excluding current file)") $
          filter (not.(`elem` cparentf)) files2

      return files3

    -- Parse the given included file (and any deeper includes, recursively) as if it was inlined in the current (parent) file.
    -- The offset of the start of the include directive in the parent file is provided for error messages.
    parseIncludedFile :: MonadIO m => InputOpts -> Int -> PrefixedFilePath -> ErroringJournalParser m ()
    parseIncludedFile iopts1 off prefixedpath = do
      let (_mprefix,filepath) = splitReaderPrefix prefixedpath

      -- Choose a reader based on the file path prefix or file extension,
      -- defaulting to JournalReader. Duplicating readJournal a bit here.
      let r = fromMaybe reader $ findReader Nothing (Just prefixedpath)
          parser = (rParser r) iopts1
      dbg7IO "parseIncludedFile: trying reader" (rFormat r)

      -- Read the file's content, or throw an error.
      -- Readers which read their own input (CSV, rules) are given empty text instead.
      childInput <-
        if readerReadsOwnInput r then pure ""
        else lift $ readFilePortably filepath & handleIOError off "failed to read a file"
      cfilepath <- liftIO $ canonicalizePath filepath
      parentj <- get
      let initChildj = newJournalWithParseStateFrom filepath cfilepath parentj

      -- Parse the file (and its own includes, if any) to a Journal
      -- with file path and source text attached. Or throw an error.
      updatedChildj <- journalAddFile (filepath, childInput) <$>
                        parseIncludeFile parser initChildj filepath childInput

      -- Child journal was parsed successfully; now merge it into the parent journal.
      -- Debug logging is provided for troubleshooting account display order (eg).
      -- The parent journal is the second argument to journalConcat; this means
      -- its parse state is kept, and its lists are appended to child's (which
      -- ultimately produces the right list order, because parent's and child's
      -- lists are in reverse order at this stage. Cf #1909)
      let
        parentj' =
          dbgJournalAcctDeclOrder ("parseChild: child " <> childfilename <> " acct decls: ") updatedChildj
          `journalConcat`
          dbgJournalAcctDeclOrder ("parseChild: parent " <> parentfilename <> " acct decls: ") parentj

          where
            childfilename = takeFileName filepath
            parentfilename = maybe "(unknown)" takeFileName $ fmap fst $ headMay $ jparseincludefilestack parentj  -- XXX more accurate than journalFilePath for some reason

      -- And update the current parse state.
      put parentj'

      where
        newJournalWithParseStateFrom :: FilePath -> FilePath -> Journal -> Journal
        newJournalWithParseStateFrom filepath cfilepath j = nulljournal{
          jparsedefaultyear      = jparsedefaultyear j
          ,jparsedefaultcommodity = jparsedefaultcommodity j
          ,jparseparentaccounts   = jparseparentaccounts j
          ,jparsedecimalmark      = jparsedecimalmark j
          ,jparsealiases          = jparsealiases j
          ,jdeclaredcommodities           = jdeclaredcommodities j
          -- ,jparsetransactioncount = jparsetransactioncount j
          ,jparsetimeclockentries = jparsetimeclockentries j
          ,jparseincludefilestack = (filepath, cfilepath) : jparseincludefilestack j
          }

-- Get the absolute path of the file referenced by this parse position.
-- (Symbolic links will not be dereferenced.)
-- This probably will always succeed, since the parse file's path is probably always absolute.
sourcePosFilePath :: (MonadIO m) => SourcePos -> m FilePath
sourcePosFilePath = liftIO . makeAbsolute . sourceName

-- | Lift an IO action into the exception monad, converting any IO error
-- to a parse error message at the given offset.
handleIOError :: MonadIO m => Int -> String -> IO a -> TextParser m a
handleIOError off msg io = do
  eResult <- liftIO $ (Right <$> io) `C.catch` \(e::C.IOException) -> pure $ Left $ printf "%s:\n%s" msg (show e)
  case eResult of
    Right res -> pure res
    Left errMsg -> setOffset off >> fail errMsg

-- Parse an account directive, adding its info to the journal's
-- list of account declarations.
accountdirectivep :: JournalParser m ()
accountdirectivep = do
  off <- getOffset -- XXX figure out a more precise position later
  pos <- getSourcePos'

  string "account"
  lift skipNonNewlineSpaces1

  -- the account name, possibly modified by preceding alias or apply account directives
  acct <- (notFollowedBy (char '(' <|> char '[') <?> "account name without brackets") >>
          modifiedaccountnamep True

  -- maybe a comment, on this and/or following lines
  (cmt, tags) <- lift transactioncommentp

  -- maybe Ledger-style subdirectives (ignored)
  skipMany indentedlinep

  -- an account type may have been set by account type code or a tag;
  -- the latter takes precedence
  let
    metype = parseAccountTypeCode <$> lookup accountTypeTagName tags

  -- update the journal
  addAccountDeclaration (acct, cmt, tags, pos)
  unless (null tags) $ addDeclaredAccountTags acct tags
  case metype of
    Nothing         -> return ()
    Just (Right t)  -> addDeclaredAccountType acct t
    Just (Left err) -> customFailure $ parseErrorAt off err

-- The special tag used for declaring account type. XXX change to "class" ?
accountTypeTagName = "type"

parseAccountTypeCode :: Text -> Either String AccountType
parseAccountTypeCode s =
  case T.toLower s of
    "asset"            -> Right Asset
    "a"                -> Right Asset
    "liability"        -> Right Liability
    "l"                -> Right Liability
    "equity"           -> Right Equity
    "e"                -> Right Equity
    "revenue"          -> Right Revenue
    "r"                -> Right Revenue
    "expense"          -> Right Expense
    "x"                -> Right Expense
    "cash"             -> Right Cash
    "c"                -> Right Cash
    "conversion"       -> Right Conversion
    "v"                -> Right Conversion
    "gains"            -> Right Gain
    "g"                -> Right Gain
    "u"                -> Right UnrealisedGain
    "unrealised"       -> Right UnrealisedGain
    "unrealised-gain"  -> Right UnrealisedGain
    "unrealised-gains" -> Right UnrealisedGain
    "unrealized"       -> Right UnrealisedGain
    "unrealized-gain"  -> Right UnrealisedGain
    "unrealized-gains" -> Right UnrealisedGain
    _                  -> Left err
  where
    err = T.unpack $ "invalid account type code "<>s<>", should be one of " <>
            T.intercalate ", " ["A","L","E","R","X","C","V","G","U","Asset","Liability","Equity","Revenue","Expense","Cash","Conversion","Gain","UnrealisedGain"]

-- Add an account declaration to the journal, auto-numbering it.
addAccountDeclaration :: (AccountName,Text,[Tag],SourcePos) -> JournalParser m ()
addAccountDeclaration (a,cmt,tags,pos) = do
  modify' (\j ->
             let
               decls = jdeclaredaccounts j
               d     = (a, nullaccountdeclarationinfo{
                              adicomment          = cmt
                             ,aditags             = tags
                             ,adideclarationorder = length decls + 1  -- gets renumbered when Journals are finalised or merged
                             ,adisourcepos        = pos
                             })
             in
               j{jdeclaredaccounts = d:decls})

-- Add a payee declaration to the journal.
addPayeeDeclaration :: (Payee,Text,[Tag]) -> JournalParser m ()
addPayeeDeclaration (p, cmt, tags) =
  modify' (\j@Journal{jdeclaredpayees} -> j{jdeclaredpayees=d:jdeclaredpayees})
             where
               d = (p
                   ,nullpayeedeclarationinfo{
                     pdicomment = cmt
                    ,pditags    = tags
                    })

-- Add a tag declaration to the journal.
addTagDeclaration :: (TagName,Text) -> JournalParser m ()
addTagDeclaration (t, cmt) =
  modify' (\j@Journal{jdeclaredtags} -> j{jdeclaredtags=tagandinfo:jdeclaredtags})
  where
    tagandinfo = (t, nulltagdeclarationinfo{tdicomment=cmt})

indentedlinep :: JournalParser m String
indentedlinep = lift skipNonNewlineSpaces1 >> (rstrip <$> lift restofline)

-- | Parse a one-line or multi-line commodity directive.
--
-- >>> Right _ <- rjp commoditydirectivep "commodity $1.00"
-- >>> Right _ <- rjp commoditydirectivep "commodity $\n  format $1.00"
-- >>> Right _ <- rjp commoditydirectivep "commodity $\n\n" -- a commodity with no format
-- >>> Right _ <- rjp commoditydirectivep "commodity $1.00\n  format $1.00" -- both, what happens ?
commoditydirectivep :: JournalParser m ()
commoditydirectivep = commoditydirectiveonelinep <|> commoditydirectivemultilinep

-- | Parse a one-line commodity directive.
--
-- >>> Right _ <- rjp commoditydirectiveonelinep "commodity $1.00"
-- >>> Right _ <- rjp commoditydirectiveonelinep "commodity $1.00 ; blah\n"
commoditydirectiveonelinep :: JournalParser m ()
commoditydirectiveonelinep = do
  (off, pos, Amount{acommodity,astyle}) <- try $ do
    string "commodity"
    pos <- getSourcePos'
    lift skipNonNewlineSpaces1
    off <- getOffset
    amt <- amountp' StyleAmount
    pure $ (off, pos, amt)
  lift skipNonNewlineSpaces
  (comment, tags) <- lift transactioncommentp
  let comm = Commodity{csymbol=acommodity, cformat=Just $ dbg7 "style from commodity directive" astyle, ccomment=comment, ctags=tags, csourcepos=pos}
  if isNothing $ asdecimalmark astyle
  then customFailure $ parseErrorAt off pleaseincludedecimalpoint
  else modify' (\j -> j{jdeclaredcommodities=M.insert acommodity comm $ jdeclaredcommodities j
                       ,jdeclaredcommoditytags=if null tags then jdeclaredcommoditytags j
                                               else M.insert acommodity tags $ jdeclaredcommoditytags j})

pleaseincludedecimalpoint :: String
pleaseincludedecimalpoint = chomp $ unlines [
   "Please include a decimal point or decimal comma in commodity directives,"
  ,"to help us parse correctly. It may be followed by zero or more decimal digits."
  ,"Examples:"
  ,"commodity $1000.            ; no thousands mark, decimal period, no decimals"
  ,"commodity 1.234,00 ARS      ; period at thousands, decimal comma, 2 decimals"
  ,"commodity EUR 1 000,000     ; space at thousands, decimal comma, 3 decimals"
  ,"commodity INR1,23,45,678.0  ; comma at thousands/lakhs/crores, decimal period, 1 decimal"
  ]

-- | Parse a multi-line commodity directive, containing 0 or more format subdirectives.
--
-- >>> Right _ <- rjp commoditydirectivemultilinep "commodity $ ; blah \n  format $1.00 ; blah"
commoditydirectivemultilinep :: JournalParser m ()
commoditydirectivemultilinep = do
  string "commodity"
  pos <- getSourcePos'
  lift skipNonNewlineSpaces1
  sym <- lift commoditysymbolp
  (comment, tags) <- lift transactioncommentp
  -- read all subdirectives, saving format subdirectives as Lefts
  subdirectives <- many $ indented (eitherP (formatdirectivep sym) (lift restofline))
  let mfmt = lastMay $ lefts subdirectives
  let comm = Commodity{csymbol=sym, cformat=mfmt, ccomment=comment, ctags=tags, csourcepos=pos}
  modify' (\j -> j{jdeclaredcommodities=M.insert sym comm $ jdeclaredcommodities j
                  ,jdeclaredcommoditytags=if null tags then jdeclaredcommoditytags j
                                          else M.insert sym tags $ jdeclaredcommoditytags j})
  where
    indented = (lift skipNonNewlineSpaces1 >>)

-- | Parse a format (sub)directive, throwing a parse error if its
-- symbol does not match the one given.
formatdirectivep :: CommoditySymbol -> JournalParser m AmountStyle
formatdirectivep expectedsym = do
  string "format"
  lift skipNonNewlineSpaces1
  off <- getOffset
  Amount{acommodity,astyle} <- amountp' StyleAmount
  _ <- lift followingcommentp
  if acommodity==expectedsym
    then
      if isNothing $ asdecimalmark astyle
      then customFailure $ parseErrorAt off pleaseincludedecimalpoint
      else return $ dbg7 "style from format subdirective" astyle
    else customFailure $ parseErrorAt off $
         printf "commodity directive symbol \"%s\" and format directive symbol \"%s\" should be the same" expectedsym acommodity

-- More Ledger directives, ignore for now:
-- apply fixed, apply tag, assert, bucket, A, capture, check, define, expr
applyfixeddirectivep, endapplyfixeddirectivep, applytagdirectivep, endapplytagdirectivep,
  assertdirectivep, bucketdirectivep, capturedirectivep, checkdirectivep, 
  endapplyyeardirectivep, definedirectivep, exprdirectivep, valuedirectivep,
  evaldirectivep, pythondirectivep, commandlineflagdirectivep
  :: JournalParser m ()
applyfixeddirectivep    = do string "apply fixed" >> lift restofline >> return ()
endapplyfixeddirectivep = do string "end apply fixed" >> lift restofline >> return ()
applytagdirectivep      = do string "apply tag" >> lift restofline >> return ()
endapplytagdirectivep   = do string "end apply tag" >> lift restofline >> return ()
endapplyyeardirectivep  = do string "end apply year" >> lift restofline >> return ()
assertdirectivep        = do string "assert"  >> lift restofline >> return ()
bucketdirectivep        = do string "A " <|> string "bucket " >> lift restofline >> return ()
capturedirectivep       = do string "capture" >> lift restofline >> return ()
checkdirectivep         = do string "check"   >> lift restofline >> return ()
definedirectivep        = do string "define"  >> lift restofline >> return ()
exprdirectivep          = do string "expr"    >> lift restofline >> return ()
valuedirectivep         = do string "value"   >> lift restofline >> return ()
evaldirectivep          = do string "eval"   >> lift restofline >> return ()
commandlineflagdirectivep = do string "--" >> lift restofline >> return ()
pythondirectivep = do
  string "python" >> lift restofline
  many $ indentedline <|> blankline
  return ()
  where
    indentedline = lift skipNonNewlineSpaces1 >> lift restofline
    blankline = lift skipNonNewlineSpaces >> newline >> return "" <?> "blank line"

keywordp :: String -> JournalParser m ()
keywordp = void . string . fromString

spacesp :: JournalParser m ()
spacesp = void $ lift skipNonNewlineSpaces1

-- | Backtracking parser similar to string, but allows varying amount of space between words
keywordsp :: String -> JournalParser m ()
keywordsp = try . sequence_ . intersperse spacesp . map keywordp . words

applyaccountdirectivep :: JournalParser m ()
applyaccountdirectivep = do
  keywordsp "apply account" <?> "apply account directive"
  lift skipNonNewlineSpaces1
  parent <- lift accountnamep
  newline
  pushParentAccount parent

endapplyaccountdirectivep :: JournalParser m ()
endapplyaccountdirectivep = do
  keywordsp "end apply account" <?> "end apply account directive"
  lift restofline
  popParentAccount

aliasdirectivep :: JournalParser m ()
aliasdirectivep = do
  string "alias"
  lift skipNonNewlineSpaces1
  alias <- lift accountaliasp
  addAccountAlias alias

endaliasesdirectivep :: JournalParser m ()
endaliasesdirectivep = do
  keywordsp "end aliases" <?> "end aliases directive"
  lift restofline
  clearAccountAliases

tagdirectivep :: JournalParser m ()
tagdirectivep = do
  string "tag" <?> "tag directive"
  lift skipNonNewlineSpaces1
  tagname <- lift $ T.pack <$> some nonspace
  (comment, _) <- lift transactioncommentp
  skipMany indentedlinep
  addTagDeclaration (tagname,comment)
  return ()

-- end tag or end apply tag
endtagdirectivep :: JournalParser m ()
endtagdirectivep = (do
  string "end"
  lift skipNonNewlineSpaces1
  optional $ string "apply" >> lift skipNonNewlineSpaces1
  string "tag"
  lift skipNonNewlineSpaces
  eol
  return ()
  ) <?> "end tag or end apply tag directive"

payeedirectivep :: JournalParser m ()
payeedirectivep = do
  string "payee" <?> "payee directive"
  lift skipNonNewlineSpaces1
  payee <- lift $ T.strip <$> (try doublequotedtextp <|> noncommenttext1p)
  (comment, tags) <- lift transactioncommentp
  skipMany indentedlinep
  addPayeeDeclaration (payee, comment, tags)
  return ()

defaultyeardirectivep :: JournalParser m ()
defaultyeardirectivep = do
  (string "Y" <|> string "year" <|> string "apply year") <?> "default year"
  lift skipNonNewlineSpaces
  y <- lift yearp
  lift restofline
  setYear y

defaultcommoditydirectivep :: JournalParser m ()
defaultcommoditydirectivep = do
  char 'D' <?> "default commodity"
  lift skipNonNewlineSpaces1
  off <- getOffset
  Amount{acommodity,astyle} <- amountp' StyleAmount
  lift restofline
  if isNothing $ asdecimalmark astyle
  then customFailure $ parseErrorAt off pleaseincludedecimalpoint
  else setDefaultCommodityAndStyle (acommodity, astyle)

marketpricedirectivep :: JournalParser m PriceDirective
marketpricedirectivep = do
  pos <- getSourcePos'
  char 'P' <?> "market price"
  lift skipNonNewlineSpaces
  date <- datep
  lift skipNonNewlineSpaces1
  -- a time of day may follow the date; it is ignored (checked cheaply first, since usually there is none)
  mc <- lift peekChar
  mtime <- if maybe False isDigit mc then lift $ optional $ try timeofdayp else pure Nothing
  when (isJust mtime) $ lift skipNonNewlineSpaces1
  symbol <- shareText =<< lift commoditysymbolp
  lift skipNonNewlineSpaces1
  price <- amountp
  lift restofline
  return $ PriceDirective pos date symbol price

ignoredpricecommoditydirectivep :: JournalParser m ()
ignoredpricecommoditydirectivep = do
  char 'N' <?> "ignored-price commodity"
  lift skipNonNewlineSpaces1
  lift commoditysymbolp
  lift restofline
  return ()

commodityconversiondirectivep :: JournalParser m ()
commodityconversiondirectivep = do
  char 'C' <?> "commodity conversion"
  lift skipNonNewlineSpaces1
  amountp
  lift skipNonNewlineSpaces
  char '='
  lift skipNonNewlineSpaces
  amountp
  lift restofline
  return ()

-- | Read a valid decimal mark from the decimal-mark directive e.g
--
-- decimal-mark ,
decimalmarkdirectivep :: JournalParser m ()
decimalmarkdirectivep = do
  string "decimal-mark" <?> "decimal mark"
  lift skipNonNewlineSpaces1
  mark <- satisfy isDecimalMark
  modify' $ \j -> j{jparsedecimalmark=Just mark}
  lift restofline
  return ()

--- *** transactions

-- | Parse a transaction modifier (auto postings) rule.
transactionmodifierp :: JournalParser m TransactionModifier
transactionmodifierp = do
  char '=' <?> "modifier transaction"
  lift skipNonNewlineSpaces
  querytxt <- lift $ T.strip <$> descriptionp
  (_comment, _tags) <- lift transactioncommentp   -- TODO apply these to modified txns ?
  postingrules <- tmpostingrulesp Nothing
  return $ TransactionModifier querytxt postingrules

-- | Parse a periodic transaction rule.
--
-- This reuses periodexprp which parses period expressions on the command line.
-- This is awkward because periodexprp supports relative and partial dates,
-- which we don't really need here, and it doesn't support the notion of a
-- default year set by a Y directive, which we do need to consider here.
-- We resolve it as follows: in periodic transactions' period expressions,
-- if there is a default year Y in effect, partial/relative dates are calculated
-- relative to Y/1/1. If not, they are calculated related to today as usual.
periodictransactionp :: MonadIO m => JournalParser m PeriodicTransaction
periodictransactionp = do
  startpos <- getSourcePos'

  -- first line
  char '~' <?> "periodic transaction"
  lift $ skipNonNewlineSpaces

  -- if there's a default year in effect, use Y/1/1 as base for partial/relative dates
  today <- liftIO getCurrentDay
  mdefaultyear <- getYear
  let refdate = case mdefaultyear of
                  Nothing -> today
                  Just y  -> fromGregorian y 1 1
  periodExcerpt <- lift $ excerpt_ $
                    singlespacedtextsatisfying1p (\c -> c /= ';' && c /= '\n')
  let periodtxt = T.strip $ getExcerptText periodExcerpt

  -- first parsing with 'singlespacedtextp', then "re-parsing" with
  -- 'periodexprp' saves 'periodexprp' from having to respect the single-
  -- and double-space parsing rules
  (interval, spn) <- lift $ reparseExcerpt periodExcerpt $ do
    pexp <- periodexprp refdate
    (<|>) eof $ do
      offset1 <- getOffset
      void takeRest
      offset2 <- getOffset
      customFailure $ parseErrorAtRegion offset1 offset2 $
           "remainder of period expression cannot be parsed"
        <> "\nperhaps you need to terminate the period expression with a double space?"
        <> "\na double space is required between period expression and description/comment"
    pure pexp

  status <- lift statusp <?> "cleared status"
  code <- lift codep <?> "transaction code"
  description <- lift $ T.strip <$> descriptionp
  (comment, tags) <- lift transactioncommentp
  -- next lines; use same year determined above
  postings <- postingsp (Just $ first3 $ toGregorian refdate)

  endpos <- getSourcePos'
  let sourcepos = (startpos, endpos)

  return $ nullperiodictransaction{
     ptperiodexpr=periodtxt
    ,ptinterval=interval
    ,ptspan=spn
    ,ptsourcepos=sourcepos
    ,ptstatus=status
    ,ptcode=code
    ,ptdescription=description
    ,ptcomment=comment
    ,pttags=tags
    ,ptpostings=postings
    }

-- | Parse a (possibly unbalanced) transaction.
transactionp :: JournalParser m Transaction
transactionp = do
  -- dbgparse 0 "transactionp"
  startpos <- getSourcePos'
  date <- datep <?> "transaction"
  mc <- lift peekChar
  edate <- if mc == Just '=' then optional (lift $ secondarydatep date) <?> "secondary date" else pure Nothing
  lookAhead (lift spacenonewline <|> newline) <?> "whitespace or newline"
  status <- lift statusp <?> "cleared status"
  code <- lift codep <?> "transaction code"
  description <- lift $ T.strip <$> descriptionp
  (comment, tags) <- lift transactioncommentp
  let year = first3 $ toGregorian date
  postings <- postingsp (Just year)
  endpos <- getSourcePos'
  let sourcepos = (startpos, endpos)
  return $ txnTieKnot $ Transaction 0 "" sourcepos date edate status code description comment tags postings

--- *** transaction fast path

-- | Whether the fast path for simple transactions (fasttransactionp) is used.
-- Controlled by the HLEDGER_FASTPATH environment variable, for testing:
-- unset or empty means use it; "off" means don't; "check" means use it, and also parse
-- each fast-path transaction with the general parser and fail if the results differ.
fastPathMode :: String
fastPathMode = unsafePerformIO $ fromMaybe "" <$> lookupEnv "HLEDGER_FASTPATH"
{-# NOINLINE fastPathMode #-}

-- | Run a fast-path parser, falling back to the general parser when it declines,
-- or as HLEDGER_FASTPATH says (see fastPathMode). In check mode, results are compared
-- after applying the given normalising function (eg to untie cyclic references).
withFastPath :: (Eq a, Show a) => (a -> a) -> JournalParser m (Maybe a) -> JournalParser m a -> JournalParser m a
withFastPath norm fastp generalp = case fastPathMode of
  "off"   -> generalp
  "check" -> do
    st0 <- getParserState
    j0  <- get
    mx  <- fastp
    case mx of
      Nothing -> generalp
      Just x -> do
        st1 <- getParserState
        j1  <- get
        setParserState st0
        put j0
        x' <- generalp
        when (norm x /= norm x') $
          fail $ "fast path mismatch:\n" ++ show (norm x) ++ "\ngeneral parser:\n" ++ show (norm x')
        setParserState st1
        put j1
        return x
  _ -> fastp >>= maybe generalp pure

-- | Parse a transaction, using the fast path when it is a simple one (see fasttransactionp).
transactionOrFastp :: JournalParser m Transaction
transactionOrFastp = withFastPath txnUntieKnot fasttransactionp transactionp

-- | Parse a market price directive, using the fast path when it is a simple one (see fastmarketpricedirectivep).
marketpriceOrFastp :: JournalParser m PriceDirective
marketpriceOrFastp = withFastPath id fastmarketpricedirectivep marketpricedirectivep

-- | The parts of a simple transaction recognised by scanSimpleTransaction: date, status,
-- description, and each posting's account name (parent account and aliases applied, brackets
-- removed), posting type, and amount if any.
data SimpleTransaction = SimpleTransaction !Day !Status !Text ![(AccountName, PostingRealness, Maybe Amount)]

-- | A fast path for the commonest kind of transaction: if the input begins with one, parse
-- it, consuming its lines; otherwise consume nothing and return Nothing, so that the general
-- transactionp can be used. This produces exactly what transactionp would, but much more
-- cheaply, by scanning the text directly instead of running megaparsec parsers (which
-- allocate heavily per token). A simple transaction has:
--
-- - a full date (YYYY-MM-DD, or with / or . separators), an optional * or ! status mark, and
--   a description with no comment, code or secondary date;
-- - zero or more postings, each an indented line with an account name (possibly in parens or
--   brackets) and optionally an amount; no status mark, comment, balance assertion or lot
--   annotation;
-- - amounts whose number is digits, with or without digit group marks, a decimal mark and decimal
--   digits (as rawnumberp accepts; but no exponent), with an optional sign, an optional unquoted
--   commodity symbol on either side, and an optional @ or @@ cost of the same form;
--   and when there is no symbol, no default commodity directive in effect;
-- - no CR characters.
--
-- Anything else declines (returns Nothing), including anything that would be a parse error,
-- so that the general parser reports it. Numbers are interpreted by the same code as the
-- general parser (interpretRawNumber), so declared commodity styles and decimal marks work.
fasttransactionp :: JournalParser m (Maybe Transaction)
fasttransactionp = do
  j <- get
  s <- getInput
  case scanSimpleTransaction j s of
    Nothing -> return Nothing
    Just (SimpleTransaction date status desc sps, consumed) -> do
      startpos <- getSourcePos'
      ps <- mapM internPosting sps
      updateParserState $ \st -> st{stateInput = T.drop consumed s, stateOffset = stateOffset st + consumed}
      endpos <- getSourcePos'
      return $ Just $ txnTieKnot $ Transaction 0 "" (startpos, endpos) date Nothing status "" desc "" [] ps
  where
    internPosting (acct, ptype, mamt) = do
      acct' <- shareText acct
      mamt' <- traverse internSimpleAmount mamt
      return posting{paccount=acct', pamount=maybe missingmixedamt mixedAmount mamt', preal=ptype}

-- | Share a scanned amount's commodity symbol and style (and its cost's), as the general parser does.
internSimpleAmount :: Amount -> JournalParser m Amount
internSimpleAmount a = do
  c <- if T.null (acommodity a) then return "" else shareText (acommodity a)
  s <- shareAmountStyle (astyle a)
  mcost <- traverse internCost (acost a)
  return a{acommodity=c, astyle=s, acost=mcost}
  where
    internCost (UnitCost ca)  = UnitCost  <$> internSimpleAmount ca
    internCost (TotalCost ca) = TotalCost <$> internSimpleAmount ca

-- | A fast path for the commonest kind of market price directive, like fasttransactionp:
-- P, a full date, an unquoted commodity symbol, and a simple amount (as described there),
-- separated by spaces, then optionally other text, which is ignored (as marketpricedirectivep
-- does). Declines otherwise, eg if a time of day follows the date.
fastmarketpricedirectivep :: JournalParser m (Maybe PriceDirective)
fastmarketpricedirectivep = do
  j <- get
  s <- getInput
  case scanSimplePrice j s of
    Nothing -> return Nothing
    Just (date, sym, amt, consumed) -> do
      pos <- getSourcePos'
      sym' <- shareText sym
      amt' <- internSimpleAmount amt
      updateParserState $ \st -> st{stateInput = T.drop consumed s, stateOffset = stateOffset st + consumed}
      return $ Just $ PriceDirective pos date sym' amt'

-- | Recognise a simple market price directive (see fastmarketpricedirectivep) at the start of
-- the text, returning its date, commodity symbol and price amount, and the number of characters
-- consumed (through the line's newline).
scanSimplePrice :: Journal -> Text -> Maybe (Day, CommoditySymbol, Amount, Int)
scanSimplePrice j s = do
  (line, _, n) <- scanSimpleLine s
  r0 <- T.stripPrefix "P" line
  (date, r1) <- scanSimpleDate $ T.dropWhile isNonNewlineSpace r0
  -- at least one space, then the symbol (a digit here would be a time of day: decline)
  guard $ maybe False (isNonNewlineSpace . fst) $ T.uncons r1
  let r2 = T.dropWhile isNonNewlineSpace r1
  (c, _) <- T.uncons r2
  guard $ not (isDigit c) && c /= '"' && not (isNonsimpleCommodityChar c)
  let (sym, r3) = T.span (not . isNonsimpleCommodityChar) r2
  guard $ maybe False (isNonNewlineSpace . fst) $ T.uncons r3
  (amt, r4) <- scanSimpleAmount j $ T.dropWhile isNonNewlineSpace r3
  -- a cost or lot annotation on the price: decline; anything else is ignored
  guard $ maybe True (\(c', _) -> c' `notElem` ("@({[" :: String)) $ T.uncons $ T.dropWhile isNonNewlineSpace r4
  Just (date, sym, amt, n)

-- | Recognise a simple transaction (see fasttransactionp) at the start of the text, returning
-- its parts and the number of characters consumed (through the newline of its last line).
scanSimpleTransaction :: Journal -> Text -> Maybe (SimpleTransaction, Int)
scanSimpleTransaction j s0 = do
  (line1, s1, n1) <- scanSimpleLine s0
  (date, r1) <- scanSimpleDate line1
  -- the date must be followed by whitespace or the end of the line (not = or anything else)
  r2 <- case T.uncons r1 of
    Nothing -> Just r1
    Just (c, _) | isNonNewlineSpace c -> Just $ T.dropWhile isNonNewlineSpace r1
    _ -> Nothing
  let (status, r3) = case T.uncons r2 of
        Just ('*', r) -> (Cleared, r)
        Just ('!', r) -> (Pending, r)
        _             -> (Unmarked, r2)
      r4 = T.dropWhile isNonNewlineSpace r3
  -- a transaction code, or a comment: decline
  guard $ not $ T.isPrefixOf "(" r4 || T.any (== ';') r4
  (sps, n) <- scanPostings s1 n1 []
  Just (SimpleTransaction date status (T.strip r4) sps, n)
  where
    parent  = concatAccountNames $ reverse $ jparseparentaccounts j
    als     = jparsealiases j
    scanPostings s n acc = case scanSimpleLine s of
      Just (line, s', k) | isIndented line -> do
        p <- scanSimplePosting j parent als line
        scanPostings s' (n + k) (p : acc)
      _ -> Just (reverse acc, n)
    -- does the line begin with whitespace followed by something ? (like postingsp's nextlineisindented)
    isIndented line = case T.uncons line of
      Just (c, _) -> isNonNewlineSpace c && not (T.null $ T.dropWhile isNonNewlineSpace line)
      Nothing     -> False

-- | The next line of the text (without its newline), the text after it, and the number of
-- characters consumed; or Nothing if the text is empty, or the line contains a CR.
scanSimpleLine :: Text -> Maybe (Text, Text, Int)
scanSimpleLine s
  | T.null s = Nothing
  | otherwise =
      let (line, rest) = T.break (== '\n') s
      in if T.any (== '\r') line
         then Nothing
         else Just (line, T.drop 1 rest, T.length line + (if T.null rest then 0 else 1))

-- | A full date in YYYY-MM-DD, YYYY/MM/DD or YYYY.MM.DD form (with one- or two-digit month and
-- day), if valid, and the text after it.
scanSimpleDate :: Text -> Maybe (Day, Text)
scanSimpleDate t = do
  let (y, r1) = T.span isDigit t
  guard $ T.length y == 4
  (sep, r2) <- T.uncons r1
  guard $ sep == '-' || sep == '/' || sep == '.'
  let (m, r3) = T.span isDigit r2
  guard $ T.length m == 1 || T.length m == 2
  (sep2, r4) <- T.uncons r3
  guard $ sep2 == sep
  let (d, r5) = T.span isDigit r4
  guard $ T.length d == 1 || T.length d == 2
  date <- fromGregorianValid (readDecimal y) (fromInteger $ readDecimal m) (fromInteger $ readDecimal d)
  Just (date, r5)

-- | A simple posting line (see fasttransactionp): its account name (with the parent account
-- and aliases applied, and brackets removed), posting type, and amount if any.
scanSimplePosting :: Journal -> AccountName -> [AccountAlias] -> Text -> Maybe (AccountName, PostingRealness, Maybe Amount)
scanSimplePosting j parent als line = do
  -- a comment anywhere, or a status mark: decline
  guard $ not $ T.any (== ';') line
  let body = T.dropWhile isNonNewlineSpace line
  guard $ not $ T.isPrefixOf "*" body || T.isPrefixOf "!" body
  let (name, r1) = scanSimpleAccountName body
      r2 = T.dropWhile isNonNewlineSpace r1
  (mamt, r3) <-
    if T.null r2
    then Just (Nothing, r2)
    else do (a, r) <- scanSimpleAmountAndCost j r2; Just (Just a, r)
  -- anything else on the line (a balance assertion, eg): decline
  guard $ T.null $ T.dropWhile isNonNewlineSpace r3
  -- as modifiedaccountnamep and postingp do (an alias error declines, to be reported there)
  full <- either (const Nothing) Just $ accountNameApplyAliases als $ joinAccountNames parent name
  Just (textUnbracket full, accountNamePostingType full, mamt)

-- | An account name as accountnamep parses it: non-whitespace parts separated by single
-- spaces (or tabs); and the text after it.
scanSimpleAccountName :: Text -> (Text, Text)
scanSimpleAccountName t = go [part1] r1
  where
    (part1, r1) = T.span (not . isSpace) t
    go parts r = case T.uncons r of
      Just (c1, r') | isNonNewlineSpace c1, Just (c2, _) <- T.uncons r', not (isSpace c2) ->
        let (part, r'') = T.span (not . isSpace) r' in go (part : parts) r''
      _ -> (T.unwords (reverse parts), r)

-- | An amount with an optional @ or @@ cost, as amountp' parses simple ones, and the text after it.
scanSimpleAmountAndCost :: Journal -> Text -> Maybe (Amount, Text)
scanSimpleAmountAndCost j t = do
  (a, r1) <- scanSimpleAmount j t
  let r2 = T.dropWhile isNonNewlineSpace r1
  case T.uncons r2 of
    Just ('@', r3) -> do
      let (total, r4) = case T.uncons r3 of
            Just ('@', r) -> (True, r)
            _             -> (False, r3)
      (ca, r5) <- scanSimpleAmount j $ T.dropWhile isNonNewlineSpace r4
      let r6 = T.dropWhile isNonNewlineSpace r5
      -- another cost, or a lot annotation: decline
      guard $ maybe True (\(c, _) -> c `notElem` ("@({[" :: String)) $ T.uncons r6
      let amtsign = case signum (aquantity a) of 0 -> 1; sgn -> sgn
          cost | total     = TotalCost ca{aquantity = amtsign * aquantity ca}
               | otherwise = UnitCost ca
      Just (a{acost = Just cost}, r6)
    Just (c, _) | c `elem` ("({[" :: String) -> Nothing
    _ -> Just (a, r2)

-- | An amount without cost, as simpleamountp parses simple ones, and the text after it.
scanSimpleAmount :: Journal -> Text -> Maybe (Amount, Text)
scanSimpleAmount j t0 = do
  (sign1, t1) <- scanSign t0
  (c, _) <- T.uncons t1
  guard $ c /= '"'
  if not (isNonsimpleCommodityChar c)
  then do  -- symbol on the left
    let (sym, t2) = T.span (not . isNonsimpleCommodityChar) t1
        (spaced, t3) = scanSpaces t2
    (sign2, t4) <- scanSign t3
    (raw, t5) <- scanSimpleNumber t4
    (q, p, mdec, mgrps) <- interpret (suggestedStyle sym) raw
    Just (nullamt{acommodity=sym, aquantity=sign1 (sign2 q), acost=Nothing
                 ,astyle=amountstyle{ascommodityside=L, ascommodityspaced=spaced, asprecision=Precision p, asdecimalmark=mdec, asdigitgroups=mgrps}}
         ,t5)
  else do
    (raw, t2) <- scanSimpleNumber t1
    let (spaced, t3) = scanSpaces t2
    case T.uncons t3 of
      Just (c2, _) | c2 == '"' -> Nothing
                   | not (isNonsimpleCommodityChar c2) -> do  -- symbol on the right
        let (sym, t4) = T.span (not . isNonsimpleCommodityChar) t3
        (q, p, mdec, mgrps) <- interpret (suggestedStyle sym) raw
        Just (nullamt{acommodity=sym, aquantity=sign1 q, acost=Nothing
                     ,astyle=amountstyle{ascommodityside=R, ascommodityspaced=spaced, asprecision=Precision p, asdecimalmark=mdec, asdigitgroups=mgrps}}
             ,t4)
      _ -> do  -- no symbol (and no default commodity directive, which would apply: decline)
        guard $ isNothing $ jparsedefaultcommodity j
        (q, p, mdec, mgrps) <- interpret (suggestedStyle "") raw
        Just (nullamt{acommodity="", aquantity=sign1 q, acost=Nothing
                     ,astyle=amountstyle{asprecision=Precision p, asdecimalmark=mdec, asdigitgroups=mgrps}}
             ,t2)
  where
    suggestedStyle sym = journalDecimalMarkStyle j <|> journalAmountStyleFor j sym
    interpret msuggested raw = either (const Nothing) Just $ interpretRawNumber (jparsedecimalmark j) msuggested raw Nothing

-- | An optional sign, as signp parses it: a - or +, then optional spaces.
scanSign :: Text -> Maybe (Quantity -> Quantity, Text)
scanSign t = case T.uncons t of
  Just ('-', r) -> Just (negate, T.dropWhile isNonNewlineSpace r)
  Just ('+', r) -> Just (id, T.dropWhile isNonNewlineSpace r)
  _             -> Just (id, t)

-- | Skip any spaces, also saying whether there were any (like skipNonNewlineSpaces').
scanSpaces :: Text -> (Bool, Text)
scanSpaces t = (maybe False (isNonNewlineSpace . fst) $ T.uncons t, T.dropWhile isNonNewlineSpace t)

-- | A number, classified as rawnumberp would: digits, possibly in groups separated by one
-- repeated digit group mark (which can be a space), possibly with a decimal mark and decimal
-- digits, or with a leading or trailing decimal mark; and the text after it. As there, a number
-- with a single mark between digits is ambiguous (the mark might be a decimal or a digit group
-- mark), left for interpretRawNumber to resolve. A number followed by an exponent, by another
-- decimal mark, or by a space and a digit, declines (the last two are parse errors).
scanSimpleNumber :: Text -> Maybe (Either AmbiguousNumber RawNumber, Text)
scanSimpleNumber t0 = do
  (raw, r) <- case T.uncons t0 of
    -- a leading decimal mark, then digits: .5
    Just (c, t1) | isDecimalMark c -> do
      (grp, r) <- digits t1
      Just (Right $ NoSeparators mempty (Just (c, grp)), r)
    _ -> do
      (grp1, r1) <- digits t0
      case T.uncons r1 of
        -- a digit group mark (which might be a decimal mark), then a digit: more digit groups
        Just (sep, r2) | isDigitSeparatorChar sep, maybe False (isDigit . fst) (T.uncons r2) -> do
          (grp2, r3) <- digits r2
          let (grps, r4) = moreGroups sep r3
          case T.uncons r4 of
            -- then a decimal mark (not the digit group mark), and maybe decimal digits
            Just (dm, r5) | isDecimalMark dm, dm /= sep ->
              let (dgrp, r6) = fromMaybe (mempty, r5) $ digits r5
              in Just (Right $ WithSeparators sep (grp1 : grp2 : grps) (Just (dm, dgrp)), r6)
            _ | null grps && isDecimalMark sep -> Just (Left $ AmbiguousNumber grp1 sep grp2, r4)
              | otherwise -> Just (Right $ WithSeparators sep (grp1 : grp2 : grps) Nothing, r4)
        -- a trailing decimal mark: 1.
        Just (dm, r2) | isDecimalMark dm -> Just (Right $ NoSeparators grp1 (Just (dm, mempty)), r2)
        _ -> Just (Right $ NoSeparators grp1 Nothing, r1)
  guard $ numberEnds r
  Just (raw, r)
  where
    digits t = let (ds, r) = T.span isDigit t in if T.null ds then Nothing else Just (digitGroup ds, r)
    moreGroups sep t = case T.uncons t of
      Just (c, t') | c == sep, Just (g, t'') <- digits t' -> let (gs, r) = moreGroups sep t'' in (g : gs, r)
      _ -> ([], t)
    digitGroup ds = DigitGrp (fromIntegral $ T.length ds) (readDecimal ds)
    -- the number must not be followed by another decimal mark, an exponent, or a digit group
    -- mark (which can be a space) and a digit; those are errors, or more complex numbers
    numberEnds r = case T.uncons r of
      Just (c, r') | isDecimalMark c -> False
                   | c == 'e' || c == 'E' -> False
                   | isDigitSeparatorChar c, Just (d, _) <- T.uncons r', isDigit d -> False
      _ -> True

--- *** postings

-- Parse the following whitespace-beginning lines as postings, posting
-- tags, and/or comments (inferring year, if needed, from the given date).
postingsp :: Maybe Year -> JournalParser m [Posting]
postingsp mTransactionYear = manyWhile nextlineisindented (postingp mTransactionYear) <?> "postings"
  where
    -- does the next line begin with whitespace followed by something ? (a cheap check before trying to parse a posting)
    nextlineisindented = do
      (spaced, mc) <- lift peekAfterSpaces
      pure $ spaced && maybe False (not . isNewline) mc

-- linebeginningwithspaces :: JournalParser m String
-- linebeginningwithspaces = do
--   sp <- lift skipNonNewlineSpaces1
--   c <- nonspace
--   cs <- lift restofline
--   return $ sp ++ (c:cs) ++ "\n"

postingp :: Maybe Year -> JournalParser m Posting
postingp = fmap fst . postingphelper False

-- Parse the following whitespace-beginning lines as transaction posting rules, posting
-- tags, and/or comments (inferring year, if needed, from the given date).
tmpostingrulesp :: Maybe Year -> JournalParser m [TMPostingRule]
tmpostingrulesp mTransactionYear = many (tmpostingrulep mTransactionYear) <?> "posting rules"

tmpostingrulep :: Maybe Year -> JournalParser m TMPostingRule
tmpostingrulep = fmap (uncurry TMPostingRule) . postingphelper True

-- Parse a Posting, and return a flag with whether a multiplier has been detected.
-- The multiplier is used in TMPostingRules.
postingphelper :: Bool -> Maybe Year -> JournalParser m (Posting, Bool)
postingphelper isPostingRule mTransactionYear = do
    -- lift $ dbgparse 0 "postingp"
    (status, account) <- try $ do
      lift skipNonNewlineSpaces1
      status <- lift statusp
      lift skipNonNewlineSpaces
      account <- modifiedaccountnamep True
      return (status, account)
    let preal = accountNamePostingType account
    account' <- shareText $ textUnbracket account
    lift skipNonNewlineSpaces
    mult <- if isPostingRule then multiplierp else pure False
    amt <- optional $ amountp' $ if mult then MultiplierAmount else OrdinaryAmount
    lift skipNonNewlineSpaces
    mc <- lift peekChar
    massertion <- if mc == Just '=' then optional balanceassertionp else pure Nothing
    lift skipNonNewlineSpaces
    (comment,tags,mdate,mdate2) <- lift $ postingcommentp mTransactionYear
    let p = posting
            { pdate=mdate
            , pdate2=mdate2
            , pstatus=status
            , paccount=account'
            , pamount=maybe missingmixedamt mixedAmount amt
            , pcomment=comment
            , preal=preal
            , ptags=tags
            , pbalanceassertion=massertion
            }
    -- Build the posting now (its fields are strict, so this also evaluates the
    -- amount), rather than leaving a thunk holding the parser's intermediate
    -- values until finalisation, which inflates peak memory use on large journals.
    p `seq` return (p, mult)
  where
    multiplierp = option False $ True <$ char '*'

--- ** tests

tests_JournalReader = testGroup "JournalReader" [

   let p = lift accountnamep :: JournalParser IO AccountName in
   testGroup "accountnamep" [
     testCase "basic" $ assertParse p "a:b:c"
    ,testCase "single space is part of the account name" $ assertParseEq p "a b:c" "a b:c"
    -- ,testCase "empty inner component" $ assertParseError p "a::c" ""  -- TODO
    -- ,testCase "empty leading component" $ assertParseError p ":b:c" "x"
    -- ,testCase "empty trailing component" $ assertParseError p "a:b:" "x"
    ]

  -- "Parse a date in YYYY/MM/DD format.
  -- Hyphen (-) and period (.) are also allowed as separators.
  -- The year may be omitted if a default year has been set.
  -- Leading zeroes may be omitted."
  ,testGroup "datep" [
     testCase "YYYY/MM/DD" $ assertParseEq datep "2018/01/01" (fromGregorian 2018 1 1)
    ,testCase "YYYY-MM-DD" $ assertParse datep "2018-01-01"
    ,testCase "YYYY.MM.DD" $ assertParse datep "2018.01.01"
    ,testCase "yearless date with no default year" $ assertParseError datep "1/1" "current year is unknown"
    ,testCase "yearless date with default year" $ do
      let s = "1/1"
      ep <- parseWithState nulljournal{jparsedefaultyear=Just 2018} datep s
      either (assertFailure . ("parse error at "++) . customErrorBundlePretty) (const $ return ()) ep
    ,testCase "no leading zero" $ assertParse datep "2018/1/1"
    ]
  ,testCase "datetimep" $ do
     let
       good  = assertParse datetimep
       bad t = assertParseError datetimep t ""
     good "2011/1/1 00:00"
     good "2011/1/1 23:59:59"
     bad "2011/1/1"
     bad "2011/1/1 24:00:00"
     bad "2011/1/1 00:60:00"
     bad "2011/1/1 00:00:60"
     bad "2011/1/1 3:5:7"
     -- timezone is parsed but ignored
     let t = LocalTime (fromGregorian 2018 1 1) (TimeOfDay 0 0 0)
     assertParseEq datetimep "2018/1/1 00:00-0800" t
     assertParseEq datetimep "2018/1/1 00:00+1234" t

  ,testGroup "periodictransactionp" [

    testCase "more period text in comment after one space" $ assertParseEq periodictransactionp
      "~ monthly from 2018/6 ;In 2019 we will change this\n"
      nullperiodictransaction {
         ptperiodexpr  = "monthly from 2018/6"
        ,ptinterval    = Months 1
        ,ptspan        = DateSpan (Just $ Flex $ fromGregorian 2018 6 1) Nothing
        ,ptsourcepos   = (SourcePos "" (mkPos 1) (mkPos 1), SourcePos "" (mkPos 2) (mkPos 1))
        ,ptdescription = ""
        ,ptcomment     = "In 2019 we will change this\n"
        }

    ,testCase "more period text in description after two spaces" $ assertParseEq periodictransactionp
      "~ monthly from 2018/6   In 2019 we will change this\n"
      nullperiodictransaction {
         ptperiodexpr  = "monthly from 2018/6"
        ,ptinterval    = Months 1
        ,ptspan        = DateSpan (Just $ Flex $ fromGregorian 2018 6 1) Nothing
        ,ptsourcepos   = (SourcePos "" (mkPos 1) (mkPos 1), SourcePos "" (mkPos 2) (mkPos 1))
        ,ptdescription = "In 2019 we will change this"
        ,ptcomment     = ""
        }

    ,testCase "Next year in description" $ assertParseEq periodictransactionp
      "~ monthly  Next year blah blah\n"
      nullperiodictransaction {
         ptperiodexpr  = "monthly"
        ,ptinterval    = Months 1
        ,ptspan        = DateSpan Nothing Nothing
        ,ptsourcepos   = (SourcePos "" (mkPos 1) (mkPos 1), SourcePos "" (mkPos 2) (mkPos 1))
        ,ptdescription = "Next year blah blah"
        ,ptcomment     = ""
        }

    ,testCase "Just date, no description" $ assertParseEq periodictransactionp
      "~ 2019-01-04\n"
      nullperiodictransaction {
         ptperiodexpr  = "2019-01-04"
        ,ptinterval    = NoInterval
        ,ptspan        = DateSpan (Just $ Exact $ fromGregorian 2019 1 4) (Just $ Exact $ fromGregorian 2019 1 5)
        ,ptsourcepos   = (SourcePos "" (mkPos 1) (mkPos 1), SourcePos "" (mkPos 2) (mkPos 1))
        ,ptdescription = ""
        ,ptcomment     = ""
        }

    ,testCase "Just date, no description + empty transaction comment" $ assertParse periodictransactionp
      "~ 2019-01-04\n  ;\n  a  1\n  b\n"

    ]

  ,testGroup "postingp" [
     testCase "basic" $ assertParseEq (postingp Nothing)
      "  expenses:food:dining  $10.00   ; a: a a \n   ; b: b b \n"
      posting{
        paccount="expenses:food:dining",
        pamount=mixedAmount (usd 10),
        pcomment="a: a a\nb: b b\n",
        ptags=[("a","a a"), ("b","b b")]
        }

    ,testCase "posting dates" $ assertParseEq (postingp Nothing)
      " a  1. ; date:2012/11/28, date2=2012/11/29,b:b\n"
      nullposting{
         paccount="a"
        ,pamount=mixedAmount (num 1)
        ,pcomment="date:2012/11/28, date2=2012/11/29,b:b\n"
        ,ptags=[("date", "2012/11/28"), ("date2=2012/11/29,b", "b")] -- TODO tag name parsed too greedily
        ,pdate=Just $ fromGregorian 2012 11 28
        ,pdate2=Nothing  -- Just $ fromGregorian 2012 11 29
        }

    ,testCase "posting dates bracket syntax" $ assertParseEq (postingp Nothing)
      " a  1. ; [2012/11/28=2012/11/29]\n"
      nullposting{
         paccount="a"
        ,pamount=mixedAmount (num 1)
        ,pcomment="[2012/11/28=2012/11/29]\n"
        ,ptags=[]
        ,pdate= Just $ fromGregorian 2012 11 28
        ,pdate2=Just $ fromGregorian 2012 11 29
        }

    ,testCase "quoted commodity symbol with digits" $ assertParse (postingp Nothing) "  a  1 \"DE123\"\n"

    ,testCase "only lot price" $ assertParse (postingp Nothing) "  a  1A {1B}\n"
    ,testCase "fixed lot price" $ assertParse (postingp Nothing) "  a  1A {=1B}\n"
    ,testCase "total lot price" $ assertParse (postingp Nothing) "  a  1A {{1B}}\n"
    ,testCase "fixed total lot price, and spaces" $ assertParse (postingp Nothing) "  a  1A {{  =  1B }}\n"
    ,testCase "lot price before transaction price" $ assertParse (postingp Nothing) "  a  1A {1B} @ 1B\n"
    ,testCase "lot price after transaction price" $ assertParse (postingp Nothing) "  a  1A @ 1B {1B}\n"
    ,testCase "lot price after balance assertion not allowed" $ assertParseError (postingp Nothing) "  a  1A @ 1B = 1A {1B}\n" "unexpected '{'"
    ,testCase "only lot date" $ assertParse (postingp Nothing) "  a  1A [2000-01-01]\n"
    ,testCase "transaction price, lot price, lot date" $ assertParse (postingp Nothing) "  a  1A @ 1B {1B} [2000-01-01]\n"
    ,testCase "lot date, lot price, transaction price" $ assertParse (postingp Nothing) "  a  1A [2000-01-01] {1B} @ 1B\n"

    ,testCase "balance assertion over entire contents of account" $ assertParse (postingp Nothing) "  a  $1 == $1\n"
    ]

  ,testGroup "transactionmodifierp" [

    testCase "basic" $ assertParseEq transactionmodifierp
      "= (some value expr)\n some:postings  1.\n"
      nulltransactionmodifier {
        tmquerytxt = "(some value expr)"
       ,tmpostingrules = [TMPostingRule nullposting{paccount="some:postings", pamount=mixedAmount (num 1)} False]
      }
    ]

  ,testGroup "transactionp" [

     testCase "just a date" $ assertParseEq transactionp "2015/1/1\n" nulltransaction{tdate=fromGregorian 2015 1 1}

    ,testCase "more complex" $ assertParseEq transactionp
      (T.unlines [
        "2012/05/14=2012/05/15 (code) desc  ; tcomment1",
        "    ; tcomment2",
        "    ; ttag1: val1",
        "    * a         $1.00  ; pcomment1",
        "    ; pcomment2",
        "    ; ptag1: val1",
        "    ; ptag2: val2"
        ])
      nulltransaction{
        tsourcepos=(SourcePos "" (mkPos 1) (mkPos 1), SourcePos "" (mkPos 8) (mkPos 1)),  -- 8 because there are 7 lines
        tprecedingcomment="",
        tdate=fromGregorian 2012 5 14,
        tdate2=Just $ fromGregorian 2012 5 15,
        tstatus=Unmarked,
        tcode="code",
        tdescription="desc",
        tcomment="tcomment1\ntcomment2\nttag1: val1\n",
        ttags=[("ttag1","val1")],
        tpostings=[
          nullposting{
            pdate=Nothing,
            pstatus=Cleared,
            paccount="a",
            pamount=mixedAmount (usd 1),
            pcomment="pcomment1\npcomment2\nptag1: val1\nptag2: val2\n",
            preal=RealPosting,
            ptags=[("ptag1","val1"),("ptag2","val2")],
            ptransaction=Nothing
            }
          ]
      }

    ,testCase "parses a well-formed transaction" $
      assertBool "" $ isRight $ rjp transactionp $ T.unlines
        ["2007/01/28 coopportunity"
        ,"    expenses:food:groceries                   $47.18"
        ,"    assets:checking                          $-47.18"
        ,""
        ]

    ,testCase "does not parse a following comment as part of the description" $
      assertParseEqOn transactionp "2009/1/1 a ;comment\n b 1\n" tdescription "a"

    ,testCase "parses a following whitespace line" $
      assertBool "" $ isRight $ rjp transactionp $ T.unlines
        ["2012/1/1"
        ,"  a  1"
        ,"  b"
        ," "
        ]

    ,testCase "parses an empty transaction comment following whitespace line" $
      assertBool "" $ isRight $ rjp transactionp $ T.unlines
        ["2012/1/1"
        ,"  ;"
        ,"  a  1"
        ,"  b"
        ," "
        ]

    ,testCase "comments everywhere, two postings parsed" $
      assertParseEqOn transactionp
        (T.unlines
          ["2009/1/1 x  ; transaction comment"
          ," a  1  ; posting 1 comment"
          ," ; posting 1 comment 2"
          ," b"
          ," ; posting 2 comment"
          ])
        (length . tpostings)
        2

    ]

  -- directives

  ,testGroup "directivep" [
    testCase "supports !" $ do
        assertParseE (directivep definputopts) "!account a\n"
        assertParseE (directivep definputopts) "!D 1.0\n"
     ]

  ,testGroup "accountdirectivep" [
       testCase "with-comment"       $ assertParse accountdirectivep "account a:b  ; a comment\n"
      ,testCase "does-not-support-!" $ assertParseError accountdirectivep "!account a:b\n" ""
      ,testCase "account-type-code"  $ assertParse accountdirectivep "account a:b  ; type:A\n"
      ,testCase "account-type-tag"   $ assertParseStateOn accountdirectivep "account a:b  ; type:asset\n"
        jdeclaredaccounts
        [("a:b", AccountDeclarationInfo{adicomment          = "type:asset\n"
                                       ,aditags             = [("type","asset")]
                                       ,adideclarationorder = 1
                                       ,adisourcepos        = nullsourcepos
                                       })
        ]
      ]

  ,testCase "commodityconversiondirectivep" $ do
     assertParse commodityconversiondirectivep "C 1h = $50.00\n"

  ,testCase "defaultcommoditydirectivep" $ do
      assertParse defaultcommoditydirectivep "D $1,000.0\n"
      assertParseError defaultcommoditydirectivep "D $1000\n" "Please include a decimal point or decimal comma"

  ,testGroup "defaultyeardirectivep" [
      testCase "1000" $ assertParse defaultyeardirectivep "Y 1000" -- XXX no \n like the others
     -- ,testCase "999" $ assertParseError defaultyeardirectivep "Y 999" "bad year number"
     ,testCase "12345" $ assertParse defaultyeardirectivep "Y 12345"
     ]

  ,testCase "ignoredpricecommoditydirectivep" $ do
     assertParse ignoredpricecommoditydirectivep "N $\n"

  ,testGroup "includedirectivep" [
      testCase "include" $ assertParseErrorE (includedirectivep definputopts) "include nosuchfile\n" "No files were matched by: nosuchfile"
     ,testCase "glob" $ assertParseErrorE (includedirectivep definputopts) "include nosuchfile*\n" "No files were matched by: nosuchfile*"
     ]

  ,testCase "marketpricedirectivep" $ assertParseEq marketpricedirectivep
    "P 2017/01/30 BTC $922.83\n"
    PriceDirective{
      pdsourcepos = nullsourcepos,
      pddate      = fromGregorian 2017 1 30,
      pdcommodity = "BTC",
      pdamount    = usd 922.83
      }

  ,testGroup "payeedirectivep" [
        testCase "simple"             $ assertParse payeedirectivep "payee foo\n"
       ,testCase "with-comment"       $ assertParse payeedirectivep "payee foo ; comment\n"
       ,testCase "double-quoted"      $ assertParse payeedirectivep "payee \"a b\"\n"
       ,testCase "empty        "      $ assertParse payeedirectivep "payee \"\"\n"
       ]

  ,testCase "tagdirectivep" $ do
     assertParse tagdirectivep "tag foo \n"

  ,testCase "endtagdirectivep" $ do
      assertParse endtagdirectivep "end tag \n"
      assertParse endtagdirectivep "end apply tag \n"

  ,testGroup "journalp" [
    testCase "empty file" $ assertParseEqE (journalp definputopts) "" nulljournal
    ]

   -- these are defined here rather than in Common so they can use journalp
  ,testCase "parseAndFinaliseJournal" $ do
      ej <- runExceptT $ parseAndFinaliseJournal (journalp definputopts) definputopts "" "2019-1-1\n"
      let Right j = ej
      assertEqual "" [""] $ journalFilePaths j

  ]
