{-# Language Arrows,OverloadedStrings #-}

-- |An parser for the RDF/XML format 
-- <http://www.w3.org/TR/REC-rdf-syntax/>.

module Text.RDF.RDF4H.XmlParser(
  parseXmlRDF, getRDF
) where

import Control.Arrow (Arrow,(>>>),(<<<),(&&&),(***),arr,returnA)
import Control.Arrow.ArrowState (ArrowState,nextState)
import Data.List (isPrefixOf)
import qualified Data.Map as Map (fromList)
import Data.RDF.Types (RDF,Node(BNodeGen),BaseUrl(..),Triple(..),Triples,Subject,Predicate,Object,PrefixMappings(..),ParseFailure(ParseFailure),mkRdf,lnode,plainL,plainLL,typedL,unode,bnode)
import qualified Data.Text as T (Text,pack,unpack)
import Text.XML.HXT.Core (ArrowXml,XmlTree,IfThen((:->)),(>.),(>>.),first,neg,(<+>),expandURI,getName,getAttrValue,getAttrValue0,getAttrl,hasAttrValue,hasAttr,constA,choiceA,getChildren,ifA,arr2A,second,hasName,isElem,xshow,listA,isA,isText,getText,this,unlistA,orElse,sattr,mkelem,xread,runSLA)

-- TODO: Create instance:
--  RdfParse XmlParser

-- |Global state for the parser
data GParseState = GParseState { stateGenId :: Int
                               }
  deriving(Show)

-- |Local state for the parser (dependant on the parent xml elements)
data LParseState = LParseState { stateBaseUrl :: BaseUrl
                               , stateLang :: Maybe String
                               , stateSubject :: Subject
                               }
  deriving(Show)

-- |Parse a xml T.Text to an RDF representation
parseXmlRDF :: forall rdf. (RDF rdf)
            => Maybe BaseUrl           -- ^ The base URL for the RDF if required
            -> Maybe T.Text        -- ^ DocUrl: The request URL for the RDF if available
            -> T.Text              -- ^ The contents to parse
            -> Either ParseFailure rdf -- ^ The RDF representation of the triples or ParseFailure
parseXmlRDF bUrl dUrl xmlStr = case runParseArrow of
                                (_,r:_) -> Right r
                                _ -> Left (ParseFailure "XML parsing failed")
  where runParseArrow = runSLA (xread >>> addMetaData bUrl dUrl >>> getRDF) initState (T.unpack xmlStr)
        initState = GParseState { stateGenId = 0 }

-- |Add a root tag to a given XmlTree to appear as if it was read from a readDocument function
addMetaData :: (ArrowXml a) => Maybe BaseUrl -> Maybe T.Text -> a XmlTree XmlTree
addMetaData bUrlM dUrlM = mkelem "/"
                        ( [ sattr "transfer-Message" "OK"
                          , sattr "transfer-MimeType" "text/rdf"
                          ] ++ mkSource dUrlM ++ mkBase bUrlM
                        )
                        [ arr id ]
  where mkSource (Just dUrl) = [ sattr "source" (T.unpack dUrl) ]
        mkSource Nothing = []
        mkBase (Just (BaseUrl bUrl)) = [ sattr "transfer-URI" (T.unpack bUrl) ]
        mkBase Nothing = []

-- |Arrow that translates HXT XmlTree to an RDF representation
getRDF :: forall rdf a. (RDF rdf, ArrowXml a, ArrowState GParseState a) => a XmlTree rdf
getRDF = proc xml -> do
            rdf <- hasName "rdf:RDF" <<< isElem <<< getChildren         -< xml
            bUrl <- arr (BaseUrl . T.pack) <<< ((getAttrValue0 "xml:base" <<< isElem <<< getChildren) `orElse` getAttrValue "transfer-URI") -< xml
            prefixMap <- arr toPrefixMap <<< toAttrMap                  -< rdf
            triples <- parseDescription' >. id -< (bUrl, rdf)
            returnA -< mkRdf triples (Just bUrl) prefixMap
  where toAttrMap = (getAttrl >>> (getName &&& (getChildren >>> getText))) >. id
        toPrefixMap = PrefixMappings . Map.fromList . map (\(n, m) -> (T.pack (drop 6 n), T.pack m)) . filter (isPrefixOf "xmlns:" . fst)

-- |Read the initial state from an rdf element
parseDescription' :: forall a. (ArrowXml a, ArrowState GParseState a) => a (BaseUrl, XmlTree) Triple
parseDescription' = proc (bUrl, rdf) -> do
                         desc <- isElem <<< getChildren -< rdf
                         state <- arr (\(s, o) -> s { stateSubject = o }) <<< arr fst &&& arr2A mkNode -< (LParseState bUrl Nothing undefined, desc)
                         triple <- parseDescription -< (state, desc)
                         returnA -< triple

-- |Read an rdf:Description tag to its corresponding Triples
parseDescription :: forall a. (ArrowXml a, ArrowState GParseState a) => a (LParseState, XmlTree) Triple
parseDescription = updateState
               >>> (arr2A parsePredicatesFromAttr
                   <+> (second (getChildren >>> isElem) >>> parsePredicatesFromChildren)
                   <+> (second (neg (hasName "rdf:Description")) >>> arr2A readTypeTriple))
               >>. replaceLiElems [] (1 :: Int)
  where readTypeTriple :: forall a. (ArrowXml a, ArrowState GParseState a) => LParseState -> a XmlTree Triple
        readTypeTriple state = getName >>> arr (Triple (stateSubject state) rdfType . unode . T.pack)
        replaceLiElems acc n (Triple s p o : rest) | p == (unode . T.pack) "rdf:li" =
            replaceLiElems (Triple s ((unode . T.pack) ("rdf:_" ++ show n)) o : acc) (n + 1) rest
        replaceLiElems acc n (Triple s p o : rest) = replaceLiElems (Triple s p o : acc) n rest
        replaceLiElems acc _ [] = acc

-- |Parse the current predicate element as a rdf:Description element (used when rdf:parseType = "Resource")
parseAsResource :: forall a. (ArrowXml a, ArrowState GParseState a) => Node -> a (LParseState, XmlTree) Triple
parseAsResource n = updateState
    >>>     (arr2A parsePredicatesFromAttr
        <+> (second getName >>> arr (\(s, p) -> Triple (stateSubject s) ((unode . T.pack) p) n))
        <+> (arr (\s -> s { stateSubject = n }) *** (getChildren >>> isElem) >>> parsePredicatesFromChildren))

-- |Read the attributes of an rdf:Description element.  These correspond to the Predicate Object pairs of the Triple
parsePredicatesFromAttr :: forall a. (ArrowXml a, ArrowState GParseState a) => LParseState -> a XmlTree Triple
parsePredicatesFromAttr state = getAttrl
    >>> (getName >>> neg isMetaAttr >>> mkUNode) &&& (getChildren >>> getText >>> arr (lnode . plainL . T.pack))
    >>> arr (attachSubject (stateSubject state))

-- | Arrow to determine if special processing is required for an attribute
isMetaAttr :: forall a. (ArrowXml a, ArrowState GParseState a) => a String String
isMetaAttr = isA (== "rdf:about")
         <+> isA (== "rdf:nodeID")
         <+> isA (== "rdf:ID")
         <+> isA (== "xml:lang")
         <+> isA (== "rdf:parseType")

-- |Read a children of an rdf:Description element.  These correspond to the Predicate portion of the Triple
parsePredicatesFromChildren :: forall a. (ArrowXml a, ArrowState GParseState a)
                            => a (LParseState, XmlTree) Triple
parsePredicatesFromChildren = updateState
    >>> choiceA
        [ second (hasAttrValue "rdf:parseType" (== "Literal")) :-> arr2A parseAsLiteralTriple
        , second (hasAttrValue "rdf:parseType" (== "Resource")) :-> (defaultA <+> (mkBlankNode &&& arr id >>> arr2A parseAsResource))
        , second (hasAttrValue "rdf:parseType" (== "Collection")) :-> (listA (defaultA >>> arr id &&& mkBlankNode) >>> mkCollectionTriples >>> unlistA)
        , second (hasAttr "rdf:datatype") :-> arr2A getTypedTriple
        , second (hasAttr "rdf:resource") :-> arr2A getResourceTriple
        , second (hasAttr "rdf:nodeID") :-> arr2A getNodeIdTriple
        , second (hasAttr "rdf:ID") :-> (arr2A mkRelativeNode &&& defaultA >>> arr2A reifyTriple >>> unlistA)
        , second hasPredicateAttr :-> (defaultA <+> (mkBlankNode &&& arr id >>> arr2A parsePredicateAttr))
        , this :-> defaultA
        ]
  where defaultA = proc (state, predXml) -> do
                         p <- arr(unode . T.pack) <<< getName -< predXml
                         t <- arr2A (arr2A . parseObjectsFromChildren) <<< second (second getChildren) -< (state, (p, predXml))
                         returnA -< t
        parsePredicateAttr n = (second getName >>> arr (\(s, p) -> Triple (stateSubject s) ((unode . T.pack) p) n))
                           <+> (first (arr (\s -> s { stateSubject = n })) >>> arr2A parsePredicatesFromAttr)
        hasPredicateAttr = getAttrl >>> neg (getName >>> isMetaAttr)

parseObjectsFromChildren :: forall a. (ArrowXml a, ArrowState GParseState a)
                         => LParseState -> Predicate -> a XmlTree Triple
parseObjectsFromChildren s p = choiceA
    [ isText :-> (getText >>> arr (Triple (stateSubject s) p . mkLiteralNode s))
    , isElem :-> (hasName "rdf:Description" >>> parseObjectDescription)
    ]
  where parseObjectDescription = proc desc -> do
                                      o <- mkNode s -< desc
                                      t0 <- arr (\(sub, (p', o)) -> Triple sub p' o) -< (stateSubject s, (p, o))
                                      t <- arr fst <+> (parseDescription <<< arr snd) -< (t0, (s { stateSubject = o }, desc))
                                      returnA -< t

attachSubject :: Subject -> (Predicate, Object) -> Triple
attachSubject s (p, o) = Triple s p o

reifyTriple :: forall a. (ArrowXml a, ArrowState GParseState a) => Subject -> a Triple Triples
reifyTriple node = arr (\(Triple s p o) -> [ Triple s p o
                                           , Triple node rdfType rdfStatement
                                           , Triple node rdfSubject s
                                           , Triple node rdfPredicate p
                                           , Triple node rdfObject o
                                           ])

-- |Updates the local state at a given node
updateState :: forall a. (ArrowXml a, ArrowState GParseState a)
            => a (LParseState, XmlTree) (LParseState, XmlTree)
updateState = ifA (second (hasAttr "xml:lang")) (arr2A readLang) (arr id)
          >>> ifA (second (hasAttr "xml:base")) (arr2A readBase) (arr id)
  where readLang state = (getAttrValue0 "xml:lang" >>> arr (\lang -> state { stateLang = Just lang } ) ) &&& arr id
        readBase state = (getAttrValue0 "xml:base" >>> arr (\base -> state { stateBaseUrl = (BaseUrl . T.pack) base } ) ) &&& arr id

-- |Read a Triple with an rdf:parseType of Literal
parseAsLiteralTriple :: forall a. (ArrowXml a, ArrowState GParseState a) => LParseState -> a XmlTree Triple
parseAsLiteralTriple state = (nameToUNode &&& (xshow getChildren >>> arr (mkTypedLiteralNode rdfXmlLiteral)))
    >>> arr (attachSubject (stateSubject state))

mkCollectionTriples :: forall a. (ArrowXml a, ArrowState GParseState a) => a [(Triple, Node)] Triples
mkCollectionTriples = arr (mkCollectionTriples' [])
  where mkCollectionTriples' [] ((Triple s1 p1 o1, n1):rest) =
            mkCollectionTriples' [Triple s1 p1 n1] ((Triple s1 p1 o1, n1):rest)
        mkCollectionTriples' acc ((Triple _ _ o1, n1):(t2, n2):rest) =
            mkCollectionTriples' (Triple n1 rdfFirst o1 : Triple n1 rdfRest n2 : acc) ((t2, n2):rest)
        mkCollectionTriples' acc [(Triple _ _ o1, n1)] =
            Triple n1 rdfFirst o1 : Triple n1 rdfRest rdfNil : acc
        mkCollectionTriples' _ [] = []

-- |Read a Triple and it's type when rdf:datatype is available
getTypedTriple :: forall a. (ArrowXml a, ArrowState GParseState a) => LParseState -> a XmlTree Triple
getTypedTriple state = nameToUNode &&& (attrExpandURI state "rdf:datatype" &&& xshow getChildren >>> arr (\(t, v) -> mkTypedLiteralNode (T.pack t) v))
    >>> arr (attachSubject (stateSubject state))

getResourceTriple :: forall a. (ArrowXml a, ArrowState GParseState a)
                  => LParseState -> a XmlTree Triple
getResourceTriple state = nameToUNode &&& (attrExpandURI state "rdf:resource" >>> mkUNode)
    >>> arr (attachSubject (stateSubject state))

getNodeIdTriple :: forall a. (ArrowXml a, ArrowState GParseState a)
                => LParseState -> a XmlTree Triple
getNodeIdTriple state = nameToUNode &&& (getAttrValue "rdf:nodeID" >>> arr (bnode . T.pack))
    >>> arr (attachSubject (stateSubject state))

-- |Read a Node from the "rdf:about" property or generate a blank node
mkNode :: forall a. (ArrowXml a, ArrowState GParseState a) => LParseState -> a XmlTree Node
mkNode state = choiceA [ hasAttr "rdf:about" :-> (attrExpandURI state "rdf:about" >>> mkUNode)
                       , hasAttr "rdf:resource" :-> (attrExpandURI state "rdf:resource" >>> mkUNode)
                       , hasAttr "rdf:nodeID" :-> (getAttrValue "rdf:nodeID" >>> arr (bnode . T.pack))
                       , hasAttr "rdf:ID" :-> mkRelativeNode state
                       , this :-> mkBlankNode
                       ]

rdfXmlLiteral :: T.Text
rdfFirst,rdfRest,rdfNil,rdfType,rdfStatement,rdfSubject,rdfPredicate,rdfObject :: Node

rdfXmlLiteral = T.pack "http://www.w3.org/1999/02/22-rdf-syntax-ns#XMLLiteral"
rdfFirst = (unode . T.pack) "rdf:first"
rdfRest = (unode . T.pack) "rdf:rest"
rdfNil = (unode . T.pack) "rdf:nil"
rdfType = (unode . T.pack) "rdf:type"
rdfStatement = (unode . T.pack) "rdf:Statement"
rdfSubject = (unode . T.pack) "rdf:subject"
rdfPredicate = (unode . T.pack) "rdf:predicate"
rdfObject = (unode . T.pack) "rdf:object"

nameToUNode :: forall a. (ArrowXml a) => a XmlTree Node
nameToUNode = getName >>> mkUNode

attrExpandURI :: forall a. (ArrowXml a) => LParseState -> String -> a XmlTree String
attrExpandURI state attr = getAttrValue attr &&& baseUrl >>> expandURI
  where baseUrl = constA (case stateBaseUrl state of BaseUrl b -> T.unpack b)

-- |Make a UNode from an absolute string
mkUNode :: forall a. (Arrow a) => a String Node
mkUNode = arr (unode . T.pack)

-- |Make a UNode from a rdf:ID element, expanding relative URIs
mkRelativeNode :: forall a. (ArrowXml a, ArrowState GParseState a) => LParseState -> a XmlTree Node
mkRelativeNode s = (getAttrValue "rdf:ID" >>> arr (\x -> '#':x)) &&& baseUrl
    >>> expandURI >>> arr (unode . T.pack)
  where baseUrl = constA (case stateBaseUrl s of BaseUrl b -> T.unpack b)

-- |Make a literal node with the given type and content
mkTypedLiteralNode :: T.Text -> String -> Node
mkTypedLiteralNode t content = lnode (typedL (T.pack content) t)

-- |Use the given state to create a literal node
mkLiteralNode :: LParseState -> String -> Node
mkLiteralNode (LParseState _ (Just lang) _) content = lnode (plainLL (T.pack content) (T.pack lang))
mkLiteralNode (LParseState _ Nothing _) content = (lnode . plainL . T.pack) content

-- |Generate an RDF blank node with incrementing IDs from the arrow state
mkBlankNode :: forall a b. (ArrowState GParseState a) => a b Node
mkBlankNode = nextState (\gState -> gState { stateGenId = stateGenId gState + 1 })
    >>> arr (BNodeGen . stateGenId)

