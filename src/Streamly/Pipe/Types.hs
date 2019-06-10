{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE CPP                       #-}
{-# LANGUAGE ExistentialQuantification #-}

#include "inline.hs"

-- |
-- Module      : Streamly.Pipe.Types
-- Copyright   : (c) 2019 Composewell Technologies
-- License     : BSD3
-- Maintainer  : harendra.kumar@gmail.com
-- Stability   : experimental
-- Portability : GHC

module Streamly.Pipe.Types
    ( Step (..)
    , Pipe (..)
    , PipeState (..)
    , map
    {-
    , zipWith
    , tee
    -}
    , compose
    )
where

import Control.Arrow (Arrow(..))
import Data.Maybe (isJust)
import Data.Semigroup (Semigroup(..))
import Prelude hiding (zipWith, map, unzip, null)
import Streamly.Strict (Tuple'(..))

import qualified Prelude
import qualified Control.Category as Cat

------------------------------------------------------------------------------
-- Notes
------------------------------------------------------------------------------

-- A scan is a much simpler version of pipes. A scan always produces an output
-- on an input whereas a pipe does not necessarily produce an output on an
-- input, it might consume multiple inputs before producing an output. That way
-- it can implement filtering. Similarly, it can produce more than one output
-- on an single input.
--
-- Therefore when two pipes are composed in parallel formation, one may run
-- slower or faster than the other. If all of them are being fed from the same
-- source, we may have to buffer the input to match the speeds. In case of
-- scans we do not have that problem.
--
-- We can upgrade a stream or a fold into a pipe. However, streams are more
-- efficient for generation and folds are more efficient for consumption.
--
-- For pure transformation we can have a 'Scan' type. A Scan would be more
-- efficient in zipping whereas pipes are useful for merging and zipping where
-- we know buffering can occur. A Scan type can be upgraded to a pipe.
--
------------------------------------------------------------------------------
-- Pipes
------------------------------------------------------------------------------

-- XXX A pipe may be closed for inputs but might still be producing outputs or
-- it may be closed for outputs but might still be accepting inputs. Currently
-- if a pipe is closed for inputs and we call consume it may return a Continue
-- state with the state changed to Produce. Do we need two separate closing
-- status, one for input and one for output?
--
-- The current model assumes that a pipe is either consuming or producing.
-- However, in general a pipe may consume or produce at the same time. So we
-- may need two different status checks i.e. isConsume, and isProduce. All
-- combinations of consume and produce should be possible. isConsume/isProduce
-- can return Ready, Blocked or Closed. We can perhaps learn more from TCP
-- sockets.
--
-- | The result yielded by running a single consume or produce step of the
-- pipe.
data Step s a =
      Yield a s    -- Yield value 'a' with the next state 's'
    | Continue s   -- Yields no value, the next state is 's'
    | Blocked      -- The pipe is blocked on input or output
    | Closed       -- The pipe is closed for input or output

instance Functor (Step s) where
    fmap f step =
        case step of
            Yield x s -> Yield (f x) s
            Continue s -> Continue s
            Blocked -> Blocked
            Closed -> Closed

-- | A 'Pipe' represents a stateful transformation over an input stream of
-- values of type @a@ to outputs of type @b@ in 'Monad' @m@. The 'Pipe'
-- consists of an initial state 's', a consume function, produce function and a
-- finalize function to indicate that we no longer want to feed any more input
-- to the pipe. The consume function can return 'Blocked' if it cannot accept
-- any more input until the buffered output is removed using the produce
-- function. Similalrly the produce funciton may return 'Blocked' if it cannot
-- produce anything unless more input is fed via the consume function.
--
-- If the pipe is called in consume mode and it returns "Blocked" then it must
-- not consume the value. If it consumes the value it must return "Continue"
-- instead of "Blocked". In other words, when Blocked is returned state must
-- not change, that's why Blocked does not return the next state while Continue
-- returns next state.
--
-- Blocked is returned only when consume is called in produce state or produce
-- is called in consume state. It MUST not return "Blocked" if consume is
-- called in consume state or produce is called in produce state.
--
-- In a multithreaded implementation the consume and produce ends of the pipe
-- may run indepedently in spearate threads. In that case, "Blocked" can be
-- used to indicate that the other thread needs to run and unblock us before we
-- can proceed further. Instead of returning "Blocked" the implementation may
-- choose to block the thread and the consumer can wake it up when a value has
-- been removed. This is quite similar to the implementation of an SVar.

data Pipe m a b =
    forall s. Pipe s          -- initial
    (s -> a -> m (Step s b))  -- consume
    (s -> m (Step s b))       -- produce
    (s -> Bool)               -- isConsume?
    (s -> s)                  -- finalize

-- An explicit either type for better readability of the code
data PipeState a b = Consume !a | Produce !b

-- | Maps a function on the output of the pipe.
instance Monad m => Functor (Pipe m a) where
    {-# INLINE_NORMAL fmap #-}
    fmap f (Pipe initial consume produce isConsume finalize) =
        Pipe initial consume' produce' isConsume finalize
        where
        {-# INLINE_LATE consume' #-}
        consume' st a = consume st a >>= return . fmap f
        {-# INLINE_LATE produce' #-}
        produce' st   = produce st   >>= return . fmap f

-- | Lift a pure function to a 'Pipe'.
--
-- @since 0.7.0
{-# INLINE map #-}
map :: Monad m => (a -> b) -> Pipe m a b
map f = Pipe () consume produce (const True) id
    where
    consume _ a = return $ Yield (f a) ()
    produce _ = return Blocked

{-
-- XXX move this to a separate module
data Deque a = Deque [a] [a]

{-# INLINE null #-}
null :: Deque a -> Bool
null (Deque [] []) = True
null _ = False

{-# INLINE snoc #-}
snoc :: a -> Deque a -> Deque a
snoc a (Deque snocList consList) = Deque (a : snocList) consList

{-# INLINE uncons #-}
uncons :: Deque a -> Maybe (a, Deque a)
uncons (Deque snocList consList) =
  case consList of
    h : t -> Just (h, Deque snocList t)
    _ ->
      case Prelude.reverse snocList of
        h : t -> Just (h, Deque [] t)
        _ -> Nothing

-- | The composed pipe distributes the input to both the constituent pipes and
-- zips the output of the two using a supplied zipping function.
--
-- @since 0.7.0
{-# INLINE_NORMAL zipWith #-}
zipWith :: Monad m => (a -> b -> c) -> Pipe m i a -> Pipe m i b -> Pipe m i c
zipWith f (Pipe stateL consumeL produceL finalizeL)
          (Pipe stateR consumeR produceR finalizeR) =
                    Pipe state consume produce finalize
        where

        -- Left state means we need to consume input from the source. A Right
        -- state means we either have buffered input or we are in generation
        -- mode so we do not need input from source in either case.
        --
        state = Tuple' (Consume stateL, Nothing, Nothing)
                       (Consume stateR, Nothing, Nothing)

        -- XXX for heavy buffering we need to have the (ring) buffer in pinned
        -- memory using the Storable instance.
        {-# INLINE_LATE consume #-}
        consume (Tuple' (sL, resL, lq) (sR, resR, rq)) a = do
            s1 <- drive sL resL lq consumeL produceL a
            s2 <- drive sR resR rq consumeR produceR a
            case (s1,s2) of
                (Just s1', Just s2') -> yieldOutput s1' s2'
                _ -> return Stop

            where

            {-# INLINE drive #-}
            drive st res queue fConsume fProduce val = do
                case res of
                    Nothing -> goConsume st queue val fConsume fProduce
                    Just x -> return $
                        case queue of
                            Nothing -> Just (st, Just x, Just $ (Deque [val] []))
                            Just q  -> Just (st, Just x, Just $ snoc val q)

            {-# INLINE goConsume #-}
            goConsume stt queue val fConsume stp2 = do
                case stt of
                    Consume st -> do
                        case queue of
                            Nothing -> do
                                r <- fConsume st val
                                return $ case r of
                                    Yield x s  -> Just (s, Just x, Nothing)
                                    Continue s -> Just (s, Nothing, Nothing)
                                    Stop -> Nothing
                            Just queue' ->
                                case uncons queue' of
                                    Just (v, q) -> do
                                        r <- fConsume st v
                                        let q' = snoc val q
                                        return $ case r of
                                            Yield x s  -> Just (s, Just x, Just q')
                                            Continue s -> Just (s, Nothing, Just q')
                                            Stop -> Nothing
                                    Nothing -> undefined -- never occurs
                    Produce st -> do
                        r <- stp2 st
                        return $ case r of
                            Yield x s  -> Just (s, Just x, queue)
                            Continue s -> Just (s, Nothing, queue)
                            Stop -> Nothing

        {-# INLINE_LATE produce #-}
        produce (Tuple' (sL, resL, lq) (sR, resR, rq)) = do
            s1 <- drive sL resL lq consumeL produceL
            s2 <- drive sR resR rq consumeR produceR
            case (s1,s2) of
                (Just s1', Just s2') -> yieldOutput s1' s2'
                _ -> return Stop

            where

            {-# INLINE drive #-}
            drive stt res q fConsume fProduce = do
                case res of
                    Nothing -> goProduce stt q fConsume fProduce
                    Just x -> return $ Just (stt, Just x, q)

            {-# INLINE goProduce #-}
            goProduce stt queue fConsume fProduce = do
                case stt of
                    Consume st -> do
                        case queue of
                            -- See yieldOutput. We enter produce mode only when
                            -- each pipe is either in Produce state or the
                            -- queue is non-empty. So this case cannot occur.
                            Nothing -> undefined
                            Just queue' ->
                                case uncons queue' of
                                    Just (v, q) -> do
                                        r <- fConsume st v
                                        -- We provide a guarantee that if the
                                        -- queue is "Just" it is always
                                        -- non-empty. yieldOutput and goConsume
                                        -- depend on it.
                                        let q' = if null q
                                                 then Nothing
                                                 else Just q
                                        return $ case r of
                                            Yield x s  -> Just (s, Just x, q')
                                            Continue s -> Just (s, Nothing, q')
                                            Stop -> Nothing
                                    Nothing -> return $ Just (stt, Nothing, Nothing)
                    Produce st -> do
                        r <- fProduce st
                        return $ case r of
                            Yield x s  -> Just (s, Just x, queue)
                            Continue s -> Just (s, Nothing, queue)
                            Stop -> Nothing

        {-# INLINE yieldOutput #-}
        yieldOutput s1@(sL', resL', lq') s2@(sR', resR', rq') = return $
            -- switch to produce mode if we do not need input
            if (isProduce sL' || isJust lq') && (isProduce sR' || isJust rq')
            then
                case (resL', resR') of
                    (Just xL, Just xR) ->
                        Yield (f xL xR) (Produce (Tuple' (clear s1) (clear s2)))
                    _ -> Continue (Produce (Tuple' s1 s2))
            else
                case (resL', resR') of
                    (Just xL, Just xR) ->
                        Yield (f xL xR) (Consume (Tuple' (clear s1) (clear s2)))
                    _ -> Continue (Consume (Tuple' s1 s2))
            where clear (s, _, q) = (s, Nothing, q)

instance Monad m => Applicative (Pipe m a) where
    {-# INLINE pure #-}
    pure b = Pipe (\_ _ -> pure $ Yield b (Consume ())) undefined ()

    (<*>) = zipWith id

-- XXX It is also possible to compose in a way so as to append the pipes after
-- distributing the input to them, but that will require full buffering of the
-- input.

data TeeConsume sL sR =
      TCBoth !sL !sR
    | TCLeft !sL
    | TCRight !sR

data TeeProduce a s sLc sLp sRp sRc =
      TPLeft a s !sRc
    | TPRight !sLc !sRp
    | TPSwitchRightOnly a !sRc
    | TPRightOnly !sRp
    | TPLeftOnly !sLp

-- | The composed pipe distributes the input to both the constituent pipes and
-- merges the outputs of the two.
--
-- @since 0.7.0
{-# INLINE_NORMAL tee #-}
tee :: Monad m => Pipe m a b -> Pipe m a b -> Pipe m a b
tee (Pipe consumeL produceL stateL) (Pipe consumeR produceR stateR) =
        Pipe consume produce state
    where

    state = TCBoth stateL stateR

    -- At the start both pipes are in Consume mode.
    --
    -- We start with the left pipe.  If either of the pipes goes in produce
    -- mode then the tee goes to produce mode. After one pipe finishes
    -- producing all outputs for a given input only then we move on to the next
    -- pipe.
    consume (TCBoth sL sR) a = do
        r <- consumeL sL a
        return $ case r of
            Yield x s  -> Yield x  (Produce (TPLeft a s sR))
            Continue s -> Continue (Produce (TPLeft a s sR))
            Stop       -> Continue (Produce (TPSwitchRightOnly a sR))

    -- Right pipe has stopped, only the left pipe is running
    consume (TCLeft sL) a = do
        r <- consumeL sL a
        return $ case r of
            Yield x (Consume s)  -> Yield x  (Consume (TCLeft s))
            Yield x (Produce s)  -> Yield x  (Produce (TPLeftOnly s))
            Continue (Consume s) -> Continue (Consume (TCLeft s))
            Continue (Produce s) -> Continue (Produce (TPLeftOnly s))
            Stop                 -> Stop

    consume (TCRight sR) a = do
        r <- consumeR sR a
        return $ case r of
            Yield x (Consume s)  -> Yield x  (Consume (TCRight s))
            Yield x (Produce s)  -> Yield x  (Produce (TPRightOnly s))
            Continue (Consume s) -> Continue (Consume (TCRight s))
            Continue (Produce s) -> Continue (Produce (TPRightOnly s))
            Stop                 -> Stop

    -- Left pipe went to produce mode and right pipe is waiting for its turn.
    produce (TPLeft a (Produce sL) sR) = do
        r <- produceL sL
        return $ case r of
            Yield x s  -> Yield x  (Produce (TPLeft a s sR))
            Continue s -> Continue (Produce (TPLeft a s sR))
            Stop       -> Continue (Produce (TPSwitchRightOnly a sR))

    -- Left pipe is done consuming an input, both pipes are again in consume
    -- mode and its Right pipe's turn to consume the buffered input now.
    produce (TPLeft a (Consume sL) sR) = do
        r <- consumeR sR a
        return $ case r of
            Yield x  (Consume s) -> Yield x  (Consume (TCBoth  sL s))
            Yield x  (Produce s) -> Yield x  (Produce (TPRight sL s))
            Continue (Consume s) -> Continue (Consume (TCBoth  sL s))
            Continue (Produce s) -> Continue (Produce (TPRight sL s))
            Stop                 -> Continue (Consume (TCLeft  sL))

    -- Left pipe has stopped, we have to continue with just the right pipe.
    produce (TPSwitchRightOnly a sR) = do
        r <- consumeR sR a
        return $ case r of
            Yield x  (Consume s) -> Yield x  (Consume (TCRight s))
            Yield x  (Produce s) -> Yield x  (Produce (TPRightOnly s))
            Continue (Consume s) -> Continue (Consume (TCRight s))
            Continue (Produce s) -> Continue (Produce (TPRightOnly s))
            Stop                 -> Stop

    -- Left pipe has consumed and produced, right pipe has consumed and is now
    -- in produce mode.
    produce (TPRight sL sR) = do
        r <- produceR sR
        return $ case r of
            Yield x  (Consume s) -> Yield x  (Consume (TCBoth sL s))
            Yield x  (Produce s) -> Yield x  (Produce (TPRight sL s))
            Continue (Consume s) -> Continue (Consume (TCBoth sL s))
            Continue (Produce s) -> Continue (Produce (TPRight sL s))
            Stop                 -> Continue (Consume (TCLeft sL))

    -- Left pipe has stopped and right pipe is in produce mode.
    produce (TPRightOnly sR) = do
        r <- produceR sR
        return $ case r of
            Yield x  (Consume s) -> Yield x  (Consume (TCRight s))
            Yield x  (Produce s) -> Yield x  (Produce (TPRightOnly s))
            Continue (Consume s) -> Continue (Consume (TCRight s))
            Continue (Produce s) -> Continue (Produce (TPRightOnly s))
            Stop                 -> Stop

    -- Right pipe has stopped and left pipe is in produce mode.
    produce (TPLeftOnly sL) = do
        r <- produceL sL
        return $ case r of
            Yield x  (Consume s) -> Yield x  (Consume (TCLeft s))
            Yield x  (Produce s) -> Yield x  (Produce (TPLeftOnly s))
            Continue (Consume s) -> Continue (Consume (TCLeft s))
            Continue (Produce s) -> Continue (Produce (TPLeftOnly s))
            Stop                 -> Stop

instance Monad m => Semigroup (Pipe m a b) where
    {-# INLINE (<>) #-}
    (<>) = tee

-}
{-
-- | A hollow or identity 'Pipe' passes through everything that comes in.
--
-- @since 0.7.0
{-# INLINE id #-}
id :: Monad m => Pipe m a a
id = map Prelude.id
-}

data ComposeState l r =
      ConsumeBoth  l r
    | ProduceLeft  l r
    | ProduceRight l r
    | ProduceBoth  l r
    | ProduceLeftOnly  l
    | ProduceNone

-- | Compose two pipes such that the output of the second pipe is attached to
-- the input of the first pipe.
--
-- @since 0.7.0
{-# INLINE_NORMAL compose #-}
compose :: Monad m => Pipe m b c -> Pipe m a b -> Pipe m a c
compose (Pipe stateL consumeL produceL isConsumeL finalizeL)
        (Pipe stateR consumeR produceR isConsumeR finalizeR) =
    Pipe state consume produce isConsume finalize

    where

    {-# INLINE_LATE nextState #-}
    nextState l r =
        let mkState =
                case (isConsumeL l, isConsumeR r) of
                    (True, True)   -> ConsumeBoth
                    (True, False)  -> ProduceRight
                    (False, True)  -> ProduceLeft
                    (False, False) -> ProduceBoth
        in mkState l r

    state = nextState stateL stateR

    {-# INLINE_LATE isConsume #-}
    isConsume (ConsumeBoth _ _) = True
    isConsume _ = False

    finalize (ConsumeBoth l r) = nextState l (finalizeR r)
    finalize (ProduceRight l r) = nextState l (finalizeR r)
    finalize (ProduceLeft l r) = nextState l (finalizeR r)
    finalize (ProduceBoth l r) = nextState l (finalizeR r)
    finalize x = x

    {-# INLINE_LATE consume #-}
    -- Both pipes are in Consume state.
    consume (ConsumeBoth sL sR) a = do
        res <- consumeR sR a
        case res of
            Yield xr sR' -> do
                l <- consumeL sL xr
                return $ case l of
                    Yield xl sL' -> Yield xl (nextState sL' sR')
                    Continue sL' -> Continue (nextState sL' sR')
                    -- Cannot return Blocked for consume in Consume state
                    Blocked      -> undefined
                    Closed       -> Closed
            Continue sR' ->
                let nextr l r =
                        if isConsumeR r
                        then ConsumeBoth l r
                        else ProduceRight l r
                 in return $ Continue (nextr sL sR')
            -- Cannot return Blocked for consume in Consume state
            Blocked      -> undefined
            Closed       ->
                let sL' = finalizeL sL
                in  if isConsumeL sL'
                    then return $ Closed
                    else return $ Continue (ProduceLeftOnly sL')
    consume s _ =
        if not (isConsume s)
        then return Blocked
        -- XXX this could be due to a bug in the implementation of the pipes
        -- being composed.
        else error "Bug: Streamly.Pipe.Types.compose: consume state not handled"

    {-# INLINE_LATE produce #-}
    -- The right stream is in produce mode and left is in consume mode
    produce (ProduceRight sL sR) = do
        res <- produceR sR
        case res of
            Yield xr sR' -> do
                l <- consumeL sL xr
                return $ case l of
                    Yield xl sL' -> Yield xl (nextState sL' sR')
                    Continue sL' -> Continue (nextState sL' sR')
                    Blocked      -> undefined
                    Closed       -> Closed
            Continue sR' ->
                let nextr l r =
                        if isConsumeR r
                        then ConsumeBoth l r
                        else ProduceRight l r
                in return $ Continue (nextr sL sR')
            Blocked      -> undefined
            Closed       -> return $ Closed

    -- Left stream is in produce state, the right stream is in consume state
    produce (ProduceLeft sL sR) = do
        let nextl l r =
                if isConsumeL l
                then ConsumeBoth l r
                else ProduceLeft l r
        res <- produceL sL
        return $ case res of
            Yield xl sL' -> Yield xl (nextl sL' sR)
            Continue sL' -> Continue (nextl sL' sR)
            Blocked      -> undefined
            Closed       -> Closed

    -- Both streams are in produce mode
    produce (ProduceBoth sL sR) = do
        let nextl l r =
                if isConsumeL l
                then ProduceRight l r
                else ProduceBoth l r
        r <- produceL sL
        return $ case r of
            Yield xl sL' -> Yield xl (nextl sL' sR)
            Continue sL' -> Continue (nextl sL' sR)
            Blocked      -> undefined
            Closed       -> Closed

    -- Left stream is in produce state, the right stream is done
    produce (ProduceLeftOnly sL) = do
        let nextl l =
                if isConsumeL l
                then ProduceNone
                else ProduceLeftOnly l
        res <- produceL sL
        return $ case res of
            Yield xl sL' -> Yield xl (nextl sL')
            Continue sL' -> Continue (nextl sL')
            Blocked      -> undefined
            Closed       -> Closed

    produce ProduceNone = return Closed

    produce s =
        if isConsume s
        then return Blocked
        -- XXX this could be due to a bug in the implementation of the pipes
        -- being composed.
        else error "Bug: Streamly.Pipe.Types.compose: produce state not handled"

instance Monad m => Cat.Category (Pipe m) where
    {-# INLINE id #-}
    id = map Prelude.id

    {-# INLINE (.) #-}
    (.) = compose

{-
unzip :: Pipe m a x -> Pipe m b y -> Pipe m (a, b) (x, y)
unzip = undefined

instance Monad m => Arrow (Pipe m) where
    {-# INLINE arr #-}
    arr = map

    {-# INLINE (***) #-}
    (***) = unzip

    {-# INLINE (&&&) #-}
    (&&&) = zipWith (,)
    -}