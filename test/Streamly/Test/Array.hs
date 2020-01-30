{-# LANGUAGE CPP #-}

-- |
-- Module      : Main
-- Copyright   : (c) 2019 Composewell Technologies
--
-- License     : BSD-3-Clause
-- Maintainer  : streamly@composewell.com
-- Stability   : experimental
-- Portability : GHC
--
module Main (main) where

import Foreign.Storable (Storable(..))
-- import Control.Monad.IO.Class (MonadIO)

import Test.Hspec.QuickCheck
import Test.QuickCheck (Property, forAll, Gen, vectorOf, arbitrary, choose)
import Test.QuickCheck.Monadic (monadicIO, assert, run)

import Test.Hspec as H

import Streamly (SerialT)

import qualified Streamly.Prelude as S

#ifdef TEST_SMALL_ARRAY
import qualified Streamly.Internal.Data.SmallArray as A
type Array = A.SmallArray
#elif defined(TEST_ARRAY)
import qualified Streamly.Memory.Mutable.Array as A
import qualified Streamly.Internal.Memory.Mutable.Array as A
import qualified Streamly.Internal.Prelude as IP
type Array = A.Array
#elif defined(TEST_ARRAY_IMMUTABLE)
import qualified Streamly.Internal.Memory.Array as A
import qualified Streamly.Internal.Memory.Array.Types as A
import qualified Streamly.Internal.Memory.Mutable.Array as MA
type Array = A.Array
#elif defined(TEST_PRIM_ARRAY)
import qualified Streamly.Internal.Data.Prim.Array as A
type Array = A.PrimArray
#else
import qualified Streamly.Internal.Data.Array as A
type Array = A.Array
#endif

-- Coverage build takes too long with default number of tests
maxTestCount :: Int
#ifdef DEVBUILD
maxTestCount = 100
#else
maxTestCount = 10
#endif

allocOverhead :: Int
allocOverhead = 2 * sizeOf (undefined :: Int)

-- XXX this should be in sync with the defaultChunkSize in Array code, or we
-- should expose that and use that. For fast testing we could reduce the
-- defaultChunkSize under CPP conditionals.
--
defaultChunkSize :: Int
defaultChunkSize = 32 * k - allocOverhead
   where k = 1024

maxArrLen :: Int
maxArrLen = defaultChunkSize * 8

genericTestFrom ::
       (Int -> SerialT IO Int -> IO (Array Int))
    -> Property
genericTestFrom arrFold =
    forAll (choose (0, maxArrLen)) $ \len ->
        forAll (vectorOf len (arbitrary :: Gen Int)) $ \list ->
            monadicIO $ do
                arr <- run $ arrFold len $ S.fromList list
                assert (A.length arr == len)

testLength :: Property
testLength = genericTestFrom (\n -> S.fold (genFoldN n))
  where
#ifdef TEST_ARRAY_IMMUTABLE
    genFoldN = fmap A.unsafeFreeze . MA.writeN
#else
    genFoldN = A.writeN
#endif
    

testLengthFromStreamN :: Property
testLengthFromStreamN = genericTestFrom A.fromStreamN

#ifndef TEST_SMALL_ARRAY
testLengthFromStream :: Property
testLengthFromStream = genericTestFrom (const A.fromStream)
#endif

genericTestFromTo ::
       (Int -> SerialT IO Int -> IO (Array Int))
    -> (Array Int -> SerialT IO Int)
    -> ([Int] -> [Int] -> Bool)
    -> Property
genericTestFromTo arrFold arrUnfold listEq =
    forAll (choose (0, maxArrLen)) $ \len ->
        forAll (vectorOf len (arbitrary :: Gen Int)) $ \list ->
            monadicIO $ do
                arr <- run $ arrFold len $ S.fromList list
                xs <- run $ S.toList $ arrUnfold arr
                assert (listEq xs list)

testFoldNUnfold :: Property
testFoldNUnfold =
    genericTestFromTo (\n -> S.fold (genFoldN n)) (S.unfold A.read) (==)
  where
#ifdef TEST_ARRAY_IMMUTABLE
    genFoldN = fmap A.unsafeFreeze . MA.writeN
#else
    genFoldN = A.writeN
#endif

testFoldNToStream :: Property
testFoldNToStream =
    genericTestFromTo (\n -> S.fold (genFoldN n)) A.toStream (==)
  where
#ifdef TEST_ARRAY_IMMUTABLE
    genFoldN = fmap A.unsafeFreeze . MA.writeN
#else
    genFoldN = A.writeN
#endif

testFoldNToStreamRev :: Property
testFoldNToStreamRev =
    genericTestFromTo
        (\n -> S.fold (genFoldN n))
        A.toStreamRev
        (\xs list -> xs == reverse list)
  where
#ifdef TEST_ARRAY_IMMUTABLE
    genFoldN = fmap A.unsafeFreeze . MA.writeN
#else
    genFoldN = A.writeN
#endif

testFromStreamNUnfold :: Property
testFromStreamNUnfold = genericTestFromTo A.fromStreamN (S.unfold A.read) (==)

testFromStreamNToStream :: Property
testFromStreamNToStream = genericTestFromTo A.fromStreamN A.toStream (==)

#ifndef TEST_SMALL_ARRAY
testFromStreamToStream :: Property
testFromStreamToStream = genericTestFromTo (const A.fromStream) A.toStream (==)

testFoldUnfold :: Property
testFoldUnfold = genericTestFromTo (const (S.fold genFold)) (S.unfold A.read) (==)
  where
#ifdef TEST_ARRAY_IMMUTABLE
    genFold = fmap A.unsafeFreeze MA.write
#else
    genFold = A.write
#endif

#endif

#ifdef TEST_ARRAY
testArraysOf :: Property
testArraysOf =
    forAll (choose (0, maxArrLen)) $ \len ->
        forAll (vectorOf len (arbitrary :: Gen Int)) $ \list ->
            monadicIO $ do
                xs <- S.toList
                    $ S.concatUnfold A.read
                    $ IP.arraysOf 240
                    $ S.fromList list
                assert (xs == list)


lastN :: Int -> [a] -> [a]
lastN n l = drop (length l - n) l

testLastN :: Property
testLastN =
    forAll (choose (0, maxArrLen)) $ \len ->
        forAll (choose (0, len)) $ \n ->
            forAll (vectorOf len (arbitrary :: Gen Int)) $ \list ->
                monadicIO $ do
                    xs <- fmap A.toList
                        $ S.fold (A.lastN n)
                        $ S.fromList list
                    assert (xs == lastN n list)
#endif

main :: IO ()
main =
    hspec $
    H.parallel $
    modifyMaxSuccess (const maxTestCount) $ do
        describe "Construction" $ do
            prop "length . genFoldN n === n" testLength
            prop "length . fromStreamN n === n" testLengthFromStreamN
            prop "read . genFoldN === id " testFoldNUnfold
            prop "toStream . genFoldN === id" testFoldNToStream
            prop "toStreamRev . genFoldN === reverse" testFoldNToStreamRev
            prop "read . fromStreamN === id" testFromStreamNUnfold
            prop "toStream . fromStreamN === id" testFromStreamNToStream
#ifndef TEST_SMALL_ARRAY
            prop "length . fromStream === n" testLengthFromStream
            prop "toStream . fromStream === id" testFromStreamToStream
            prop "read . genFold === id" testFoldUnfold
#endif
#ifdef TEST_ARRAY
            prop "arraysOf concats to original" testArraysOf
#endif
#ifdef TEST_ARRAY
        describe "Fold" $ do
            prop "lastN" $ testLastN
#endif
