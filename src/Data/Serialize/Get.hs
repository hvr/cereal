{-# LANGUAGE CPP        #-}
{-# LANGUAGE MagicHash  #-}
{-# LANGUAGE Rank2Types #-}

-----------------------------------------------------------------------------
-- |
-- Module      : Data.Serialize.Get
-- Copyright   : Lennart Kolmodin, Galois Inc. 2009
-- License     : BSD3-style (see LICENSE)
-- 
-- Maintainer  : Trevor Elliott <trevor@galois.com>
-- Stability   :
-- Portability :
--
-- The Get monad. A monad for efficiently building structures from
-- strict ByteStrings
--
-----------------------------------------------------------------------------

#if defined(__GLASGOW_HASKELL__) && !defined(__HADDOCK__)
#include "MachDeps.h"
#endif

module Data.Serialize.Get (

    -- * The Get type
      Get
    , runGet
    , runGetState
    , Result(..)
    , runGetPartial

    -- * Parsing
    , ensure
    , isolate
    , label
    , skip
    , uncheckedSkip
    , lookAhead
    , lookAheadM
    , lookAheadE
    , uncheckedLookAhead

    -- * Utility
    , getBytes
    , remaining
    , isEmpty

    -- * Parsing particular types
    , getWord8

    -- ** ByteStrings
    , getByteString
    , getLazyByteString

    -- ** Big-endian reads
    , getWord16be
    , getWord32be
    , getWord64be

    -- ** Little-endian reads
    , getWord16le
    , getWord32le
    , getWord64le

    -- ** Host-endian, unaligned reads
    , getWordhost
    , getWord16host
    , getWord32host
    , getWord64host

    -- ** Containers
    , getTwoOf
    , getListOf
    , getIArrayOf
    , getTreeOf
    , getSeqOf
    , getMapOf
    , getIntMapOf
    , getSetOf
    , getIntSetOf
    , getMaybeOf
    , getEitherOf

  ) where

import Control.Applicative (Applicative(..),Alternative(..))
import Control.Monad (unless,when,ap,MonadPlus(..),liftM2)
import Data.Array.IArray (IArray,listArray)
import Data.Ix (Ix)
import Data.List (intercalate)
import Data.Maybe (isNothing)
import Foreign

import qualified Data.ByteString          as B
import qualified Data.ByteString.Internal as B
import qualified Data.ByteString.Unsafe   as B
import qualified Data.ByteString.Lazy     as L
import qualified Data.IntMap              as IntMap
import qualified Data.IntSet              as IntSet
import qualified Data.Map                 as Map
import qualified Data.Sequence            as Seq
import qualified Data.Set                 as Set
import qualified Data.Tree                as T


#if defined(__GLASGOW_HASKELL__) && !defined(__HADDOCK__)
import GHC.Base
import GHC.Word
#endif

type Failure   r = [String]     -> String -> Result r
type Success a r = B.ByteString -> More -> a      -> Result r

-- | The result of a parse.
data Result r = Fail String
              -- ^ The parse failed. The 'String' is the
              --   message describing the error, if any.
              | Partial (B.ByteString -> Result r)
              -- ^ Supply this continuation with more input so that
              --   the parser can resume. To indicate that no more
              --   input is available, use an 'B.empty' string.
              | Done r B.ByteString
              -- ^ The parse succeeded.  The 'B.ByteString' is the
              --   input that had not yet been consumed (if any) when
              --   the parse succeeded.

instance Show r => Show (Result r) where
    show (Fail msg)  = "Fail " ++ show msg
    show (Partial _) = "Partial _"
    show (Done r bs) = "Done " ++ show r ++ " " ++ show bs

instance Functor Result where
    fmap _ (Fail msg)  = Fail msg
    fmap f (Partial k) = Partial (fmap f . k)
    fmap f (Done r bs) = Done (f r) bs

-- | The Get monad is an Exception and State monad.
newtype Get a = Get
  { unGet :: forall r. B.ByteString
                    -> More
                    -> Failure   r
                    -> Success a r
                   -- -> Either String (r, B.ByteString) }
                    -> Result r }

-- | Have we read all available input?
data More = Complete | Incomplete
    deriving (Eq)

instance Functor Get where
    fmap p m = Get (\s0 m0 f k -> unGet m s0 m0 f (\s m1 a -> k s m1 (p a)))

instance Applicative Get where
    pure  = return
    (<*>) = ap

instance Alternative Get where
    empty = failDesc "empty"
    (<|>) = mplus

-- Definition directly from Control.Monad.State.Strict
instance Monad Get where
    return a = Get (\s0 m _ k -> k s0 m a)
    m >>= g  = Get (\s0 m0 f k -> unGet m s0 m0 f (\s m1 a -> unGet (g a) s m1 f k))
    fail     = failDesc

instance MonadPlus Get where
    mzero = failDesc "mzero"
    mplus a b = Get (\s0 m0 f k -> unGet a s0 m0 (\_ _ -> unGet b s0 m0 f k) k)

------------------------------------------------------------------------

formatTrace :: [String] -> String
formatTrace [] = "Empty call stack"
formatTrace ls = "From:\t" ++ intercalate "\n\t" ls ++ "\n"

get :: Get B.ByteString
get  = Get (\s0 m0 _ k -> k s0 m0 s0)

put :: B.ByteString -> Get ()
put s = Get (\_ m _ k -> k s m ())

label :: String -> Get a -> Get a
label l m = Get (\s0 m0 f k -> unGet m s0 m0 (\ls -> f (l:ls)) k)

finalK :: Success a a
finalK s _ a = Done a s

failK :: Failure a
failK ls s = Fail (unlines [s, formatTrace ls])

-- | Run the Get monad applies a 'get'-based parser on the input ByteString
runGet :: Get a -> B.ByteString -> Either String a
runGet m str = case unGet m str Complete failK finalK of
  Fail i    -> Left i
  Done a _  -> Right a
  Partial{} -> Left "Failed reading: Internal error: unexpected Partial."
{-# INLINE runGet #-}

-- | Run the Get monad applies a 'get'-based parser on the input ByteString
runGetPartial :: Get a -> B.ByteString -> Result a
runGetPartial m str = unGet m str Incomplete failK finalK
{-# INLINE runGetPartial #-}

-- | Run the Get monad applies a 'get'-based parser on the input
-- ByteString. Additional to the result of get it returns the number of
-- consumed bytes and the rest of the input.
runGetState :: Get a -> B.ByteString -> Int
            -> Either String (a, B.ByteString)
runGetState m str off =
    case unGet m (B.drop off str) Complete failK finalK of
      Fail i      -> Left i
      Done a bs   -> Right (a, bs)
      Partial{}   -> Left "Failed reading: Internal error: unexpected Partial."
{-# INLINE runGetState #-}

------------------------------------------------------------------------

-- | If at least @n@ bytes of input are available, return the current
--   input, otherwise fail.
ensure :: Int -> Get B.ByteString
ensure n = n `seq` Get $ \i0 m0 kf ks ->
    if B.length i0 >= n
    then ks i0 m0 i0
    else unGet (demandInput >> ensureRec n) i0 m0 kf ks
{-# INLINE ensure #-}

-- | If at least @n@ bytes of input are available, return the current
--   input, otherwise fail.
ensureRec :: Int -> Get B.ByteString
ensureRec n = Get $ \i0 m0 kf ks ->
    if B.length i0 >= n
    then ks i0 m0 i0
    else unGet (demandInput >> ensureRec n) i0 m0 kf ks

-- | Isolate an action to operating within a fixed block of bytes.  The action
--   is required to consume all the bytes that it is isolated to.
isolate :: Int -> Get a -> Get a
isolate n m = do
  when (n < 0) (fail "Attempted to isolate a negative number of bytes")
  s <- ensure n
  let (s',rest) = B.splitAt n s
  put s'
  a    <- m
  used <- get
  unless (B.null used) (fail "not all bytes parsed in isolate")
  put rest
  return a

-- | Immediately demand more input via a 'Partial' continuation
--   result.
demandInput :: Get ()
demandInput = Get $ \i0 m0 kf ks ->
    if m0 == Complete
    then kf ["demandInput"] "too few bytes"
    else Partial $ \s ->
         if B.null s
         then kf ["demandInput"] "too few bytes"
         else ks (i0 `B.append` s) Incomplete ()

failDesc :: String -> Get a
failDesc err = do
    let msg = "Failed reading: " ++ err
    Get (\_ _ f _ -> f [] msg)

-- | Skip ahead @n@ bytes. Fails if fewer than @n@ bytes are available.
skip :: Int -> Get ()
skip n = do
  s <- ensure n
  put (B.drop n s)

-- | Skip ahead @n@ bytes. No error if there isn't enough bytes.
uncheckedSkip :: Int -> Get ()
uncheckedSkip n = do
    s <- get
    put (B.drop n s)

-- | Run @ga@, but return without consuming its input.
-- Fails if @ga@ fails.
lookAhead :: Get a -> Get a
lookAhead ga = do
    s <- get
    a <- ga
    put s
    return a

-- | Like 'lookAhead', but consume the input if @gma@ returns 'Just _'.
-- Fails if @gma@ fails.
lookAheadM :: Get (Maybe a) -> Get (Maybe a)
lookAheadM gma = do
    s <- get
    ma <- gma
    when (isNothing ma) (put s)
    return ma

-- | Like 'lookAhead', but consume the input if @gea@ returns 'Right _'.
-- Fails if @gea@ fails.
lookAheadE :: Get (Either a b) -> Get (Either a b)
lookAheadE gea = do
    s <- get
    ea <- gea
    case ea of
        Left _ -> put s
        _      -> return ()
    return ea

-- | Get the next up to @n@ bytes as a ByteString, without consuming them.
uncheckedLookAhead :: Int -> Get B.ByteString
uncheckedLookAhead n = do
    s <- get
    return (B.take n s)

------------------------------------------------------------------------
-- Utility

-- | Get the number of remaining unparsed bytes.
-- Useful for checking whether all input has been consumed.
-- Note that this forces the rest of the input.
remaining :: Get Int
remaining = B.length `fmap` get

-- | Test whether all input has been consumed,
-- i.e. there are no remaining unparsed bytes.
isEmpty :: Get Bool
isEmpty = B.null `fmap` get

------------------------------------------------------------------------
-- Utility with ByteStrings

-- | An efficient 'get' method for strict ByteStrings. Fails if fewer
-- than @n@ bytes are left in the input. This function creates a fresh
-- copy of the underlying bytes.
getByteString :: Int -> Get B.ByteString
getByteString n = do
  bs <- getBytes n
  return $! B.copy bs

getLazyByteString :: Int64 -> Get L.ByteString
getLazyByteString n = f `fmap` getByteString (fromIntegral n)
  where f bs = L.fromChunks [bs]


------------------------------------------------------------------------
-- Helpers

-- | Pull @n@ bytes from the input, as a strict ByteString.
getBytes :: Int -> Get B.ByteString
getBytes n = do
    s <- ensure n
    let consume = B.unsafeTake n s
        rest    = B.unsafeDrop n s
        -- (consume,rest) = B.splitAt n s
    put rest
    return consume


------------------------------------------------------------------------
-- Primtives

-- helper, get a raw Ptr onto a strict ByteString copied out of the
-- underlying strict byteString.

getPtr :: Storable a => Int -> Get a
getPtr n = do
    (fp,o,_) <- B.toForeignPtr `fmap` getBytes n
    let k p = peek (castPtr (p `plusPtr` o))
    return (B.inlinePerformIO (withForeignPtr fp k))

------------------------------------------------------------------------

-- | Read a Word8 from the monad state
getWord8 :: Get Word8
getWord8 = getPtr (sizeOf (undefined :: Word8))

-- | Read a Word16 in big endian format
getWord16be :: Get Word16
getWord16be = do
    s <- getBytes 2
    return $! (fromIntegral (s `B.index` 0) `shiftl_w16` 8) .|.
              (fromIntegral (s `B.index` 1))

-- | Read a Word16 in little endian format
getWord16le :: Get Word16
getWord16le = do
    s <- getBytes 2
    return $! (fromIntegral (s `B.index` 1) `shiftl_w16` 8) .|.
              (fromIntegral (s `B.index` 0) )

-- | Read a Word32 in big endian format
getWord32be :: Get Word32
getWord32be = do
    s <- getBytes 4
    return $! (fromIntegral (s `B.index` 0) `shiftl_w32` 24) .|.
              (fromIntegral (s `B.index` 1) `shiftl_w32` 16) .|.
              (fromIntegral (s `B.index` 2) `shiftl_w32`  8) .|.
              (fromIntegral (s `B.index` 3) )

-- | Read a Word32 in little endian format
getWord32le :: Get Word32
getWord32le = do
    s <- getBytes 4
    return $! (fromIntegral (s `B.index` 3) `shiftl_w32` 24) .|.
              (fromIntegral (s `B.index` 2) `shiftl_w32` 16) .|.
              (fromIntegral (s `B.index` 1) `shiftl_w32`  8) .|.
              (fromIntegral (s `B.index` 0) )

-- | Read a Word64 in big endian format
getWord64be :: Get Word64
getWord64be = do
    s <- getBytes 8
    return $! (fromIntegral (s `B.index` 0) `shiftl_w64` 56) .|.
              (fromIntegral (s `B.index` 1) `shiftl_w64` 48) .|.
              (fromIntegral (s `B.index` 2) `shiftl_w64` 40) .|.
              (fromIntegral (s `B.index` 3) `shiftl_w64` 32) .|.
              (fromIntegral (s `B.index` 4) `shiftl_w64` 24) .|.
              (fromIntegral (s `B.index` 5) `shiftl_w64` 16) .|.
              (fromIntegral (s `B.index` 6) `shiftl_w64`  8) .|.
              (fromIntegral (s `B.index` 7) )

-- | Read a Word64 in little endian format
getWord64le :: Get Word64
getWord64le = do
    s <- getBytes 8
    return $! (fromIntegral (s `B.index` 7) `shiftl_w64` 56) .|.
              (fromIntegral (s `B.index` 6) `shiftl_w64` 48) .|.
              (fromIntegral (s `B.index` 5) `shiftl_w64` 40) .|.
              (fromIntegral (s `B.index` 4) `shiftl_w64` 32) .|.
              (fromIntegral (s `B.index` 3) `shiftl_w64` 24) .|.
              (fromIntegral (s `B.index` 2) `shiftl_w64` 16) .|.
              (fromIntegral (s `B.index` 1) `shiftl_w64`  8) .|.
              (fromIntegral (s `B.index` 0) )

------------------------------------------------------------------------
-- Host-endian reads

-- | /O(1)./ Read a single native machine word. The word is read in
-- host order, host endian form, for the machine you're on. On a 64 bit
-- machine the Word is an 8 byte value, on a 32 bit machine, 4 bytes.
getWordhost :: Get Word
getWordhost = getPtr (sizeOf (undefined :: Word))

-- | /O(1)./ Read a 2 byte Word16 in native host order and host endianness.
getWord16host :: Get Word16
getWord16host = getPtr (sizeOf (undefined :: Word16))

-- | /O(1)./ Read a Word32 in native host order and host endianness.
getWord32host :: Get Word32
getWord32host = getPtr  (sizeOf (undefined :: Word32))

-- | /O(1)./ Read a Word64 in native host order and host endianess.
getWord64host   :: Get Word64
getWord64host = getPtr  (sizeOf (undefined :: Word64))

------------------------------------------------------------------------
-- Unchecked shifts

shiftl_w16 :: Word16 -> Int -> Word16
shiftl_w32 :: Word32 -> Int -> Word32
shiftl_w64 :: Word64 -> Int -> Word64

#if defined(__GLASGOW_HASKELL__) && !defined(__HADDOCK__)
shiftl_w16 (W16# w) (I# i) = W16# (w `uncheckedShiftL#`   i)
shiftl_w32 (W32# w) (I# i) = W32# (w `uncheckedShiftL#`   i)

#if WORD_SIZE_IN_BITS < 64
shiftl_w64 (W64# w) (I# i) = W64# (w `uncheckedShiftL64#` i)

#if __GLASGOW_HASKELL__ <= 606
-- Exported by GHC.Word in GHC 6.8 and higher
foreign import ccall unsafe "stg_uncheckedShiftL64"
    uncheckedShiftL64#     :: Word64# -> Int# -> Word64#
#endif

#else
shiftl_w64 (W64# w) (I# i) = W64# (w `uncheckedShiftL#` i)
#endif

#else
shiftl_w16 = shiftL
shiftl_w32 = shiftL
shiftl_w64 = shiftL
#endif


-- Containers ------------------------------------------------------------------

getTwoOf :: Get a -> Get b -> Get (a,b)
getTwoOf ma mb = liftM2 (,) ma mb

-- | Get a list in the following format:
--   Word64 (big endian format)
--   element 1
--   ...
--   element n
getListOf :: Get a -> Get [a]
getListOf m = go [] =<< getWord64be
  where
  go as 0 = return (reverse as)
  go as i = do x <- m
               x `seq` go (x:as) (i - 1)

-- | Get an IArray in the following format:
--   index (lower bound)
--   index (upper bound)
--   Word64 (big endian format)
--   element 1
--   ...
--   element n
getIArrayOf :: (Ix i, IArray a e) => Get i -> Get e -> Get (a i e)
getIArrayOf ix e = liftM2 listArray (getTwoOf ix ix) (getListOf e)

-- | Get a sequence in the following format:
--   Word64 (big endian format)
--   element 1
--   ...
--   element n
getSeqOf :: Get a -> Get (Seq.Seq a)
getSeqOf m = go Seq.empty =<< getWord64be
  where
  go xs 0 = return $! xs
  go xs n = xs `seq` n `seq` do
              x <- m
              go (xs Seq.|> x) (n - 1)

-- | Read as a list of lists.
getTreeOf :: Get a -> Get (T.Tree a)
getTreeOf m = liftM2 T.Node m (getListOf (getTreeOf m))

-- | Read as a list of pairs of key and element.
getMapOf :: Ord k => Get k -> Get a -> Get (Map.Map k a)
getMapOf k m = Map.fromDistinctAscList `fmap` getListOf (getTwoOf k m)

-- | Read as a list of pairs of int and element.
getIntMapOf :: Get Int -> Get a -> Get (IntMap.IntMap a)
getIntMapOf i m = IntMap.fromDistinctAscList `fmap` getListOf (getTwoOf i m)

-- | Read as a list of elements.
getSetOf :: Ord a => Get a -> Get (Set.Set a)
getSetOf m = Set.fromDistinctAscList `fmap` getListOf m

-- | Read as a list of ints.
getIntSetOf :: Get Int -> Get IntSet.IntSet
getIntSetOf m = IntSet.fromDistinctAscList `fmap` getListOf m

-- | Read in a Maybe in the following format:
--   Word8 (0 for Nothing, anything else for Just)
--   element (when Just)
getMaybeOf :: Get a -> Get (Maybe a)
getMaybeOf m = do
  tag <- getWord8
  case tag of
    0 -> return Nothing
    _ -> Just `fmap` m

-- | Read an Either, in the following format:
--   Word8 (0 for Left, anything else for Right)
--   element a when 0, element b otherwise
getEitherOf :: Get a -> Get b -> Get (Either a b)
getEitherOf ma mb = do
  tag <- getWord8
  case tag of
    0 -> Left  `fmap` ma
    _ -> Right `fmap` mb
