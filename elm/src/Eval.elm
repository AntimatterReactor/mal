module Eval exposing (..)

import Env
import IO exposing (IO)
import Types exposing (..)


apply : Eval a -> Env -> EvalContext a
apply f env =
    f env


run : Env -> Eval a -> EvalContext a
run env e =
    apply e env


withEnv : (Env -> Eval a) -> Eval a
withEnv f env =
    apply (f env) env


setEnv : Env -> Eval ()
setEnv env _ =
    apply (succeed ()) env


modifyEnv : (Env -> Env) -> Eval ()
modifyEnv f env =
    apply (succeed ()) (f env)


succeed : a -> Eval a
succeed res env =
    ( env, EvalOk res )


io : Cmd Msg -> (IO -> Eval a) -> Eval a
io cmd cont env =
    ( env, EvalIO cmd cont )


map : (a -> b) -> Eval a -> Eval b
map f e env =
    case apply e env of
        ( env_, EvalOk res ) ->
            ( env_, EvalOk (f res) )

        ( env_, EvalErr msg ) ->
            ( env_, EvalErr msg )

        ( env_, EvalIO cmd cont ) ->
            ( env_, EvalIO cmd (cont >> map f) )


{-| Chain two Eval's together. The function f takes the result from
the left eval and generates a new Eval.
-}
andThen : (a -> Eval b) -> Eval a -> Eval b
andThen f e env =
    case apply e env of
        ( env_, EvalOk res ) ->
            apply (f res) env_

        ( env_, EvalErr msg ) ->
            ( env_, EvalErr msg )

        ( env_, EvalIO cmd cont ) ->
            ( env_, EvalIO cmd (cont >> andThen f) )


{-| Apply a transformation to the Env, for a Ok and a Err.
-}
finally : (Env -> Env) -> Eval a -> Eval a
finally f e env =
    case apply e env of
        ( env_, EvalOk res ) ->
            ( f env_, EvalOk res )

        ( env_, EvalErr msg ) ->
            ( f env_, EvalErr msg )

        ( env_, EvalIO cmd cont ) ->
            ( env_, EvalIO cmd (cont >> finally f) )


gcPass : Eval MalExpr -> Eval MalExpr
gcPass e env =
    let
        -- fix shadowing error by changing the function argument name
        go env_arg t expr =
            if env_arg.gcCounter >= env_arg.gcInterval then
                --Debug.log
                --    ("before GC: "
                --        ++ (printEnv env)
                --    )
                --    ""
                --    |> always ( Env.gc env, t expr )
                ( Env.gc expr env_arg, t expr )

            else
                ( env_arg, t expr )
    in
    case apply e env of
        ( env_, EvalOk res ) ->
            go env_ EvalOk res

        ( env_, EvalErr msg ) ->
            go env_ EvalErr msg

        ( env_, EvalIO cmd cont ) ->
            ( env_, EvalIO cmd (cont >> gcPass) )


catchError : (MalExpr -> Eval a) -> Eval a -> Eval a
catchError f e env =
    case apply e env of
        ( env_, EvalOk res ) ->
            ( env, EvalOk res )

        ( env_, EvalErr msg ) ->
            apply (f msg) env

        ( env_, EvalIO cmd cont ) ->
            ( env, EvalIO cmd (cont >> catchError f) )


fail : String -> Eval a
fail msg env =
    ( env, EvalErr <| MalString msg )


throw : MalExpr -> Eval a
throw ex env =
    ( env, EvalErr ex )


{-| Apply f to expr repeatedly.
Continues iterating if f returns (Left eval).
Stops if f returns (Right expr).

Tail call optimized.

-}
runLoop : (MalExpr -> Env -> Either (Eval MalExpr) MalExpr) -> MalExpr -> Eval MalExpr
runLoop f expr env =
    case f expr env of
        Left e ->
            case apply e env of
                ( env_, EvalOk expr_ ) ->
                    runLoop f expr env

                ( env_, EvalErr msg ) ->
                    ( env, EvalErr msg )

                ( env_, EvalIO cmd cont ) ->
                    ( env, EvalIO cmd (cont >> andThen (runLoop f)) )

        Right expr_ ->
            ( env, EvalOk expr )


fromResult : Result String a -> Eval a
fromResult res =
    case res of
        Ok val ->
            succeed val

        Err msg ->
            fail msg


{-| Chain the left and right Eval but ignore the right's result.
-}
ignore : Eval b -> Eval a -> Eval a
ignore right left =
    left
        |> andThen
            (\res ->
                right
                    |> andThen (\_ -> succeed res)
            )


withStack : Eval a -> Eval a
withStack e =
    withEnv
        (\env ->
            e
                |> ignore
                    (modifyEnv
                        (Env.restoreRefs env.stack)
                    )
        )


pushRef : MalExpr -> Eval a -> Eval a
pushRef ref e =
    modifyEnv (Env.pushRef ref)
        |> andThen (always e)


inGlobal : Eval a -> Eval a
inGlobal body =
    let
        enter env =
            setEnv
                { env
                    | keepFrames = env.currentFrameId :: env.keepFrames
                    , currentFrameId = Env.globalFrameId
                }

        leave oldEnv newEnv =
            { newEnv
                | keepFrames = oldEnv.keepFrames
                , currentFrameId = oldEnv.currentFrameId
            }
    in
    withEnv
        (\env ->
            if env.currentFrameId /= Env.globalFrameId then
                enter env
                    |> andThen (always body)
                    |> finally (leave env)

            else
                body
        )


runSimple : Eval a -> Result MalExpr a
runSimple e =
    case run Env.global e of
        ( _, EvalOk res ) ->
            Ok res

        ( _, EvalErr msg ) ->
            Err msg

        _ ->
            Debug.todo "can't happen"
