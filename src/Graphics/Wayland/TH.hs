{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}

module Graphics.Wayland.TH
    ( Side (..)
    , generateFromXml
    )
where

import Control.Applicative
import Control.Arrow
import Data.Char
import Data.Int
import Data.List
import Data.Word
import Graphics.Wayland.Dispatch
import Graphics.Wayland.Protocol hiding (Type)
import Graphics.Wayland.Types
import Graphics.Wayland.Wire
import qualified Graphics.Wayland.Protocol as P
import Language.Haskell.TH
import System.Posix (Fd)
import Text.XML.HXT.Core hiding (mkName)

data RecordType = Slots | Signals deriving (Eq, Show)
data Side = Server | Client deriving (Eq, Show)

-- | Applies a function to the first element in a list.
mapFirst :: (a -> a) -> [a] -> [a]
mapFirst _ []     = []
mapFirst f (a:as) = f a : as

-- | Returns the type name associated with the given 'Side'.
sideName :: Side -> Name
sideName Client = ''Client
sideName Server = ''Server

-- | Converst a snake_case string to CamelCase, leaving the first character as
-- upper-case.
toCamelL :: String -> String
toCamelL []       = []
toCamelL ('_':ss) = toCamelU ss
toCamelL (s  :ss) = s : toCamelL ss

-- | Converst a snake_case string to CamelCase, leaving the first character as
-- lower-case.
toCamelU :: String -> String
toCamelU = mapFirst toUpper . toCamelL

-- | Creates a 'Name' beginning with lower case from a snake_case string.
mkNameL :: String -> Name
mkNameL = mkName . toCamelL

-- | Creates a 'Name' beginning with upper case from a snake_case string.
mkNameU :: String -> Name
mkNameU = mkName . toCamelU

-- | Creates an integer literal expression.
intE :: Integral i => i -> Q Exp
intE = litE . integerL . fromIntegral

-- | Generates an empty type declaration with the given name.
genEmptyType :: Name -> Q [Dec]
genEmptyType name = return [ DataD [] name [] [] [] ]

-- | Generates a class instance for 'DispatchInterface' for the given 'Interface'.
genDispatchInterfaceInst :: Interface -> Q [Dec]
genDispatchInterfaceInst iface =
    (: [])
    <$> instanceD
            (cxt [])
            [t| DispatchInterface $(conT . mkNameU $ ifaceName iface) |]
            [ funD 'interfaceName    $ funC (stringE $ ifaceName    iface)
            , funD 'interfaceVersion $ funC (intE    $ ifaceVersion iface)
            ]
    where
        funC e = [ clause [ wildP ] (normalB e) [] ]

-- | Gets the interface's requests.
getRequests :: Interface -> [(String, [P.Type])]
getRequests = map (reqName &&& (map argType . reqArgs)) . ifaceRequests

-- | Gets the interface's events.
getEvents :: Interface -> [(String, [P.Type])]
getEvents = map (eventName &&& (map argType . eventArgs)) . ifaceEvents

-- | Wraps a type in 'Maybe' if the first argument is 'True'.
wrapMaybe :: Bool -> Type -> Type
wrapMaybe True c = AppT (ConT ''Maybe) c
wrapMaybe _    c = c

-- | Generates the type of an interface, depending on its name. If it is
-- 'Nothing', an unique type variable will be generated, otherwise the type
-- corresponding to the interface is returned.
genInterfaceType :: Maybe String -> Q (Type, [Name])
genInterfaceType = maybe ((VarT &&& (: [])) <$> newName "i") (return . (, []) . ConT . mkNameU)

-- | Generates the type of an 'Object' argument.
--
-- The type is 'Object s i' where s is either 'Client' or 'Server' and i is the
-- object's interface type. If the interface isn't specified, the type will be
-- 'ObjId'.
--
-- If the object is nullable the type will be wrapped in 'Maybe'.
genObjectType :: Side -> Bool -> Maybe String -> (Type, [Name])
genObjectType s nullable =
    first (wrapMaybe nullable)
    . maybe
        (ConT ''ObjId, [])
        ((, []) . AppT obj . ConT . mkNameU)
    where
        obj = AppT (ConT ''Object) (ConT $ sideName s)

-- | Generates the type of a new object.
--
-- If this is a Slot (incoming call), the new type will be
--
-- 'forall i . DispatchInterface => SlotConstructor c i m'
--
-- for calls where the interface is not know at compile time and
--
-- 'SlotConstructor c Interface m'
--
-- where it is known at compile time. 'c' is 'Server' or 'Client'.
--
-- If this is a Signal (outgoing call), the new type will be
--
-- 'SignalConstructor c i m'
--
-- and 'i' is either a type variable or a specific interface. The new object is
-- also added to the return type of the function.
genNewType :: RecordType -> Side -> Bool -> Maybe String -> Q (Type, [Name], [Type])
genNewType rt s nullable iface = do
    (it, ns) <- genInterfaceType iface

    let c    = conT $ sideName s
        i    = return it
        m    = varT $ mkName "m"
        obj  = [t| Object $c $i |]

    case rt of
         Slots ->
             (, [], [])
             <$> forallT
                 (map PlainTV ns)
                 (cxt $ map classCxt ns)
                 [t| SlotConstructor $c $i $m |]
         Signals ->
             (, ns, )
             <$> (wrapMaybe nullable <$> [t| SignalConstructor $c $i $m |])
             <*> ((: []) . wrapMaybe nullable <$> obj)

-- | Generates the type of a single function argument, returning both the type,
-- any type variables it contains that needs too be caught and optionally a
-- list of types to add to the function's return value.
genArgType :: RecordType -> Side -> P.Type -> Q (Type, [Name], [Type])
genArgType rt s t =
    case t of
         TypeSigned     -> (, [], [])               <$> [t| Int32     |]
         TypeUnsigned   -> (, [], [])               <$> [t| Word32    |]
         TypeFixed      -> (, [], [])               <$> [t| Double    |]
         TypeFd         -> (, [], [])               <$> [t| Fd        |]
         TypeArray      -> (, [], [])               <$> [t| [Word32]  |]
         TypeString n   -> (, [], []) . wrapMaybe n <$> [t| String    |]
         TypeObject n i -> return . uncurry (,, []) $ genObjectType s n i
         TypeNew    n i -> genNewType rt s n i

-- | Creates a tuple with the given list of element types.
--
-- The list can be empty, in which case the type will simply be '()'.
mkTuple :: [Type] -> Type
mkTuple ts = foldl AppT (TupleT $ length ts) ts

-- | Returns a class predicate for 'DispatchInterface' for the given name.
classCxt :: Name -> PredQ
classCxt i = classP ''DispatchInterface [varT i]

-- | Generates a function type for a record field.
genFuncType :: RecordType -> Side -> [P.Type] -> Q Type
genFuncType rt s ts = do
    (ts', is', rs') <- unzip3 <$> mapM (genArgType rt s) ts

    let is  = concat is'
        rs  = concat rs'
        ret = AppT (VarT $ mkName "m") (mkTuple rs)
        t   = foldr (\a b -> AppT (AppT ArrowT a) b) ret ts'

    forallT
        (map PlainTV is)
        (cxt $ map classCxt is)
        (return t)

-- | Returns a record field name given an interface and the function name.
fieldName :: Interface -> String -> Name
fieldName iface func = mkNameL $ ifaceName iface ++ "_" ++ func

-- | Returns the data family name associated with a 'RecordType'.
recordTypeName :: RecordType -> Name
recordTypeName Slots   = ''Slots
recordTypeName Signals = ''Signals

-- | Generates a data family instance for 'Signals' or 'Slots'.
--
-- The instance will have a single record constructor, with fields for every
-- slot or signal function.
genRecord :: RecordType             -- ^ The record type to generate.
          -> Side                   -- ^ The 'Side' to generate it for.
          -> [(String, [P.Type])]   -- ^ The record's fields.
          -> Interface              -- ^ The interface this record belongs to.
          -> Q Dec
genRecord rt s args iface =
    dataInstD (pure []) (recordTypeName rt) types [con] []
    where
        con            = recC conName $ map mkField args
        conName        = mkNameU $ ifaceName iface ++ show rt
        typeName       = mkNameU $ ifaceName iface
        types          = [ conT $ sideName s
                         , conT typeName
                         , varT $ mkName "m"
                         ]
        mkField (n, t) = (fieldName iface n, NotStrict, ) <$> genFuncType rt s t

-- | Returns the slots of an interface.
getSlots :: Side -> Interface -> [(String, [P.Type])]
getSlots Server = getRequests
getSlots Client = getEvents

-- | Returns the signals of an interface.
getSignals :: Side -> Interface -> [(String, [P.Type])]
getSignals Server = getEvents
getSignals Client = getRequests

-- | Generates a slot record for the given interface.
genSlotsRec :: Side -> Interface -> Q Dec
genSlotsRec s iface =
    genRecord Slots s (getSlots s iface) iface

-- | Generates a signal record for the given interface.
genSignalsRec :: Side -> Interface -> Q Dec
genSignalsRec s iface =
    genRecord Signals s (getSignals s iface) iface

-- | Generates a list of names of arguments to get from the message and an
-- expression to pass to the function.
genDispatchArg :: P.Type            -- ^ The type of the function argument.
               -> Q ([Name], ExpQ)  -- ^ A tuple with arguments from the
                                    -- message and argument to pass to the function.
genDispatchArg t =
    case t of
         TypeNew    nullable interface -> do
             name <- newName "name"
             ver  <- newName "ver"
             new  <- newName "new"

             let (ns, just) = case interface of
                                   Just _  -> ([new           ], [| Nothing                          |])
                                   Nothing -> ([name, ver, new], [| Just ($(varE name), $(varE ver)) |])
                 arg  = if nullable
                          then [| fmap (regObject $just) $(varE new) |]
                          else [| regObject $just $(varE new) |]

             return (ns, arg)

         TypeObject nullable (Just _) -> do
             obj <- newName "obj"
             let arg = if nullable
                         then [| fmap Object $(varE obj) |]
                         else [| Object $(varE obj) |]
             return ([obj], arg)

         _ -> ((: []) &&& varE) <$> newName "arg"

-- | Generates a single 'MatchQ' clause for a case statement, matching a
-- specific opcode.
--
-- The match clause will be of the form
-- 'op -> \... -> fieldName slots ...
-- where fieldName is the record field name for that specific function.
genDispatchCase :: Interface -> (Integer, (String, [P.Type])) -> MatchQ
genDispatchCase iface (op, (n, ts)) = do
    (pats, args') <- first concat . unzip <$> mapM genDispatchArg ts
    args          <- sequence args'

    let func  = lamE (map varP pats) (return $ foldl AppE field args)
        field = AppE (VarE $ fieldName iface n) (VarE $ mkName "slots")

    match
        (litP $ IntegerL op)
        (normalB [| fromMessage $(varE $ mkName "msg") $(func) |])
        []

-- | Generates the expression for the 'dispatch' function of a 'Dispatch' instance.
--
-- The expression will be a lambda function
-- '\slots msg -> case msgOp msg of { 0 -> case0; 1 -> case1; _ -> fail "unknown opcode" }
-- with one case for every possible opcode.
genDispatch :: Side -> Interface -> Q Exp
genDispatch s iface =
    lamE [slotsP, varP $ mkName "msg"] $
        caseE [| msgOp $(varE $ mkName "msg") |]
        ( map (genDispatchCase iface) (zip [0..] slots) ++
        [ match (varP op) (normalB [| fail ("Unknown opcode " ++ show $(varE op)) |]) [] ]
        )
    where
        op = mkName "op"
        slots  = getSlots s iface
        slotsP = if null slots
                   then wildP
                   else varP $ mkName "slots"

-- | Generates code for a single argument of a signal function.
--
-- The function returns a tuple with a function that can add to the functions
-- body expression, the name of the function argument, a list of expression for
-- values to add to the message and a list of names of values to add to the
-- return value.
genSignalArg :: P.Type -> Q (Exp -> Exp, Name, [Exp], [Name])
genSignalArg t =
    case t of
         TypeNew nullable interface -> do
             newId <- newName "newId"
             name  <- newName "name"
             ver   <- newName "ver"
             obj   <- newName "obj"
             cons  <- newName "cons"

             let args = case interface of
                             Nothing -> map VarE [ver, name, newId]
                             _       -> map VarE [newId]
                 newObj = if nullable
                            then AppE (VarE 'maybeNewObject) (VarE cons)
                            else AppE (VarE 'newObject)      (VarE cons)
                 func   = InfixE (Just newObj) (VarE $ mkName ">>=") . Just . body
                 body   = LamE [TupP [VarP newId, VarP obj]] . lete
                 lete e = case interface of
                               Nothing -> LetE decs e
                               _       -> e
                 decs   = [ ValD (VarP ver ) (NormalB $ AppE (VarE 'consName) (VarE cons)) []
                          , ValD (VarP name) (NormalB $ AppE (VarE 'consVer ) (VarE cons)) []
                          ]

             return (func, cons, args, [obj])

         TypeObject nullable interface -> do
             obj <- newName "obj"
             arg <- case interface of
                         Nothing -> varE obj
                         _       -> if nullable
                                      then [| fmap unObject $(varE obj) |]
                                      else [| unObject $(varE obj) |]
             return (id, obj, [arg], [])
         _ -> (\n -> (id, n, [VarE n], [])) <$> newName "arg"

-- | Generates a single signal function for the 'signals' function.
genSignal :: Interface -> Name -> (Integer, (String, [P.Type])) -> Q (Name, Exp)
genSignal iface obj (op, (name, ts)) = do
    (fs, pats', args', rets') <- unzip4 <$> mapM genSignalArg ts

    let args = concat args'
        pats = map varP pats'
        rets = map varE $ concat rets'
        ret  = tupE rets
        msg  = flip (foldl AppE) args <$> [| toMessage $(intE op) (unObject $(varE obj)) |]
        body = foldl (.) id fs <$> [| sendMessage $msg >> return $ret |]

    (fieldName iface name, ) <$> lamE pats body

-- | Generates a function for the 'signals' function of the 'Dispatch' class.
genSignals :: Side -> Interface -> Q Exp
genSignals s iface = do
    obj <- newName "obj"
    lam1E
        (objP obj)
        (recConE conName . map (genSignal iface obj) $ zip [0..] sigs)
    where
        conName = mkNameU $ ifaceName iface ++ "_signals"
        sigs    = getSignals s iface
        objP o  = if null sigs
                    then wildP
                    else varP o

-- | Generates an instance for the 'Dispatch' class for the given 'Interface'.
genDispatchInstance :: Side -> Interface -> Q [Dec]
genDispatchInstance s iface =
    (: [])
    <$> instanceD (cxt []) [t| Dispatch $i $c |]
        [ genSlotsRec   s iface
        , genSignalsRec s iface
        , funD 'dispatch [clause [] (normalB $ genDispatch s iface) []]
        , funD 'signals  [clause [] (normalB $ genSignals  s iface) []]
        ]
    where
        c = conT $ sideName s
        i = conT . mkNameU $ ifaceName iface

-- | Generates all the code for an interface.
generateInterface :: Side -> Interface -> Q [Dec]
generateInterface s iface =
    concat <$> sequence
    [ genEmptyType . mkName . toCamelU $ ifaceName iface
    , genDispatchInterfaceInst iface
    , genDispatchInstance s iface
    ]

-- | Generates code for a protocol.
generateProtocol :: Side -> Protocol -> Q [Dec]
generateProtocol s = fmap concat . mapM (generateInterface s) . protoInterfaces

-- | Generates code for a protocol specified in the given XML file.
generateFromXml :: Side -> FilePath -> Q [Dec]
generateFromXml s file = do
    proto <- runIO . runX $ xunpickleDocument xpickle [withRemoveWS yes] file
    case proto of
         [p] -> generateProtocol s p
         _   -> fail $ "Could not unpickle protocol file " ++ file
