{-# OPTIONS_GHC -Wno-name-shadowing #-}

-- | The client
module Calamity.Client.Client
    ( react
    , runBotIO
    , runBotIO'
    , stopBot
    , sendPresence
    , events
    , fire
    , waitUntil
    , waitUntilM
    , CalamityEvent(Dispatch, ShutDown)
    , customEvt ) where

import           Calamity.Cache.Eff
import           Calamity.Client.ShardManager
import           Calamity.Client.Types
import           Calamity.Gateway.DispatchEvents
import           Calamity.Gateway.Types
import           Calamity.Gateway.Intents
import           Calamity.HTTP.Internal.Ratelimit
import           Calamity.Internal.ConstructorName
import           Calamity.Internal.RunIntoIO
import qualified Calamity.Internal.SnowflakeMap    as SM
import           Calamity.Internal.Updateable
import           Calamity.Internal.Utils
import           Calamity.Metrics.Eff
import           Calamity.Types.Model.Channel
import           Calamity.Types.Model.Guild
import           Calamity.Types.Model.Presence     ( Presence(..) )
import           Calamity.Types.Model.User
import           Calamity.Types.Snowflake
import           Calamity.Types.Token

import           Control.Concurrent.Chan.Unagi
import           Control.Concurrent.MVar
import           Control.Concurrent.STM
import           Control.Exception                 ( SomeException )
import           Control.Lens                      hiding ( (<.>) )
import           Control.Monad

import           Data.Default.Class
import           Data.Dynamic
import           Data.Foldable
import           Data.Generics.Product.Subtype
import           Data.IORef
import           Data.Maybe
import           Data.Proxy
import qualified Data.Text                         as S
import           Data.Time.Clock.POSIX
import           Data.Traversable
import           Data.Typeable

import qualified DiPolysemy                        as Di

import           Network.Wreq.Session            ( Session, newAPISession )

import           Fmt

import qualified Polysemy                          as P
import qualified Polysemy.Async                    as P
import qualified Polysemy.AtomicState              as P
import qualified Polysemy.Error                    as P
import qualified Polysemy.Fail                     as P
import qualified Polysemy.Reader                   as P

import           TextShow                          ( TextShow(showt) )

timeA :: P.Member (P.Embed IO) r => P.Sem r a -> P.Sem r (Double, a)
timeA m = do
  start <- P.embed getPOSIXTime
  res <- m
  end <- P.embed getPOSIXTime
  let duration = fromRational . toRational $ end - start
  pure (duration, res)


newClient :: Token -> Session -> IO Client
newClient token session = do
  shards'        <- newTVarIO []
  numShards'     <- newEmptyMVar
  rlState'       <- newRateLimitState
  (inc, outc)    <- newChan
  ehidCounter    <- newIORef 0

  pure $ Client shards'
                numShards'
                token
                rlState'
                inc
                outc
                ehidCounter
                session

-- | Create a bot, run your setup action, and then loop until the bot closes.
runBotIO :: forall r a.
         (P.Members '[P.Embed IO, P.Final IO, CacheEff, MetricEff] r, Typeable (SetupEff r))
         => Token
         -> P.Sem (SetupEff r) a
         -> P.Sem r (Maybe StartupError)
runBotIO token setup = runBotIO' token Nothing Nothing Nothing setup

-- | Create a bot, run your setup action, and then loop until the bot closes.
--
-- This version allows you to specify the session and initial status and intents.
runBotIO' :: forall r a.
          (P.Members '[P.Embed IO, P.Final IO, CacheEff, MetricEff] r, Typeable (SetupEff r))
          => Token
          -> Maybe Session
          -> Maybe StatusUpdateData
          -> Maybe Intents
          -> P.Sem (SetupEff r) a
          -> P.Sem r (Maybe StartupError)
runBotIO' token session status intents setup = do
  session' <- maybe (P.embed newAPISession) pure session
  client <- P.embed $ newClient token session'
  handlers <- P.embed $ newTVarIO def
  P.asyncToIOFinal . P.runAtomicStateTVar handlers . P.runReader client . Di.runDiToStderrIOFinal . Di.push "calamity" $ do
    void $ Di.push "calamity-setup" setup
    r <- shardBot status intents
    case r of
      Left e  -> pure (Just e)
      Right _ -> do
        Di.push "calamity-loop" clientLoop
        Di.push "calamity-stop" finishUp
        pure Nothing

-- | Register an event handler, returning an action that removes the event handler from the bot.
--
-- Refer to 'EventType' for what events you can register, and 'EHType' for the
-- parameters the event handlers they receive.
--
-- You'll probably want @TypeApplications@ and need @DataKinds@ enabled to
-- specify the type of @s@.
--
-- ==== Examples
--
-- Reacting to every message:
--
-- @
-- 'react' @\''MessageCreateEvt' '$' \msg -> 'print' '$' "Got message: " '<>' 'show' msg
-- @
--
-- Reacting to a custom event:
--
-- @
-- 'react' @(\''CustomEvt' "my-event" ('Data.Text.Text', 'Message')) $ \(s, m) ->
--    'void' $ 'Calamity.Types.Tellable.tell' @'Data.Text.Text' m ("Somebody told me to tell you about: " '<>' s)
-- @
--
-- ==== Notes
--
-- This function is pretty bad for giving nasty type errors,
-- since if something doesn't match then 'EHType' might not get substituted,
-- which will result in errors about parameter counts mismatching.
react :: forall (s :: EventType) r.
      (BotC r, ReactConstraints s)
      => (EHType s -> (P.Sem r) ())
      -> P.Sem r (P.Sem r ())
react handler = do
  handler' <- bindSemToIO handler
  ehidC <- P.asks (^. #ehidCounter)
  id' <- P.embed $ atomicModifyIORef ehidC (\i -> (i + 1, i))
  let handlers = makeEventHandlers (Proxy @s) id' (const () <.> handler')
  P.atomicModify (handlers <>)
  pure $ removeHandler @s id'

removeHandler :: forall (s :: EventType) r. (BotC r, RemoveEventHandler s) => Integer -> P.Sem r ()
removeHandler id' = P.atomicModify (removeEventHandler (Proxy @s) id')

-- | Fire an event that the bot will then handle.
--
-- ==== Examples
--
-- Firing an event named \"my-event\":
--
-- @
-- 'fire' '$' 'customEvt' @"my-event" ("aha" :: 'Data.Text.Text', msg)
-- @
fire :: BotC r => CalamityEvent -> P.Sem r ()
fire e = do
  inc <- P.asks (^. #eventsIn)
  P.embed $ writeChan inc e

-- | Build a Custom CalamityEvent
--
-- You'll probably want @TypeApplications@ to specify the type of @s@.
--
-- The types of @s@ and @a@ must match up with the event handler you want to
-- receive it.
--
-- ==== Examples
--
-- Building an event named \"my-event\":
--
-- @
-- 'customEvt' @"my-event" ("aha" :: 'Data.Text.Text', msg)
-- @
customEvt :: forall s a. (Typeable s, Typeable a) => a -> CalamityEvent
customEvt x = Custom (typeRep $ Proxy @s) (toDyn x)

-- | Get a copy of the event stream.
events :: BotC r => P.Sem r (OutChan CalamityEvent)
events = do
  inc <- P.asks (^. #eventsIn)
  P.embed $ dupChan inc

-- | Wait until an event satisfying a condition happens, then returns it's
-- parameters.
--
-- The check function for this command is pure unlike 'waitUntilM'
--
-- This is what it would look like with @s ~ \''MessageCreateEvt'@:
--
-- @
-- 'waitUntil' :: ('Message' -> 'Bool') -> 'P.Sem' r 'Message'
-- @
--
-- And for @s ~ \''MessageUpdateEvt'@:
--
-- @
-- 'waitUntil' :: (('Message', 'Message') -> 'Bool') -> 'P.Sem' r ('Message', 'Message')
-- @
--
-- ==== Examples
--
-- Waiting for a message containing the text \"hi\":
--
-- @
-- f = do msg \<\- 'waitUntil' @\''MessageCreateEvt' (\m -> 'Data.Text.Lazy.isInfixOf' "hi" $ m ^. #content)
--        print $ msg ^. #content
-- @
waitUntil
  :: forall (s :: EventType) r.
  ( BotC r, ReactConstraints s)
  => (EHType s -> Bool)
  -> P.Sem r (EHType s)
waitUntil f = do
  result <- P.embed newEmptyMVar
  remove <- react @s (checker result)
  res <- P.embed $ takeMVar result
  remove
  pure res
  where
    checker :: MVar (EHType s) -> EHType s -> P.Sem r ()
    checker result args = do
      when (f args) $ do
        P.embed $ putMVar result args

-- | Wait until an event satisfying a condition happens, then returns it's
-- parameters
--
-- This is what it would look like with @s ~ \''MessageCreateEvt'@:
--
-- @
-- 'waitUntilM' :: ('Message' -> 'P.Sem' r 'Bool') -> 'P.Sem' r 'Message'
-- @
--
-- And for @s ~ \''MessageUpdateEvt'@:
--
-- @
-- 'waitUntilM' :: (('Message', 'Message') -> 'P.Sem' r 'Bool') -> 'P.Sem' r ('Message', 'Message')
-- @
--
-- ==== Examples
--
-- Waiting for a message containing the text \"hi\":
--
-- @
-- f = do msg \<\- 'waitUntilM' @\''MessageCreateEvt' (\m -> ('debug' $ "got message: " <> 'showt' msg) >> ('pure' $ 'Data.Text.Lazy.isInfixOf' "hi" $ m ^. #content))
--        print $ msg ^. #content
-- @
waitUntilM
  :: forall (s :: EventType) r.
  ( BotC r, ReactConstraints s)
  => (EHType s -> P.Sem r Bool)
  -> P.Sem r (EHType s)
waitUntilM f = do
  result <- P.embed newEmptyMVar
  remove <- react @s (checker result)
  res <- P.embed $ takeMVar result
  remove
  pure res
  where
    checker :: MVar (EHType s) -> EHType s -> P.Sem r ()
    checker result args = do
      res <- f args
      when res $ do
        P.embed $ putMVar result args

-- | Set the bot's presence on all shards.
sendPresence :: BotC r => StatusUpdateData -> P.Sem r ()
sendPresence s = do
  shards <- P.asks (^. #shards) >>= P.embed . readTVarIO
  for_ shards $ \(inc, _) ->
    P.embed $ writeChan inc (SendPresence s)

-- | Initiate shutting down the bot.
stopBot :: BotC r => P.Sem r ()
stopBot = do
  debug "stopping bot"
  inc <- P.asks (^. #eventsIn)
  P.embed $ writeChan inc ShutDown

finishUp :: BotC r => P.Sem r ()
finishUp = do
  debug "finishing up"
  shards <- P.asks (^. #shards) >>= P.embed . readTVarIO
  for_ shards $ \(inc, _) ->
    P.embed $ writeChan inc ShutDownShard
  for_ shards $ \(_, shardThread) -> P.await shardThread
  debug "bot has stopped"

-- | main loop of the client, handles fetching the next event, processing the
-- event and invoking it's handler functions
clientLoop :: BotC r => P.Sem r ()
clientLoop = do
  outc <- P.asks (^. #eventsOut)
  void . P.runError . forever $ do
    evt' <- P.embed $ readChan outc
    case evt' of
      -- NOTE: these raise's are needed to raise into the Error effect
      Dispatch sid evt -> P.raise $ handleEvent sid evt
      Custom s d   -> P.raise $ handleCustomEvent s d
      ShutDown     -> P.throw ()
  debug "leaving client loop"

handleCustomEvent :: forall r. BotC r => TypeRep -> Dynamic -> P.Sem r ()
handleCustomEvent s d = do
  debug $ "handling a custom event, s: " +|| s ||+ ", d: " +|| d ||+ ""
  eventHandlers <- P.atomicGet

  let handlers = getCustomEventHandlers s (dynTypeRep d) eventHandlers

  for_ handlers (\h -> P.async . P.embed $ h d)

catchAllLogging :: BotC r => P.Sem r () -> P.Sem r ()
catchAllLogging m = do
  r <- P.errorToIOFinal . P.fromExceptionSem @SomeException $ P.raise m
  case r of
    Right _ -> pure ()
    Left e -> debug $ "got exception: " +|| e ||+ ""

handleEvent :: BotC r => Int -> DispatchData -> P.Sem r ()
handleEvent shardID data' = do
  debug "handling an event"
  eventHandlers <- P.atomicGet
  actions <- P.runFail $ do
    evtCounter <- registerCounter "events_received" [("type", S.pack $ ctorName data'), ("shard", showt shardID)]
    void $ addCounter 1 evtCounter
    cacheUpdateHisto <- registerHistogram "cache_update" mempty [10, 20..100]
    (time, res) <- timeA $ Di.reset $ handleEvent' eventHandlers data'
    void $ observeHistogram time cacheUpdateHisto
    pure res

  eventHandleHisto <- registerHistogram "event_handle" mempty [10, 20..100]

  case actions of
    Right actions -> for_ actions $ \action -> P.async $ do
      (time, _) <- timeA . catchAllLogging $ P.embed action
      void $ observeHistogram time eventHandleHisto
    Left err      -> debug $ "Failed handling actions for event: " +| err |+ ""

handleEvent' :: BotC r
              => EventHandlers
              -> DispatchData
              -> P.Sem (P.Fail ': r) [IO ()]
handleEvent' eh evt@(Ready rd@ReadyData {}) = do
  updateCache evt
  pure $ map ($ rd) (getEventHandlers @'ReadyEvt eh)

handleEvent' _ Resumed = pure []

handleEvent' eh evt@(ChannelCreate (DMChannel' chan)) = do
  updateCache evt
  Just newChan <- DMChannel' <<$>> getDM (getID chan)
  pure $ map ($ newChan) (getEventHandlers @'ChannelCreateEvt eh)

handleEvent' eh evt@(ChannelCreate (GuildChannel' chan)) = do
  updateCache evt
  Just guild <- getGuild (getID chan)
  Just newChan <- pure $ GuildChannel' <$> guild ^. #channels . at (getID chan)
  pure $ map ($ newChan) (getEventHandlers @'ChannelCreateEvt eh)

handleEvent' eh evt@(ChannelUpdate (DMChannel' chan)) = do
  Just oldChan <- DMChannel' <<$>> getDM (getID chan)
  updateCache evt
  Just newChan <- DMChannel' <<$>> getDM (getID chan)
  pure $ map ($ (oldChan, newChan)) (getEventHandlers @'ChannelUpdateEvt eh)

handleEvent' eh evt@(ChannelUpdate (GuildChannel' chan)) = do
  Just oldGuild <- getGuild (getID chan)
  Just oldChan <- pure $ GuildChannel' <$> oldGuild ^. #channels . at (getID chan)
  updateCache evt
  Just newGuild <- getGuild (getID chan)
  Just newChan <- pure $ GuildChannel' <$> newGuild ^. #channels . at (getID chan)
  pure $ map ($ (oldChan, newChan)) (getEventHandlers @'ChannelUpdateEvt eh)

handleEvent' eh evt@(ChannelDelete (GuildChannel' chan)) = do
  Just oldGuild <- getGuild (getID chan)
  Just oldChan <- pure $ GuildChannel' <$> oldGuild ^. #channels . at (getID chan)
  updateCache evt
  pure $ map ($ oldChan) (getEventHandlers @'ChannelDeleteEvt eh)

handleEvent' eh evt@(ChannelDelete (DMChannel' chan)) = do
  Just oldChan <- DMChannel' <<$>> getDM (getID chan)
  updateCache evt
  pure $ map ($ oldChan) (getEventHandlers @'ChannelDeleteEvt eh)

-- handleEvent' eh evt@(ChannelPinsUpdate ChannelPinsUpdateData { channelID, lastPinTimestamp }) = do
--   chan <- (GuildChannel' <$> os ^? #channels . at (coerceSnowflake channelID) . _Just)
--     <|> (DMChannel' <$> os ^? #dms . at (coerceSnowflake channelID) . _Just)
--   pure $ map (\f -> f chan lastPinTimestamp) (getEventHandlers @"channelpinsupdate" eh)

handleEvent' eh evt@(GuildCreate guild) = do
  isNew <- not <$> isUnavailableGuild (getID guild)
  updateCache evt
  Just guild <- getGuild (getID guild)
  pure $ map ($ (guild, (if isNew then GuildCreateNew else GuildCreateAvailable)))
    (getEventHandlers @'GuildCreateEvt eh)

handleEvent' eh evt@(GuildUpdate guild) = do
  Just oldGuild <- getGuild (getID guild)
  updateCache evt
  Just newGuild <- getGuild (getID guild)
  pure $ map ($ (oldGuild, newGuild)) (getEventHandlers @'GuildUpdateEvt eh)

-- NOTE: Guild will be deleted in the new cache if unavailable was false
handleEvent' eh evt@(GuildDelete UnavailableGuild { id, unavailable }) = do
  Just oldGuild <- getGuild id
  updateCache evt
  pure $ map ($ (oldGuild, (if unavailable then GuildDeleteUnavailable else GuildDeleteRemoved)))
    (getEventHandlers @'GuildDeleteEvt eh)

handleEvent' eh evt@(GuildBanAdd BanData { guildID, user }) = do
  Just guild <- getGuild guildID
  updateCache evt
  pure $ map ($ (guild, user)) (getEventHandlers @'GuildBanAddEvt eh)

handleEvent' eh evt@(GuildBanRemove BanData { guildID, user }) = do
  Just guild <- getGuild guildID
  updateCache evt
  pure $ map ($ (guild, user)) (getEventHandlers @'GuildBanRemoveEvt eh)

-- NOTE: we fire this event using the guild data with old emojis
handleEvent' eh evt@(GuildEmojisUpdate GuildEmojisUpdateData { guildID, emojis }) = do
  Just guild <- getGuild guildID
  updateCache evt
  pure $ map ($ (guild, emojis)) (getEventHandlers @'GuildEmojisUpdateEvt eh)

handleEvent' eh evt@(GuildIntegrationsUpdate GuildIntegrationsUpdateData { guildID }) = do
  updateCache evt
  Just guild <- getGuild guildID
  pure $ map ($ guild) (getEventHandlers @'GuildIntegrationsUpdateEvt eh)

handleEvent' eh evt@(GuildMemberAdd member) = do
  updateCache evt
  Just guild <- getGuild (getID member)
  Just member <- pure $ guild ^. #members . at (getID member)
  pure $ map ($ member) (getEventHandlers @'GuildMemberAddEvt eh)

handleEvent' eh evt@(GuildMemberRemove GuildMemberRemoveData { user, guildID }) = do
  Just guild <- getGuild guildID
  Just member <- pure $ guild ^. #members . at (getID user)
  updateCache evt
  pure $ map ($ member) (getEventHandlers @'GuildMemberRemoveEvt eh)

handleEvent' eh evt@(GuildMemberUpdate GuildMemberUpdateData { user, guildID }) = do
  Just oldGuild <- getGuild guildID
  Just oldMember <- pure $ oldGuild ^. #members . at (getID user)
  updateCache evt
  Just newGuild <- getGuild guildID
  Just newMember <- pure $ newGuild ^. #members . at (getID user)
  pure $ map ($ (oldMember, newMember)) (getEventHandlers @'GuildMemberUpdateEvt eh)

handleEvent' eh evt@(GuildMembersChunk GuildMembersChunkData { members, guildID }) = do
  updateCache evt
  Just guild <- getGuild guildID
  let members' = guild ^.. #members . foldMap (at . getID) members . _Just
  pure $ map ($ (guild, members')) (getEventHandlers @'GuildMembersChunkEvt eh)

handleEvent' eh evt@(GuildRoleCreate GuildRoleData { guildID, role }) = do
  updateCache evt
  Just guild <- getGuild guildID
  Just role' <- pure $ guild ^. #roles . at (getID role)
  pure $ map ($ (guild, role')) (getEventHandlers @'GuildRoleCreateEvt eh)

handleEvent' eh evt@(GuildRoleUpdate GuildRoleData { guildID, role }) = do
  Just oldGuild <- getGuild guildID
  Just oldRole <- pure $ oldGuild ^. #roles . at (getID role)
  updateCache evt
  Just newGuild <- getGuild guildID
  Just newRole <- pure $ newGuild ^. #roles . at (getID role)
  pure $ map ($ (newGuild, oldRole, newRole)) (getEventHandlers @'GuildRoleUpdateEvt eh)

handleEvent' eh evt@(GuildRoleDelete GuildRoleDeleteData { guildID, roleID }) = do
  Just guild <- getGuild guildID
  Just role <- pure $ guild ^. #roles . at roleID
  updateCache evt
  pure $ map ($ (guild, role)) (getEventHandlers @'GuildRoleDeleteEvt eh)

handleEvent' eh (InviteCreate d) = do
  pure $ map ($ d) (getEventHandlers @'InviteCreateEvt eh)

handleEvent' eh (InviteDelete d) = do
  pure $ map ($ d) (getEventHandlers @'InviteDeleteEvt eh)

handleEvent' eh evt@(MessageCreate msg) = do
  updateCache evt
  pure $ map ($ msg) (getEventHandlers @'MessageCreateEvt eh)

handleEvent' eh evt@(MessageUpdate msg) = do
  Just oldMsg <- getMessage (getID msg)
  updateCache evt
  Just newMsg <- getMessage (getID msg)
  pure $ map ($ (oldMsg, newMsg)) (getEventHandlers @'MessageUpdateEvt eh)

handleEvent' eh evt@(MessageDelete MessageDeleteData { id }) = do
  Just oldMsg <- getMessage id
  updateCache evt
  pure $ map ($ oldMsg) (getEventHandlers @'MessageDeleteEvt eh)

handleEvent' eh evt@(MessageDeleteBulk MessageDeleteBulkData { ids }) = do
  messages <- catMaybes <$> traverse getMessage ids
  updateCache evt
  join <$> for messages (\msg -> pure $ map ($ msg) (getEventHandlers @'MessageDeleteEvt eh))

handleEvent' eh evt@(MessageReactionAdd reaction) = do
  updateCache evt
  Just msg <- getMessage (getID reaction)
  pure $ map ($ (msg, reaction)) (getEventHandlers @'MessageReactionAddEvt eh)

handleEvent' eh evt@(MessageReactionRemove reaction) = do
  Just msg <- getMessage (getID reaction)
  updateCache evt
  pure $ map ($ (msg, reaction)) (getEventHandlers @'MessageReactionRemoveEvt eh)

handleEvent' eh evt@(MessageReactionRemoveAll MessageReactionRemoveAllData { messageID }) = do
  Just msg <- getMessage messageID
  updateCache evt
  pure $ map ($ msg) (getEventHandlers @'MessageReactionRemoveAllEvt eh)

handleEvent' eh evt@(PresenceUpdate PresenceUpdateData { userID, presence = Presence { guildID } }) = do
  Just oldGuild <- getGuild guildID
  Just oldMember <- pure $ oldGuild ^. #members . at (coerceSnowflake userID)
  updateCache evt
  Just newGuild <- getGuild guildID
  Just newMember <- pure $ newGuild ^. #members . at (coerceSnowflake userID)
  let oldUser :: User = upcast oldMember
      newUser :: User = upcast newMember
      userUpdates = if oldUser /= newUser
                    then map ($ (oldUser, newUser)) (getEventHandlers @'UserUpdateEvt eh)
                    else mempty
  pure $ userUpdates <> map ($ (oldMember, newMember)) (getEventHandlers @'GuildMemberUpdateEvt eh)

handleEvent' eh (TypingStart TypingStartData { channelID, guildID, userID, timestamp }) =
  case guildID of
    Just gid -> do
      Just guild <- getGuild gid
      Just chan <- pure $ GuildChannel' <$> guild ^. #channels . at (coerceSnowflake channelID)
      pure $ map ($ (chan, userID, timestamp)) (getEventHandlers @'TypingStartEvt eh)
    Nothing -> do
      Just chan <- DMChannel' <<$>> getDM (coerceSnowflake channelID)
      pure $ map ($ (chan, userID, timestamp)) (getEventHandlers @'TypingStartEvt eh)

handleEvent' eh evt@(UserUpdate _) = do
  Just oldUser <- getBotUser
  updateCache evt
  Just newUser <- getBotUser
  pure $ map ($ (oldUser, newUser)) (getEventHandlers @'UserUpdateEvt eh)

handleEvent' _ e = fail $ "Unhandled event: " <> show e

updateCache :: P.Members '[CacheEff, P.Fail] r => DispatchData -> P.Sem r ()
updateCache (Ready ReadyData { user, guilds }) = do
  setBotUser user
  for_ (map getID guilds) setUnavailableGuild

updateCache Resumed = pure ()

updateCache (ChannelCreate (DMChannel' chan)) =
  setDM chan

updateCache (ChannelCreate (GuildChannel' chan)) =
  updateGuild (getID chan) (#channels %~ SM.insert chan)

updateCache (ChannelUpdate (DMChannel' chan)) =
  updateDM (getID chan) (update chan)

updateCache (ChannelUpdate (GuildChannel' chan)) =
  updateGuild (getID chan) (#channels . ix (getID chan) %~ update chan)

updateCache (ChannelDelete (DMChannel' chan)) =
  delDM (getID chan)

updateCache (ChannelDelete (GuildChannel' chan)) =
  updateGuild (getID chan) (#channels %~ sans (getID chan))

updateCache (GuildCreate guild) = do
  isNew <- isUnavailableGuild (getID guild)
  when isNew $ delUnavailableGuild (getID guild)
  setGuild guild
  for_ (SM.fromList (guild ^.. #members . traverse . super)) setUser

updateCache (GuildUpdate guild) =
  updateGuild (getID guild) (update guild)

updateCache (GuildDelete UnavailableGuild { id, unavailable }) =
  if unavailable
  then setUnavailableGuild id
  else delGuild id

updateCache (GuildEmojisUpdate GuildEmojisUpdateData { guildID, emojis }) =
  updateGuild guildID (#emojis .~ SM.fromList emojis)

updateCache (GuildMemberAdd member) = do
  setUser (member ^. super)
  updateGuild (getID member) (#members . at (getID member) ?~ member)

updateCache (GuildMemberRemove GuildMemberRemoveData { guildID, user }) =
  updateGuild guildID (#members %~ sans (getID user))

updateCache (GuildMemberUpdate GuildMemberUpdateData { guildID, roles, user, nick }) = do
  setUser user
  updateGuild guildID (#members . ix (getID user) %~ (#roles .~ roles) . (#nick .~ nick))

updateCache (GuildMembersChunk GuildMembersChunkData { members }) =
  traverse_ (updateCache . GuildMemberAdd) members

updateCache (GuildRoleCreate GuildRoleData { guildID, role }) =
  updateGuild guildID (#roles %~ SM.insert role)

updateCache (GuildRoleUpdate GuildRoleData { guildID, role }) =
  updateGuild guildID (#roles %~ SM.insert role)

updateCache (GuildRoleDelete GuildRoleDeleteData { guildID, roleID }) =
  updateGuild guildID (#roles %~ sans roleID)

updateCache (MessageCreate msg) = setMessage msg

updateCache (MessageUpdate msg) =
  updateMessage (getID msg) (update msg)

updateCache (MessageDelete MessageDeleteData { id }) = delMessage id

updateCache (MessageDeleteBulk MessageDeleteBulkData { ids }) =
  for_ ids delMessage

updateCache (MessageReactionAdd reaction) =
  updateMessage (getID reaction) (#reactions %~ cons reaction)

updateCache (MessageReactionRemove reaction) =
  updateMessage (getID reaction) (#reactions %~ filter (\r -> r ^. #emoji /= reaction ^. #emoji))

updateCache (MessageReactionRemoveAll MessageReactionRemoveAllData { messageID }) =
  updateMessage messageID (#reactions .~ mempty)

updateCache (PresenceUpdate PresenceUpdateData { userID, roles, presence }) =
  updateGuild (getID presence) ((#members . at (coerceSnowflake userID) . _Just . #roles .~ roles)
                                . (#presences . at userID ?~ presence))

updateCache (UserUpdate user) = setBotUser user

-- we don't handle group channels currently
updateCache (ChannelCreate (GroupChannel' _)) = pure ()
updateCache (ChannelUpdate (GroupChannel' _)) = pure ()
updateCache (ChannelDelete (GroupChannel' _)) = pure ()

-- these don't modify state
updateCache (GuildBanAdd _) = pure ()
updateCache (GuildBanRemove _) = pure ()
updateCache (GuildIntegrationsUpdate _) = pure ()
updateCache (TypingStart _) = pure ()
updateCache (ChannelPinsUpdate _) = pure ()
updateCache (WebhooksUpdate _) = pure ()
updateCache (InviteCreate _) = pure ()
updateCache (InviteDelete _) = pure ()

-- we don't handle voice state currently
updateCache (VoiceStateUpdate _) = pure ()
updateCache (VoiceServerUpdate _) = pure ()
