{-# LANGUAGE Rank2Types #-}

-- |
-- Module      : Database.HDBC.Session
-- Copyright   : 2013-2016 Kei Hibino
-- License     : BSD3
--
-- Maintainer  : ex8k.hibino@gmail.com
-- Stability   : experimental
-- Portability : unknown
--
-- This module provides a base bracketed function
-- to call close correctly against opend DB connection.
module Database.HDBC.Session (
  -- * Bracketed session
  -- $bracketedSession
  withConnectionCommit,
  withConnectionIO, withConnectionIO',

  bracketConnection,

  -- * Show errors
  -- $showErrors
  showSqlError, handleSqlError',

  -- * Deprecated
  withConnection,
  ) where

import Database.HDBC (IConnection, handleSql,
                      SqlError(seState, seNativeError, seErrorMsg))
import qualified Database.HDBC as HDBC
import Control.Exception (bracket)


{- $bracketedSession
Bracket function implementation is provided by several packages,
so this package provides base implementation which requires
bracket function and corresponding lift function.
-}

{- $showErrors
Functions to show 'SqlError' type not to show 'String' fields.
-}

-- | show 'SqlError' not to show 'String' fields.
showSqlError :: SqlError -> String
showSqlError se = unlines
  ["seState: '" ++ seState se ++ "'",
   "seNativeError: " ++ show (seNativeError se),
   "seErrorMsg: '" ++ seErrorMsg se ++ "'"]

-- | Like 'handleSqlError', but not to show 'String' fields of SqlError.
handleSqlError' :: IO a -> IO a
handleSqlError' =  handleSql (fail . reformat . showSqlError)  where
  reformat = ("SQL error: \n" ++) . unlines . map ("  " ++) . lines

-- | Generalized session with bracketed HDBC connection.
--   Run a transaction on a HDBC IConnection and close the connection.
bracketConnection :: (Monad m, IConnection conn)
                  => (forall c. m c -> (c -> m ()) -> (c -> m a) -> m a) -- ^ bracket
                  -> (forall b. IO b -> m b)                             -- ^ lift
                  -> IO conn                                             -- ^ Connect action
                  -> (conn -> m a)                                       -- ^ Transaction body
                  -> m a
bracketConnection bracket_ lift connect tbody =
    bracket_ (lift open) (lift . close) bodyWithRollback
  where
    open  = handleSqlError' connect
    close :: IConnection conn => conn -> IO ()
    close =  handleSqlError' . HDBC.disconnect
    bodyWithRollback conn =
      bracket_
      (return ())
      -- Do rollback independent from driver default behavior when disconnect.
      (const . lift . handleSqlError' $ HDBC.rollback conn)
      (const $ tbody conn)

{-# DEPRECATED withConnection "use 'bracketConnection' instead of this." #-}
-- | Deprecated. use 'bracketConnection' instead of this.
withConnection :: (Monad m, IConnection conn)
               => (forall c. m c -> (c -> m ()) -> (c -> m a) -> m a)
               -> (forall b. IO b -> m b)
               -> IO conn
               -> (conn -> m a)
               -> m a
withConnection = bracketConnection

-- | Run a transaction on a HDBC 'IConnection' and close the connection.
--   Simple 'IO' version.
withConnectionIO :: IConnection conn
                 => IO conn        -- ^ Connect action
                 -> (conn -> IO a) -- ^ Transaction body
                 -> IO a           -- ^ Result transaction action
withConnectionIO = bracketConnection bracket id

-- | Same as 'withConnectionIO' other than issuing commit at the end of transaction body.
--   In other words, the transaction with no exception is committed.
--   Handy defintion for simple transactions.
withConnectionCommit :: IConnection conn
                     => IO conn        -- ^ Connect action
                     -> (conn -> IO a) -- ^ Transaction body
                     -> IO a           -- ^ Result transaction action
withConnectionCommit conn body =
  withConnectionIO conn $ \c -> do
    x <- body c
    HDBC.commit c
    return x

-- | Same as 'withConnectionIO' other than wrapping transaction body in 'handleSqlError''.
withConnectionIO' :: IConnection conn
                  => IO conn        -- ^ Connect action
                  -> (conn -> IO a) -- ^ Transaction body
                  -> IO a           -- ^ Result transaction action
withConnectionIO' connect body = withConnectionIO connect $ handleSqlError' . body
