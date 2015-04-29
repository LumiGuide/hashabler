{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE MagicHash , UnliftedFFITypes #-}
module Data.Hashabler (
{- | 
  The core of this library consists of 
     
  - the 'Hashable' class which defines how hashable chunks of bytes are
    delivered to a hash function; new instances can be defined to support
    the hashing of new datatypes using an existing algorithm

  - the 'Hash' class which implements a particular hashing algorithm,
    consuming bytes delivered in 'hash'; new instances can be defined to
    support hashing existing 'Hashable' types with a new algorithm.

  Currently we implement only the 32 and 64-bit variations of the 
  <http://www.isthe.com/chongo/tech/comp/fnv/ FNV-1a non-cryptographic hashing algorithm> 
  ('hashFNV32' and 'hashFNV64'), which have good hashing properties and are
  easy to implement in different languages and on different platforms.

  Please see the project description for more information.
 -}
    Hashable(..)
  , Hash(..)
  -- * Hashing with the FNV-1a algorithm
  , FNV32(..)
  , hashFNV32
  , FNV64(..)
  , hashFNV64
  -- ** Internals
  -- *** FNV Primes
  , fnvPrime32
  , fnvPrime64
  -- *** Standard seed values
  -- | The arbitrary initial seed values for different output hash sizes. These
  -- values are part of the spec, but there is nothing special about them;
  -- supposedly, in terms of hash quality, any non-zero value seed should be
  -- fine passed to 'hash':
  , fnvOffsetBasis32
  , fnvOffsetBasis64

  -- * Creating Hash and Hashable instances
  , mixConstructor
  -- ** Defining principled Hashable instances
{- | 
 #principled#

 Special care needs to be taken when defining instances of Hashable for your
 own types, especially for recursive types and types with multiple
 constructors. First instances need to ensure that /distinct values produce
 distinct hash values/. Here's an example of a /bad/ implementation for 'Maybe':
 
 > instance (Hashable a)=> Hashable (Maybe a) where              -- BAD!
 >     hash h (Just a) = h `hash` a          -- BAD!
 >     hash h Nothing  = h `hash` (1::Word8) -- BAD!

 Here @Just (1::Word8)@ hashes to the same value as @Nothing@.

 Second and more tricky, instances should not permit a function 
 @f :: a -> (a,a)@ such that 
 @x `hash` y == x `hash` y1 `hash` y2 where (y1,y2) = f y@... or something.
 The idea is we want to avoid the following kinds of collisions:

 > hash [Just 1, Nothing] == hash [Just 1]     -- BAD!
 > hash ([1,2], [3])      == hash ([1], [2,3]  -- BAD!)

 Maybe what we mean is that where @a@ is a 'Monoid', we expect replacing
 `mappend` with the hash operation to always yield /different/ values. This
 needs clarifying; please help.

 Here are a few rules of thumb which should result in principled instances for
 your own types (This is a work-in-progress; please help):

 - If all values of a type have a static structure, i.e. the arrangement and
   number of child parts to be hashed is knowable from the type, then one may
   simply hash each child element of the type in turn. This is the case for
   product types like tuples (where the arity is reflected in the type), or
   primitive numeric values composed of a static number of bits.

 Otherwise if the type has variable structure, e.g. if it has multiple
 constructors or is an array type...

 - Every possible value of a type should inject at least one byte of entropy
   /apart/ from any recursive calls to child elements; we can ensure this is
   the case by hashing an initial or final distinct byte for each distinct
   constructor of our type

 To ensure hashing remains consistent across platforms, instances should not
 compile-time-conditionally call different @mix@-family 'Hash' functions.
 This rule doesn't matter for instances like 'FNV32' which mix in data one byte
 at a time, but other 'Hash' instances may operate on multiple bytes at a time,
 perhaps using padding bytes, so this becomes important.

 A final important note: we're not concerned with collisions between values of
 /different types/; in fact in many cases "equivalent" values of different
 types intentionally hash to the same value. This also means instances cannot
 rely on the hashing of child elements being uncorrelated. That might be one
 interpretation of the mistake in our faulty @Maybe@ instance above
 -}
  
  
  
#ifdef EXPORT_INTERNALS
  -- * Internal functions exposed for testing; you shouldn't see these
  , hashFoldl'
  , hashLeftUnfolded
  , bytesFloat, bytesDouble
  , magnitudeAsWord
  , _byteSwap32, _byteSwap64, _hash32Integer, _hash32_Word_64, _hash32_Int_64
  , _bytes64_32 , _bytes64_64, _signByte
#endif
    ) where


import Data.Word
import Data.Int
import Data.Bits
import Data.Char
import Data.List

-- For ByteString & Text instances:
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as B
import qualified Data.ByteString.Lazy.Internal as BL (foldlChunks, ByteString)
#if MIN_VERSION_bytestring(0,10,4)
import qualified Data.ByteString.Short.Internal as BSh
#endif
import qualified Data.Text as T
import qualified Data.Text.Internal as T
import qualified Data.Text.Array as T (Array(..))
import qualified Data.Primitive as P
import qualified Data.Text.Lazy as TL (foldlChunks, Text)
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Storable (peekByteOff)

import Control.Exception(assert)

-- For casting of floating point values:
import Data.Array.ST (newArray, readArray, MArray, STUArray)
import Data.Array.Unsafe (castSTUArray)
import GHC.ST (runST, ST)

import Data.Version(Version, versionBranch)
import Data.Unique(Unique, hashUnique)

-- for reading the bytes of ByteStrings:
import System.IO.Unsafe (unsafeDupablePerformIO)

-- For getting our Int from ThreadId:
import Foreign.C (CInt(..))
import GHC.Conc(ThreadId(..))
import GHC.Prim(ThreadId#)

-- For TypeRep
import Data.Typeable
import GHC.Fingerprint.Type(Fingerprint(..))
#if  __GLASGOW_HASKELL__ >= 710
#else 
-- __GLASGOW_HASKELL__ >= 702
import Data.Typeable.Internal(TypeRep(..))
#endif

import System.Mem.StableName
import Data.Ratio (Ratio, denominator, numerator)

-- For Integer:
#ifdef MIN_VERSION_integer_gmp
import GHC.Exts (Int(..))
import GHC.Integer.GMP.Internals (Integer(..))
# if MIN_VERSION_integer_gmp(1,0,0)
import GHC.Integer.GMP.Internals (BigNat(BN#))
# endif
#endif

-- For GHC 7.10 Natural and Void:
#if MIN_VERSION_base(4,8,0)
import Data.Void (Void, absurd)
import GHC.Natural (Natural(..))
import GHC.Exts (Word(..))
#endif

-- For WORD_SIZE_IN_BITS constant:
-- TODO Use Data.Primitive.MachDeps ?
#include "MachDeps.h"
import MachDeps

-- Do error just once, and assume 32 else 64 below:
#if WORD_SIZE_IN_BITS == 32
-- for fast div by power of two:
#define LOG_SIZEOF_WORD 2
#elif WORD_SIZE_IN_BITS == 64
#define LOG_SIZEOF_WORD 3
#else
#error We only know how to support 32-bit and 64-bit systems, sorry.
#endif

import Unsafe.Coerce

-- COMMENTED BELOW, WHEN FOUND NOT BENEFICIAL:
-- These should be fine in all cases:
coerceInt32Word32 :: Int32 -> Word32
coerceInt32Word32 = 
#  if WORD_SIZE_IN_BITS == 32
    unsafeCoerce
#  else
    fromIntegral -- TODO or is unsafeCoerce okay on 64-bit?
#  endif
coerceInt64Word64 :: Int64 -> Word64
coerceInt64Word64 = unsafeCoerce
-- coerceIntWord :: Int -> Word
-- coerceIntWord = unsafeCoerce

-- For when argument is known in-bounds:
-- unsafeCoerceWord8 :: Word -> Word8
-- unsafeCoerceWord8 = unsafeCoerce

-- For 32-bit:
#if WORD_SIZE_IN_BITS == 32
unsafeCoerceIntWord32 :: Int -> Word32
unsafeCoerceIntWord32 = unsafeCoerce
-- unsafeCoerceWordWord32 :: Word -> Word32
-- unsafeCoerceWordWord32 = unsafeCoerce
#endif
  -- But why is that? The unsafeCoerce version simply has more instructions AFAICT!


#if MIN_VERSION_base(4,7,0)
-- Exported from Data.Word in base >= 4.7
#else
byteSwap32 :: Word32 -> Word32
byteSwap32 = _byteSwap32
# if WORD_SIZE_IN_BITS == 64
byteSwap64 :: Word64 -> Word64
byteSwap64 = _byteSwap64
# endif
#endif

-- TODO This is probably so slow it deserves a warning...
_byteSwap32 :: Word32 -> Word32
_byteSwap32 = \w-> 
    let mask0 = 0xFF000000
        mask1 = 0x00FF0000
        mask2 = 0x0000FF00
        mask3 = 0x000000FF
     in (unsafeShiftR (w .&. mask0) 24) .|.
        (unsafeShiftR (w .&. mask1) 8)  .|.
        (unsafeShiftL (w .&. mask2) 8)  .|.
        (unsafeShiftL (w .&. mask3) 24)

_byteSwap64 :: Word64 -> Word64
_byteSwap64 = \w-> 
    let mask0 = 0xFF00000000000000
        mask1 = 0x00FF000000000000
        mask2 = 0x0000FF0000000000
        mask3 = 0x000000FF00000000
        mask4 = 0x00000000FF000000
        mask5 = 0x0000000000FF0000
        mask6 = 0x000000000000FF00
        mask7 = 0x00000000000000FF
     in (unsafeShiftR (w .&. mask0) 56) .|.
        (unsafeShiftR (w .&. mask1) 40) .|.
        (unsafeShiftR (w .&. mask2) 24) .|.
        (unsafeShiftR (w .&. mask3) 8)  .|.
        (unsafeShiftL (w .&. mask4) 8)  .|.
        (unsafeShiftL (w .&. mask5) 24) .|.
        (unsafeShiftL (w .&. mask6) 40) .|.
        (unsafeShiftL (w .&. mask7) 56)

-- TODO BENCHMARKING for 'abs' see: http://graphics.stanford.edu/~seander/bithacks.html#IntegerAbs  and  http://stackoverflow.com/q/22445019/176841


foreign import ccall unsafe "rts_getThreadId" getThreadId :: ThreadId# -> CInt 


{-
-- see also the non-powers of two mapping methods outlined:
--  http://www.isthe.com/chongo/tech/comp/fnv/#FNV-1a
-}




-- FNV CONSTANTS ----------------------------------------------------

-- The special FNV primes required for different hash output sizes:

fnvPrime32 :: Word32
fnvPrime64 :: Word64
{-# INLINE fnvPrime32 #-}
{-# INLINE fnvPrime64 #-}
fnvPrime32 = 16777619
fnvPrime64 = 1099511628211
-- fnvPrime128 = 309485009821345068724781371
-- fnvPrime256 = 374144419156711147060143317175368453031918731002211


fnvOffsetBasis32 :: FNV32
fnvOffsetBasis64 :: FNV64
{-# INLINE fnvOffsetBasis32 #-}
{-# INLINE fnvOffsetBasis64 #-}
fnvOffsetBasis32 = FNV32 2166136261
fnvOffsetBasis64 = FNV64 14695981039346656037
-- fnvOffsetBasis128 = FNV128 144066263297769815596495629667062367629
-- fnvOffsetBasis256 = FNV256 100029257958052580907070968620625704837092796014241193945225284501741471925557


-- | The FNV-1a hash algorithm. See <http://www.isthe.com/chongo/tech/comp/fnv/>
newtype FNV32 = FNV32 { fnv32 :: Word32 }
    deriving (Eq, Ord, Read, Show)

newtype FNV64 = FNV64 { fnv64 :: Word64 }
    deriving (Eq, Ord, Read, Show)





-- EXTRACTING BYTES FROM DIFFERENT TYPES ----------------------------
-- NOTE we're to hash the resulting Word8s from left to right

-- TODO check inlining on these:

bytes16 :: Word16 -> (Word8, Word8)
{-# INLINE bytes16 #-}
bytes16 wd = (shifted 8, fromIntegral wd)
     where shifted = fromIntegral . unsafeShiftR wd

bytes32 :: Word32 -> (Word8,Word8,Word8,Word8)
{-# INLINE bytes32 #-}
bytes32 wd = (shifted 24, shifted 16, shifted 8, fromIntegral wd)
     where shifted = fromIntegral . unsafeShiftR wd

bytes64 :: Word64 -> (Word8,Word8,Word8,Word8,Word8,Word8,Word8,Word8)
{-# INLINE bytes64 #-}
bytes64 = \wd64->
#  if WORD_SIZE_IN_BITS == 32
    _bytes64_32 wd64
#  else
    _bytes64_64 wd64
#  endif

_bytes64_64 :: Word64 -> (Word8,Word8,Word8,Word8,Word8,Word8,Word8,Word8)
{-# INLINE _bytes64_64 #-}
_bytes64_64 wd = ( shifted 56, shifted 48, shifted 40, shifted 32
                 , shifted 24, shifted 16, shifted 8, fromIntegral wd)
     where shifted = fromIntegral . unsafeShiftR wd

-- faster for 32-bit archs
_bytes64_32 :: Word64 -> (Word8,Word8,Word8,Word8,Word8,Word8,Word8,Word8)
{-# INLINE _bytes64_32 #-}
_bytes64_32 wd = 
    let (wd0, wd1) = words32 wd
        (b0,b1,b2,b3) = bytes32 wd0
        (b4,b5,b6,b7) = bytes32 wd1
     in (b0,b1,b2,b3,b4,b5,b6,b7)

words32 :: Word64 -> (Word32, Word32)
{-# INLINE words32 #-}
words32 wd64 = (fromIntegral $ unsafeShiftR wd64 32, fromIntegral wd64)

-- These appear to return bytes in big endian on my machine (little endian),
-- but TODO verify what happens on a BE machine.

-- Get raw IEEE bytes from floating point types.
-- TODO better, if possible
bytesFloat :: Float -> (Word8,Word8,Word8,Word8)
{-# INLINE bytesFloat #-}
bytesFloat = bytes32 . floatToWord

bytesDouble :: Double -> (Word8,Word8,Word8,Word8,Word8,Word8,Word8,Word8)
{-# INLINE bytesDouble #-}
bytesDouble = bytes64 . doubleToWord


-- See: http://stackoverflow.com/a/7002812/176841 . 
-- Someone just kill me now...
floatToWord :: Float -> Word32
floatToWord x = runST (castViaSTArray x)

doubleToWord :: Double -> Word64
doubleToWord x = runST (castViaSTArray x)

castViaSTArray :: (MArray (STUArray s) a (ST s),
                   MArray (STUArray s) b (ST s)) => a -> ST s b
{-# INLINE castViaSTArray #-}
castViaSTArray x = newArray (0 :: Int,0) x >>= castSTUArray >>= flip readArray 0


-- HASHABLE CLASS AND INSTANCES -------------------------------------



-- | A class of types that can be converted into a hash value.  We expect all
-- instances to display "good" hashing properties (w/r/t avalanche, bit
-- independence, etc.) when passed to a "good" 'Hash' function.
--
-- We try to ensure that bytes are extracted from values in a way that is
-- portable across architectures (where possible), and straightforward to
-- replicate on other platforms and in other languages. Exceptions are
-- __NOTE__-ed in instance docs.
--
-- See the section <#principled "Defining Hashable instances"> for details of what we expect
-- from instances.
class Hashable a where
    -- | Add the bytes from the second argument into the hash, producing a new
    -- hash value. This is essentially a left fold of the methods of 'Hash'
    -- over individual bytes extracted from @a@.
    --
    -- For some instances of 'Hash', this method might be a complete hashing
    -- algorithm, or might comprise the core of a hashing algorithm (perhaps
    -- with some final mixing), or might do something completely apart from
    -- hashing (e.g. simply cons bytes into a list for debugging).
    hash :: (Hash h)=> h -> a -> h


-- | A class for hash functions which take a running hash value and
-- incrementally mix in bytes (or chunks of bytes). Bytes are fed to these
-- methods in our 'Hashable' instances, which promise to call these methods in
-- a platform-independent way.
--
-- Instances of 'Hash' only need to define 'mix8', but may additional handle
-- @mix@-ing in larger word chunks for performance reasons. For instance a hash
-- function which operates on four bytes at a time might make use of 'mix32',
-- and perhaps in 'mix8' pad with three additional 0s.
class (Eq h)=> Hash h where
    -- | Hash in one byte.
    mix8 :: h -> Word8 -> h
    -- | Hash in a 2-byte word. Defaults to 'mix8' on bytes from most to least significant.
    mix16 :: h -> Word16 -> h
    -- | Hash in a 4-byte word. Defaults to 'mix8' on bytes from most to least significant.
    mix32 :: h -> Word32 -> h
    -- | Hash in an architecture-dependent word. Defaults to 'mix8' on bytes
    -- from most to least significant. If you override the default
    -- implementation, you should ensure 'hash' produces the same values on all
    -- architectures.
    --
    {-# INLINE mix16 #-}
    mix16 h = \wd16-> 
       let (wd8_0,wd8_1) = bytes16 wd16
        in h `mix8` wd8_0 `mix8` wd8_1

    {-# INLINE mix32 #-}
    mix32 h = \wd32->
       let (b0,b1,b2,b3) = bytes32 wd32
        in h `mix8` b0 `mix8` b1 `mix8` b2 `mix8` b3 



-- FNV HASH KERNELS -------------------------------------------------

-- | @
-- 'mix8' ('FNV32' h32) b = 'FNV32' $ (h32 ``xor`` fromIntegral b) * 'fnvPrime32'
-- @
instance Hash FNV32 where
    {-# INLINE mix8 #-}
    mix8 (FNV32 h32) = \b-> FNV32 $ (h32 `xor` fromIntegral b) * fnvPrime32
    -- TODO look at inlining


-- | Hash a value using the standard spec-prescribed 32-bit seed value.  For
-- relevant instances of primitive types, we expect this to produce values
-- following the FNV1a spec.
--
-- @
--   hashFNV32 = 'hash' 'fnvOffsetBasis32'
-- @
hashFNV32 :: Hashable a=> a -> FNV32
{-# INLINE hashFNV32 #-}
hashFNV32 = hash fnvOffsetBasis32


-- | @
-- 'mix8' ('FNV64' h64) b = 'FNV64' $ (h64 ``xor`` fromIntegral b) * 'fnvPrime64'
-- @
instance Hash FNV64 where
    {-# INLINE mix8 #-}
    mix8 (FNV64 h64) = \b-> FNV64 $ (h64 `xor` fromIntegral b) * fnvPrime64
    -- TODO look at inlining


-- | Hash a value using the standard spec-prescribed 64-bit seed value.  For
-- relevant instances of primitive types, we expect this to produce values
-- following the FNV1a spec.
--
-- This may be slow on 32-bit machines.
--
-- @
--   hashFNV64 = 'hash' 'fnvOffsetBasis64'
-- @
hashFNV64 :: Hashable a=> a -> FNV64
{-# INLINE hashFNV64 #-}
hashFNV64 = hash fnvOffsetBasis64


-- ------------------------------------------------------------------
-- NUMERIC TYPES:

-- TODO TESTING: for 7.8 and below, see if we can get a small value into J#, and then test that it hashes to the same as the literal small value
--                (look at code; simple */div or +/- don't seem to do it)

-- NOTE: non-obviously, but per our rule about variable-width values, this must
-- also be wrapped in a `mixConstructor`; consider the hashes of (0xDEAD,
-- 0xBEEF) and (0xDE, 0xADBEEF). The way we mix in the sign handles this.
-- 
-- I would rather truncate to 8-bit "limbs" but using 32-bit limbs seems like a
-- good tradeoff: on 64-bit platforms we just do a conditional instead of on
-- avg 4 extra hash ops, and on 32-bit no extra work is required.
--
-- | Arbitrary-precision integers are hashed as follows: the magnitude is
-- represented with 32-bit chunks (at least one, for zero; but no more than
-- necessary), then bytes are added to the hash from most to least significant
-- (including all initial padding 0s). Finally 'mixConstructor' is called on
-- the resulting hash value, with @(1::Word8)@ if the @Integer@ was negative,
-- otherwise with @0@.
instance Hashable Integer where
    {-# INLINE hash #-}
-- integer-gmp implementation: --------------------------------------
#ifdef MIN_VERSION_integer_gmp
    hash h = \i-> case i of
      (S# n#) ->
        let magWord = magnitudeAsWord (I# n#)
            sign = _signByte (I# n#)
         in mixConstructor sign $ 
#           if WORD_SIZE_IN_BITS == 32
              h `mix32` magWord
#           else
              -- only hash enough 32-bit chunks as needed to represent magnitude
              h `mixSignificantMachWord64` magWord
              -- TODO benchmark and try unsafeCoerce on 64-bit
#           endif

-- GHC 7.10: ------------------------
--
#   if MIN_VERSION_integer_gmp(1,0,0)
        -- NOTE: these used only when out of range of Int:
      (Jp# bn) -> mixConstructor 0 $ hash32BigNatBytes h bn
      (Jn# bn) -> mixConstructor 1 $ hash32BigNatBytes h bn

-- GHC 7.8 and below: ---------------
--
-- J# is more or less directly the gmp arbitrary precision int type, where:
--     1) sz# is number of limbs, or negative of that for negative
--     2) limbs stored little endian (i.e. i[0] is least significant limb)
--     3) whenever sz# is non-zero , the most significant limb is non-zero; the
--        value 0 is represented by sz# == 0, in which case ba# is ignored
--     4) a limb is machine Word size.
-- And some Integer-specific caveats/notes:
--     5) J# may be used for even small integers
--     6) ba# may be over-allocated, so size should be ignored
#   else
--    Note, 5 and 3 together mean that we have to special case for sz == 0,
--    even though I can't get that case to occur in practice:
      (J# 0# _) -> mixConstructor 0 (h `mix32` 0)
      (J# sz# ba#) -> 
             -- Note, (abs minBound == minBound) but I don't think that value
             -- is possible since we wouldn't even be able to specify the size
             -- (maxBound+1) as an Int value.
         let numLimbs = abs (I# sz#)
             sign = _signByte (I# sz#)
          in assert ((I# sz#) /= minBound) $
              mixConstructor sign $ 
               hash32BigNatByteArrayBytes h numLimbs (P.ByteArray ba#)
#   endif

-- other Integer implementations: -----------------------------------
#else
    -- For non-gmp Integer; quite slow.
    hash = _hash32Integer
#endif


-- TODO benchmark against conditional
-- Helper to quickly (hopefully) extract sign bit (1 for negative, 0 otherwise)
-- from Int. Assumes two's complement.
_signByte :: Int -> Word8
{-# INLINE _signByte #-}
_signByte n = fromIntegral ((fromIntegral n :: Word) 
                              `unsafeShiftR` (WORD_SIZE_IN_BITS - 1))

-- Exposed for testing. In particular we ensure that magnitudeAsWord minBound
-- is correct.
-- TODO make Int -> Word, and use fromIntegral at usage site, maybe
magnitudeAsWord :: Int 
#             if WORD_SIZE_IN_BITS == 32
                -> Word32
#             else
                -> Word64
#             endif
magnitudeAsWord = fromIntegral . abs

#if WORD_SIZE_IN_BITS == 64
-- Helper for hashing a 64-bit word, possibly omiting the first 32-bit chunk
-- (if 0). We use this when normalizing big natural representations.
mixSignificantMachWord64 :: (Hash h)=> h -> Word64 -> h
{-# INLINE mixSignificantMachWord64 #-}
mixSignificantMachWord64 h w64 = 
     let (word32_0, word32_1) = words32 w64
      in if word32_0 == 0 
          then h `mix32` word32_1
          else h `mix32` word32_0 `mix32`  word32_1
#endif


-- Very slow Integer-implementation-agnostic hashing:
_hash32Integer :: (Hash h)=> h -> Integer -> h
_hash32Integer h i = 
    let (sgn, limbs) = _integerWords i
     in mixConstructor sgn $ 
         foldl' hash h limbs

-- Convert an opaque Integer into a gmp-like format, except that we order our
-- list of limbs returned from most to least significant:
_integerWords :: Integer -> (Word8, [Word32])
_integerWords nSigned = (sign , go (abs nSigned) []) where
    sign = if nSigned < 0 then 1 else 0
           -- we will hash at least one limb (even if zero):
    go nMag acc = let (nMag', w32) = splitAtLastWord nMag
                   in (if nMag' == 0 then id else go nMag') (w32:acc)

    splitAtLastWord :: Integer -> (Integer, Word32)
    splitAtLastWord x = 
      assert (x >= 0) $
        (x `shiftR` 32, fromIntegral x)


#ifdef MIN_VERSION_integer_gmp
-- GHC 7.10:
# if MIN_VERSION_integer_gmp(1,0,0)
-- Internal. Hashable instances will require a 'mixConstructor'. We use the same
-- chunks-of-32-bits scheme as in the Integer instance.
--
-- Invariants of BigNat (from docs):
--   - ByteArray# size is an exact multiple of Word# size
--   - limbs are stored in least-significant-limb-first order,
--   - the most-significant limb must be non-zero, except for
--      0 which is represented as a 1-limb.
--      - NOTE, though: Jp#/Jn# in Integer on GHC 7.10 guarantee that contained
--        BigNat are non-zero
hash32BigNatBytes :: (Hash h)=> h -> BigNat -> h
{-# INLINE hash32BigNatBytes #-}
hash32BigNatBytes h (BN# ba#) = 
    let ba = P.ByteArray ba#
        szBytes = P.sizeofByteArray ba
        numLimbs = szBytes `unsafeShiftR` LOG_SIZEOF_WORD
     in assert (numLimbs >= 1 && (numLimbs * SIZEOF_HSWORD) == szBytes) $
         hash32BigNatByteArrayBytes h numLimbs ba


-- | The @BigNat@'s value is represented in 32-bit chunks (at least one, for
-- zero; but no more than necessary), then bytes are added to the hash from
-- most to least significant (including all initial padding 0s). Finally
-- @'mixConstructor' 0@ is called on the resulting hash value.
--
-- Exposed only in GHC 7.10.
instance Hashable BigNat where
    {-# INLINE hash #-}
    hash h = mixConstructor 0 . hash32BigNatBytes h

# endif


-- Hashing of internals of BigNat-format ByteArrays of at least 1 limb, for old
-- and new style Integer from integer-gmp.
hash32BigNatByteArrayBytes :: (Hash h)=> h -> Int -> P.ByteArray -> h
{-# INLINE hash32BigNatByteArrayBytes #-}
hash32BigNatByteArrayBytes h numLimbs ba = 
  assert (numLimbs > 0) $
    let mostSigLimbIx = numLimbs - 1
        -- NOTE: to correctly handle small-endian, we must read in Word-size
        -- chunks (not just Word32 size)
        go !h' (-1) = h'
        go !h' !ix = let wd = P.indexByteArray ba ix
                      in go (h' `mixWord` wd) (ix - 1)
#  if WORD_SIZE_IN_BITS == 32
        mixWord = mix32
     in go h mostSigLimbIx
#  else
        mixWord h' wd = let (wd32_0, wd32_1) = words32 wd
                         in h' `mix32` wd32_0 `mix32` wd32_1
        -- handle dropping possibly-empty most-significant Word32, before
        -- processing remaining limbs:
        h0 = let mostSigLimb = P.indexByteArray ba mostSigLimbIx
              in h `mixSignificantMachWord64` mostSigLimb
        ix0 = mostSigLimbIx - 1
     in go h0 ix0
#  endif

#endif

-- Also GHC 7.10:
#if MIN_VERSION_base(4,8,0)
-- | The @Natural@'s value is represented in 32-bit chunks (at least one, for
-- zero; but no more than necessary), then bytes are added to the hash from
-- most to least significant (including all initial padding 0s). Finally
-- @'mixConstructor' 0@ is called on the resulting hash value.
--
-- Exposed only in GHC 7.10
instance Hashable Natural where
    {-# INLINE hash #-}
    hash h nat = case nat of
# if defined (MIN_VERSION_integer_gmp) && MIN_VERSION_integer_gmp(1,0,0)
        -- For Word-size natural
        (NatS# wd#) -> mixConstructor 0 $
#         if WORD_SIZE_IN_BITS == 32
            h `mix32` (fromIntegral $ W# wd#)  -- TODO benchmark unsafeCoerce
#         else
            h `mixSignificantMachWord64` (fromIntegral $ W# wd#)  -- TODO benchmark unsafeCoerce on 64-bit
#         endif
        -- Else using a BigNat (which instance calls required mixConstructor):
        (NatJ# bn)  -> hash h bn
# else
        -- Natural represented with non-negative Integer:
        (Natural n) -> hash h n
# endif

-- This is the instance in void-0.7:
--
-- | > hash _ _ = absurd
--
-- Exposed only in GHC 7.10
instance Hashable Void where
    hash _ = absurd

#endif


-- | > hash s a = s `hash` numerator a `hash` denominator a
instance (Integral a, Hashable a) => Hashable (Ratio a) where
    {-# INLINE hash #-}
    hash s a = s `hash` numerator a `hash` denominator a


-- ---------
-- Architecture-dependent types, with special handling.

-- | __NOTE__: @Int@ has platform-dependent size. When hashing on 64-bit machines
-- if the @Int@ value to be hashed falls in the 32-bit Int range, we first cast
-- it to an Int32. This should help ensure that programs that are correct
-- across architectures will also produce the same hash values.
instance Hashable Int where
    {-# INLINE hash #-}
    hash h i =
#     if WORD_SIZE_IN_BITS == 32
        mix32 h $ unsafeCoerceIntWord32 i
#     else
        _hash32_Int_64 h (fromIntegral i)
#     endif

-- | __NOTE__: @Word@ has platform-dependent size. When hashing on 64-bit
-- machines if the @Word@ value to be hashed falls in the 32-bit Word range, we
-- first cast it to a Word32. This should help ensure that programs that are
-- correct across architectures will also produce the same hash values.
instance Hashable Word where
    {-# INLINE hash #-}
    hash h w =
#     if WORD_SIZE_IN_BITS == 32
        hash h (fromIntegral w :: Word32)
#     else
        _hash32_Word_64 h (fromIntegral w) -- TODO benchmarking unsafeCoerce on 64-bit
#     endif


-- TODO Benchmarking + try unsafeCoerce on 64-bit
-- NOTE: the expressions in the conditionals alone make these quite slow on
--       32-bit machines, so don't worry about benchmarking this directly.
_hash32_Int_64 :: (Hash h)=> h -> Int64 -> h
{-# INLINE _hash32_Int_64 #-}
_hash32_Int_64 h = \i->
    -- Can we losslessly cast to 32-bit representation?
    if i <= (fromIntegral (maxBound :: Int32)) && 
       i >= (fromIntegral (minBound :: Int32)) -- TODO benchmark and maybe use (.&.), and check ==0
        then hash h (fromIntegral i :: Int32)
        else hash h i

_hash32_Word_64 :: (Hash h)=> h -> Word64 -> h
{-# INLINE _hash32_Word_64 #-}
_hash32_Word_64 h = \w->
    -- Can we losslessly cast to 32-bit representation?
    if w <= (fromIntegral (maxBound :: Word32))
        then hash h (fromIntegral w :: Word32)
        else hash h w



-- | Hash a Float as IEEE 754 single-precision format bytes. This is terribly
-- slow; direct complaints to http://hackage.haskell.org/trac/ghc/ticket/4092
instance Hashable Float where
    {-# INLINE hash #-}
    hash h x = assert (isIEEE x) $
        hash h $ bytesFloat x

-- | Hash a Double as IEEE 754 double-precision format bytes. This is terribly
-- slow; direct complaints to http://hackage.haskell.org/trac/ghc/ticket/4092
instance Hashable Double where
    {-# INLINE hash #-}
    hash h x = assert (isIEEE x) $
        hash h $ bytesDouble x


-- GHC uses two's complement representation for signed ints; C has this
-- undefined, I guess; just cast to Word and hash.

instance Hashable Int8 where
    {-# INLINE hash #-}
    hash h = mix8 h . fromIntegral

instance Hashable Int16 where
    {-# INLINE hash #-}
    hash h = mix16 h . fromIntegral

instance Hashable Int32 where
    {-# INLINE hash #-}
    hash h = mix32 h . coerceInt32Word32


instance Hashable Int64 where
    {-# INLINE hash #-}
    hash h = \i-> hash h (coerceInt64Word64 i :: Word64)

-- Straightforward hashing of different Words and byte arrays:

instance Hashable Word8 where
    {-# INLINE hash #-}
    hash = mix8

instance Hashable Word16 where
    {-# INLINE hash #-}
    hash = mix16

instance Hashable Word32 where
    {-# INLINE hash #-}
    hash = mix32

instance Hashable Word64 where
    {-# INLINE hash #-}
    hash h = hash h . bytes64


-- ------------------------------------------------------------------
-- ARRAYS AND LIST:


-- Since below have variable-length, we'll use this helper (which is also
-- useful for multi-constructor types):

-- > mixConstructor n h = h `mix8` (0xFF - n)
mixConstructor :: (Hash h)
               => Word8  -- ^ Constructor number. We recommend starting from 0 and incrementing.
               -> h      -- ^ Hash value to mix our byte into
               -> h      -- ^ New hash value
{-# INLINE mixConstructor #-}
mixConstructor n = \h-> h `mix8` (0xFF - n)

-- | Strict @ByteString@
instance Hashable B.ByteString where
    {-# INLINE hash #-}
    hash h = mixConstructor 0 .
        hashBytesUnrolled64 h

-- TODO benchmarks for fusion:
-- | Lazy @ByteString@
instance Hashable BL.ByteString where
    {-# INLINE hash #-}
    hash h = mixConstructor 0 .
        BL.foldlChunks hashBytesUnrolled64 h

#if MIN_VERSION_bytestring(0,10,4)
-- | Exposed only in bytestring >= v0.10.4
instance Hashable BSh.ShortByteString where
    {-# INLINE hash #-}
    hash h  = 
      \(BSh.SBS ba_) -> -- when MIN_VERSION_base(4,3,0)
        let ba = P.ByteArray ba_
         in mixConstructor 0 $
              hashByteArray h (P.sizeofByteArray ba) ba
#endif

-- | Strict @Text@, hashed as big endian UTF-16.
instance Hashable T.Text where
    {-# INLINE hash #-}
    hash h = mixConstructor 0 .
        hashText h

-- TODO benchmarks for fusion:
-- | Lazy @Text@, hashed as big endian UTF-16.
instance Hashable TL.Text where
    {-# INLINE hash #-}
    hash h = mixConstructor 0 .
        TL.foldlChunks hashText h

-- | Here we hash each byte of the array in turn. If using this to hash some
-- data stored internally as a @ByteArray#@, be aware that depending on the
-- size and alignment requirements of that data, as well as the endianness of
-- your machine, this might result in different hash values across different
-- architectures.
instance Hashable P.ByteArray where
    {-# INLINE hash #-}
    hash h = \ba-> mixConstructor 0 $
        hashByteArray h (P.sizeofByteArray ba) ba

-- ------------------------------------------------------------------
-- MISC THINGS:



-- TODO look at core
-- | Hash a @Char@ as big endian UTF-16. Note that Char permits values in the
-- reserved unicode range U+D800 to U+DFFF; these Char values are added to the
-- hash just as if they were valid 16-bit characters.
instance Hashable Char where
    {-# INLINE hash #-}
    hash h = go where
      -- Encoding a unicode code point in UTF-16. adapted from
      -- Data.Text.Internal.Unsafe.Char.unsafeWrite:
    --go c | n .&. complement 0xFFFF == 0 =  -- TODO try this, etc. TODO try look at core & try unsafeCoerce
      go c | n < 0x10000 = h `mix16` fromIntegral n
              -- TODO MODIFY lo AND CALL mix32, 
           | otherwise = h `mix16` lo `mix16` hi

        where n = ord c
              m = n - 0x10000
              lo = fromIntegral $ (m `unsafeShiftR` 10) + 0xD800
              hi = fromIntegral $ (m .&. 0x3FF) + 0xDC00


-- | __NOTE__: no promise of consistency across runs or platforms.
instance Hashable ThreadId where
    {-# INLINE hash #-}
    hash h = \(ThreadId tid)-> 
        hash h (fromIntegral $ getThreadId tid :: Word)

-- | __NOTE__: no promise of consistency across platforms or GHC versions.
instance Hashable TypeRep where
    {-# INLINE hash #-}
    hash h = hash h . typeRepInt32

typeRepInt32 :: TypeRep -> Int32
{-# INLINE typeRepInt32 #-}
typeRepInt32 = 
# if __GLASGOW_HASKELL__ >= 710
    -- Fingerprint is just the MD5, so taking any Int from it is fine
    (\(Fingerprint i64 _) -> fromIntegral i64) . typeRepFingerprint
# else
-- __GLASGOW_HASKELL__ >= 702
    -- Fingerprint is just the MD5, so taking any Int from it is fine
    \(TypeRep (Fingerprint i64 _) _ _) -> fromIntegral i64
# endif


-- | __NOTE__: No promise of stability across runs or platforms. Implemented via
-- 'hashStableName'.
instance Hashable (StableName a) where
    {-# INLINE hash #-}
    hash h = \x-> hash h $ hashStableName x
    
-- | The (now deprecated) @versionTags@ field is ignored, and we follow the
-- 'Eq' instance which does not ignore trailing zeros.
instance Hashable Version where
    {-# INLINE hash #-}
    hash h = \x-> hash h $ versionBranch x

instance Hashable Unique where
    {-# INLINE hash #-}
    hash h = \x-> hash h $ hashUnique x

-- ------------------------------------------------------------------
-- ALGEBRAIC DATA TYPES:


-- ---------
-- Sum types

-- | > hash h = hash h . \b-> if b then (1::Word8) else 0
instance Hashable Bool where
    {-# INLINE hash #-}
    hash h = hash h . \b-> if b then (1::Word8) else 0


instance Hashable Ordering where
    {-# INLINE hash #-}
    hash h = flip mixConstructor h . fromIntegral . fromEnum

instance Hashable a => Hashable [a] where
    -- TODO OPTIMIZE (see notes below)
    {-# INLINE hash #-}
    hash h = mixConstructor 0 .
        hashFoldl' h

instance Hashable a => Hashable (Maybe a) where
    {-# INLINE hash #-}
    hash h Nothing  = mixConstructor 0 h
    hash h (Just a) = mixConstructor 1 $ hash h a
        
instance (Hashable a, Hashable b) => Hashable (Either a b) where
    {-# INLINE hash #-}
    hash h = either (mx 0) (mx 1) where
        mx n = mixConstructor n . hash h


-- ---------
-- Tuples (product types)

-- Per our rules, this must perturb the hash value by at least a byte, even
-- though its value is entirely "fixed" by its type. Consider [()]; the
-- instance relies on () following the rule.
--
-- | > hash = const . mixConstructor 0
instance Hashable () where
    {-# INLINE hash #-}
    hash = const . mixConstructor 0

instance (Hashable a1, Hashable a2) => Hashable (a1, a2) where
    {-# INLINE hash #-}
    hash h (a,b) = h `hash` a `hash` b
    
instance (Hashable a1, Hashable a2, Hashable a3) => Hashable (a1, a2, a3) where
    {-# INLINE hash #-}
    hash h (a,b,c) = h `hash` a `hash` b `hash` c

instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4) => Hashable (a1, a2, a3, a4) where
    {-# INLINE hash #-}
    hash h (a,b,c,d) = h `hash` a `hash` b `hash` c `hash` d

instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4, Hashable a5) => Hashable (a1, a2, a3, a4, a5) where
    {-# INLINE hash #-}
    hash h (a,b,c,d,e) = h `hash` a `hash` b `hash` c `hash` d `hash` e

instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4, Hashable a5, Hashable a6) => Hashable (a1, a2, a3, a4, a5, a6) where
    {-# INLINE hash #-}
    hash h (a,b,c,d,e,f) = h `hash` a `hash` b `hash` c `hash` d `hash` e `hash` f

instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4, Hashable a5, Hashable a6, Hashable a7) => Hashable (a1, a2, a3, a4, a5, a6, a7) where
    {-# INLINE hash #-}
    hash h (a,b,c,d,e,f,g) = h `hash` a `hash` b `hash` c `hash` d `hash` e `hash` f `hash` g

instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4, Hashable a5, Hashable a6, Hashable a7, Hashable a8) => Hashable (a1, a2, a3, a4, a5, a6, a7, a8) where
    {-# INLINE hash #-}
    hash hsh (a,b,c,d,e,f,g,h) = hsh `hash` a `hash` b `hash` c `hash` d `hash` e `hash` f `hash` g `hash` h

-- WISHLIST:
--   - :: Word64 -> (Word32,Word32)  for 32-bit machines.


-- This is about twice as fast as a loop with single byte peeks:
hashBytesUnrolled64 :: (Hash h)=> h -> B.ByteString -> h
{-# INLINE hashBytesUnrolled64 #-}
hashBytesUnrolled64 h = \(B.PS fp off lenBytes) -> unsafeDupablePerformIO $
      withForeignPtr fp $ \base ->
        let !bytesRem = lenBytes .&. 7  -- lenBytes `mod` 8
            -- index where we begin to read (bytesRem < 8) individual bytes:
            !bytesIx = off+lenBytes-bytesRem
            !ixFinal = off+lenBytes-1

            hash8ByteLoop !hAcc !ix 
                | ix == bytesIx = hashRemainingBytes hAcc bytesIx
                | otherwise     = assert (ix < bytesIx) $ do
#                 if WORD_SIZE_IN_BITS == 32
                    w0Dirty <- peekByteOff base ix
                    w1Dirty <- peekByteOff base (ix+4)
                    let (w0,w1) = if littleEndian
                                   then (byteSwap32 w0Dirty, byteSwap32 w1Dirty)
                                   else (w0Dirty,w1Dirty)
#                 else
                    w64Dirty <- peekByteOff base ix
                    let w64 = if littleEndian
                                then byteSwap64 w64Dirty
                                else w64Dirty
                        (w0,w1) = words32 w64
#                 endif
                    hash8ByteLoop (hAcc `mix32` w0 `mix32` w1) (ix + 8)
            
            -- TODO we could unroll this for [0..7]
            hashRemainingBytes !hAcc !ix 
                | ix > ixFinal  = return hAcc 
                | otherwise     = assert (ix <= ixFinal) $ do
                    byt <- peekByteOff base ix
                    hashRemainingBytes (hAcc `mix8` byt) (ix+1)
        
         in hash8ByteLoop h off 


-- NOTE: we can't simply call hashByteArray here; Text is stored as
-- machine-endian UTF-16 (as promised by public Data.Text.Foreign), so we need
-- to read Word16 here in order to hash as Big-Endian UTF-16.
hashText :: (Hash h)=> h -> T.Text -> h
{-# INLINE hashText #-}
hashText h = \(T.Text (T.Array ba_) off lenWord16) -> 
    let ba = P.ByteArray ba_
        !word16sRem = lenWord16 .&. 3         -- lenWord16 `mod` 4
        -- index where we begin to read (word16sRem < 4) individual Word16s:
        !word16sIx = off+lenWord16-word16sRem
        !ixFinal = off+lenWord16-1

        hash4Word16sLoop !hAcc !ix 
            | ix == word16sIx = hashRemainingWord16s hAcc word16sIx
            | otherwise     = assert (ix < word16sIx) $
                -- CAREFUL: Word16s are stored in machine-endian, so we must
                -- read them out as Word16:
                let w0 = P.indexByteArray ba ix
                    w1 = P.indexByteArray ba (ix+1)
                    w2 = P.indexByteArray ba (ix+2)
                    w3 = P.indexByteArray ba (ix+3)
                 in hash4Word16sLoop (hAcc `mix16` w0 `mix16` w1 `mix16` w2 `mix16` w3) (ix + 4)
        
        -- TODO we could unroll this for [0..3]
        hashRemainingWord16s !hAcc !ix 
            | ix > ixFinal  = hAcc 
            | otherwise     = assert (ix <= ixFinal) $
                let w0 = P.indexByteArray ba ix
                 in hashRemainingWord16s (hAcc `mix16` w0) (ix+1)
     in hash4Word16sLoop h off 

hashByteArray :: (Hash h)=> h -> Int -> P.ByteArray -> h
{-# INLINE hashByteArray #-}
hashByteArray h !lenBytes ba = 
    let !bytesRem = lenBytes .&. 7         -- lenBytes `mod` 8
        -- index where we begin to read (bytesRem < 8) individual bytes:
        !bytesIx = lenBytes-bytesRem
        !ixFinal = lenBytes-1
        -- bytesIx in elements of Word32:
        !bytesIxWd = bytesIx `unsafeShiftR`
#                       if WORD_SIZE_IN_BITS == 32
                          2  -- `div` 4
#                       else
                          3  -- `div` 8
#                       endif

        -- Index `ix` in terms of elements of Word32 or Word64, depending on
        -- WORD_SIZE_IN_BITS
        hash8ByteLoop !hAcc !ix 
            | ix == bytesIxWd = hashRemainingBytes hAcc bytesIx
            | otherwise     = assert (ix < bytesIxWd) $
#                 if WORD_SIZE_IN_BITS == 32
                    let w0Dirty = P.indexByteArray ba ix
                        w1Dirty = P.indexByteArray ba (ix+1)
                        (w0,w1) = if littleEndian
                                   then (byteSwap32 w0Dirty, byteSwap32 w1Dirty)
                                   else (w0Dirty,w1Dirty)
                        incr = 2 -- x Word32
#                 else
                    let w64Dirty = P.indexByteArray ba ix
                        w64 = if littleEndian
                                then byteSwap64 w64Dirty
                                else w64Dirty
                        (w0,w1) = words32 w64
                        incr = 1 -- x Word64
#                 endif
                     in hash8ByteLoop (hAcc `mix32` w0 `mix32` w1) (ix + incr)
        
        -- TODO we could unroll this for [0..7]
        hashRemainingBytes !hAcc !ix 
            | ix > ixFinal  = hAcc 
            | otherwise     = assert (ix <= ixFinal) $
                let b0 = P.indexByteArray ba ix
                 in hashRemainingBytes (hAcc `mix8` b0) (ix+1)
     in hash8ByteLoop h 0 




---------------- LIST INSTANCE SCRATCH WORK:
-- 
-- We need to look at how inlining progresses and figure out a way to have our
-- list instance be optimal. See scratch work below.



-- TODO more different benchmarks of different types of lists, and ways of
-- constructing, and examine which of these two to use (and when):
--   We might be able to NOINLINE hashLeftUnfolded version (if performance
--   unaffected), and then re-write to hashFoldl' version based on argument
--   TODO :
--     or use our own rules so that we can get both fusion and unrolling?
--     (or would that not be helpful, since values already in a register?)

-- 7.10
--   APPLIED TO (take 250 $ iterate (+1) (1::Word8))  339.4 ns  !! MATCHING BASELINE
--   APPLIED TO ([1.. 250 :: Word8])                  1.766 μs
-- 7.8
--   APPLIED TO (take 250 $ iterate (+1) (1::Word8))  8.938 μs  -- NOTE: in general, 7.8 seems to do poorly applying folds to this in the context of criterion benchmarks
--   APPLIED TO ([1.. 250 :: Word8])                  846.5 ns
hashFoldl' :: (Hashable a, Hash h)=> h -> [a] -> h
-- hashFoldl' :: Word32 -> [Word8] -> Word32  -- NOTE: tested above w/ this monomorphic sig
{-# INLINE hashFoldl' #-}
hashFoldl' = foldl' (\h' a-> h' `hash` a)

-- 7.10
--   APPLIED TO ([1.. 250 :: Word8])                  675.6 ns
-- 7.8
--   APPLIED TO ([1.. 250 :: Word8])                  729.6 ns
hashLeftUnfolded :: (Hashable a, Hash h)=> h -> [a] -> h
-- hashLeftUnfolded :: Word32 -> [Word8] -> Word32  -- NOTE: tested above w/ this monomorphic sig
{-# INLINE hashLeftUnfolded #-}
hashLeftUnfolded = go
    where go !h [] = h
          -- This seems to be sweet spot on my machine:
          go !h (a1:a2:a3:a4:a5:a6:as) = go (h `hash` a1 `hash` a2 `hash` a3 `hash` a4 `hash` a5 `hash` a6) as
          go !h (a1:as) = go (h `hash` a1) as
