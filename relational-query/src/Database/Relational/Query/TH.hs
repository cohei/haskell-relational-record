{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE ParallelListComp #-}

-- |
-- Module      : Database.Relational.Query.TH
-- Copyright   : 2013 Kei Hibino
-- License     : BSD3
--
-- Maintainer  : ex8k.hibino@gmail.com
-- Stability   : experimental
-- Portability : unknown
--
-- This module defines templates for Haskell record type and type class instances
-- to define column projection on SQL query like Haskell records.
-- Templates are generated by also using functions of "Database.Record.TH" module,
-- so mapping between list of untyped SQL type and Haskell record type will be done too.
module Database.Relational.Query.TH (
  -- * All templates about table
  defineTable,
  defineTableDefault,

  -- * Inlining typed 'Query'
  unsafeInlineQuery,
  inlineQuery,

  -- * Column projections and basic 'Relation' for Haskell record
  defineTableTypesAndRecord,
  defineTableTypesAndRecordDefault,

  -- * Constraint key templates
  defineHasPrimaryKeyInstance,
  defineHasPrimaryKeyInstanceWithConfig,
  defineHasPrimaryKeyInstanceDefault,
  defineHasNotNullKeyInstance,
  defineHasNotNullKeyInstanceWithConfig,
  defineHasNotNullKeyInstanceDefault,
  defineScalarDegree,

  -- * Column projections
  defineColumns, defineColumnsDefault,

  -- * Table metadata type and basic 'Relation'
  defineTableTypes, defineTableTypesWithConfig, defineTableTypesDefault,

  -- * Basic SQL templates generate rules
  definePrimaryQuery,
  definePrimaryUpdate,

  -- * Var expression templates
  derivationExpDefault,
  tableVarExpDefault,
  relationVarExp,
  relationVarExpDefault,

  -- * Derived SQL templates from table definitions
  defineSqlsWithPrimaryKey,
  defineSqlsWithPrimaryKeyDefault,

  -- * Add type class instance against record type
  defineProductConstructorInstance,

  -- * Reify
  makeRelationalRecordDefault,
  reifyRelation,
  ) where

import Data.Char (toUpper, toLower)
import Data.List (foldl1')
import Data.Array.IArray ((!))

import Language.Haskell.TH
  (Name, nameBase, Q, reify, Info (VarI), TypeQ, Type (AppT, ConT), ExpQ,
   tupleT, appT, arrowT, Dec, stringE, listE)
import Language.Haskell.TH.Name.CamelCase
  (VarName, varName, ConName (ConName), conName, varNameWithPrefix, varCamelcaseName, toVarExp, toTypeCon, toDataCon)
import Language.Haskell.TH.Lib.Extra (simpleValD, maybeD, integralE)

import Database.Record.TH
  (columnOffsetsVarNameDefault, recordTypeName, recordType,
   defineRecordTypeWithConfig, defineHasColumnConstraintInstance)
import qualified Database.Record.TH as Record

import Database.Relational.Query
  (Table, Pi, id', Relation, ProductConstructor (..),
   NameConfig (..), SchemaNameMode (..), IdentifierQuotation (..),
   Config (normalizedTableName, schemaNameMode, nameConfig, identifierQuotation), defaultConfig,
   relationalQuerySQL, Query, relationalQuery, KeyUpdate,
   Insert, derivedInsert, InsertQuery, derivedInsertQuery,
   HasConstraintKey(constraintKey), Primary, NotNull, primary, primaryUpdate)

import Database.Relational.Query.Scalar (defineScalarDegree)
import Database.Relational.Query.Constraint (Key, unsafeDefineConstraintKey)
import Database.Relational.Query.Table (TableDerivable (..))
import qualified Database.Relational.Query.Table as Table
import Database.Relational.Query.Relation (derivedRelation)
import Database.Relational.Query.SQL (QuerySuffix)
import Database.Relational.Query.Type (unsafeTypedQuery)
import qualified Database.Relational.Query.Pi.Unsafe as UnsafePi


-- | Rule template to infer constraint key.
defineHasConstraintKeyInstance :: TypeQ   -- ^ Constraint type
                               -> TypeQ   -- ^ Record type
                               -> TypeQ   -- ^ Key type
                               -> [Int]   -- ^ Indexes specifies key
                               -> Q [Dec] -- ^ Result 'HasConstraintKey' declaration
defineHasConstraintKeyInstance constraint recType colType indexes = do
  -- kc <- defineHasColumnConstraintInstance constraint recType index
  ck <- [d| instance HasConstraintKey $constraint $recType $colType  where
              constraintKey = unsafeDefineConstraintKey $(listE [integralE ix | ix <- indexes])
          |]
  return ck

-- | Rule template to infer primary key.
defineHasPrimaryKeyInstance :: TypeQ   -- ^ Record type
                            -> TypeQ   -- ^ Key type
                            -> [Int]   -- ^ Indexes specifies key
                            -> Q [Dec] -- ^ Result constraint key declarations
defineHasPrimaryKeyInstance recType colType indexes = do
  kc <- Record.defineHasPrimaryKeyInstance recType indexes
  ck <- defineHasConstraintKeyInstance [t| Primary |] recType colType indexes
  return $ kc ++ ck

-- | Rule template to infer primary key.
defineHasPrimaryKeyInstanceWithConfig :: Config  -- ^ configuration parameters
                                      -> String  -- ^ Schema name
                                      -> String  -- ^ Table name
                                      -> TypeQ   -- ^ Column type
                                      -> [Int]   -- ^ Primary key index
                                      -> Q [Dec] -- ^ Declarations of primary constraint key
defineHasPrimaryKeyInstanceWithConfig config scm =
  defineHasPrimaryKeyInstance . recordType (recordConfig $ nameConfig config) scm

{-# DEPRECATED defineHasPrimaryKeyInstanceDefault "Use ' defineHasPrimaryKeyInstanceWithConfig defaultConfig ' instead of this." #-}
-- | Rule template to infer primary key.
defineHasPrimaryKeyInstanceDefault :: String  -- ^ Schema name
                                   -> String  -- ^ Table name
                                   -> TypeQ   -- ^ Column type
                                   -> [Int]   -- ^ Primary key index
                                   -> Q [Dec] -- ^ Declarations of primary constraint key
defineHasPrimaryKeyInstanceDefault =
  defineHasPrimaryKeyInstanceWithConfig defaultConfig

-- | Rule template to infer not-null key.
defineHasNotNullKeyInstance :: TypeQ   -- ^ Record type
                            -> Int     -- ^ Column index
                            -> Q [Dec] -- ^ Result 'ColumnConstraint' declaration
defineHasNotNullKeyInstance =
  defineHasColumnConstraintInstance [t| NotNull |]

-- | Rule template to infer not-null key.
defineHasNotNullKeyInstanceWithConfig :: Config  -- ^ configuration parameters
                                      -> String  -- ^ Schema name
                                      -> String  -- ^ Table name
                                      -> Int     -- ^ NotNull key index
                                      -> Q [Dec] -- ^ Declaration of not-null constraint key
defineHasNotNullKeyInstanceWithConfig config scm =
  defineHasNotNullKeyInstance . recordType (recordConfig $ nameConfig config) scm

{-# DEPRECATED defineHasNotNullKeyInstanceDefault "Use ' defineHasNotNullKeyInstanceWithConfig defaultConfig ' instead of this." #-}
-- | Rule template to infer not-null key.
defineHasNotNullKeyInstanceDefault :: String  -- ^ Schema name
                                   -> String  -- ^ Table name
                                   -> Int     -- ^ NotNull key index
                                   -> Q [Dec] -- ^ Declaration of not-null constraint key
defineHasNotNullKeyInstanceDefault =
  defineHasNotNullKeyInstanceWithConfig defaultConfig


-- | Column projection path 'Pi' template.
columnTemplate' :: TypeQ   -- ^ Record type
                -> VarName -- ^ Column declaration variable name
                -> ExpQ    -- ^ Column index expression in record (begin with 0)
                -> TypeQ   -- ^ Column type
                -> Q [Dec] -- ^ Column projection path declaration
columnTemplate' recType var' iExp colType = do
  let var = varName var'
  simpleValD var [t| Pi $recType $colType |]
    [| UnsafePi.definePi $(iExp) |]

-- | Column projection path 'Pi' and constraint key template.
columnTemplate :: Maybe (TypeQ, VarName) -- ^ May Constraint type and constraint object name
               -> TypeQ                  -- ^ Record type
               -> VarName                -- ^ Column declaration variable name
               -> ExpQ                   -- ^ Column index expression in record (begin with 0)
               -> TypeQ                  -- ^ Column type
               -> Q [Dec]                -- ^ Column projection path declaration
columnTemplate mayConstraint recType var' iExp colType = do
  col <- columnTemplate' recType var' iExp colType
  cr  <- maybe
    (return [])
    ( \(constraint, cname') -> do
         simpleValD (varName cname') [t| Key $constraint $recType $colType |]
           [| unsafeDefineConstraintKey $(iExp) |] )
    mayConstraint
  return $ col ++ cr

-- | Column projection path 'Pi' templates.
defineColumns :: ConName                                      -- ^ Record type name
              -> [((VarName, TypeQ), Maybe (TypeQ, VarName))] -- ^ Column info list
              -> Q [Dec]                                      -- ^ Column projection path declarations
defineColumns recTypeName cols = do
  let defC ((cn, ct), mayCon) ix = columnTemplate mayCon (toTypeCon recTypeName) cn
                                   [| $(toVarExp . columnOffsetsVarNameDefault $ conName recTypeName) ! $(integralE ix) |] ct
  fmap concat . sequence $ zipWith defC cols [0 :: Int ..]

-- | Make column projection path and constraint key templates using default naming rule.
defineColumnsDefault :: ConName                          -- ^ Record type name
                     -> [((String, TypeQ), Maybe TypeQ)] -- ^ Column info list
                     -> Q [Dec]                          -- ^ Column projection path declarations
defineColumnsDefault recTypeName cols =
  defineColumns recTypeName [((varN n, ct), fmap (withCName n) mayC) | ((n, ct), mayC) <- cols]
  where varN      name   = varCamelcaseName (name ++ "'")
        withCName name t = (t, varCamelcaseName ("constraint_key_" ++ name))

-- | Rule template to infer table derivations.
defineTableDerivableInstance :: TypeQ -> String -> [String] -> Q [Dec]
defineTableDerivableInstance recordType' table columns =
  [d| instance TableDerivable $recordType' where
        derivedTable = Table.table $(stringE table) $(listE $ map stringE columns)
    |]

-- | Template to define inferred entries from table type.
defineTableDerivations :: VarName -- ^ Table declaration variable name
                       -> VarName -- ^ Relation declaration variable name
                       -> VarName -- ^ Insert statement declaration variable name
                       -> VarName -- ^ InsertQuery statement declaration variable name
                       -> TypeQ   -- ^ Record type
                       -> Q [Dec] -- ^ Table and Relation declaration
defineTableDerivations tableVar' relVar' insVar' insQVar' recordType' = do
  let tableVar = varName tableVar'
  tableDs <- simpleValD tableVar [t| Table $recordType' |]
             [| derivedTable |]
  let relVar   = varName relVar'
  relDs   <- simpleValD relVar   [t| Relation () $recordType' |]
             [| derivedRelation |]
  let insVar   = varName insVar'
  insDs   <- simpleValD insVar   [t| Insert $recordType' |]
             [| derivedInsert id' |]
  let insQVar  = varName insQVar'
  insQDs  <- simpleValD insQVar  [t| forall p . Relation p $recordType' -> InsertQuery p |]
             [| derivedInsertQuery id' |]
  return $ concat [tableDs, relDs, insDs, insQDs]

-- | 'Table' and 'Relation' templates.
defineTableTypes :: VarName  -- ^ Table declaration variable name
                 -> VarName  -- ^ Relation declaration variable name
                 -> VarName  -- ^ Insert statement declaration variable name
                 -> VarName  -- ^ InsertQuery statement declaration variable name
                 -> TypeQ    -- ^ Record type
                 -> String   -- ^ Table name in SQL ex. FOO_SCHEMA.table0
                 -> [String] -- ^ Column names
                 -> Q [Dec]  -- ^ Table and Relation declaration
defineTableTypes tableVar' relVar' insVar' insQVar' recordType' table columns = do
  iDs <- defineTableDerivableInstance recordType' table columns
  dDs <- defineTableDerivations tableVar' relVar' insVar' insQVar' recordType'
  return $ iDs ++ dDs

tableSQL :: Bool -> SchemaNameMode -> IdentifierQuotation -> String -> String -> String
tableSQL normalize snm iq schema table = case snm of
  SchemaQualified     ->  (qt normalizeS) ++ '.' : (qt normalizeT)
  SchemaNotQualified  ->  (qt normalizeT)
  where
    normalizeS
      | normalize = map toUpper schema
      | otherwise = schema
    normalizeT
      | normalize = map toLower table
      | otherwise = table
    qt s = case iq of
             NoQuotation -> s
             Quotation qc -> qc : s ++ qc : [] -- TODO: Escaping.

derivationVarNameDefault :: String -> VarName
derivationVarNameDefault =  (`varNameWithPrefix` "derivationFrom")

-- | Make 'TableDerivation' variable expression template from table name using default naming rule.
derivationExpDefault :: String -- ^ Table name string
                     -> ExpQ   -- ^ Result var Exp
derivationExpDefault =  toVarExp . derivationVarNameDefault

tableVarNameDefault :: String -> VarName
tableVarNameDefault =  (`varNameWithPrefix` "tableOf")

-- | Make 'Table' variable expression template from table name using default naming rule.
tableVarExpDefault :: String -- ^ Table name string
                   -> ExpQ   -- ^ Result var Exp
tableVarExpDefault =  toVarExp . tableVarNameDefault

-- | Make 'Relation' variable expression template from table name using specified naming rule.
relationVarExp :: Config -- ^ Configuration which has  naming rules of templates
                         -> String -- ^ Schema name string
                         -> String -- ^ Table name string
                         -> ExpQ   -- ^ Result var Exp
relationVarExp config scm = toVarExp . relationVarName (nameConfig config) scm

{-# DEPRECATED relationVarExpDefault "Use ' relationVarExp defaultConfig ' instead of this." #-}
-- | Make 'Relation' variable expression template from table name using default naming rule.
relationVarExpDefault :: String -- ^ Schema name string
                      -> String -- ^ Table name string
                      -> ExpQ   -- ^ Result var Exp
relationVarExpDefault = relationVarExp defaultConfig

-- | Make template for 'ProductConstructor' instance.
defineProductConstructorInstance :: TypeQ -> ExpQ -> [TypeQ] -> Q [Dec]
defineProductConstructorInstance recTypeQ recData colTypes =
  [d| instance ProductConstructor $(foldr (appT . (arrowT `appT`)) recTypeQ colTypes) where
        productConstructor = $(recData)
    |]

-- | Make template for record 'ProductConstructor' instance using specified naming rule.
defineProductConstructorInstanceWithConfig :: Config -> String -> String -> [TypeQ] -> Q [Dec]
defineProductConstructorInstanceWithConfig config schema table colTypes = do
  let typeName = recordTypeName (recordConfig $ nameConfig config) schema table
  defineProductConstructorInstance
    (toTypeCon typeName)
    (toDataCon typeName)
    colTypes

-- | Make templates about table and column metadatas using specified naming rule.
defineTableTypesWithConfig :: Config                           -- ^ Configuration to generate query with
                           -> String                           -- ^ Schema name
                           -> String                           -- ^ Table name
                           -> [((String, TypeQ), Maybe TypeQ)] -- ^ Column names and types and constraint type
                           -> Q [Dec]                          -- ^ Result declarations
defineTableTypesWithConfig config schema table columns = do
  let nmconfig = nameConfig config
      recConfig = recordConfig nmconfig
  tableDs <- defineTableTypes
             (tableVarNameDefault table)
             (relationVarName nmconfig schema table)
             (table `varNameWithPrefix` "insert")
             (table `varNameWithPrefix` "insertQuery")
             (recordType recConfig schema table)
             (tableSQL (normalizedTableName config) (schemaNameMode config) (identifierQuotation config) schema table)
             (map (fst . fst) columns)
  colsDs <- defineColumnsDefault (recordTypeName recConfig schema table) columns
  return $ tableDs ++ colsDs

{-# DEPRECATED defineTableTypesDefault "Use defineTableTypesWithConfig instead of this." #-}
-- | Make templates about table and column metadatas using default naming rule.
defineTableTypesDefault :: Config                           -- ^ Configuration to generate query with
                        -> String                           -- ^ Schema name
                        -> String                           -- ^ Table name
                        -> [((String, TypeQ), Maybe TypeQ)] -- ^ Column names and types and constraint type
                        -> Q [Dec]                          -- ^ Result declarations
defineTableTypesDefault = defineTableTypesWithConfig

-- | Make templates about table, column and haskell record using specified naming rule.
defineTableTypesAndRecord :: Config            -- ^ Configuration to generate query with
                          -> String            -- ^ Schema name
                          -> String            -- ^ Table name
                          -> [(String, TypeQ)] -- ^ Column names and types
                          -> [Name]            -- ^ Record derivings
                          -> Q [Dec]           -- ^ Result declarations
defineTableTypesAndRecord config schema table columns derives = do
  recD    <- defineRecordTypeWithConfig (recordConfig $ nameConfig config) schema table columns derives
  rconD   <- defineProductConstructorInstanceWithConfig config schema table [t | (_, t) <- columns]
  tableDs <- defineTableTypesWithConfig config schema table [(c, Nothing) | c <- columns ]
  return $ recD ++ rconD ++ tableDs

{-# DEPRECATED defineTableTypesAndRecordDefault "Use defineTableTypesAndRecord instead of this." #-}
-- | Make templates about table, column and haskell record using default naming rule.
defineTableTypesAndRecordDefault :: Config            -- ^ Configuration to generate query with
                                 -> String            -- ^ Schema name
                                 -> String            -- ^ Table name
                                 -> [(String, TypeQ)] -- ^ Column names and types
                                 -> [Name]            -- ^ Record derivings
                                 -> Q [Dec]           -- ^ Result declarations
defineTableTypesAndRecordDefault = defineTableTypesAndRecord

-- | Template of derived primary 'Query'.
definePrimaryQuery :: VarName -- ^ Variable name of result declaration
                   -> TypeQ   -- ^ Parameter type of 'Query'
                   -> TypeQ   -- ^ Record type of 'Query'
                   -> ExpQ    -- ^ 'Relation' expression
                   -> Q [Dec] -- ^ Result 'Query' declaration
definePrimaryQuery toDef' paramType recType relE = do
  let toDef = varName toDef'
  simpleValD toDef
    [t| Query $paramType $recType |]
    [|  relationalQuery (primary $relE) |]

-- | Template of derived primary 'Update'.
definePrimaryUpdate :: VarName -- ^ Variable name of result declaration
                    -> TypeQ   -- ^ Parameter type of 'Update'
                    -> TypeQ   -- ^ Record type of 'Update'
                    -> ExpQ    -- ^ 'Table' expression
                    -> Q [Dec] -- ^ Result 'Update' declaration
definePrimaryUpdate toDef' paramType recType tableE = do
  let toDef = varName toDef'
  simpleValD toDef
    [t| KeyUpdate $paramType $recType |]
    [|  primaryUpdate $tableE |]


-- | SQL templates derived from primary key.
defineSqlsWithPrimaryKey :: VarName -- ^ Variable name of select query definition from primary key
                         -> VarName -- ^ Variable name of update statement definition from primary key
                         -> TypeQ   -- ^ Primary key type
                         -> TypeQ   -- ^ Record type
                         -> ExpQ    -- ^ Relation expression
                         -> ExpQ    -- ^ Table expression
                         -> Q [Dec] -- ^ Result declarations
defineSqlsWithPrimaryKey sel upd paramType recType relE tableE = do
  selD <- definePrimaryQuery  sel paramType recType relE
  updD <- definePrimaryUpdate upd paramType recType tableE
  return $ selD ++ updD

-- | SQL templates derived from primary key using default naming rule.
defineSqlsWithPrimaryKeyDefault :: String  -- ^ Table name of Database
                                -> TypeQ   -- ^ Primary key type
                                -> TypeQ   -- ^ Record type
                                -> ExpQ    -- ^ Relation expression
                                -> ExpQ    -- ^ Table expression
                                -> Q [Dec] -- ^ Result declarations
defineSqlsWithPrimaryKeyDefault table  =
  defineSqlsWithPrimaryKey sel upd
  where
    sel = table `varNameWithPrefix` "select"
    upd = table `varNameWithPrefix` "update"

-- | All templates about primary key.
defineWithPrimaryKey :: Config
                     -> String  -- ^ Schema name
                     -> String  -- ^ Table name string
                     -> TypeQ   -- ^ Type of primary key
                     -> [Int]   -- ^ Indexes specifies primary key
                     -> Q [Dec] -- ^ Result declarations
defineWithPrimaryKey config schema table keyType ixs = do
  instD <- defineHasPrimaryKeyInstanceWithConfig config schema table keyType ixs
  let recType  = recordType (recordConfig $ nameConfig config) schema table
      tableE   = tableVarExpDefault table
      relE     = relationVarExp config schema table
  sqlsD <- defineSqlsWithPrimaryKeyDefault table keyType recType relE tableE
  return $ instD ++ sqlsD

-- | All templates about not-null key.
defineWithNotNullKeyWithConfig :: Config -> String -> String -> Int -> Q [Dec]
defineWithNotNullKeyWithConfig = defineHasNotNullKeyInstanceWithConfig

-- | Generate all templtes about table using specified naming rule.
defineTable :: Config            -- ^ Configuration to generate query with
            -> String            -- ^ Schema name string of Database
            -> String            -- ^ Table name string of Database
            -> [(String, TypeQ)] -- ^ Column names and types
            -> [Name]            -- ^ derivings for Record type
            -> [Int]             -- ^ Primary key index
            -> Maybe Int         -- ^ Not null key index
            -> Q [Dec]           -- ^ Result declarations
defineTable config schema table columns derives primaryIxs mayNotNullIdx = do
  tblD  <- defineTableTypesAndRecord config schema table columns derives
  let pairT x y = appT (appT (tupleT 2) x) y
      keyType   = foldl1' pairT . map (snd . (columns !!)) $ primaryIxs
  primD <- case primaryIxs of
    []  -> return []
    ixs -> defineWithPrimaryKey config schema table keyType ixs
  nnD   <- maybeD (\i -> defineWithNotNullKeyWithConfig config schema table i) mayNotNullIdx
  return $ tblD ++ primD ++ nnD

{-# DEPRECATED defineTableDefault "Use defineTable instead of this." #-}
-- | Generate all templtes about table using default naming rule.
defineTableDefault :: Config            -- ^ Configuration to generate query with
                   -> String            -- ^ Schema name string of Database
                   -> String            -- ^ Table name string of Database
                   -> [(String, TypeQ)] -- ^ Column names and types
                   -> [Name]            -- ^ derivings for Record type
                   -> [Int]             -- ^ Primary key index
                   -> Maybe Int         -- ^ Not null key index
                   -> Q [Dec]           -- ^ Result declarations
defineTableDefault = defineTable


-- | Unsafely inlining SQL string 'Query' in compile type.
unsafeInlineQuery :: TypeQ   -- ^ Query parameter type
                  -> TypeQ   -- ^ Query result type
                  -> String  -- ^ SQL string query to inline
                  -> VarName -- ^ Variable name for inlined query
                  -> Q [Dec] -- ^ Result declarations
unsafeInlineQuery p r sql qVar' =
  simpleValD (varName qVar')
    [t| Query $p $r |]
    [|  unsafeTypedQuery $(stringE sql) |]

-- | Extract param type and result type from defined Relation
reifyRelation :: Name           -- ^ Variable name which has Relation type
              -> Q (Type, Type) -- ^ Extracted param type and result type from Relation type
reifyRelation relVar = do
  relInfo <- reify relVar
  case relInfo of
    VarI _ (AppT (AppT (ConT prn) p) r) _ _
      | prn == ''Relation    ->  return (p, r)
    _                        ->
      fail $ "expandRelation: Variable must have Relation type: " ++ show relVar

-- | Inlining composed 'Query' in compile type.
inlineQuery :: Name         -- ^ Top-level variable name which has 'Relation' type
            -> Relation p r -- ^ Object which has 'Relation' type
            -> Config       -- ^ Configuration to generate SQL
            -> QuerySuffix  -- ^ suffix SQL words
            -> String       -- ^ Variable name to define as inlined query
            -> Q [Dec]      -- ^ Result declarations
inlineQuery relVar rel config sufs qns = do
  (p, r) <- reifyRelation relVar
  unsafeInlineQuery (return p) (return r)
    (relationalQuerySQL config rel sufs)
    (varCamelcaseName qns)

-- | Generate all templates against defined record like type constructor
--   other than depending on sql-value type.
makeRelationalRecordDefault :: Name    -- ^ Type constructor name
                            -> Q [Dec] -- ^ Result declaration
makeRelationalRecordDefault recTypeName = do
  let recTypeConName = ConName recTypeName
  ((tyCon, dataCon), (mayNs, cts)) <- Record.reifyRecordType recTypeName
  pw <- Record.defineColumnOffsets recTypeConName cts
  cs <- maybe
        (return [])
        (\ns -> defineColumnsDefault recTypeConName
                [ ((nameBase n, ct), Nothing) | n  <- ns  | ct <- cts ])
        mayNs
  pc <- defineProductConstructorInstance tyCon dataCon cts
  return $ concat [pw, cs, pc]
