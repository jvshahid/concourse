module Build.Header.Header exposing
    ( handleCallback
    , handleDelivery
    , header
    , update
    , view
    )

import Application.Models exposing (Session)
import Build.Header.Models exposing (BuildPageType(..), HistoryItem, Model)
import Build.Header.Views as Views
import Build.StepTree.Models as STModels
import Concourse
import Concourse.BuildStatus
import Concourse.Pagination exposing (Paginated)
import DateFormat
import Duration exposing (Duration)
import EffectTransformer exposing (ET)
import HoverState
import Html exposing (Html)
import Keyboard
import List.Extra
import Maybe.Extra
import Message.Callback exposing (Callback(..))
import Message.Effects as Effects exposing (Effect(..), ScrollDirection(..))
import Message.Message exposing (DomID(..), Message(..))
import Message.Subscription
    exposing
        ( Delivery(..)
        , Interval(..)
        , Subscription(..)
        )
import Routes
import Time


historyId : String
historyId =
    "builds"


header : Session -> Model r -> Views.Header
header session model =
    { leftWidgets =
        [ Views.Title model.name model.job
        , Views.Duration (duration session model)
        ]
    , rightWidgets =
        [ Views.Button
            (if Concourse.BuildStatus.isRunning model.status then
                Just
                    { type_ = Views.Abort
                    , isClickable = True
                    , backgroundShade =
                        if
                            HoverState.isHovered
                                AbortBuildButton
                                session.hovered
                        then
                            Views.Dark

                        else
                            Views.Light
                    , backgroundColor = Concourse.BuildStatus.BuildStatusFailed
                    , tooltip = False
                    }

             else if model.job /= Nothing then
                let
                    isHovered =
                        HoverState.isHovered
                            RerunBuildButton
                            session.hovered
                in
                Just
                    { type_ = Views.Rerun
                    , isClickable = True
                    , backgroundShade =
                        if isHovered then
                            Views.Dark

                        else
                            Views.Light
                    , backgroundColor = model.status
                    , tooltip = isHovered
                    }

             else
                Nothing
            )
        , Views.Button
            (if model.job /= Nothing then
                let
                    isHovered =
                        HoverState.isHovered
                            TriggerBuildButton
                            session.hovered
                in
                Just
                    { type_ = Views.Trigger
                    , isClickable = not model.disableManualTrigger
                    , backgroundShade =
                        if isHovered then
                            Views.Dark

                        else
                            Views.Light
                    , backgroundColor = model.status
                    , tooltip = isHovered && model.disableManualTrigger
                    }

             else
                Nothing
            )
        ]
    , backgroundColor = model.status
    , tabs = tabs model
    }


tabs : Model r -> List Views.BuildTab
tabs model =
    model.history
        |> List.map
            (\b ->
                { id = b.id
                , name = b.name
                , background = b.status
                , href = Routes.buildRoute b.id b.name model.job
                , isCurrent = b.id == model.id
                }
            )


historyItem : Model r -> HistoryItem
historyItem model =
    { id = model.id
    , name = model.name
    , status = model.status
    }


duration : Session -> Model r -> Views.BuildDuration
duration session model =
    case ( model.duration.startedAt, model.duration.finishedAt ) of
        ( Nothing, Nothing ) ->
            Views.Pending

        ( Nothing, Just finished ) ->
            Views.Cancelled (timestamp session.timeZone model.now finished)

        ( Just started, Nothing ) ->
            Views.Running (timestamp session.timeZone model.now started)

        ( Just started, Just finished ) ->
            Views.Finished
                { started = timestamp session.timeZone model.now started
                , finished = timestamp session.timeZone model.now finished
                , duration = timespan <| Duration.between started finished
                }


timestamp : Time.Zone -> Maybe Time.Posix -> Time.Posix -> Views.Timestamp
timestamp timeZone now time =
    let
        ago =
            Maybe.map (Duration.between time) now

        formatted =
            format timeZone time
    in
    case ago of
        Just a ->
            if a < 24 * 60 * 60 * 1000 then
                Views.Relative (timespan a) formatted

            else
                Views.Absolute formatted (Just <| timespan a)

        Nothing ->
            Views.Absolute formatted Nothing


format : Time.Zone -> Time.Posix -> String
format =
    DateFormat.format
        [ DateFormat.monthNameAbbreviated
        , DateFormat.text " "
        , DateFormat.dayOfMonthNumber
        , DateFormat.text " "
        , DateFormat.yearNumber
        , DateFormat.text " "
        , DateFormat.hourFixed
        , DateFormat.text ":"
        , DateFormat.minuteFixed
        , DateFormat.text ":"
        , DateFormat.secondFixed
        , DateFormat.text " "
        , DateFormat.amPmUppercase
        ]


timespan : Duration -> Views.Timespan
timespan dur =
    let
        seconds =
            dur // 1000

        remainingSeconds =
            remainderBy 60 seconds

        minutes =
            seconds // 60

        remainingMinutes =
            remainderBy 60 minutes

        hours =
            minutes // 60

        remainingHours =
            remainderBy 24 hours

        days =
            hours // 24
    in
    case ( ( days, remainingHours ), remainingMinutes, remainingSeconds ) of
        ( ( 0, 0 ), 0, s ) ->
            Views.JustSeconds s

        ( ( 0, 0 ), m, s ) ->
            Views.MinutesAndSeconds m s

        ( ( 0, h ), m, _ ) ->
            Views.HoursAndMinutes h m

        ( ( d, h ), _, _ ) ->
            Views.DaysAndHours d h


view : Session -> Model r -> Html Message
view session model =
    header session model |> Views.viewHeader


handleDelivery : Delivery -> ET (Model r)
handleDelivery delivery ( model, effects ) =
    case delivery of
        KeyDown keyEvent ->
            handleKeyPressed keyEvent ( model, effects )

        KeyUp keyEvent ->
            case keyEvent.code of
                Keyboard.T ->
                    ( { model | previousTriggerBuildByKey = False }, effects )

                _ ->
                    ( model, effects )

        ElementVisible ( id, True ) ->
            let
                lastBuildVisible =
                    model.history
                        |> List.Extra.last
                        |> Maybe.map .id
                        |> Maybe.map String.fromInt
                        |> Maybe.map ((==) id)
                        |> Maybe.withDefault False

                hasNextPage =
                    model.nextPage /= Nothing

                needsToFetchMorePages =
                    not model.fetchingHistory && lastBuildVisible && hasNextPage
            in
            case model.job of
                Just job ->
                    if needsToFetchMorePages then
                        ( { model | fetchingHistory = True }
                        , effects ++ [ FetchBuildHistory job model.nextPage ]
                        )

                    else
                        ( model, effects )

                Nothing ->
                    ( model, effects )

        ElementVisible ( id, False ) ->
            let
                currentBuildInvisible =
                    String.fromInt model.id == id

                shouldScroll =
                    currentBuildInvisible && not model.scrolledToCurrentBuild
            in
            ( { model | scrolledToCurrentBuild = True }
            , effects
                ++ (if shouldScroll then
                        [ Scroll (ToId id) historyId ]

                    else
                        []
                   )
            )

        EventsReceived result ->
            Result.toMaybe result
                |> Maybe.map
                    (List.filter
                        (.url
                            >> String.endsWith
                                ("/api/v1/builds/"
                                    ++ String.fromInt model.id
                                    ++ "/events"
                                )
                        )
                    )
                |> Maybe.map
                    (List.filterMap
                        (\{ data } ->
                            case data of
                                STModels.BuildStatus status date ->
                                    Just ( status, date )

                                _ ->
                                    Nothing
                        )
                    )
                |> Maybe.andThen List.Extra.last
                |> Maybe.map
                    (\( status, date ) ->
                        let
                            newStatus =
                                if Concourse.BuildStatus.isRunning model.status then
                                    status

                                else
                                    model.status
                        in
                        ( { model
                            | history =
                                List.Extra.updateIf (.id >> (==) model.id)
                                    (\item -> { item | status = newStatus })
                                    model.history
                            , duration =
                                let
                                    dur =
                                        model.duration
                                in
                                { dur
                                    | finishedAt =
                                        if Concourse.BuildStatus.isRunning status then
                                            dur.finishedAt

                                        else
                                            Just date
                                }
                            , status = newStatus
                          }
                        , effects
                        )
                    )
                |> Maybe.withDefault ( model, effects )

        _ ->
            ( model, effects )


handleKeyPressed : Keyboard.KeyEvent -> ET (Model r)
handleKeyPressed keyEvent ( model, effects ) =
    if Keyboard.hasControlModifier keyEvent then
        ( model, effects )

    else
        case ( keyEvent.code, keyEvent.shiftKey ) of
            ( Keyboard.H, False ) ->
                case nextHistoryItem model.history (historyItem model) of
                    Just item ->
                        ( model
                        , effects
                            ++ [ NavigateTo <|
                                    Routes.toString <|
                                        Routes.buildRoute
                                            item.id
                                            item.name
                                            model.job
                               ]
                        )

                    Nothing ->
                        ( model, effects )

            ( Keyboard.L, False ) ->
                case prevHistoryItem model.history (historyItem model) of
                    Just item ->
                        ( model
                        , effects
                            ++ [ NavigateTo <|
                                    Routes.toString <|
                                        Routes.buildRoute
                                            item.id
                                            item.name
                                            model.job
                               ]
                        )

                    Nothing ->
                        ( model, effects )

            ( Keyboard.T, True ) ->
                if not model.previousTriggerBuildByKey then
                    (model.job
                        |> Maybe.map (DoTriggerBuild >> (::) >> Tuple.mapSecond)
                        |> Maybe.withDefault identity
                    )
                        ( { model | previousTriggerBuildByKey = True }, effects )

                else
                    ( model, effects )

            ( Keyboard.R, True ) ->
                ( model
                , effects
                    ++ (if Concourse.BuildStatus.isRunning model.status then
                            []

                        else
                            model.job
                                |> Maybe.map
                                    (\j ->
                                        RerunJobBuild
                                            { teamName = j.teamName
                                            , pipelineName = j.pipelineName
                                            , jobName = j.jobName
                                            , buildName = model.name
                                            }
                                    )
                                |> Maybe.Extra.toList
                       )
                )

            ( Keyboard.A, True ) ->
                if Just (historyItem model) == List.head model.history then
                    ( model, DoAbortBuild model.id :: effects )

                else
                    ( model, effects )

            _ ->
                ( model, effects )


prevHistoryItem : List HistoryItem -> HistoryItem -> Maybe HistoryItem
prevHistoryItem builds b =
    case builds of
        first :: second :: rest ->
            if first == b then
                Just second

            else
                prevHistoryItem (second :: rest) b

        _ ->
            Nothing


nextHistoryItem : List HistoryItem -> HistoryItem -> Maybe HistoryItem
nextHistoryItem builds b =
    case builds of
        first :: second :: rest ->
            if second == b then
                Just first

            else
                nextHistoryItem (second :: rest) b

        _ ->
            Nothing


update : Message -> ET (Model r)
update msg ( model, effects ) =
    case msg of
        ScrollBuilds event ->
            let
                scroll =
                    if event.deltaX == 0 then
                        [ Scroll (Sideways event.deltaY) historyId ]

                    else
                        [ Scroll (Sideways -event.deltaX) historyId ]

                checkVisibility =
                    case model.history |> List.Extra.last of
                        Just b ->
                            [ Effects.CheckIsVisible <| String.fromInt b.id ]

                        Nothing ->
                            []
            in
            ( model, effects ++ scroll ++ checkVisibility )

        Click RerunBuildButton ->
            ( model
            , effects
                ++ (model.job
                        |> Maybe.map
                            (\j ->
                                RerunJobBuild
                                    { teamName = j.teamName
                                    , pipelineName = j.pipelineName
                                    , jobName = j.jobName
                                    , buildName = model.name
                                    }
                            )
                        |> Maybe.Extra.toList
                   )
            )

        _ ->
            ( model, effects )


handleCallback : Callback -> ET (Model r)
handleCallback callback ( model, effects ) =
    case callback of
        BuildFetched (Ok ( browsingIndex, b )) ->
            handleBuildFetched browsingIndex b ( model, effects )

        BuildTriggered (Ok b) ->
            ( { model
                | history =
                    ({ id = b.id
                     , name = b.name
                     , status = b.status
                     }
                        :: model.history
                    )
                        |> List.sortWith
                            (\n m ->
                                Maybe.map2
                                    (\( i, j ) ( k, l ) ->
                                        case compare i k of
                                            EQ ->
                                                compare j l

                                            x ->
                                                x
                                    )
                                    (buildName n.name)
                                    (buildName m.name)
                                    |> Maybe.withDefault EQ
                            )
                        |> List.reverse
              }
            , effects
                ++ [ NavigateTo <| Routes.toString <| Routes.buildRoute b.id b.name model.job ]
            )

        BuildHistoryFetched (Ok history) ->
            handleHistoryFetched history ( model, effects )

        BuildHistoryFetched (Err _) ->
            -- https://github.com/concourse/concourse/issues/3201
            ( { model | fetchingHistory = False }, effects )

        _ ->
            ( model, effects )


buildName : String -> Maybe ( Int, Int )
buildName s =
    case String.split "." s |> List.map String.toInt of
        [ Just n ] ->
            Just ( n, 0 )

        [ Just n, Just m ] ->
            Just ( n, m )

        _ ->
            Nothing


handleBuildFetched : Int -> Concourse.Build -> ET (Model r)
handleBuildFetched browsingIndex b ( model, effects ) =
    if browsingIndex == model.browsingIndex then
        ( { model
            | history =
                List.Extra.setIf (.id >> (==) b.id)
                    { id = b.id
                    , name = b.name
                    , status = b.status
                    }
                    model.history
            , fetchingHistory = True
            , job = b.job
            , id = b.id
            , name = b.name
          }
        , effects
        )

    else
        ( model, effects )


handleHistoryFetched : Paginated Concourse.Build -> ET (Model r)
handleHistoryFetched history ( model, effects ) =
    let
        newModel =
            { model
                | history =
                    model.history
                        ++ (history.content
                                |> List.map
                                    (\b ->
                                        { id = b.id
                                        , name = b.name
                                        , status = b.status
                                        }
                                    )
                           )
                , nextPage = history.pagination.nextPage
                , fetchingHistory = False
            }
    in
    case model.job of
        Just job ->
            if List.member (historyItem model) newModel.history then
                ( newModel
                , effects ++ [ CheckIsVisible <| String.fromInt <| model.id ]
                )

            else
                ( { newModel | fetchingHistory = True }
                , effects ++ [ FetchBuildHistory job history.pagination.nextPage ]
                )

        _ ->
            ( newModel, effects )
