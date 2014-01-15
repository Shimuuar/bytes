{-# LANGUAGE CPP #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
#if defined(__GLASGOW_HASKELL__) && __GLASGOW_HASKELL__ >= 704
{-# LANGUAGE Trustworthy #-}
#endif
--------------------------------------------------------------------
-- |
-- Copyright :  (c) Edward Kmett 2013
-- License   :  BSD3
-- Maintainer:  Edward Kmett <ekmett@gmail.com>
-- Stability :  experimental
-- Portability: non-portable
--
-- This module contains two main classes, each providing methods to
-- serialize and deserialize types. 'Serial' is the primary class,
-- to be used for the canonical way to serialize a specific
-- type. 'SerialEndian' is used to provide endian-specific methods
-- for serializing a type.
--------------------------------------------------------------------
module Data.Bytes.Serial
  (
  -- * Serialization
    Serial(..)
  -- * Specifying endianness
  , SerialEndian(..)
  -- * Higher-order
  -- $higher
  , Serial1(..)
  , serialize1, deserialize1
  , Serial2(..)
  , serialize2, deserialize2
  -- * Storable
  , store, restore
  -- * Generics
  -- $generics
  , GSerial(..)
  , GSerialEndian(..)
  , GSerial1(..)
  ) where

import Control.Monad
import qualified Data.Foldable as F
import Data.Bytes.Get
import Data.Bytes.Put
import Data.Bytes.Signed
import Data.Bytes.VarInt
import Data.ByteString.Internal
import Data.ByteString.Lazy as Lazy
import Data.ByteString as Strict
import Data.Int
import Data.Bits
import qualified Data.IntMap as IMap
import qualified Data.IntSet as ISet
import qualified Data.Map as Map
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Data.Text as SText
import Data.Text.Encoding as SText
import Data.Text.Lazy as LText
import Data.Text.Lazy.Encoding as LText
import Data.Void
import Data.Word
import Data.Fixed
import Foreign.ForeignPtr
import Foreign.Ptr
import Foreign.Storable
import GHC.Generics
import System.IO.Unsafe

foreign import ccall floatToWord32 :: Float -> Word32
foreign import ccall word32ToFloat :: Word32 -> Float
foreign import ccall doubleToWord64 :: Double -> Word64
foreign import ccall word64ToDouble :: Word64 -> Double

------------------------------------------------------------------------------
-- Endianness-Dependant Serialization
------------------------------------------------------------------------------

{-| Methods to serialize and deserialize type 'a' to a big and little endian
binary representations. Methods suffixed with "host" are automatically defined
to use equal the methods corresponding to the current machine's native
endianness, but they can be overridden.
-}
class SerialEndian a where
  serializeBE :: MonadPut m => a -> m ()
#ifndef HLINT
  default serializeBE :: (MonadPut m, GSerialEndian (Rep a), Generic a) => a -> m ()
  serializeBE = gserializeBE . from
#endif

  deserializeBE :: MonadGet m => m a
#ifndef HLINT
  default deserializeBE :: (MonadGet m, GSerialEndian (Rep a), Generic a) => m a
  deserializeBE = liftM to gdeserializeBE
#endif

  serializeLE :: MonadPut m => a -> m ()
#ifndef HLINT
  default serializeLE :: (MonadPut m, GSerialEndian (Rep a), Generic a) => a -> m ()
  serializeLE = gserializeLE . from
#endif

  deserializeLE :: MonadGet m => m a
#ifndef HLINT
  default deserializeLE :: (MonadGet m, GSerialEndian (Rep a), Generic a) => m a
  deserializeLE = liftM to gdeserializeLE
#endif

  serializeHost :: MonadPut m => a -> m ()
  deserializeHost :: MonadGet m => m a
#ifdef WORDS_BIGENDIAN
  serializeHost = serializeBE
  deserializeHost = deserializeBE
#else
  serializeHost = serializeLE
  deserializeHost = deserializeLE
#endif

instance SerialEndian Double where
  serializeBE = serializeBE . doubleToWord64
  deserializeBE = liftM word64ToDouble deserializeBE

  serializeLE = serializeLE . doubleToWord64
  deserializeLE = liftM word64ToDouble deserializeLE

instance SerialEndian Float where
  serializeBE = serializeBE . floatToWord32
  deserializeBE = liftM word32ToFloat deserializeBE

  serializeLE = serializeLE . floatToWord32
  deserializeLE = liftM word32ToFloat deserializeLE

instance SerialEndian Char where
  serializeBE = putWord32be . fromIntegral . fromEnum
  deserializeBE = liftM (toEnum . fromIntegral) getWord32be

  serializeLE = putWord32le . fromIntegral . fromEnum
  deserializeLE = liftM (toEnum . fromIntegral) getWord32le

instance SerialEndian Word64 where
  serializeBE = putWord64be
  deserializeBE = getWord64be

  serializeLE = putWord64le
  deserializeLE = getWord64le

instance SerialEndian Word32 where
  serializeBE = putWord32be
  deserializeBE = getWord32be

  serializeLE = putWord32le
  deserializeLE = getWord32le

instance SerialEndian Word16 where
  serializeBE = putWord16be
  deserializeBE = getWord16be

  serializeLE = putWord16le
  deserializeLE = getWord16le

instance SerialEndian Int64 where
  serializeBE = putWord64be . fromIntegral
  deserializeBE = liftM fromIntegral getWord64be

  serializeLE = putWord64le . fromIntegral
  deserializeLE = liftM fromIntegral getWord64le

instance SerialEndian Int32 where
  serializeBE = putWord32be . fromIntegral
  deserializeBE = liftM fromIntegral getWord32be

  serializeLE = putWord32le . fromIntegral
  deserializeLE = liftM fromIntegral getWord32le

instance SerialEndian Int16 where
  serializeBE = putWord16be . fromIntegral
  deserializeBE = liftM fromIntegral getWord16be

  serializeLE = putWord16le . fromIntegral
  deserializeLE = liftM fromIntegral getWord16le

------------------------------------------------------------------------------
-- Serialization
------------------------------------------------------------------------------

{-| Methods to serialize and deserialize type 'a' to a binary representation

Instances provided here for fixed-with Integers and Words are big endian.
Instances for strict and lazy bytestrings store also the length of bytestring
big endian. Instances for Word and Int are host endian as they are
machine-specific types.
-}
class Serial a where
  serialize :: MonadPut m => a -> m ()
#ifndef HLINT
  default serialize :: (MonadPut m, GSerial (Rep a), Generic a) => a -> m ()
  serialize = gserialize . from
#endif

  deserialize :: MonadGet m => m a
#ifndef HLINT
  default deserialize :: (MonadGet m, GSerial (Rep a), Generic a) => m a
  deserialize = liftM to gdeserialize
#endif

instance Serial Strict.ByteString where
  serialize bs = putWord32be (fromIntegral (Strict.length bs)) >> putByteString bs
  deserialize = do
    n <- getWord32be
    getByteString (fromIntegral n)

instance Serial Lazy.ByteString where
  serialize bs = putWord64be (fromIntegral (Lazy.length bs)) >> putLazyByteString bs
  deserialize = do
    n <- getWord64be
    getLazyByteString (fromIntegral n)

instance Serial SText.Text where
  serialize = serialize . SText.encodeUtf8
  deserialize = SText.decodeUtf8 `fmap` deserialize

instance Serial LText.Text where
  serialize = serialize . LText.encodeUtf8
  deserialize = LText.decodeUtf8 `fmap` deserialize

instance Serial ()
instance Serial a => Serial [a]
instance Serial a => Serial (Maybe a)
instance (Serial a, Serial b) => Serial (Either a b)
instance (Serial a, Serial b) => Serial (a, b)
instance (Serial a, Serial b, Serial c) => Serial (a, b, c)
instance (Serial a, Serial b, Serial c, Serial d) => Serial (a, b, c, d)
instance (Serial a, Serial b, Serial c, Serial d, Serial e) => Serial (a, b, c, d, e)

instance Serial Bool

-- | serialize any 'Storable' in a host-specific format.
store :: (MonadPut m, Storable a) => a -> m ()
store a = putByteString bs
  where bs = unsafePerformIO $ create (sizeOf a) $ \ p -> poke (castPtr p) a

-- | deserialize any 'Storable' in a host-specific format.
restore :: forall m a. (MonadGet m, Storable a) => m a
restore = do
  let required = sizeOf (undefined :: a)
  PS fp o n <- getByteString required
  unless (n >= required) $ fail "restore: Required more bytes"
  return $ unsafePerformIO $ withForeignPtr fp $ \p -> peekByteOff p o

instance Serial Double where
  serialize = serializeBE
  deserialize = deserializeBE

instance Serial Float where
  serialize = serializeBE
  deserialize = deserializeBE

instance Serial Char where
  serialize = serializeBE
  deserialize = deserializeBE

 -- host endian
instance Serial Word where
  serialize = putWordhost
  deserialize = getWordhost

instance Serial Word64 where
  serialize = serializeBE
  deserialize = deserializeBE

instance Serial Word32 where
  serialize = serializeBE
  deserialize = deserializeBE

instance Serial Word16 where
  serialize = serializeBE
  deserialize = deserializeBE

instance Serial Word8 where
  serialize = putWord8
  deserialize = getWord8

 -- host endian
instance Serial Int where
  serialize = putWordhost . fromIntegral
  deserialize = liftM fromIntegral getWordhost

instance Serial Int64 where
  serialize = serializeBE
  deserialize = deserializeBE

instance Serial Int32 where
  serialize = serializeBE
  deserialize = deserializeBE

instance Serial Int16 where
  serialize = serializeBE
  deserialize = deserializeBE

instance Serial Int8 where
  serialize = putWord8 . fromIntegral
  deserialize = liftM fromIntegral getWord8

instance Serial Void where
  serialize = absurd
  deserialize = fail "I looked into the void."

instance Serial ISet.IntSet where
  serialize = serialize . ISet.toAscList
  deserialize = ISet.fromList `liftM` deserialize

instance Serial a => Serial (Seq.Seq a) where
  serialize = serializeWith serialize
  deserialize = deserializeWith deserialize

instance (Serial a, Ord a) => Serial (Set.Set a) where
  serialize = serialize . Set.toAscList
  deserialize = Set.fromList `liftM` deserialize

instance Serial v => Serial (IMap.IntMap v) where
  serialize = serializeWith serialize
  deserialize = deserializeWith deserialize

instance (Serial k, Serial v, Ord k) => Serial (Map.Map k v) where
  serialize = serializeWith serialize
  deserialize = deserializeWith deserialize

putVarInt :: (MonadPut m, Integral a, Bits a) => a -> m ()
putVarInt n
  | n < 0x80 = putWord8 $ fromIntegral n
  | otherwise = do
    putWord8 $ setBit (fromIntegral n) 7
    putVarInt $ shiftR n 7
{-# INLINE putVarInt #-}

getVarInt :: (MonadGet m, Num b, Bits b) => Word8 -> m b
getVarInt n
  | testBit n 7 = do
    VarInt m <- getWord8 >>= getVarInt
    return $ shiftL m 7 .|. clearBit (fromIntegral n) 7
  | otherwise = return $ fromIntegral n
{-# INLINE getVarInt #-}

-- |
-- $setup
-- >>> import Data.Word
-- >>> import Data.Fixed
-- >>> import Data.Bytes.Serial

-- | Integer/Word types serialized to base-128 variable-width ints.
--
-- >>> import Data.Monoid (mconcat)
-- >>> import qualified Data.ByteString.Lazy as BSL
-- >>> mconcat $ BSL.toChunks $ runPutL $ serialize (97 :: Word64)
-- "\NUL\NUL\NUL\NUL\NUL\NUL\NULa"
-- >>> mconcat $ BSL.toChunks $ runPutL $ serialize (97 :: VarInt Word64)
-- "a"
instance (Bits n, Integral n, Bits (Unsigned n), Integral (Unsigned n)) => Serial (VarInt n) where
  serialize (VarInt n) = putVarInt $ unsigned n
  {-# INLINE serialize #-}
  deserialize = getWord8 >>= getVarInt
  {-# INLINE deserialize #-}

-- |
-- >>> (runGetL deserialize $ runPutL $ serialize (1.82::Fixed E2))::Fixed E2
-- 1.82
instance HasResolution a => Serial (Fixed a) where
  serialize f =
      serialize i
    where
      i :: VarInt Integer
      i = VarInt . truncate . (* r) $ f
      r = fromInteger $ resolution f
  deserialize =
    (((flip (/)) (fromInteger $ resolution (undefined::Fixed a))) . fromInteger . unVarInt) `liftM` deserialize

------------------------------------------------------------------------------
-- Generic Serialization
------------------------------------------------------------------------------

-- $generics
--
-- You probably will never need to care that these exist except they
-- provide us with default definitions for 'Serial' and 'SerialEndian'

-- | Used internally to provide generic serialization
class GSerial f where
  gserialize :: MonadPut m => f a -> m ()
  gdeserialize :: MonadGet m => m (f a)

instance GSerial U1 where
  gserialize U1 = return ()
  gdeserialize = return U1

instance GSerial V1 where
  gserialize _ = fail "I looked into the void."
  gdeserialize = fail "I looked into the void."

instance (GSerial f, GSerial g) => GSerial (f :*: g) where
  gserialize (f :*: g) = do
    gserialize f
    gserialize g
  gdeserialize = liftM2 (:*:) gdeserialize gdeserialize

instance (GSerial f, GSerial g) => GSerial (f :+: g) where
  gserialize (L1 x) = putWord8 0 >> gserialize x
  gserialize (R1 y) = putWord8 1 >> gserialize y
  gdeserialize = getWord8 >>= \a -> case a of
    0 -> liftM L1 gdeserialize
    1 -> liftM R1 gdeserialize
    _ -> fail "Missing case"

instance GSerial f => GSerial (M1 i c f) where
  gserialize (M1 x) = gserialize x
  gdeserialize = liftM M1 gdeserialize

instance Serial a => GSerial (K1 i a) where
  gserialize (K1 x) = serialize x
  gdeserialize = liftM K1 deserialize


-- | Used internally to provide generic big-endian serialization
class GSerialEndian f where
  gserializeBE :: MonadPut m => f a -> m ()
#ifndef HLINT
  default gserializeBE :: (MonadPut m, GSerial f) => f a -> m ()
  gserializeBE = gserialize
#endif

  gdeserializeBE :: MonadGet m => m (f a)
#ifndef HLINT
  default gdeserializeBE :: (MonadGet m, GSerial f) => m (f a)
  gdeserializeBE = gdeserialize
#endif

  gserializeLE :: MonadPut m => f a -> m ()
#ifndef HLINT
  default gserializeLE :: (MonadPut m, GSerial f) => f a -> m ()
  gserializeLE = gserialize
#endif

  gdeserializeLE :: MonadGet m => m (f a)
#ifndef HLINT
  default gdeserializeLE :: (MonadGet m, GSerial f) => m (f a)
  gdeserializeLE = gdeserialize
#endif

-- only difference between GSerialEndian and GSerial
instance SerialEndian a => GSerialEndian (K1 i a) where
  gserializeBE (K1 x) = serializeBE x
  gdeserializeBE = liftM K1 deserializeBE

  gserializeLE (K1 x) = serializeLE x
  gdeserializeLE = liftM K1 deserializeLE

------------------------------------------------------------------------------
-- Higher-Rank Serialization
------------------------------------------------------------------------------

-- $higher
--
-- These classes provide us with the ability to serialize containers that need
-- polymorphic recursion.

class Serial1 f where
  serializeWith :: MonadPut m => (a -> m ()) -> f a -> m ()
#ifndef HLINT
  default serializeWith :: (MonadPut m, GSerial1 (Rep1 f), Generic1 f) => (a -> m ()) -> f a -> m ()
  serializeWith f = gserializeWith f . from1
#endif

  deserializeWith :: MonadGet m => m a -> m (f a)
#ifndef HLINT
  default deserializeWith :: (MonadGet m, GSerial1 (Rep1 f), Generic1 f) => m a -> m (f a)
  deserializeWith f = liftM to1 (gdeserializeWith f)
#endif

instance Serial1 [] where
  serializeWith _ [] = putWord8 0
  serializeWith f (x:xs) = putWord8 1 >> f x >> serializeWith f xs
  deserializeWith m = getWord8 >>= \a -> case a of
    0 -> return []
    1 -> liftM2 (:) m (deserializeWith m)
    _ -> error "[].deserializeWith: Missing case"
instance Serial1 Maybe where
  serializeWith _ Nothing = putWord8 0
  serializeWith f (Just a) = putWord8 1 >> f a
  deserializeWith m = getWord8 >>= \a -> case a of
    0 -> return Nothing
    1 -> liftM Just m
    _ -> error "Maybe.deserializeWith: Missing case"
instance Serial a => Serial1 (Either a) where
  serializeWith = serializeWith2 serialize
  deserializeWith = deserializeWith2 deserialize
instance Serial a => Serial1 ((,) a) where
  serializeWith = serializeWith2 serialize
  deserializeWith = deserializeWith2 deserialize
instance (Serial a, Serial b) => Serial1 ((,,) a b) where
  serializeWith = serializeWith2 serialize
  deserializeWith = deserializeWith2 deserialize
instance (Serial a, Serial b, Serial c) => Serial1 ((,,,) a b c) where
  serializeWith = serializeWith2 serialize
  deserializeWith = deserializeWith2 deserialize
instance (Serial a, Serial b, Serial c, Serial d) => Serial1 ((,,,,) a b c d) where
  serializeWith = serializeWith2 serialize
  deserializeWith = deserializeWith2 deserialize

instance Serial1 Seq.Seq where
  serializeWith pv = serializeWith pv . F.toList
  deserializeWith gv = Seq.fromList `liftM` deserializeWith gv

{-
instance Serial1 Set.Set where
  serializeWith pv = serializeWith pv . Set.toAscList
  deserializeWith gv = Set.fromList `liftM` deserializeWith gv
-}

instance Serial1 IMap.IntMap where
  serializeWith pv = serializeWith (serializeWith2 serialize pv)
                   . IMap.toAscList
  deserializeWith gv = IMap.fromList
               `liftM` deserializeWith (deserializeWith2 deserialize gv)

instance (Ord k, Serial k) => Serial1 (Map.Map k) where
  -- serializeWith = serializeWith2 serialize
  -- deserializeWith = deserializeWith2 deserialize
  serializeWith pv = serializeWith (serializeWith2 serialize pv)
                   . Map.toAscList
  deserializeWith gv = Map.fromList
               `liftM` deserializeWith (deserializeWith2 deserialize gv)

serialize1 :: (MonadPut m, Serial1 f, Serial a) => f a -> m ()
serialize1 = serializeWith serialize
{-# INLINE serialize1 #-}

deserialize1 :: (MonadGet m, Serial1 f, Serial a) => m (f a)
deserialize1 = deserializeWith deserialize
{-# INLINE deserialize1 #-}

------------------------------------------------------------------------------
-- Higher-Rank Generic Serialization
------------------------------------------------------------------------------

-- | Used internally to provide generic serialization
class GSerial1 f where
  gserializeWith :: MonadPut m => (a -> m ()) -> f a -> m ()
  gdeserializeWith :: MonadGet m => m a -> m (f a)

instance GSerial1 Par1 where
  gserializeWith f (Par1 a) = f a
  gdeserializeWith m = liftM Par1 m

instance GSerial1 f => GSerial1 (Rec1 f) where
  gserializeWith f (Rec1 fa) = gserializeWith f fa
  gdeserializeWith m = liftM Rec1 (gdeserializeWith m)

-- instance (Serial1 f, GSerial1 g) => GSerial1 (f :.: g) where

instance GSerial1 U1 where
  gserializeWith _ U1 = return ()
  gdeserializeWith _  = return U1

instance GSerial1 V1 where
  gserializeWith _   = fail "I looked into the void."
  gdeserializeWith _ = fail "I looked into the void."

instance (GSerial1 f, GSerial1 g) => GSerial1 (f :*: g) where
  gserializeWith f (a :*: b) = gserializeWith f a >> gserializeWith f b
  gdeserializeWith m = liftM2 (:*:) (gdeserializeWith m) (gdeserializeWith m)

instance (GSerial1 f, GSerial1 g) => GSerial1 (f :+: g) where
  gserializeWith f (L1 x) = putWord8 0 >> gserializeWith f x
  gserializeWith f (R1 y) = putWord8 1 >> gserializeWith f y
  gdeserializeWith m = getWord8 >>= \a -> case a of
    0 -> liftM L1 (gdeserializeWith m)
    1 -> liftM R1 (gdeserializeWith m)
    _ -> fail "Missing case"

instance GSerial1 f => GSerial1 (M1 i c f) where
  gserializeWith f (M1 x) = gserializeWith f x
  gdeserializeWith = liftM M1 . gdeserializeWith

instance Serial a => GSerial1 (K1 i a) where
  gserializeWith _ (K1 x) = serialize x
  gdeserializeWith _ = liftM K1 deserialize

------------------------------------------------------------------------------
-- Higher-Rank Serialization
------------------------------------------------------------------------------

class Serial2 f where
  serializeWith2 :: MonadPut m => (a -> m ()) -> (b -> m ()) -> f a b -> m ()
  deserializeWith2 :: MonadGet m => m a -> m b ->  m (f a b)

serialize2 :: (MonadPut m, Serial2 f, Serial a, Serial b) => f a b -> m ()
serialize2 = serializeWith2 serialize serialize
{-# INLINE serialize2 #-}

deserialize2 :: (MonadGet m, Serial2 f, Serial a, Serial b) => m (f a b)
deserialize2 = deserializeWith2 deserialize deserialize
{-# INLINE deserialize2 #-}

instance Serial2 Either where
  serializeWith2 f _ (Left x)  = putWord8 0 >> f x
  serializeWith2 _ g (Right y) = putWord8 1 >> g y
  deserializeWith2 m n = getWord8 >>= \a -> case a of
    0 -> liftM Left m
    1 -> liftM Right n
    _ -> fail "Missing case"

instance Serial2 (,) where
  serializeWith2 f g (a, b) = f a >> g b
  deserializeWith2 m n = liftM2 (,) m n

instance Serial a => Serial2 ((,,) a) where
  serializeWith2 f g (a, b, c) = serialize a >> f b >> g c
  deserializeWith2 m n = liftM3 (,,) deserialize m n

instance (Serial a, Serial b) => Serial2 ((,,,) a b) where
  serializeWith2 f g (a, b, c, d) = serialize a >> serialize b >> f c >> g d
  deserializeWith2 m n = liftM4 (,,,) deserialize deserialize m n

instance (Serial a, Serial b, Serial c) => Serial2 ((,,,,) a b c) where
  serializeWith2 f g (a, b, c, d, e) = serialize a >> serialize b >> serialize c >> f d >> g e
  deserializeWith2 m n = liftM5 (,,,,) deserialize deserialize deserialize m n
