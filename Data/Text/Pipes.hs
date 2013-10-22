{-# LANGUAGE RankNTypes, TypeFamilies, CPP #-}

{-| This module provides @pipes@ utilities for \"text streams\", which are
    streams of 'Text' chunks.  The individual chunks are uniformly @strict@, but 
    can interact lazy 'Text's  and 'IO.Handle's.

    To stream to or from 'IO.Handle's, use 'fromHandle' or 'toHandle'.  For
    example, the following program copies a document from one file to another:

> import Pipes
> import qualified Data.Text.Pipes as Text
> import System.IO
>
> main =
>     withFile "inFile.txt"  ReadMode  $ \hIn  ->
>     withFile "outFile.txt" WriteMode $ \hOut ->
>     runEffect $ Text.fromHandle hIn >-> Text.toHandle hOut

To stream from files, the following is perhaps more Prelude-like (note that it uses Pipes.Safe):

> import Pipes
> import qualified Data.Text.Pipes as Text
> import Pipes.Safe
>
> main = runSafeT $ runEffect $ Text.readFile "inFile.txt" >-> Text.writeFile "outFile.txt"

    You can stream to and from 'stdin' and 'stdout' using the predefined 'stdin'
    and 'stdout' proxies, as with the following \"echo\" program:

> main = runEffect $ Text.stdin >-> Text.stdout

    You can also translate pure lazy 'TL.Text's to and from proxies:

> main = runEffect $ Text.fromLazy (TL.pack "Hello, world!\n") >-> Text.stdout

    In addition, this module provides many functions equivalent to lazy
    'Text' functions so that you can transform or fold text streams.  For
    example, to stream only the first three lines of 'stdin' to 'stdout' you
    might write:

> import Pipes
> import qualified Pipes.Text as Text
> import qualified Pipes.Parse as Parse
>
> main = runEffect $ takeLines 3 Text.stdin >-> Text.stdout
>   where
>     takeLines n = Text.unlines . Parse.takeFree n . Text.lines

    The above program will never bring more than one chunk of text (~ 32 KB) into
    memory, no matter how long the lines are.

    Note that functions in this library are designed to operate on streams that
    are insensitive to text boundaries.  This means that they may freely split
    text into smaller texts and /discard empty texts/.  However, they will
    /never concatenate texts/ in order to provide strict upper bounds on memory
    usage.
-}

module Data.Text.Pipes  (
    -- * Producers
    fromLazy,
    stdin,
    fromHandle,
    readFile,
    stdinLn,

    -- * Consumers
    stdout,
    stdoutLn,
    toHandle,
    writeFile,

    -- * Pipes
    map,
    concatMap,
    take,
    drop,
    takeWhile,
    dropWhile,
    filter,
    scan,

    -- * Folds
    toLazy,
    toLazyM,
    fold,
    head,
    last,
    null,
    length,
    any,
    all,
    maximum,
    minimum,
    find,
    index,
--    elemIndex,
--    findIndex,
    count,

    -- * Splitters
    splitAt,
    chunksOf,
    span,
    break,
    splitWith,
    split,
    groupBy,
    group,
    lines,
    words,
#if MIN_VERSION_text(0,11,4)
    decodeUtf8,
#endif
    -- * Transformations
    intersperse,
    
    -- * Joiners
    intercalate,
    unlines,
    unwords,

    -- * Character Parsers
    -- $parse
    nextChar,
    drawChar,
    unDrawChar,
    peekChar,
    isEndOfChars,

    -- * Re-exports
    -- $reexports
    module Data.Text,
    module Pipes.Parse
    ) where

import Control.Exception (throwIO, try)
import Control.Monad (liftM, unless)
import Control.Monad.Trans.State.Strict (StateT)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Encoding as TE
import Data.Text (Text)
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.IO as TL
import Data.Text.Lazy.Internal (foldrChunks, defaultChunkSize)
import Data.ByteString.Unsafe (unsafeTake, unsafeDrop)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Char (ord)
import Data.Functor.Identity (Identity)
import qualified Data.List as List
import Foreign.C.Error (Errno(Errno), ePIPE)
import qualified GHC.IO.Exception as G
import Pipes
import qualified Pipes.ByteString.Parse as PBP
import Data.Text.Pipes.Parse (
    nextChar, drawChar, unDrawChar, peekChar, isEndOfChars )
import Pipes.Core (respond, Server')
import qualified Pipes.Parse as PP
import Pipes.Parse (input, concat, FreeT)
import qualified Pipes.Safe.Prelude as Safe
import qualified Pipes.Safe as Safe
import Pipes.Safe (MonadSafe(..), Base(..))
import qualified Pipes.Prelude as P
import qualified System.IO as IO
import Data.Char (isSpace)
import Prelude hiding (
    all,
    any,
    break,
    concat,
    concatMap,
    drop,
    dropWhile,
    elem,
    filter,
    head,
    last,
    lines,
    length,
    map,
    maximum,
    minimum,
    notElem,
    null,
    readFile,
    span,
    splitAt,
    take,
    takeWhile,
    unlines,
    unwords,
    words,
    writeFile )

-- | Convert a lazy 'TL.Text' into a 'Producer' of strict 'Text's
fromLazy :: (Monad m) => TL.Text -> Producer' Text m ()
fromLazy  = foldrChunks (\e a -> yield e >> a) (return ()) 
{-# INLINABLE fromLazy #-}

-- | Stream bytes from 'stdin'
stdin :: MonadIO m => Producer' Text m ()
stdin = fromHandle IO.stdin
{-# INLINABLE stdin #-}

{-| Convert a 'IO.Handle' into a text stream using a text size 
    determined by the good sense of the text library. 

-}

fromHandle :: MonadIO m => IO.Handle -> Producer' Text m ()
fromHandle h = go where
    go = do txt <- liftIO (T.hGetChunk h)
            unless (T.null txt) $ do yield txt
                                     go
{-# INLINABLE fromHandle#-}

{-| Stream text from a file using Pipes.Safe

>>> runSafeT $ runEffect $ Text.readFile "hello.hs" >-> Text.map toUpper >-> hoist lift Text.stdout
MAIN = PUTSTRLN "HELLO WORLD"
-}

readFile :: (MonadSafe m, Base m ~ IO) => FilePath -> Producer' Text m ()
readFile file = Safe.withFile file IO.ReadMode fromHandle
{-# INLINABLE readFile #-}

{-| Stream lines of text from stdin (for testing in ghci etc.) 

>>> let safely = runSafeT . runEffect
>>> safely $ for Text.stdinLn (lift . lift . print . T.length)
hello
5
world
5

-}
stdinLn :: MonadIO m => Producer' Text m ()
stdinLn = go where
    go = do
        eof <- liftIO (IO.hIsEOF IO.stdin)
        unless eof $ do
            txt <- liftIO (T.hGetLine IO.stdin)
            yield txt
            go


{-| Stream text to 'stdout'

    Unlike 'toHandle', 'stdout' gracefully terminates on a broken output pipe.

    Note: For best performance, use @(for source (liftIO . putStr))@ instead of
    @(source >-> stdout)@ in suitable cases.
-}
stdout :: MonadIO m => Consumer' Text m ()
stdout = go
  where
    go = do
        txt <- await
        x  <- liftIO $ try (T.putStr txt)
        case x of
            Left (G.IOError { G.ioe_type  = G.ResourceVanished
                            , G.ioe_errno = Just ioe })
                 | Errno ioe == ePIPE
                     -> return ()
            Left  e  -> liftIO (throwIO e)
            Right () -> go
{-# INLINABLE stdout #-}

stdoutLn :: (MonadIO m) => Consumer' Text m ()
stdoutLn = go
  where
    go = do
        str <- await
        x   <- liftIO $ try (T.putStrLn str)
        case x of
           Left (G.IOError { G.ioe_type  = G.ResourceVanished
                           , G.ioe_errno = Just ioe })
                | Errno ioe == ePIPE
                    -> return ()
           Left  e  -> liftIO (throwIO e)
           Right () -> go
{-# INLINABLE stdoutLn #-}

{-| Convert a text stream into a 'Handle'

    Note: again, for best performance, where possible use 
    @(for source (liftIO . hPutStr handle))@ instead of @(source >-> toHandle handle)@.
-}
toHandle :: MonadIO m => IO.Handle -> Consumer' Text m r
toHandle h = for cat (liftIO . T.hPutStr h)
{-# INLINABLE toHandle #-}

-- | Stream text into a file. Uses @pipes-safe@.
writeFile :: (MonadSafe m, Base m ~ IO) => FilePath -> Consumer' Text m ()
writeFile file = Safe.withFile file IO.WriteMode toHandle

-- | Apply a transformation to each 'Char' in the stream
map :: (Monad m) => (Char -> Char) -> Pipe Text Text m r
map f = P.map (T.map f)
{-# INLINABLE map #-}

-- | Map a function over the characters of a text stream and concatenate the results
concatMap
    :: (Monad m) => (Char -> Text) -> Pipe Text Text m r
concatMap f = P.map (T.concatMap f)
{-# INLINABLE concatMap #-}

-- | @(take n)@ only allows @n@ individual characters to pass; 
--  contrast @Pipes.Prelude.take@ which would let @n@ chunks pass.
take :: (Monad m, Integral a) => a -> Pipe Text Text m ()
take n0 = go n0 where
    go n
        | n <= 0    = return ()
        | otherwise = do
            txt <- await
            let len = fromIntegral (T.length txt)
            if (len > n)
                then yield (T.take (fromIntegral n) txt)
                else do
                    yield txt
                    go (n - len)
{-# INLINABLE take #-}

-- | @(drop n)@ drops the first @n@ characters
drop :: (Monad m, Integral a) => a -> Pipe Text Text m r
drop n0 = go n0 where
    go n
        | n <= 0    = cat
        | otherwise = do
            txt <- await
            let len = fromIntegral (T.length txt)
            if (len >= n)
                then do
                    yield (T.drop (fromIntegral n) txt)
                    cat
                else go (n - len)
{-# INLINABLE drop #-}

-- | Take characters until they fail the predicate
takeWhile :: (Monad m) => (Char -> Bool) -> Pipe Text Text m ()
takeWhile predicate = go
  where
    go = do
        txt <- await
        let (prefix, suffix) = T.span predicate txt
        if (T.null suffix)
            then do
                yield txt
                go
            else yield prefix
{-# INLINABLE takeWhile #-}

-- | Drop characters until they fail the predicate
dropWhile :: (Monad m) => (Char -> Bool) -> Pipe Text Text m r
dropWhile predicate = go where
    go = do
        txt <- await
        case T.findIndex (not . predicate) txt of
            Nothing -> go
            Just i -> do
                yield (T.drop i txt)
                cat
{-# INLINABLE dropWhile #-}

-- | Only allows 'Char's to pass if they satisfy the predicate
filter :: (Monad m) => (Char -> Bool) -> Pipe Text Text m r
filter predicate = P.map (T.filter predicate)
{-# INLINABLE filter #-}


-- | Strict left scan over the characters
scan
    :: (Monad m)
    => (Char -> Char -> Char) -> Char -> Pipe Text Text m r
scan step begin = go begin
  where
    go c = do
        txt <- await
        let txt' = T.scanl step c txt
            c' = T.last txt'
        yield txt'
        go c'
{-# INLINABLE scan #-}

{-| Fold a pure 'Producer' of strict 'Text's into a lazy
    'TL.Text'
-}
toLazy :: Producer Text Identity () -> TL.Text
toLazy = TL.fromChunks . P.toList
{-# INLINABLE toLazy #-}

{-| Fold an effectful 'Producer' of strict 'Text's into a lazy
    'TL.Text'

    Note: 'toLazyM' is not an idiomatic use of @pipes@, but I provide it for
    simple testing purposes.  Idiomatic @pipes@ style consumes the chunks
    immediately as they are generated instead of loading them all into memory.
-}
toLazyM :: (Monad m) => Producer Text m () -> m TL.Text
toLazyM = liftM TL.fromChunks . P.toListM
{-# INLINABLE toLazyM #-}

-- | Reduce the text stream using a strict left fold over characters
fold
    :: Monad m
    => (x -> Char -> x) -> x -> (x -> r) -> Producer Text m () -> m r
fold step begin done = P.fold (T.foldl' step) begin done
{-# INLINABLE fold #-}

-- | Retrieve the first 'Char'
head :: (Monad m) => Producer Text m () -> m (Maybe Char)
head = go
  where
    go p = do
        x <- nextChar p
        case x of
            Left   _      -> return  Nothing
            Right (c, _) -> return (Just c)
{-# INLINABLE head #-}

-- | Retrieve the last 'Char'
last :: (Monad m) => Producer Text m () -> m (Maybe Char)
last = go Nothing
  where
    go r p = do
        x <- next p
        case x of
            Left   ()      -> return r
            Right (txt, p') ->
                if (T.null txt)
                then go r p'
                else go (Just $ T.last txt) p'
{-# INLINABLE last #-}

-- | Determine if the stream is empty
null :: (Monad m) => Producer Text m () -> m Bool
null = P.all T.null
{-# INLINABLE null #-}

-- | Count the number of bytes
length :: (Monad m, Num n) => Producer Text m () -> m n
length = P.fold (\n txt -> n + fromIntegral (T.length txt)) 0 id
{-# INLINABLE length #-}

-- | Fold that returns whether 'M.Any' received 'Char's satisfy the predicate
any :: (Monad m) => (Char -> Bool) -> Producer Text m () -> m Bool
any predicate = P.any (T.any predicate)
{-# INLINABLE any #-}

-- | Fold that returns whether 'M.All' received 'Char's satisfy the predicate
all :: (Monad m) => (Char -> Bool) -> Producer Text m () -> m Bool
all predicate = P.all (T.all predicate)
{-# INLINABLE all #-}

-- | Return the maximum 'Char' within a byte stream
maximum :: (Monad m) => Producer Text m () -> m (Maybe Char)
maximum = P.fold step Nothing id
  where
    step mc txt =
        if (T.null txt)
        then mc
        else Just $ case mc of
            Nothing -> T.maximum txt
            Just c -> max c (T.maximum txt)
{-# INLINABLE maximum #-}

-- | Return the minimum 'Char' within a byte stream
minimum :: (Monad m) => Producer Text m () -> m (Maybe Char)
minimum = P.fold step Nothing id
  where
    step mc txt =
        if (T.null txt)
        then mc
        else case mc of
            Nothing -> Just (T.minimum txt)
            Just c -> Just (min c (T.minimum txt))
{-# INLINABLE minimum #-}

-- | Find the first element in the stream that matches the predicate
find
    :: (Monad m)
    => (Char -> Bool) -> Producer Text m () -> m (Maybe Char)
find predicate p = head (p >-> filter predicate)
{-# INLINABLE find #-}

-- | Index into a byte stream
index
    :: (Monad m, Integral a)
    => a-> Producer Text m () -> m (Maybe Char)
index n p = head (p >-> drop n)
{-# INLINABLE index #-}

-- | Find the index of an element that matches the given 'Char'
-- elemIndex
--     :: (Monad m, Num n) => Char -> Producer Text m () -> m (Maybe n)
-- elemIndex w8 = findIndex (w8 ==)
-- {-# INLINABLE elemIndex #-}

-- | Store the first index of an element that satisfies the predicate
-- findIndex
--     :: (Monad m, Num n)
--     => (Char -> Bool) -> Producer Text m () -> m (Maybe n)
-- findIndex predicate p = P.head (p >-> findIndices predicate)
-- {-# INLINABLE findIndex #-}
-- 
-- | Store a tally of how many segments match the given 'Text'
count :: (Monad m, Num n) => Text -> Producer Text m () -> m n
count c p = P.fold (+) 0 id (p >-> P.map (fromIntegral . T.count c))
{-# INLINABLE count #-}

#if MIN_VERSION_text(0,11,4)
-- | Transform a Pipe of 'ByteString's expected to be UTF-8 encoded
-- into a Pipe of Text
decodeUtf8
  :: Monad m
  => Producer ByteString m r -> Producer Text m (Producer ByteString m r)
decodeUtf8 = go TE.streamDecodeUtf8
  where go dec p = do
            x <- lift (next p)
            case x of
                Left r -> return (return r)
                Right (chunk, p') -> do
                    let TE.Some text l dec' = dec chunk
                    if B.null l
                      then do
                          yield text
                          go dec' p'
                      else return $ do
                          yield l
                          p'
{-# INLINEABLE decodeUtf8 #-}
#endif

-- | Splits a 'Producer' after the given number of characters
splitAt
    :: (Monad m, Integral n)
    => n
    -> Producer Text m r
    -> Producer' Text m (Producer Text m r)
splitAt = go
  where
    go 0 p = return p
    go n p = do
        x <- lift (next p)
        case x of
            Left   r       -> return (return r)
            Right (txt, p') -> do
                let len = fromIntegral (T.length txt)
                if (len <= n)
                    then do
                        yield txt
                        go (n - len) p'
                    else do
                        let (prefix, suffix) = T.splitAt (fromIntegral n) txt
                        yield prefix
                        return (yield suffix >> p')
{-# INLINABLE splitAt #-}

-- | Split a text stream into 'FreeT'-delimited text streams of fixed size
chunksOf
    :: (Monad m, Integral n)
    => n -> Producer Text m r -> FreeT (Producer Text m) m r
chunksOf n p0 = PP.FreeT (go p0)
  where
    go p = do
        x <- next p
        return $ case x of
            Left   r       -> PP.Pure r
            Right (txt, p') -> PP.Free $ do
                p'' <- splitAt n (yield txt >> p')
                return $ PP.FreeT (go p'')
{-# INLINABLE chunksOf #-}

{-| Split a text stream in two, where the first text stream is the longest
    consecutive group of text that satisfy the predicate
-}
span
    :: (Monad m)
    => (Char -> Bool)
    -> Producer Text m r
    -> Producer' Text m (Producer Text m r)
span predicate = go
  where
    go p = do
        x <- lift (next p)
        case x of
            Left   r       -> return (return r)
            Right (txt, p') -> do
                let (prefix, suffix) = T.span predicate txt
                if (T.null suffix)
                    then do
                        yield txt
                        go p'
                    else do
                        yield prefix
                        return (yield suffix >> p')
{-# INLINABLE span #-}

{-| Split a byte stream in two, where the first byte stream is the longest
    consecutive group of bytes that don't satisfy the predicate
-}
break
    :: (Monad m)
    => (Char -> Bool)
    -> Producer Text m r
    -> Producer Text m (Producer Text m r)
break predicate = span (not . predicate)
{-# INLINABLE break #-}

{-| Split a byte stream into sub-streams delimited by bytes that satisfy the
    predicate
-}
splitWith
    :: (Monad m)
    => (Char -> Bool)
    -> Producer Text m r
    -> PP.FreeT (Producer Text m) m r
splitWith predicate p0 = PP.FreeT (go0 p0)
  where
    go0 p = do
        x <- next p
        case x of
            Left   r       -> return (PP.Pure r)
            Right (txt, p') ->
                if (T.null txt)
                then go0 p'
                else return $ PP.Free $ do
                    p'' <- span (not . predicate) (yield txt >> p')
                    return $ PP.FreeT (go1 p'')
    go1 p = do
        x <- nextChar p
        return $ case x of
            Left   r      -> PP.Pure r
            Right (_, p') -> PP.Free $ do
                    p'' <- span (not . predicate) p'
                    return $ PP.FreeT (go1 p'')
{-# INLINABLE splitWith #-}

-- | Split a text stream using the given 'Char' as the delimiter
split :: (Monad m)
      => Char
      -> Producer Text m r
      -> FreeT (Producer Text m) m r
split c = splitWith (c ==)
{-# INLINABLE split #-}

{-| Group a text stream into 'FreeT'-delimited byte streams using the supplied
    equality predicate
-}
groupBy
    :: (Monad m)
    => (Char -> Char -> Bool)
    -> Producer Text m r
    -> FreeT (Producer Text m) m r
groupBy equal p0 = PP.FreeT (go p0)
  where
    go p = do
        x <- next p
        case x of
            Left   r       -> return (PP.Pure r)
            Right (txt, p') -> case (T.uncons txt) of
                Nothing      -> go p'
                Just (c, _) -> do
                    return $ PP.Free $ do
                        p'' <- span (equal c) (yield txt >> p')
                        return $ PP.FreeT (go p'')
{-# INLINABLE groupBy #-}

-- | Group a byte stream into 'FreeT'-delimited byte streams of identical bytes
group
    :: (Monad m) => Producer Text m r -> FreeT (Producer Text m) m r
group = groupBy (==)
{-# INLINABLE group #-}

{-| Split a byte stream into 'FreeT'-delimited lines

    Note: This function is purely for demonstration purposes since it assumes a
    particular encoding.  You should prefer the 'Data.Text.Text' equivalent of
    this function from the upcoming @pipes-text@ library.
-}
lines
    :: (Monad m) => Producer Text m r -> FreeT (Producer Text m) m r
lines p0 = PP.FreeT (go0 p0)
  where
    go0 p = do
        x <- next p
        case x of
            Left   r       -> return (PP.Pure r)
            Right (txt, p') ->
                if (T.null txt)
                then go0 p'
                else return $ PP.Free $ go1 (yield txt >> p')
    go1 p = do
        p' <- break ('\n' ==) p
        return $ PP.FreeT (go2 p')
    go2 p = do
        x  <- nextChar p
        return $ case x of
            Left   r      -> PP.Pure r
            Right (_, p') -> PP.Free (go1 p')
{-# INLINABLE lines #-}



-- | Split a text stream into 'FreeT'-delimited words
words
    :: (Monad m) => Producer Text m r -> FreeT (Producer Text m) m r
words p0 = removeEmpty (splitWith isSpace p0)
  where
    removeEmpty f = PP.FreeT $ do
        x <- PP.runFreeT f
        case x of
            PP.Pure r -> return (PP.Pure r)
            PP.Free p -> do
                y <- next p
                case y of
                    Left   f'      -> PP.runFreeT (removeEmpty f')
                    Right (bs, p') -> return $ PP.Free $ do
                        yield bs
                        f' <- p'
                        return (removeEmpty f')
{-# INLINABLE words #-}

-- | Intersperse a 'Char' in between the bytes of the byte stream
intersperse
    :: (Monad m) => Char -> Producer Text m r -> Producer Text m r
intersperse c = go0
  where
    go0 p = do
        x <- lift (next p)
        case x of
            Left   r       -> return r
            Right (txt, p') -> do
                yield (T.intersperse c txt)
                go1 p'
    go1 p = do
        x <- lift (next p)
        case x of
            Left   r       -> return r
            Right (txt, p') -> do
                yield (T.singleton c)
                yield (T.intersperse c txt)
                go1 p'
{-# INLINABLE intersperse #-}

{-| 'intercalate' concatenates the 'FreeT'-delimited text streams after
    interspersing a text stream in between them
-}
intercalate
    :: (Monad m)
    => Producer Text m ()
    -> FreeT (Producer Text m) m r
    -> Producer Text m r
intercalate p0 = go0
  where
    go0 f = do
        x <- lift (PP.runFreeT f)
        case x of
            PP.Pure r -> return r
            PP.Free p -> do
                f' <- p
                go1 f'
    go1 f = do
        x <- lift (PP.runFreeT f)
        case x of
            PP.Pure r -> return r
            PP.Free p -> do
                p0
                f' <- p
                go1 f'
{-# INLINABLE intercalate #-}

{-| Join 'FreeT'-delimited lines into a byte stream
-}
unlines
    :: (Monad m) => FreeT (Producer Text m) m r -> Producer Text m r
unlines = go
  where
    go f = do
        x <- lift (PP.runFreeT f)
        case x of
            PP.Pure r -> return r
            PP.Free p -> do
                f' <- p
                yield $ T.singleton '\n'
                go f'
{-# INLINABLE unlines #-}

{-| Join 'FreeT'-delimited words into a text stream
-}
unwords
    :: (Monad m) => FreeT (Producer Text m) m r -> Producer Text m r
unwords = intercalate (yield $ T.pack " ")
{-# INLINABLE unwords #-}

{- $parse
    The following parsing utilities are single-character analogs of the ones found
    @pipes-parse@.
-}

{- $reexports
    @Pipes.Text.Parse@ re-exports 'nextChar', 'drawChar', 'unDrawChar', 'peekChar', and 'isEndOfChars'.
    
    @Data.Text@ re-exports the 'Text' type.

    @Pipes.Parse@ re-exports 'input', 'concat', and 'FreeT' (the type).
-}