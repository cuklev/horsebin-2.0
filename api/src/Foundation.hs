{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE RankNTypes #-}

module Foundation where

import Database.Persist.MongoDB hiding (master)
import Import.NoFoundation

import Yesod.Auth.OAuth2.Github
import Yesod.Core.Types            (Logger)
import qualified Yesod.Core.Unsafe as Unsafe

-- | The foundation datatype for your application. This can be a good place to
-- keep settings and values requiring initialization before your application
-- starts running, such as database connections. Every handler will have
-- access to the data present here.
data App = App
    { appSettings        :: AppSettings
    , appConnPool        :: ConnectionPool -- ^ Database connection pool.
    , appHttpManager     :: Manager
    , appLogger          :: Logger
    }


-- This is where we define all of the routes in our application. For a full
-- explanation of the syntax, please see:
-- http://www.yesodweb.com/book/routing-and-handlers
--
-- Note that this is really half the story; in Application.hs, mkYesodDispatch
-- generates the rest of the code. Please see the following documentation
-- for an explanation for this split:
-- http://www.yesodweb.com/book/scaffolding-and-the-site-template#scaffolding-and-the-site-template_foundation_and_application_modules
--
-- This function also generates the following type synonyms:
-- type Handler = HandlerT App IO
-- type Widget = WidgetT App IO ()
mkYesodData "App" $(parseRoutesFile "config/routes")

-- | A convenient synonym for creating forms.
type Form x = Html -> MForm (HandlerT App IO) (FormResult x, Widget)

-- | A convenient synonym for database access functions.
type DB a = forall (m :: * -> *).
    (MonadIO m, Functor m) => ReaderT MongoContext m a

-- Please see the documentation for the Yesod typeclass. There are a number
-- of settings which can be configured by overriding methods here.
instance Yesod App where
    -- Controls the base of generated URLs. For more information on modifying,
    -- see: https://github.com/yesodweb/yesod/wiki/Overriding-approot
    -- approot = ApprootRequest $ \app req ->
    --     case appRoot $ appSettings app of
    --         Nothing -> getApprootText guessApproot app req
    --         Just root -> root
    approot = ApprootRequest $ \app req ->
        case appRoot $ appSettings app of
            Nothing -> getApprootText guessApproot app req
            Just root -> root
    -- Yesod Middleware allows you to run code before and after each handler function.
    -- The defaultYesodMiddleware adds the response header "Vary: Accept, Accept-Language" and performs authorization checks.
    -- Some users may also want to add the defaultCsrfMiddleware, which:
    --   a) Sets a cookie with a CSRF token in it.
    --   b) Validates that incoming write requests include that token in either a header or POST parameter.
    -- To add it, chain it together with the defaultMiddleware: yesodMiddleware = defaultYesodMiddleware . defaultCsrfMiddleware
    -- For details, see the CSRF documentation in the Yesod.Core.Handler module of the yesod-core package.
    yesodMiddleware = defaultYesodMiddleware


    -- The page to be redirected to when authentication is required.
    authRoute _ = Just $ AuthR LoginR

    -- Routes not requiring authentication.
    isAuthorized FoldersR _ = return Authorized
    isAuthorized (FolderR _) _ = return Authorized
    isAuthorized (AuthR _) _ = return Authorized
    isAuthorized CommentR _ = return Authorized
    isAuthorized RobotsR _ = return Authorized

    -- What messages should be logged. The following includes all messages when
    -- in development, and warnings and errors in production.
    shouldLog app _source level =
        appShouldLogAll (appSettings app)
            || level == LevelWarn
            || level == LevelError

    makeLogger = return . appLogger


-- How to run database actions.
instance YesodPersist App where
    type YesodPersistBackend App = MongoContext
    runDB action = do
        master <- getYesod
        runMongoDBPool
            (mgAccessMode $ appDatabaseConf $ appSettings master)
            action
            (appConnPool master)

instance YesodAuth App where
    type AuthId App = Key User
    getAuthId creds = runDB $ do
        x <- insertBy $ User (credsIdent creds) $ Nothing
        return $ Just $
            case x of
                Left (Entity userid _) -> userid
                Right userid           -> userid

    loginDest _ = FoldersR
    logoutDest _ = FoldersR

    authPlugins _ =
        [ oauth2Github "2deac129fc386eae730d" "73a478f983b35dcecb868839eb3e610d2376f6a7"
        ]

    authHttpManager = getHttpManager
    maybeAuthId = return Nothing

    -- The default maybeAuthId assumes a Persistent database. We're going for a
    -- simpler AuthId, so we'll just do a direct lookup in the session.
    -- maybeAuthId = lookupSession "_ID"

-- | Access function to determine if a user is logged in.
isAuthenticated :: Handler AuthResult
isAuthenticated = do
    muid <- maybeAuthId
    return $ case muid of
        Nothing -> Unauthorized "You must login to access this page"
        Just _ -> Authorized

instance YesodAuthPersist App

-- This instance is required to use forms. You can modify renderMessage to
-- achieve customized and internationalized form validation messages.
instance RenderMessage App FormMessage where
    renderMessage _ _ = defaultFormMessage

-- Useful when writing code that is re-usable outside of the Handler context.
-- An example is background jobs that send email.
-- This can also be useful for writing code that works across multiple Yesod applications.
instance HasHttpManager App where
    getHttpManager = appHttpManager

unsafeHandler :: App -> Handler a -> IO a
unsafeHandler = Unsafe.fakeHandlerGetLogger appLogger

-- Note: Some functionality previously present in the scaffolding has been
-- moved to documentation in the Wiki. Following are some hopefully helpful
-- links:
--
-- https://github.com/yesodweb/yesod/wiki/Sending-email
-- https://github.com/yesodweb/yesod/wiki/Serve-static-files-from-a-separate-domain
-- https://github.com/yesodweb/yesod/wiki/i18n-messages-in-the-scaffolding
