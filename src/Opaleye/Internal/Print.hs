module Opaleye.Internal.Print where

import           Prelude hiding (product)

import qualified Opaleye.Internal.PrimQuery as PQ
import qualified Opaleye.Internal.Sql as Sql
import           Opaleye.Internal.Sql (Select(SelectFrom,
                                              Table,
                                              RelExpr,
                                              SelectJoin,
                                              SelectValues,
                                              SelectBinary,
                                              SelectLabel,
                                              SelectExists),
                                       From, Join, Values, Binary, Label, Exists)

import qualified Opaleye.Internal.HaskellDB.Sql as HSql
import qualified Opaleye.Internal.HaskellDB.Sql.Print as HPrint

import           Text.PrettyPrint.HughesPJ (Doc, ($$), (<+>), text, empty,
                                            parens, doubleQuotes)
import qualified Data.Char
import qualified Data.List.NonEmpty as NEL
import qualified Data.Text          as ST

type TableAlias = String

ppSql :: Select -> Doc
ppSql (SelectFrom s)   = ppSelectFrom s
ppSql (Table table)    = HPrint.ppTable table
ppSql (RelExpr expr)   = HPrint.ppSqlExpr expr
ppSql (SelectJoin j)   = ppSelectJoin j
ppSql (SelectValues v) = ppSelectValues v
ppSql (SelectBinary v) = ppSelectBinary v
ppSql (SelectLabel v)  = ppSelectLabel v
ppSql (SelectExists v) = ppSelectExists v

ppDistinctOn :: Maybe (NEL.NonEmpty HSql.SqlExpr) -> Doc
ppDistinctOn = maybe mempty $ \nel ->
    text "DISTINCT ON" <+>
        text "(" $$ HPrint.commaV HPrint.ppSqlExpr (NEL.toList nel) $$ text ")"

ppSelectFrom :: From -> Doc
ppSelectFrom s = text "SELECT"
                 <+> ppDistinctOn (Sql.distinctOn s)
                 $$  ppAttrs (Sql.attrs s)
                 $$  ppTables (Sql.tables s)
                 $$  HPrint.ppWhere (Sql.criteria s)
                 $$  ppGroupBy (Sql.groupBy s)
                 $$  HPrint.ppOrderBy (Sql.orderBy s)
                 $$  ppLimit (Sql.limit s)
                 $$  ppOffset (Sql.offset s)


ppSelectJoin :: Join -> Doc
ppSelectJoin j = text "SELECT *"
                 $$  text "FROM"
                 $$  ppTable (tableAlias 1 (pure s1))
                 $$  ppJoinType (Sql.jJoinType j)
                 $$  ppTable (tableAlias 2 (pure s2))
                 $$  text "ON"
                 $$  HPrint.ppSqlExpr (Sql.jCond j)
  where (s1, s2) = Sql.jTables j

ppSelectValues :: Values -> Doc
ppSelectValues v = text "SELECT"
                   <+> ppAttrs (Sql.vAttrs v)
                   $$  text "FROM"
                   $$  ppValues (Sql.vValues v)

ppSelectBinary :: Binary -> Doc
ppSelectBinary b = ppSql (Sql.bSelect1 b)
                   $$ ppBinOp (Sql.bOp b)
                   $$ ppSql (Sql.bSelect2 b)

ppSelectLabel :: Label -> Doc
ppSelectLabel l = text "/*" <+> text (preprocess (Sql.lLabel l)) <+> text "*/"
                  $$ ppSql (Sql.lSelect l)
  where
    preprocess = defuseComments . filter Data.Char.isPrint
    defuseComments = ST.unpack
                   . ST.replace (ST.pack "--") (ST.pack " - - ")
                   . ST.replace (ST.pack "/*") (ST.pack " / * ")
                   . ST.replace (ST.pack "*/") (ST.pack " * / ")
                   . ST.pack

ppSelectExists :: Exists -> Doc
ppSelectExists e =
  text "SELECT EXISTS"
  <+> ppTable (Sql.sqlSymbol (Sql.existsBinding e), pure (Sql.existsTable e))

ppJoinType :: Sql.JoinType -> Doc
ppJoinType Sql.LeftJoin = text "LEFT OUTER JOIN"
ppJoinType Sql.RightJoin = text "RIGHT OUTER JOIN"
ppJoinType Sql.FullJoin = text "FULL OUTER JOIN"

ppAttrs :: Sql.SelectAttrs -> Doc
ppAttrs Sql.Star                 = text "*"
ppAttrs (Sql.SelectAttrs xs)     = (HPrint.commaV nameAs . NEL.toList) xs
ppAttrs (Sql.SelectAttrsStar xs) =
  HPrint.commaV id ((map nameAs . NEL.toList) xs ++ [text "*"])

-- This is pretty much just nameAs from HaskellDB
nameAs :: (HSql.SqlExpr, Maybe HSql.SqlColumn) -> Doc
nameAs (expr, name) = HPrint.ppAs (fmap unColumn name) (HPrint.ppSqlExpr expr)
  where unColumn (HSql.SqlColumn s) = s

ppTables :: [(PQ.Lateral, Select)] -> Doc
ppTables [] = empty
ppTables ts = text "FROM" <+> HPrint.commaV ppTable (zipWith tableAlias [1..] ts)

tableAlias :: Int -> (PQ.Lateral, Select) -> (TableAlias, (PQ.Lateral, Select))
tableAlias i select = ("T" ++ show i, select)

-- TODO: duplication with ppSql
ppTable :: (TableAlias, (PQ.Lateral, Select)) -> Doc
ppTable (alias, (lat, select)) = HPrint.ppAs (Just alias) $ case select of
  Table table           -> HPrint.ppTable table
  RelExpr expr          -> HPrint.ppSqlExpr expr
  SelectFrom selectFrom -> lateral $ parens (ppSelectFrom selectFrom)
  SelectJoin slj        -> lateral $ parens (ppSelectJoin slj)
  SelectValues slv      -> lateral $ parens (ppSelectValues slv)
  SelectBinary slb      -> lateral $ parens (ppSelectBinary slb)
  SelectLabel sll       -> lateral $ parens (ppSelectLabel sll)
  SelectExists saj      -> lateral $ parens (ppSelectExists saj)
  where
    lateral = case lat of
      PQ.NonLateral -> id
      PQ.Lateral -> (text "LATERAL" $$)

ppGroupBy :: Maybe (NEL.NonEmpty HSql.SqlExpr) -> Doc
ppGroupBy Nothing   = empty
ppGroupBy (Just xs) = HPrint.ppGroupBy (NEL.toList xs)

ppLimit :: Maybe Int -> Doc
ppLimit Nothing = empty
ppLimit (Just n) = text ("LIMIT " ++ show n)

ppOffset :: Maybe Int -> Doc
ppOffset Nothing = empty
ppOffset (Just n) = text ("OFFSET " ++ show n)

ppValues :: [[HSql.SqlExpr]] -> Doc
ppValues v = HPrint.ppAs (Just "V") (parens (text "VALUES" $$ HPrint.commaV ppValuesRow v))

ppValuesRow :: [HSql.SqlExpr] -> Doc
ppValuesRow = parens . HPrint.commaH HPrint.ppSqlExpr

ppBinOp :: Sql.BinOp -> Doc
ppBinOp o = text $ case o of
  Sql.Union        -> "UNION"
  Sql.UnionAll     -> "UNION ALL"
  Sql.Except       -> "EXCEPT"
  Sql.ExceptAll    -> "EXCEPT ALL"
  Sql.Intersect    -> "INTERSECT"
  Sql.IntersectAll -> "INTERSECT ALL"

ppInsertReturning :: Sql.Returning HSql.SqlInsert -> Doc
ppInsertReturning (Sql.Returning insert returnExprs) =
  HPrint.ppInsert insert
  $$ text "RETURNING"
  <+> HPrint.commaV HPrint.ppSqlExpr (NEL.toList returnExprs)

ppUpdateReturning :: Sql.Returning HSql.SqlUpdate -> Doc
ppUpdateReturning (Sql.Returning update returnExprs) =
  HPrint.ppUpdate update
  $$ text "RETURNING"
  <+> HPrint.commaV HPrint.ppSqlExpr (NEL.toList returnExprs)

ppDeleteReturning :: Sql.Returning HSql.SqlDelete -> Doc
ppDeleteReturning (Sql.Returning delete returnExprs) =
  HPrint.ppDelete delete
  $$ text "RETURNING"
  <+> HPrint.commaV HPrint.ppSqlExpr (NEL.toList returnExprs)
