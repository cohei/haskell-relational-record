{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}

module Database.Relational.Schema.OracleDataDictionary.ConsColumns where

import GHC.Generics (Generic)
import Data.Int (Int32)
import Database.Relational.TH (defineTableTypesAndRecord)

import Database.Relational.Schema.OracleDataDictionary.Config (config)


$(defineTableTypesAndRecord config
    "SYS" "dba_cons_columns"
    -- Column                                    NULL?    Datatype
    -- ----------------------------------------- -------- ----------------------------
    -- OWNER                                     NOT NULL VARCHAR2(30)
    [ ("owner", [t|String|])
    -- CONSTRAINT_NAME                           NOT NULL VARCHAR2(30)
    , ("constraint_name", [t|String|])
    -- TABLE_NAME                                NOT NULL VARCHAR2(30)
    , ("table_name", [t|String|])
    -- COLUMN_NAME                                        VARCHAR2(4000)
    , ("column_name", [t|Maybe String|])
    -- POSITION                                           NUMBER
    , ("position", [t|Maybe Int32|])
    ] [''Show, ''Generic])
