%%%----------------------------------------------------------------------
%%% File    : triviajabber_game.erl
%%% Author  : Phong C. <od06@htklabs.com>
%%% Purpose : game manager: each process handles each game
%%% Created : Apr 16, 2013
%%%
%%%

-module(triviajabber_game).
-author('od06@htklabs.com').

-behavior(gen_server).

%% API
-export([start_link/2]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).
%% helpers
-export([take_new_player/9, refresh_player/9,
         remove_old_player/1,
         current_question/1, get_answer/5,
         current_status/1, get_question_fifty/2,
         lifeline_fifty/3,
         lifeline_clair/3,
         lifeline_rollback/3
        ]).

-include("ejabberd.hrl").
-include("jlib.hrl").

-define(PROCNAME, ejabberd_triviapad_game).
-define(DEFAULT_MINPLAYERS, 1).
-define(READY, "no").
%%-define(KILLAFTER, 2000).
-define(DELAYNEXT1, 1500).
-define(DELAYNEXT2, 3000).
-define(REASONABLE, 5000).
-define(COUNTDOWNSTR, "Game is about to start. Please wait for other players to join.").

-record(gamestate, {host, slug, pool_id, time_start,
    questions, seconds, final_players, playersset,
    delay1, delay2, delaybetween, answerrightqueue, answerwrongqueue,
    maxplayers, minplayers = ?DEFAULT_MINPLAYERS, started = ?READY}).

%% when new player has joined game room,
%% check if there are enough players to start
handle_cast({joined, Slug, PoolId, NewComer}, #gamestate{
    host = Host, time_start = TimeStart,
    slug = Slug, pool_id = PoolId,
    questions = Questions, seconds = Seconds,
    final_players = Final, started = Started,
    maxplayers = MaxPlayers, minplayers = MinPlayers,
    answerrightqueue = RightQueue,
    answerwrongqueue = WrongQueue,
    playersset = PlayersState,
    delay1 = D1, delay2 = D2, delaybetween = D3}) ->
  ?WARNING_MSG("~p child knows [incoming] -> ~p, min ~p, final ~p",
      [self(), Slug, MinPlayers, Final+1]),
  triviajabber_scores:insert(Slug, NewComer, 0, 0, 0),
  NewMax = if
    Final + 1 > MaxPlayers -> (Final + 1);
    true -> MaxPlayers
  end, 
  case Started of
    "no" ->
       List = player_store:match_object({Slug, '_', '_', '_', '_', '_'}),
       NewStarted = if
         erlang:length(List) >= MinPlayers ->
           ?WARNING_MSG("new commer fills enough players to start game", []),
           triviajabber_question:insert(self(), 0, null, null, 0, null,
               null, null, null, null),
           will_send_question(Host, Slug, Seconds),
           "yes";
         true ->
           ?WARNING_MSG("still not enough players to start game", []),
           "no"
       end,
       
       NewState1 = #gamestate{
           host = Host, slug = Slug, time_start = TimeStart,
           questions = Questions, seconds = Seconds,
           pool_id = PoolId, final_players = Final+1,
           started = NewStarted, playersset = PlayersState,
           answerrightqueue = RightQueue,
           answerwrongqueue = WrongQueue,
           delay1 = D1, delay2 = D2, delaybetween = D3,
           maxplayers = NewMax, minplayers = MinPlayers},
       {noreply, NewState1};
    Yes ->  
      NewState3 = #gamestate{
          host = Host, slug = Slug, time_start = TimeStart,
          questions = Questions, seconds = Seconds,
          pool_id = PoolId, final_players = Final+1,
          started = Yes, playersset = PlayersState,
          answerrightqueue = RightQueue,
          answerwrongqueue = WrongQueue,
          delay1 = D1, delay2 = D2, delaybetween = D3,
          maxplayers = NewMax, minplayers = MinPlayers},
      {noreply, NewState3}
  end;

%% when one player has left
handle_cast({left, Slug}, #gamestate{
    host = Host, time_start = TimeStart,
    slug = Slug, pool_id = PoolId, playersset = PlayersState,
    answerrightqueue = RightQueue,
    answerwrongqueue = WrongQueue,
    questions = Questions, seconds = Seconds,
    final_players = Final, started = Started,
    delay1 = D1, delay2 = D2, delaybetween = D3,
    maxplayers = MaxPlayers, minplayers = MinPlayers}) ->
  ?WARNING_MSG("~p child knows [outcoming] <- ~p", [self(), Slug]),
  NewState =  #gamestate{host = Host,
      slug = Slug, pool_id = PoolId, time_start = TimeStart,
      questions = Questions, seconds = Seconds,
      final_players = Final-1, started = Started,
      delay1 = D1, delay2 = D2, delaybetween = D3,
      playersset = PlayersState,
      answerrightqueue = RightQueue,
      answerwrongqueue = WrongQueue,
      maxplayers = MaxPlayers, minplayers = MinPlayers},
  {noreply, NewState};
handle_cast({answer, Player, Answer, QuestionId, ClientTime}, #gamestate{
    host = Host, slug = Slug, time_start = TimeStart,
    questions = Questions, seconds = StrSeconds,
    pool_id = PoolId, final_players = Final,
    started = Started, maxplayers = MaxPlayers,
    delay1 = D1, delay2 = D2, delaybetween = D3,
    playersset = PlayersState,
    answerrightqueue = RightQueue,
    answerwrongqueue = WrongQueue,
    minplayers = MinPlayers} = State) ->
  case sets:is_element(Player, PlayersState) of
    false ->
      case triviajabber_question:match_object(
          {self(), '_', '_', QuestionId, '_', '_', '_', '_', '_', '_'}) of
        [{_Pid, _Question, Answer, QuestionId, Stamp1, _, _, _, _, _}] ->
          {NewRightQueue, NewPlayersState1} =
            case reasonable_hittime(Stamp1, ClientTime, StrSeconds) of
              "toolate" ->
                ?ERROR_MSG("late to give right answer", []),
                {RightQueue, PlayersState};
              "error" ->
                ?ERROR_MSG("reasonable_hittime1 ERROR", []),
                {RightQueue, PlayersState};
              {HitTimeY, reset} ->
                ?WARNING_MSG("(RR) right answer. hittime ~p",
                    [HitTimeY]),
                PlayersStatea = sets:del_element(Player, PlayersState),
                %% push into true queue
                NewRight1 = push_right_answer(RightQueue, Player, HitTimeY),
                statistic_answer(Slug, Answer),
                {NewRight1, PlayersStatea};
              {HitTimeX, no} ->
                ?WARNING_MSG("(RN) right answer. hittime ~p",
                    [HitTimeX]),
                PlayersStateb = sets:add_element(Player, PlayersState),
                %% push into true queue
                NewRight2 = push_right_answer(RightQueue, Player, HitTimeX),
                statistic_answer(Slug, Answer),
                {NewRight2, PlayersStateb}
            end,
          State1 = #gamestate{
              host = Host, slug = Slug, time_start = TimeStart,
              questions = Questions, seconds = StrSeconds,
              pool_id = PoolId, final_players = Final,
              started = Started, maxplayers = MaxPlayers,
              delay1 = D1, delay2 = D2, delaybetween = D3,
              playersset = NewPlayersState1,
              answerrightqueue = NewRightQueue,
              answerwrongqueue = WrongQueue,
              minplayers = MinPlayers},
          {noreply, State1};
        [{_Pid, _Question, A1, QuestionId, Stamp0, _, _, _, _, _}] ->
          {NewWrongQueue, NewPlayersState2} =
            case reasonable_hittime(Stamp0, ClientTime, StrSeconds) of
              "toolate" ->
                ?ERROR_MSG("late to give right answer", []),
                {WrongQueue, PlayersState};
              "error" ->
                ?ERROR_MSG("reasonable_hittime2 ERROR", []),
                {WrongQueue, PlayersState};
              {HitTime0X, reset} ->
                ?WARNING_MSG("(WR) wrong answer. Correct: ~p. hittime ~p",
                    [A1, HitTime0X]),
                PlayersSetd = sets:del_element(Player, PlayersState),
                %% push into wrong queue
                NewWrong1 = push_wrong_answer(WrongQueue, Player, HitTime0X),
                statistic_answer(Slug, Answer),
                {NewWrong1, PlayersSetd};
              {HitTime0Y, no} ->
                ?WARNING_MSG("(WN) wrong answer. Correct: ~p. hittime ~p",
                    [A1, HitTime0Y]),
                PlayersStatec = sets:add_element(Player, PlayersState),
                %% push into wrong queue
                NewWrong2 = push_wrong_answer(WrongQueue, Player, HitTime0Y),
                statistic_answer(Slug, Answer),
                {NewWrong2, PlayersStatec}
            end,
          State2 = #gamestate{
              host = Host, slug = Slug, time_start = TimeStart,
              questions = Questions, seconds = StrSeconds,
              pool_id = PoolId, final_players = Final,
              started = Started, maxplayers = MaxPlayers,
              delay1 = D1, delay2 = D2, delaybetween = D3,
              playersset = NewPlayersState2,
              answerrightqueue = RightQueue,
              answerwrongqueue = NewWrongQueue,
              minplayers = MinPlayers},
          {noreply, State2};
        [] ->
          ?WARNING_MSG("~p has answered late, but we dont count", [Player]),
          PlayersSet3 = sets:del_element(Player, PlayersState),
          State3 = #gamestate{
              host = Host, slug = Slug, time_start = TimeStart,
              questions = Questions, seconds = StrSeconds,
              pool_id = PoolId, final_players = Final,
              started = Started, maxplayers = MaxPlayers,
              delay1 = D1, delay2 = D2, delaybetween = D3,
              playersset = PlayersSet3,
              answerrightqueue = RightQueue,
              answerwrongqueue = WrongQueue,
              minplayers = MinPlayers},
          {noreply, State3};
        Ret ->
          ?WARNING_MSG("~p answered uncorrectly: ~p",
              [Player, Ret]),
          {noreply, State}
      end;
    true ->
      ?WARNING_MSG("~p answered, slug ~p doesnt handle more",
          [Player, Slug]),
      {noreply, State};
    Ret -> %% never reach here
      ?ERROR_MSG("onetime_answer(~p, ~p) = ~p",
          [Slug, Player, Ret]),
      {noreply, State}
  end;
handle_cast({rollback, Player}, #gamestate{
    host = Host, slug = Slug, time_start = TimeStart,
    questions = Questions, seconds = StrSeconds,
    pool_id = PoolId, final_players = Final,
    started = Started, maxplayers = MaxPlayers,
    delay1 = D1, delay2 = D2, delaybetween = D3,
    playersset = PlayersState,
    answerrightqueue = RightQueue,
    answerwrongqueue = WrongQueue,
    minplayers = MinPlayers}) ->
  %% remove from queue
  PlayersState1 = sets:del_element(Player, PlayersState),
  {RightQueue1, WrongQueue1} = pop_current_answer(RightQueue, WrongQueue, Player),
  State1 = #gamestate{
    host = Host, slug = Slug, time_start = TimeStart,
    questions = Questions, seconds = StrSeconds,
    pool_id = PoolId, final_players = Final,
    started = Started, maxplayers = MaxPlayers,
    delay1 = D1, delay2 = D2, delaybetween = D3,
    playersset = PlayersState1,
    answerrightqueue = RightQueue1,
    answerwrongqueue = WrongQueue1,
    minplayers = MinPlayers},
  {noreply, State1};
handle_cast(stop, State) ->
  {stop, normal, State};
handle_cast(Msg, State) ->
  ?WARNING_MSG("async msg: ~p\nstate ~p", [Msg, State]),
  {noreply, State}.

%% client request game status
handle_call(gamestatus, _From, #gamestate{
    host = _Host, slug = _Slug, time_start = _TimeStart,
    questions = Questions, seconds = _StrSeconds,
    pool_id = _PoolId, final_players = Final,
    started = _Started, maxplayers = _MaxPlayers, 
    delay1 = _D1, delay2 = _D2, delaybetween = _D3,
    playersset = _PlayersState,
    answerrightqueue = _RightQueue,
    answerwrongqueue = _WrongQueue,
    minplayers = _MinPlayers} = State) ->
  case triviajabber_question:lookup(self()) of
    {ok, _, Q, _, _, _, _QPhrase, _, _, _, _} ->
      QuestionNumStr = erlang:integer_to_list(Q),
      FinalStr = erlang:integer_to_list(Final),     
      {reply, {ok, QuestionNumStr, Questions, FinalStr}, State};
    Any ->
      {reply, Any, State}
  end;
%% handle lifeline:fifty
handle_call(fifty, _From, #gamestate{
    host = _Host, slug = _Slug, time_start = _TimeStart,
    questions = _Questions, seconds = _StrSeconds,
    pool_id = _PoolId, final_players = _Final,
    started = _Started, maxplayers = _MaxPlayers,
    delay1 = _D1, delay2 = _D2, delaybetween = _D3,
    playersset = _PlayersState,
    answerrightqueue = _RightQueue,
    answerwrongqueue = _WrongQueue,
    minplayers = _MinPlayers} = State) ->
  Reply = case triviajabber_question:lookup(self()) of
    {ok, _Pid, Question, AnswerId, _QuestionId, _Time, QPhrase,
        Opt1, Opt2, Opt3, Opt4} ->
      if
        Question > 0 ->
          {ok, Question, AnswerId, QPhrase, Opt1, Opt2, Opt3, Opt4};
        true ->
          {error, invalid_question}
      end;
    {null, not_found} ->
      {null, notfound};
    Ret ->
      {error, Ret}
  end,
  {reply, Reply, State};
%% handle lifeline:clairvoyance
handle_call(clair, _From, #gamestate{
    host = _Host, slug = Slug, time_start = _TimeStart,
    questions = _Questions, seconds = _StrSeconds,
    pool_id = _PoolId, final_players = _Final,
    started = _Started, maxplayers = _MaxPlayers,
    delay1 = _D1, delay2 = _D2, delaybetween = _D3,
    playersset = _PlayersState,
    answerrightqueue = _RightQueue,
    answerwrongqueue = _WrongQueue,
    minplayers = _MinPlayers} = State) ->
  Reply = case triviajabber_question:lookup(self()) of
    {ok, _, Question, _AnswerId, _QuesId, _Time, _QPhrase,
        _O1, _O2, _O3, _O4} ->
      ?WARNING_MSG("before dirty_read statistic of ~p question", [Question]),
      case triviajabber_statistic:lookup(Slug) of
        [] ->
          {ok, Question, 0, 0, 0, 0};
        {ok, O1, O2, O3, O4} ->
          {ok, Question, O1, O2, O3, O4};
        Hell ->
          ?ERROR_MSG("statistic HELL ~p", [Hell]),
          {ok, Question, -1, -1, -1, -1}
      end;
    {null, not_found} ->
      {null, notfound};
    {error, Any} ->
      {error, Any};
    Ret ->
      {error, Ret}
  end,
  ?WARNING_MSG("handled clair of ~p = ~p", [Slug, Reply]),
  {reply, Reply, State};
%% when module kills child because game room is empty
handle_call(stop, _From, State) ->
  ?WARNING_MSG("Stopping manager ...~nState:~p~n", [State]),
  {stop, normal, State}.

handle_info({sendstatusdelay, Packet}, #gamestate{
    host = Host, slug = Slug, time_start = _TimeStart,
    questions = _Questions, seconds = _StrSeconds,
    pool_id = _PoolId, final_players = _Final,
    started = _Started, maxplayers = _MaxPlayers,
    delay1 = _D1, delay2 = _D2, delaybetween = _D3,
    playersset = _PlayersState,
    answerrightqueue = _RightQueue,
    answerwrongqueue = _WrongQueue,
    minplayers = _MinPlayers} = State) ->
  List = mod_triviajabber:get_room_occupants(Host, Slug),
  lists:foreach(fun(To) ->
    GameServer = "triviajabber." ++ Host,
    From = jlib:make_jid(Slug, GameServer, Slug),
    ejabberd_router:route(From, To, Packet)
  end, List),
  {noreply, State};
handle_info({specialone, Player, Resource}, #gamestate{
    host = Host, slug = Slug, time_start = _TimeStart,
    questions = _Questions, seconds = StrSeconds,
    pool_id = _PoolId, final_players = _Final,
    started = _Started, maxplayers = _MaxPlayers,
    delay1 = _D1, delay2 = _D2, delaybetween = _D3,
    playersset = _PlayersState,
    answerrightqueue = _RightQueue,
    answerwrongqueue = _WrongQueue,
    minplayers = _MinPlayers} = State) ->
  CountdownPacket = {xmlelement, "message",
     [{"type", "status"}, {"id", randoms:get_string()}],
     [{xmlelement, "countdown",
         [{"secs", StrSeconds}],
         [{xmlcdata, ?COUNTDOWNSTR}]}]
  },
  To = jlib:make_jid(Player, Host, Resource),
  GameServer = "triviajabber." ++ Host,
  From = jlib:make_jid(Slug, GameServer, Slug),
  ejabberd_router:route(From, To, CountdownPacket),
  case string:to_integer(StrSeconds) of
    {Seconds, []} ->
      %% TODO: send zeroscores
      erlang:send_after((Seconds-5)*1000, self(), zeroscores),
      erlang:send_after(Seconds * 1000, self(), countdown);
    {RetSeconds, Reason} ->
      ?ERROR_MSG("Error0 to convert seconds to integer {~p, ~p}",
          [RetSeconds, Reason]);
    Ret ->
      ?ERROR_MSG("Error0 to convert seconds to integer ~p",
          [Ret])
  end,
  {noreply, State};
%% TODO: zeroscore before first question
handle_info(zeroscores, #gamestate{
    host = Host, slug = Slug, time_start = _TimeStart,
    questions = Questions, seconds = _StrSeconds,
    pool_id = _PoolId, final_players = _Final,
    started = _Started, maxplayers = _MaxPlayers,
    delay1 = _D1, delay2 = _D2, delaybetween = _D3,
    playersset = _PlayersState,
    answerrightqueue = _RightQueue,
    answerwrongqueue = _WrongQueue,
    minplayers = _MinPlayers} = State) ->
    case player_store:match_object({Slug, '_', '_', '_', '_', '_'}) of
      [] ->
        ok; %% nothing to do
      List when erlang:is_list(List) ->
        CurrentPlayers = current_players(List),
        RankItems = zeroscores_ranks([], CurrentPlayers),
        RankingZero = {xmlelement, "message",
            [{"type", "ranking"}, {"id", "0"}],
            [{xmlelement, "rank",
                [{"type", "game"},
                {"count", "0"},
                {"total", Questions}],
            RankItems
             }
            ]
        },
        lists:foreach(fun({CPlayer, CResource}) ->
            To = jlib:make_jid(CPlayer, Host, CResource),
            GameServer = "triviajabber." ++ Host,
            From = jlib:make_jid(Slug, GameServer, Slug),
            ejabberd_router:route(From, To, RankingZero)
        end, CurrentPlayers);
      Error ->
        ?ERROR_MSG("zeroscores:match ~p", [Error])
    end,
    {noreply, State};
handle_info(countdown, #gamestate{
    host = Host, slug = Slug, time_start = TimeStart,
    questions = Questions, seconds = StrSeconds,
    pool_id = PoolId, final_players = Final,
    started = Started, maxplayers = MaxPlayers,
    delay1 = D1, delay2 = D2, delaybetween = D3,
    playersset = PlayersState,
    answerrightqueue = RightQueue,
    answerwrongqueue = WrongQueue,
    minplayers = MinPlayers} = State) ->
  QuestionIds = question_ids(Host, PoolId, Questions),
  ?WARNING_MSG("from ~p (~p), list ~p", [Slug, Questions, QuestionIds]),
  case QuestionIds of
    [] ->
      ?ERROR_MSG("~p (~p) has no question after returning permutation",
          [Slug, PoolId]),
      triviajabber_statistic:delete(Slug),
      {stop, normal, State};
    [{UniqueQuestion}] ->
      send_status(Host, Slug, Final, Questions, 1),
      Delays0 = {D1, D2, D3},
      Rank1 = result_previous_question(Slug, Final, RightQueue, WrongQueue),
      send_question(Host, Delays0, Rank1, Questions,
          Slug, UniqueQuestion, StrSeconds, 1),
      next_question(D1+D2+D3, StrSeconds, [], 1),
      State1 = #gamestate{
        host = Host, slug = Slug, time_start = TimeStart,
        questions = Questions, seconds = StrSeconds,
        pool_id = PoolId, final_players = Final,
        started = Started, maxplayers = MaxPlayers,
        delay1 = D1, delay2 = D2, delaybetween = D3,
        playersset = PlayersState,
        answerrightqueue = queue:new(),
        answerwrongqueue = queue:new(),
        minplayers = MinPlayers},
      {noreply, State1};
    [{Head}|Tail] ->
      send_status(Host, Slug, Final, Questions, 1),
      Delays1 = {D1, D2, D3},
      Rank2 = result_previous_question(Slug, Final, RightQueue, WrongQueue),
      send_question(Host, Delays1, Rank2, Questions,
          Slug, Head, StrSeconds, 1),
      next_question(D1+D2+D3, StrSeconds, Tail, 2),
      State2 = #gamestate{
        host = Host, slug = Slug, time_start = TimeStart,
        questions = Questions, seconds = StrSeconds,
        pool_id = PoolId, final_players = Final,
        started = Started, maxplayers = MaxPlayers,
        delay1 = D1, delay2 = D2, delaybetween = D3,
        playersset = PlayersState,
        answerrightqueue = queue:new(),
        answerwrongqueue = queue:new(),
        minplayers = MinPlayers},
      {noreply, State2}
  end;
handle_info({questionslist, QuestionIds, Step}, #gamestate{
    host = Host, slug = Slug, time_start = TimeStart,
    pool_id = PoolId, questions = Questions,
    seconds = StrSeconds, final_players = Final,
    started = Started, maxplayers = MaxPlayers,
    delay1 = D1, delay2 = D2, delaybetween = D3,
    playersset = PlayersState,
    answerrightqueue = RightQueue,
    answerwrongqueue = WrongQueue,
    minplayers = MinPlayers} = State) ->
  case QuestionIds of
    [] ->
      Rank0 = result_previous_question(Slug, Final, RightQueue, WrongQueue),
      finish_game(Host, Slug, PoolId, Rank0, Step, Questions,
          TimeStart, MaxPlayers),
      {stop, normal, State};
    [{LastQuestion}] ->
      send_status_delay(D1 + D2 + 1000, Final, Questions, Step),
      Delays0 = {D1, D2, D3},
      Rank1 = result_previous_question(Slug, Final, RightQueue, WrongQueue),
      send_question(Host, Delays0, Rank1, Questions,
          Slug, LastQuestion, StrSeconds, Step),
      next_question(D1+D2+D3, StrSeconds, [], Step + 1),
      State1 = #gamestate{
        host = Host, slug = Slug, time_start = TimeStart,
        questions = Questions, seconds = StrSeconds,
        pool_id = PoolId, final_players = Final,
        started = Started, maxplayers = MaxPlayers,
        delay1 = D1, delay2 = D2, delaybetween = D3,
        playersset = PlayersState,
        answerrightqueue = queue:new(),
        answerwrongqueue = queue:new(),
        minplayers = MinPlayers},
      {noreply, State1};
    [{Head}|Tail] ->
      send_status_delay(D1 + D2 + 1000, Final, Questions, Step),
      Delays1 = {D1, D2, D3},
      Rank2 = result_previous_question(Slug, Final, RightQueue, WrongQueue),
      send_question(Host, Delays1, Rank2, Questions,
          Slug, Head, StrSeconds, Step),
      next_question(D1+D2+D3, StrSeconds, Tail, Step + 1),
      State2 = #gamestate{
        host = Host, slug = Slug, time_start = TimeStart,
        questions = Questions, seconds = StrSeconds,
        pool_id = PoolId, final_players = Final,
        started = Started, maxplayers = MaxPlayers,
        delay1 = D1, delay2 = D2, delaybetween = D3,
        playersset = PlayersState,
        answerrightqueue = queue:new(),
        answerwrongqueue = queue:new(),
        minplayers = MinPlayers},
      {noreply, State2}
  end;
handle_info({rankinggame, List, RankingGame}, #gamestate{
    host = Host, slug = Slug, time_start = _TimeStart,
    pool_id = _PoolId, questions = _Questions,
    seconds = _StrSeconds, final_players = _Final,
    started = _Started, maxplayers = _MaxPlayers,
    delay1 = _D1, delay2 = _D2, delaybetween = _D3,
    playersset = _PlayersState,
    answerrightqueue = _RightQueue,
    answerwrongqueue = _WrongQueue,
    minplayers = _MinPlayers} = State) ->
  ?WARNING_MSG("ranking-game ...", []),
  broadcast_msg(Host, Slug, List, RankingGame),
  {noreply, State};
handle_info({rankingquestion, List, RankingQuestion}, #gamestate{
    host = Host, slug = Slug, time_start = _TimeStart,
    pool_id = _PoolId, questions = _Questions,
    seconds = _StrSeconds, final_players = _Final,
    started = _Started, maxplayers = _MaxPlayers,
    delay1 = _D1, delay2 = _D2, delaybetween = _D3,
    playersset = _PlayersState,
    answerrightqueue = _RightQueue,
    answerwrongqueue = _WrongQueue,
    minplayers = _MinPlayers} = State) ->
  broadcast_msg(Host, Slug, List, RankingQuestion),
  {noreply, State};
handle_info({nextquestion, QLst, Qst, Step, Asw}, #gamestate{
    host = Host, slug = Slug, time_start = TimeStart,
    pool_id = PoolId, questions = Questions,
    seconds = StrSeconds, final_players = Final,
    delay1 = D1, delay2 = D2, delaybetween = D3,
    started = Started, maxplayers = MaxPlayers,
    playersset = _PlayersState,
    answerrightqueue = RightQueue,
    answerwrongqueue = WrongQueue,
    minplayers = MinPlayers}) ->
  MsgId = Slug ++ randoms:get_string(),
  QLstLen = erlang:length(QLst),
  {OptList, RevertOpts} = generate_opt_list(QLst, [], [], QLstLen),
  QuestionPacket = {xmlelement, "message",
      [{"type", "question"}, {"id", MsgId}],
      [{xmlelement, "question",
          [{"time", StrSeconds}], [{xmlcdata, Qst}]
       },
       {xmlelement, "answers",
          [], OptList
       }
      ]
  },
  %% reset playersstate.playersets for new question
  PlayersState1 = sets:new(),
  CurrentTime = get_timestamp(),
  SecretId = find_answer(OptList, Asw),
  ?WARNING_MSG("nextquestion ~p ... secret(~p) = ~p", [Step, Asw, SecretId]),
  [Opt1, Opt2, Opt3, Opt4] = RevertOpts,
  triviajabber_question:insert(self(), Step, SecretId, MsgId, CurrentTime, Qst,
      Opt1, Opt2, Opt3, Opt4),
  List = player_store:match_object({Slug, '_', '_', '_', '_', '_'}),
  broadcast_msg(Host, Slug, List, QuestionPacket),
  State1 = #gamestate{
    host = Host, slug = Slug, time_start = TimeStart,
    pool_id = PoolId, questions = Questions,
    seconds = StrSeconds, final_players = Final,
    delay1 = D1, delay2 = D2, delaybetween = D3,
    started = Started, maxplayers = MaxPlayers,
    playersset = PlayersState1,
    answerrightqueue = RightQueue,
    answerwrongqueue = WrongQueue,
    minplayers = MinPlayers},
  {noreply, State1};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(Reason, #gamestate{
      slug = Slug, playersset = _PlayersState,
      answerrightqueue = _RightQueue,
      answerwrongqueue = _WrongQueue}) ->
  Pid = self(),
  ?WARNING_MSG("terminate ~p(~p):\n~p", [Pid, Slug, Reason]),
  triviajabber_statistic:delete(Slug),
  triviajabber_scores:match_delete({Slug, '_', '_', '_', '_'}),
  recycle_game(Pid, Slug),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

start_link(Host, Opts) ->
  Slug = gen_mod:get_opt(slug, Opts, ""),
  %% each child has each process name ejabberd_triviapad_game_<Slug>
  Proc = gen_mod:get_module_proc(Slug, ?PROCNAME),
  gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

init([Host, Opts]) ->
  RightQueue = queue:new(),
  WrongQueue = queue:new(),
  PlayersState = sets:new(),

  Slug = gen_mod:get_opt(slug, Opts, ""),
  triviajabber_statistic:delete(Slug),
  triviajabber_scores:match_delete({Slug, '_', '_', '_', '_'}),

  MinPlayers = gen_mod:get_opt(minplayers, Opts, 1),
  PoolId = gen_mod:get_opt(pool_id, Opts, 1),
  Questions = gen_mod:get_opt(questions, Opts, 0),
  Seconds = gen_mod:get_opt(seconds, Opts, -1),
  FirstPlayer = gen_mod:get_opt(player, Opts, ""),
  Delay1 = gen_mod:get_opt(delay1, Opts, 5000),
  Delay2 = gen_mod:get_opt(delay2, Opts, 5000),
  Delayb = gen_mod:get_opt(delaybetween, Opts, 5000),
  ?WARNING_MSG("@@@ child ~p processes {~p, ~p, ~p, ~p}",
      [self(), Slug, PoolId, Questions, Seconds]),
  triviajabber_scores:insert(Slug, FirstPlayer, 0, 0, 0),

  Started = if
    MinPlayers =:= 1 ->
      triviajabber_question:insert(self(), 0, null, null, 0, null,
          null, null, null, null),
      Resource = gen_mod:get_opt(resource, Opts, ""),
      erlang:send_after(?DELAYNEXT1, self(), {specialone, FirstPlayer, Resource}),
      "yes";
    true ->
      triviajabber_question:insert(self(), -1, null, null, 0, null,
          null, null, null, null),
      "no"
  end,
  {ok, #gamestate{
      host = Host, time_start = erlang:universaltime(),
      slug = Slug, pool_id = PoolId,
      questions = Questions, seconds = Seconds,
      final_players = 1, minplayers = MinPlayers,
      maxplayers = 1, delay1 = Delay1,
      delay2 = Delay2, delaybetween = Delayb,
      playersset = PlayersState,
      answerrightqueue = RightQueue,
      answerwrongqueue = WrongQueue,
      started = Started}
  }.

%%% ------------------------------------
%%% Game manager is notified when
%%% player has joined/left.
%%% ------------------------------------

%% New player has joined game room (slug)
%% If there's no process handle this game, create new one.
take_new_player(Host, Slug, PoolId, Player, Resource,
    Questions, Seconds, MinPlayers, DelayComplex) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, PoolId, Pid} ->
      ?INFO_MSG("B. <notify> process ~p: someone joined  ~p", [Pid, Slug]),
      gen_server:cast(Pid, {joined, Slug, PoolId, Player}),
      ok;
    {null, not_found} ->
      {Delay1, Delay2, Delayb} = DelayComplex,
      Opts = [{slug, Slug}, {pool_id, PoolId},
              {questions, Questions}, {seconds, Seconds},
              {player, Player}, {resource, Resource},
              {minplayers, MinPlayers}, {delay1, Delay1},
              {delay2, Delay2}, {delaybetween, Delayb}],
      {ok, Pid} = start_link(Host, Opts),
      ?INFO_MSG("C. new process ~p handles ~p", [Pid, Opts]),
      triviajabber_store:insert(Slug, PoolId, Pid),
      ok;
    {error, Any} ->
      ?ERROR_MSG("D. [player joined] lookup : ~p", [Any]);
    Error ->
      ?ERROR_MSG("E. [player joined] lookup : ~p", [Error])  
  end.
%% Player disconnected. Player has connected again to continue game.
refresh_player(Host, Slug, PoolId, Player, Resource,
    Questions, Seconds, MinPlayers, DelayComplex) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, PoolId, Pid} ->
      ?WARNING_MSG("B2. process ~p: someone continues ~p", [Pid, Slug]),
      ok;
    {null, not_found} ->
    %% bad case: after reconnect, game has terminated.
    %% you start over the game.
      {Delay1, Delay2, Delayb} = DelayComplex,
      Opts = [{slug, Slug}, {pool_id, PoolId},
              {questions, Questions}, {seconds, Seconds},
              {player, Player}, {resource, Resource},
              {minplayers, MinPlayers}, {delay1, Delay1},
              {delay2, Delay2}, {delaybetween, Delayb}],
      {ok, Pid} = start_link(Host, Opts),
      ?INFO_MSG("C2. new process ~p handles ~p", [Pid, Opts]),
      triviajabber_store:insert(Slug, PoolId, Pid),
      ok;
    {error, Any} ->
      ?ERROR_MSG("D2. [player joined] lookup : ~p", [Any]);
    Error ->
      ?ERROR_MSG("E2. [player joined] lookup : ~p", [Error])
  end.
%% Old player joined game room (slug),
%% After he requested, he has left.
remove_old_player(Slug) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, _PoolId, Pid} ->
      case player_store:match_object({Slug, '_', '_', '_', '_', '_'}) of
        [] ->
          ?WARNING_MSG("idle process ~p", [Pid]);
          %% kill empty slug in 1500 miliseconds
          %%erlang:send_after(?KILLAFTER, Pid, killafter);
        Res ->
          ?WARNING_MSG("sync notify ~p", [Res]),
          gen_server:cast(Pid, {left, Slug})
      end;
    {null, not_found} ->
      ?ERROR_MSG("there no process to handle ~p", [Slug]),
      ok;
    {error, Any} ->
      ?ERROR_MSG("[player left] lookup : ~p", [Any]);
    Error ->
      ?ERROR_MSG("[player left] lookup : ~p", [Error])
  end.


%% Using 50%-lifeline
lifeline_fifty(Slug, Player, Resource) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, _PoolId, Pid} ->
      case player_store:match_object({Slug, Player, Resource, '_', '_', '_'}) of
        [{Slug, Player, Resource, Fifty, Clair, Rollback}] ->
          if
            Fifty > 0 ->
              player_store:match_delete({Slug, Player, Resource, '_', '_', '_'}),
              player_store:insert(Slug, Player, Resource, Fifty-1, Clair, Rollback),
              lifeline_fifty_call(Pid, Slug);
            true ->
              {failed, Slug, "you used lifeline:fifty"}
          end;
        Ret ->
          ?ERROR_MSG("many resources of player joined ~p", [Ret]),
          {failed, Slug, "many resources of player joined in game"}
      end;
    {null, not_found} ->
       {failed, Slug, "game havent started"};
    {error, _} ->
       {failed, Slug, "failed to find game thread"}
  end.

lifeline_clair(Slug, Player, Resource) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, _PoolId, Pid} ->
      case player_store:match_object({Slug, Player, Resource, '_', '_', '_'}) of
        [{Slug, Player, Resource, Fifty, Clair, Rollback}] ->
          if
            Clair > 0 ->
              player_store:match_delete({Slug, Player, Resource, '_', '_', '_'}),
              player_store:insert(Slug, Player, Resource, Fifty, Clair-1, Rollback),
              lifeline_clair_call(Pid, Slug);
            true ->
              {failed, Slug, "you used lifeline:clairvoyance"}
          end;
        ManyRes ->
          ?ERROR_MSG("many resources of player joined ~p", [ManyRes]),
          {failed, Slug, "many resources of player joined in game"}
      end;
    {null, not_found} ->
      {failed, Slug, "game havent started"};
    {error, _} ->
      {failed, Slug, "failed to find game thread"};
    Ret ->
      ?ERROR_MSG("lifeline_clair ~p", [Ret]),
      {failed, Slug, "failed to lookup thread"}
  end.

lifeline_rollback(Slug, Player, Resource) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, _PoolId, Pid} ->
      case player_store:match_object({Slug, Player, Resource, '_', '_', '_'}) of
        [{Slug, Player, Resource, Fifty, Clair, Rollback}] ->
          if
            Rollback > 0 ->
              player_store:match_delete({Slug, Player, Resource, '_', '_', '_'}),
              player_store:insert(Slug, Player, Resource, Fifty, Clair, Rollback-1),
              %% child handles lifeline:rollback asynchronously
              gen_server:cast(Pid, {rollback, Player}),
              {ok, Slug, "another chance"};
            true ->
              {failed, Slug, "you used lifeline:rollback"}
          end;
        ManyRes ->
          ?ERROR_MSG("many resources of player joined ~p", [ManyRes]),
          {failed, Slug, "many resources of player joined in game"}
      end;
    {null, not_found} ->
      {failed, Slug, "game havent started"};
    {error, _} ->
      {failed, Slug, "failed to find game thread"};
    Ret ->
      ?ERROR_MSG("lifeline_clair ~p", [Ret]),
      {failed, Slug, "failed to lookup thread"}
  end.

% get_current_question
current_question(Slug) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, _PoolId, Pid} ->
      case triviajabber_question:lookup(Pid) of
        {ok, _Pid, Question, _Answer, _QuestionId, _Time, _QPhrase,
            _, _, _, _} ->
          {ok, Question};
        {null, not_found} ->
          {null, notfound};
        Ret ->
          {error, Ret}
      end;
    {null, not_found} ->
      {failed, null};
    Error ->
      ?ERROR_MSG("find pid of slug ~p: ~p", [Slug, Error]),
      {error, Error}
  end.

current_status(Slug) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, _PoolId, Pid} ->
      try
        {ok, Question, Total, Players} =
            gen_server:call(Pid, gamestatus),
        {ok, Question, Total, Players}
      catch
        EClass:Exc ->
          ?ERROR_MSG("Exception: ~p, ~p", [EClass, Exc]),
          {exception, EClass, Exc}
      end;
    {null, not_found} ->
      {failed, noprocess};
    Error ->
      ?ERROR_MSG("find pid of slug ~p: ~p", [Slug, Error]),
      {error, Error}
  end.

%% check answer from player
get_answer(Player, Slug, Answer, ClientTime, QuestionId) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, _PoolId, Pid} ->
      case string:to_integer(ClientTime) of
        {ClientInt, []} ->
          gen_server:cast(Pid, {answer, Player, Answer, QuestionId, ClientInt});
        {RetSeconds, Reason} ->
          ?ERROR_MSG("Error3 to convert seconds to integer {~p, ~p}",
              [RetSeconds, Reason]);
        Ret ->
          ?ERROR_MSG("Error3 to convert seconds to integer ~p",
              [Ret])
      end;
    {null, not_found} ->
      ?ERROR_MSG("there's no process handle ~p", [Slug]);
    Error ->
      ?ERROR_MSG("there's no process handle ~p: ~p",
          [Slug, Error])
  end.

%%% ------------------------------------
%%% Request child handle lifeline
%%% ------------------------------------    

lifeline_fifty_call(Pid, Slug) ->
  try gen_server:call(Pid, fifty) of
    {null, notfound} ->
      {failed, Slug, "question havent been sent"};
    {error, Unknown} ->
      ?ERROR_MSG("fifty, error ~p", [Unknown]),
      {failed, Slug, "not found question"};
    {ok, Question, AnswerIdStr, QPhrase, Opt1, Opt2, Opt3, Opt4} ->
      {Random1, Random2} = take_two_opts(AnswerIdStr, Opt1, Opt2, Opt3, Opt4),
      {ok, Question, QPhrase, Random1, Random2};
    ErrorRet ->
      ?ERROR_MSG("triviajabber_question:lookup ~p", [ErrorRet]),
      {failed, Slug, "unknown error"}
  catch
    EClass:Exc ->
      ?ERROR_MSG("Exception: ~p, ~p", [EClass, Exc]),
      {failed, Slug, "exception"}
  end.

lifeline_clair_call(Pid, Slug) ->
  try gen_server:call(Pid, clair) of
    {null, notfound} ->
      {failed, Slug, "question havent been sent"};
    {error, Unknown} ->
      ?ERROR_MSG("fifty, error ~p", [Unknown]),
      {failed, Slug, "not found question"};
    {ok, Question, O1, O2, O3, O4} ->
      {ok, Question, O1, O2, O3, O4};
    WhattheHell ->
      ?ERROR_MSG("HELL clair ~p", [WhattheHell]),
      {failed, Slug, "hellraiser"}
  catch
    EClass:Exc ->
      ?ERROR_MSG("Exception: ~p, ~p", [EClass, Exc]),
      {failed, Slug, "exception"}
  end.

%%% ------------------------------------
%%% Child handles a game
%%% ------------------------------------

%% send countdown chat message when there are enough players
will_send_question(Server, Slug, StrSeconds) ->
  CountdownPacket = {xmlelement, "message",
     [{"type", "status"}, {"id", randoms:get_string()}],
     [{xmlelement, "countdown",
         [{"secs", StrSeconds}],
         [{xmlcdata, ?COUNTDOWNSTR}]}]
  },
  case string:to_integer(StrSeconds) of
    {Seconds, []} ->
      List = player_store:match_object({Slug, '_', '_', '_', '_', '_'}),
      lists:foreach(
        fun({_, Player, Resource, _, _, _}) ->
          To = jlib:make_jid(Player, Server, Resource),
          GameServer = "triviajabber." ++ Server,
          From = jlib:make_jid(Slug, GameServer, Slug),
          ejabberd_router:route(From, To, CountdownPacket)
        end,
      List),
      %% TODO: send zeroscores
      erlang:send_after((Seconds-5)*1000, self(), zeroscores),
      erlang:send_after(Seconds * 1000, self(), countdown);
    {RetSeconds, Reason} ->
      ?ERROR_MSG("Error1 to convert seconds to integer {~p, ~p}",
          [RetSeconds, Reason]);
    Ret ->
      ?ERROR_MSG("Error1 to convert seconds to integer ~p",
          [Ret])
  end.

send_status(Server, Slug, Final, Questions, Step) ->
  List = mod_triviajabber:get_room_occupants(Server, Slug),
  MsgId = "status-game" ++ randoms:get_string(),
  WhichQuestion = erlang:integer_to_list(Step),
  Players = erlang:integer_to_list(Final),
  Packet = {xmlelement, "message",
      [{"type", "status"}, {"id", MsgId}],
      [{xmlelement, "status",
          [{"question", WhichQuestion},
           {"total", Questions},
           {"players", Players}],
          []
       }
      ]
  },
  ?WARNING_MSG("@@@@@ send_status(~p, ~p)", [Slug, Step]),
  lists:foreach(fun(To) ->
    GameServer = "triviajabber." ++ Server,
    From = jlib:make_jid(Slug, GameServer, Slug),
    ejabberd_router:route(From, To, Packet)
  end, List).
%% delay status after ranking, before new question
send_status_delay(Delays, Final, Questions, Step) ->
  MsgId = "status-game" ++ randoms:get_string(),
  WhichQuestion = erlang:integer_to_list(Step),
  Players = erlang:integer_to_list(Final),
  Packet = {xmlelement, "message",
      [{"type", "status"}, {"id", MsgId}],
      [{xmlelement, "status",
          [{"question", WhichQuestion},
           {"total", Questions},
           {"players", Players}],
          []
       }
      ]
  },
  erlang:send_after(Delays, self(), {sendstatusdelay, Packet}).

%% send first question
%% TODO ? add delay ?
send_question(Server, _Delays, _, _, Slug,
    QuestionId, Seconds, 1) ->
  case get_question_info(Server, QuestionId) of
    {ok, Qst, Asw, QLst} ->
      MsgId = Slug ++ randoms:get_string(),
      QLstLen = erlang:length(QLst),
      {OptList, RevertOpts} = generate_opt_list(QLst, [], [], QLstLen),
      QuestionPacket = {xmlelement, "message",
        [{"type", "question"}, {"id", MsgId}],
        [{xmlelement, "question",
            [{"time", Seconds}], [{xmlcdata, Qst}]
         },
         {xmlelement, "answers",
            [], OptList
         }
        ]
      },
      %% set first question,
      CurrentTime = get_timestamp(),
      SecretId = find_answer(OptList, Asw),
      ?WARNING_MSG("store secret1 ~p", [SecretId]),
      [Opt1, Opt2, Opt3, Opt4] = RevertOpts,
      triviajabber_question:insert(self(), 1, SecretId, MsgId, CurrentTime, Qst,
          Opt1, Opt2, Opt3, Opt4),
      %% broadcast first question
      List = player_store:match_object({Slug, '_', '_', '_', '_', '_'}),
      lists:foreach(fun({_, Player, Resource, _, _, _}) ->
        To = jlib:make_jid(Player, Server, Resource),
        GameServer = "triviajabber." ++ Server,
        From = jlib:make_jid(Slug, GameServer, Slug),
        ejabberd_router:route(From, To, QuestionPacket)
      end, List);
    _ ->
      error
  end;
%% send question to all player in slug
%% TODO add 2 delays
send_question(Server, Delays, Rank, Questions, Slug,
    QuestionId, _Seconds, Step) ->
  case get_question_info(Server, QuestionId) of
    {ok, Qst, Asw, QLst} ->
      Random = randoms:get_string(),
      Prev = Step - 1,
      PreviousQuestionStep = erlang:integer_to_list(Prev),
      MsgQId = "ranking-question" ++ Random,
      RankingQuestion = {xmlelement, "message",
        [{"type", "ranking"}, {"id", MsgQId}],
        [{xmlelement, "rank",
            [{"type", "question"},
             {"count", PreviousQuestionStep},
             {"total", Questions}],
            Rank
         }
        ]
      },

      AnswerIdStr = case triviajabber_question:lookup(self()) of
        {ok, _, Prev, AnswerId, _QuestionId, _TimeStamp, _QPhrase,
            _Opt1, _Opt2, _Opt3, _Opt4} ->
          AnswerId;
        {ok, _, BugStep, Answ, _QuestionId, _TimeStamp, _QPhrase,
            _Opt1, _Opt2, _Opt3, _Opt4} ->
          ?ERROR_MSG("Bug: step = ~p", [BugStep]),
          Answ;
        {null, not_found} ->
          ?ERROR_MSG("Bug: not found question in ETS", []),
          "0";
        {error, Any} ->
          ?ERROR_MSG("Bug: ~p", [Any]),
          "0"
      end,     
      RevealPacket = {xmlelement, "message",
        [{"type", "reveal"}, {"id", "reveal" ++ Random}],
        [{xmlelement, "option",
            [{"id", AnswerIdStr}, {"question", PreviousQuestionStep}],
            []
         }
        ]
      },
      
      List = player_store:match_object({Slug, '_', '_', '_', '_', '_'}),
      %% broacast reveal message
      broadcast_msg(Server, Slug, List, RevealPacket),
      {Delay1, Delay2, Delayb} = Delays,
      %% delay to return rankingquestion
      erlang:send_after(Delay1, self(),
          {rankingquestion, List, RankingQuestion}),
      RGame = update_scoreboard(Slug, List, []),
      MaxPos = erlang:length(List),
      SortScoreboard = scoreboard_items(RGame, [], MaxPos),
      ?WARNING_MSG("scoreboard_items ~p", [SortScoreboard]),
      MsgGId = "ranking-game" ++ Random,
      RankingGame = {xmlelement, "message",
        [{"type", "ranking"}, {"id", MsgGId}],
        [{xmlelement, "rank",
            [{"type", "game"},
             {"count", PreviousQuestionStep},
             {"total", Questions}],
            SortScoreboard
         }
        ]
      },
      %% delay to return rankinggame
      erlang:send_after(Delay1+Delay2, self(),
          {rankinggame, List, RankingGame}),
      %% delay to broadcast next question
      erlang:send_after(Delay1+Delay2+Delayb, self(),
          {nextquestion, QLst, Qst, Step, Asw});
    _ ->
      error
  end.

broadcast_msg(Server, Slug, List, Packet) ->
  lists:foreach(fun({_, Player, Resource, _, _, _}) ->
    To = jlib:make_jid(Player, Server, Resource),
    GameServer = "triviajabber." ++ Server,
    From = jlib:make_jid(Slug, GameServer, Slug),
    ejabberd_router:route(From, To, Packet)
  end, List).

%% how people answered current question
statistic_answer(Slug, AnswerIdStr) ->
  {Opt1, Opt2, Opt3, Opt4} = case triviajabber_statistic:lookup(Slug) of
    {ok, O1, O2, O3, O4} ->
      {O1, O2, O3, O4};
    Any ->
      ?WARNING_MSG("triviajabber_statistic(~p): ~p", [Slug, Any]),
      {0, 0, 0, 0}
  end,
  {U1, U2, U3, U4} = statistic_update(AnswerIdStr,
    Opt1, Opt2, Opt3, Opt4),
  ?INFO_MSG("triviajabber_statistic(~p) insert {~p, ~p, ~p, ~p}",
      [Slug, U1, U2, U3, U4]),
  triviajabber_statistic:insert(Slug, U1, U2, U3, U4).

statistic_update("1", Opt1, Opt2, Opt3, Opt4) ->
  {Opt1+1, Opt2, Opt3, Opt4};
statistic_update("2", Opt1, Opt2, Opt3, Opt4) ->
  {Opt1, Opt2+1, Opt3, Opt4};
statistic_update("3", Opt1, Opt2, Opt3, Opt4) ->
  {Opt1, Opt2, Opt3+1, Opt4};
statistic_update("4", Opt1, Opt2, Opt3, Opt4) ->
  {Opt1, Opt2, Opt3, Opt4+1};
statistic_update(AnswerIdStr, Opt1, Opt2, Opt3, Opt4) ->
  ?ERROR_MSG("dont know answer ~p of question", [AnswerIdStr]),
  {Opt1, Opt2, Opt3, Opt4}.

%% push right answer
push_right_answer(RightQueue, Player, HitTime) ->
  ?INFO_MSG("push_right(~p, ~p)", [Player, HitTime]),
  queue:in({Player, HitTime}, RightQueue).

%% push wrong answer
push_wrong_answer(WrongQueue, Player, HitTime) ->
  ?INFO_MSG("push_wrong(~p, ~p)", [Player, HitTime]),
  queue:in({Player, HitTime}, WrongQueue).

%% pop current answer
pop_current_answer(RightQueue, WrongQueue, Player) ->
  Answer0List = queue:to_list(WrongQueue),
  FiltedList = filter_list_answer(Player, Answer0List),
  if
    FiltedList == Answer0List ->
      NewRightQueue = filter_right_queue(RightQueue, Answer0List),
      {NewRightQueue, WrongQueue};
    true ->
      NewWrongQueue = queue:from_list(FiltedList),
      {RightQueue, NewWrongQueue}
  end.

filter_list_answer(Player, List) ->
  lists:filter(fun({Name, _Hit}) ->
    if
      Name =:= Player -> false;
      true -> true
    end
  end, List).

filter_right_queue(RightQueue, Player) ->
  Answer1List = queue:to_list(RightQueue),
  FiltedList = filter_list_answer(Player, Answer1List),
  if
    FiltedList == Answer1List ->
      RightQueue;
    true ->
      queue:from_list(FiltedList)
  end.

%% result of previous question
result_previous_question(Slug, Final, RightQueue, WrongQueue) ->
  %% get 2 queues
  {Plus, PosRanking} = positive_scores(RightQueue, Final, [], 1),
  {Minus, NegRanking} = negative_scores(WrongQueue, Final, [], 1),
  ?INFO_MSG("minus = ~p, ranking: ~p", [Minus, NegRanking]),
  Ranking = prepend_scores(PosRanking, NegRanking),
  %?INFO_MSG("plus = ~p, minus = ~p \n ranking: ~p", [Plus, Minus, Ranking]),
  PlayersTag = update_score(Slug, Ranking, [], Plus+Minus),
  ?INFO_MSG("playerstag: ~p", [PlayersTag]),
  triviajabber_statistic:delete(Slug),
  PlayersTag.

%% next question will be sent in seconds
next_question(Delays, StrSeconds, Tail, Step) ->
  case string:to_integer(StrSeconds) of
    {Seconds, []} ->
      erlang:send_after(Seconds * 1000 + Delays, self(),
          {questionslist, Tail, Step});
    {RetSeconds, Reason} ->
      ?ERROR_MSG("Error to convert seconds to integer {~p, ~p}",
          [RetSeconds, Reason]);
    Ret ->
      ?ERROR_MSG("Error to convert seconds to integer ~p",
          [Ret])
  end.

finish_game(Server, Slug, _PoolId, _Rank, 1, _Questions,
    TimeStart, MaxPlayers) ->
  LastId = traverse_scoresstate1(Server, TimeStart, Slug, MaxPlayers),
  if
    LastId > 0 ->
      Last = erlang:integer_to_list(LastId),
      GameCounterStr = "game-" ++ Slug ++ "-" ++ Last,
      traverse_scoresstate2(Slug, Server, GameCounterStr);
    true ->
      ?ERROR_MSG("Slug ~p insert row into games table returning ~p", [LastId])
  end;
finish_game(Server, Slug, PoolId, Rank, Step, Questions,
    TimeStart, MaxPlayers) ->
  ?WARNING_MSG("game ~p (pool ~p) finished",
      [Slug, PoolId]),
  %% update score after game has finished
  PreviousQuestionStep = erlang:integer_to_list(Step-1),
  Random = randoms:get_string(),
  MsgQId = "ranking-question" ++ Random,
  RankingQuestion = {xmlelement, "message",
      [{"type", "ranking"}, {"id", MsgQId}],
      [{xmlelement, "rank",
          [{"type", "question"},
           {"count", PreviousQuestionStep},
           {"total", Questions}],
          Rank
       }
      ]
  },

  List = player_store:match_object({Slug, '_', '_', '_', '_', '_'}),
  %% then broadcast result previous question
  broadcast_msg(Server, Slug, List, RankingQuestion),
  MsgGId = "ranking-game" ++ Random,
  RGame = update_scoreboard(Slug, List, []),
  MaxPos = erlang:length(List),
  SortScoreboard = scoreboard_items(RGame, [], MaxPos),
  ?WARNING_MSG("scoreboard_items0 ~p", [SortScoreboard]),
  RankingGame = {xmlelement, "message",
      [{"type", "ranking"}, {"id", MsgGId}],
      [{xmlelement, "rank",
          [{"type", "game"},
           {"count", PreviousQuestionStep},
           {"total", Questions}],
          SortScoreboard
       }
      ]
  },
  broadcast_msg(Server, Slug, List, RankingGame),
  LastId = traverse_scoresstate1(Server, TimeStart, Slug, MaxPlayers),
  if
    LastId > 0 ->
      Last = erlang:integer_to_list(LastId),
      GameCounterStr = "game-" ++ Slug ++ "-" ++ Last,
      traverse_scoresstate2(Slug, Server, GameCounterStr);
    true ->
      ?ERROR_MSG("Slug ~p insert row into games table returning ~p", [LastId])
  end.

%% store_score;
%% return {maxscore, totalscore};
%% save in MySql
traverse_scoresstate1(Server, TimeStart, Slug, MaxPlayers) ->
  {Date, Time} = TimeStart,
  {Day, Month, Year} = Date,
  {_, Week} = calendar:iso_week_number({Day,Month,Year}),
  Raddress = "room-" ++ Slug,
  Iterator =  fun(Rec, {Max, Total})->
    {_, Player, Score, Hits, Responses} = Rec,
    %% redis store_scores
    ?WARNING_MSG("store_scores ~p: ~p, ~p, ~p", [Player, Score, Hits, Responses]),
    RedisData = {Score, Hits, Responses},
    case RedisData of
      {0, 0, 0} ->
        ok; %% dont have to update
      _ ->
        Alltime = Raddress ++ "-alltime",
        redis_store_scores_alltime(Server, Alltime, Player, RedisData),
        Yearly = Raddress ++ "-year:" ++ erlang:integer_to_list(Year),
        redis_store_scores_alltime(Server, Yearly, Player, RedisData),
        Monthly = Raddress ++ "-month:" ++ erlang:integer_to_list(Month),
        redis_store_scores_alltime(Server, Monthly, Player, RedisData),
        Weekly = Raddress ++ "-week:" ++ erlang:integer_to_list(Week),
        redis_store_scores_alltime(Server, Weekly, Player, RedisData),
        Daily = Raddress ++ "-day:" ++ erlang:integer_to_list(Day),
        redis_store_scores_alltime(Server, Daily, Player, RedisData)
    end,
    NewMax = if
      Score > Max -> Score;
      true -> Max
    end,
    {NewMax, Total + Score}
  end,

  case triviajabber_scores:match_object({Slug, '_', '_', '_', '_'}) of
    List when erlang:is_list(List) ->
      {WinnerScore, TotalScore} = lists:foldl(Iterator, {0, 0}, List),
      ?WARNING_MSG("triviajabber_games: ~p, ~p, ~p, ~p",
          [Slug, MaxPlayers, WinnerScore, TotalScore]),
      mod_triviajabber:games_table(Server, Date, Time, Slug,
          MaxPlayers, WinnerScore, TotalScore);
    Error ->
      ?ERROR_MSG("triviajabber_scores:match1: ~p", [Error]),
      -6
  end.

%% store_game
traverse_scoresstate2(Slug, Server, GameCounterStr) ->
  Iterator =  fun(Rec, _) ->
    {_, Player, Score, Hits, Responses} = Rec,
    RedisData = {Score, Hits, Responses},
    case RedisData of
      {0, 0, 0} ->
        ok; %% dont have to update
      _ ->
        redis_store_game(Server, GameCounterStr, Player, RedisData)
    end,
    []
  end,
  case triviajabber_scores:match_object({Slug, '_', '_', '_', '_'}) of
    List when erlang:is_list(List) ->
      lists:foldl(Iterator, [], List);
    Error ->
      ?ERROR_MSG("triviajabber_scores:match2 ~p", [Error])
  end.

recycle_game(Pid, Slug) ->
  player_store:match_delete({Slug, '_', '_', '_', '_', '_'}),
  triviajabber_store:delete(Slug),
  triviajabber_question:delete(Pid).

% [
%  {xmlelement, "option", [{"id", "1"}], [{xmlcdata, "White"}]},
%  {xmlelement, "option", [{"id", "2"}], [{xmlcdata, "Black"}]},
%  {xmlelement, "option", [{"id", "3"}], [{xmlcdata, "White with black dots"}]}
%  {xmlelement, "option", [{"id", "4"}], [{xmlcdata, "Brown"}]},
% ]
generate_opt_list([], Ret1, Ret2, _) ->
  {Ret1, Ret2};
generate_opt_list([Head|Tail], Ret1, Ret2, Count) ->
  CountStr = erlang:integer_to_list(Count),
  AddOne = {xmlelement, "answer",
      [{"id", CountStr}],
      [{xmlcdata, Head}]},
  generate_opt_list(Tail, [AddOne|Ret1], [Head|Ret2], Count-1).

%% get permutation of question_id from pool
question_ids(Server, PoolId, Questions) ->
  if
    Questions > 0 ->
      try ejabberd_odbc:sql_query(Server,
          ["select id from triviajabber_questions "
           "where pool_id='", PoolId, "' order by rand() "
           "limit ", Questions]) of
        {selected, ["id"], []} ->
          ?ERROR_MSG("pool_id ~p has no question", [PoolId]),
          [];
        {selected, ["id"], QuestionsList}
            when erlang:is_list(QuestionsList) ->
          QuestionsList;
        Error ->
          ?ERROR_MSG("pool_id ~p failed to generate ~p questions: ~p",
              [PoolId, Questions, Error]),
          []
      catch
        Res2:Desc2 ->
          ?ERROR_MSG("Exception when random question_id from pool: ~p, ~p",
              [Res2, Desc2]),
          []
      end;
    true ->
      []
  end.
%% get question info by question_id,
%% permutate options to sent to players
get_question_info(Server, QuestionId) ->
  try ejabberd_odbc:sql_query(Server,
      ["select question, answer, option1, option2, option3 "
       "from triviajabber_questions where id='", QuestionId, "'"]) of
    {selected, ["question", "answer", "option1", "option2", "option3"],
        []} ->
      ?ERROR_MSG("Query question info: Empty", []),
      empty;
    {selected, ["question", "answer", "option1", "option2", "option3"],
        [{Q, A, O1, O2, O3}]} ->
      List = permutation:permute([A, O1, O2, O3]),
      {ok, Q, A, List};
    Res ->
      ?ERROR_MSG("Query question ~p failed: ~p", [QuestionId, Res]),
      error
  catch
    Res2:Desc2 ->
      ?ERROR_MSG("Exception when get question (~p) info: ~p, ~p",
          [QuestionId, Res2, Desc2]),
      error
  end.

get_question_fifty(Server, QuestionId) ->
  try ejabberd_odbc:sql_query(Server,
      ["select question, answer, option1, option2, option3 "
       "from triviajabber_questions where id='", QuestionId, "'"]) of
    {selected, ["question", "answer", "option1", "option2", "option3"],
        []} ->
      ?ERROR_MSG("Query question info: Empty", []),
      empty;
    {selected, ["question", "answer", "option1", "option2", "option3"],
        [{Q, A, O1, O2, O3}]} ->
      [HeadO| _Tail] = permutation:permute([O1, O2, O3]),
      {ok, Q, A, HeadO}; %% question, answer, option
    Res ->
      ?ERROR_MSG("Query question ~p failed: ~p", [QuestionId, Res]),
      error
  catch
    Res2:Desc2 ->
      ?ERROR_MSG("Exception when get question (~p) info: ~p, ~p",
          [QuestionId, Res2, Desc2]),
      error
  end.

take_two_opts(AnswerIdStr, Opt1, Opt2, Opt3, Opt4) ->
  {_, _, Micro} = erlang:now(),
  Rem = Micro rem 3,
  two_opts(AnswerIdStr, Rem, Opt1, Opt2, Opt3, Opt4).
%% 1st option is correct
two_opts("1", Rem, Opt1, Opt2, Opt3, Opt4) ->
  case Rem of
    0 ->
      {{1, Opt1}, {2, Opt2}};
    1 ->
      {{1, Opt1}, {3, Opt3}};
    2 ->
      {{1, Opt1}, {4, Opt4}}
  end;
%% 2nd option is correct
two_opts("2", Rem, Opt1, Opt2, Opt3, Opt4) ->
  case Rem of
    0 ->
      {{1, Opt1}, {2, Opt2}};
    1 ->
      {{2, Opt2}, {3, Opt3}};
    2 ->
      {{2, Opt2}, {4, Opt4}}
  end;
%% 3rd option is correct
two_opts("3", Rem, Opt1, Opt2, Opt3, Opt4) ->
  case Rem of
    0 ->
      {{1, Opt1}, {3, Opt3}};
    1 ->
      {{2, Opt2}, {3, Opt3}};
    2 ->
      {{3, Opt3}, {4, Opt4}}
  end;
%% 4th option is correct
two_opts("4", Rem, Opt1, Opt2, Opt3, Opt4) ->
  case Rem of
    0 ->
      {{1, Opt1}, {4, Opt4}};
    1 ->
      {{2, Opt2}, {4, Opt4}};
    2 ->
      {{3, Opt3}, {4, Opt4}}
  end;
two_opts(Bug, _, Opt1, Opt2, _, _) ->
  ?ERROR_MSG("Cannot have option ~p", [Bug]),
  {{1, Opt1}, {2, Opt2}}.

get_timestamp() ->
  {Mega,Sec,Micro} = erlang:now(),
  MegaSeconds = (Mega*1000000+Sec)*1000000+Micro,
  MegaSeconds div 1000.

reasonable_hittime(ServerStamp, ClientTime, StrSeconds) ->
  case string:to_integer(StrSeconds) of
    {Seconds, []} ->
      ServerTime = get_timestamp() - ServerStamp,
      Gap = ServerTime - ClientTime,
      if
        Gap > 0, Gap < ?REASONABLE ->
          Reset = if
            ServerTime >= Seconds*1000 ->
              reset;
            true ->
              no
          end,
          %% ClientTime is less than ServerTime,
          %% but it's reasonable.
          ?WARNING_MSG("server ~p, reasonable ~p, reset?~p",
              [ServerTime, ClientTime, Reset]),
          {ClientTime, Reset};
        Gap > 0 ->
          %% ClientTime is too small,
          %% it's unreasonable.
          if
            ServerTime > Seconds + ?REASONABLE ->
              "toolate";
            true ->           
              {ServerTime, no}
          end;
        true ->
          ?WARNING_MSG("How servertime < clienttime???", []),
          {ServerTime, no}
      end;
    {RetSeconds, Reason} ->
      ?ERROR_MSG("Error1 to convert seconds to integer {~p, ~p}",
          [RetSeconds, Reason]),
      "error";
    Ret ->
      ?ERROR_MSG("Error2 to convert seconds to integer ~p",
          [Ret]),
      "error"
  end.

positive_scores(Queue, Final, Ret, Position) ->
  case queue:is_empty(Queue) of
    true ->
      {Position-1, Ret};
    false ->
      Score = Final / Position,
      {{value, {Player, HitTime}}, Tail} = queue:out(Queue),
      Add = {Player, HitTime, erlang:round(Score)},
      positive_scores(Tail, Final, [Add|Ret], Position+1);
    _ ->
      {Position-1, Ret}
  end.

negative_scores(Queue, Final, Ret, Position) ->
  case queue:is_empty(Queue) of
    true ->
      {Position-1, Ret};
    false ->
      Score = Final / (Position * -2),
      {{value, {Player, HitTime}}, Tail} = queue:out(Queue),
      Add = {Player, HitTime, erlang:round(Score)},
      negative_scores(Tail, Final, [Add|Ret], Position+1);
    _ ->
      {Position-1, Ret}
  end.

prepend_scores(MergeRanking, []) ->
  MergeRanking;
prepend_scores(PosRanking, [Head|Tails]) ->
  prepend_scores([Head|PosRanking], Tails).

update_score(_, [], Ret, _) ->
  Ret;
update_score(Slug, [{Player, Time, Score}|Tail], Ret, DecPos) ->
  {Gap, Response} = if
    Score > 0 ->
      {1, 1}; %% one hit, one response
    Score < 0 ->
      {0, 1}; %% no hit, one response
    true ->
      {0, 0} %% no hit, no response
  end,
  ?INFO_MSG("update_score(~p, ~p, ~p, ~p)", [Player, Time, Score, DecPos]),
  case triviajabber_scores:match_object({Slug, Player, '_', '_', '_'}) of
    [] ->
      triviajabber_scores:insert(Slug, Player, Score, Gap, Response),
      update_score(Slug, Tail, Ret, DecPos);
    [{_, _, OldScores, OldHits, OldResponses}] ->
      triviajabber_scores:match_delete({Slug, Player, '_', '_', '_'}),
      GameScore = if %% only show positive score
        OldScores + Score > 0 ->
          OldScores + Score;
        true ->
          0
      end,
      NewHit = OldHits + Gap,
      NewRes = OldResponses + Response,
      triviajabber_scores:insert(Slug, Player, GameScore, NewHit, NewRes),
      ?WARNING_MSG("update_score(~p, ~p, hit:~p, res:~p) = ~p",
          [Player, Score, NewHit, NewRes, GameScore]),
      AddTag = questionranking_player_tag(
          Player, Time, DecPos, Score),
      update_score(Slug, Tail, [AddTag|Ret], DecPos-1);
    List when erlang:is_list(List) ->
      ?WARNING_MSG("Many ~p in scoresstate: ~p", [Player, List]),
      {SumScores, SumHits, SumResponses} =
          sameplayers(List, {0, 0, 0}),
      triviajabber_scores:match_delete({Slug, Player, '_', '_', '_'}),
      GameScore2 = if %% only show positive score
        SumScores + Score > 0 ->
          SumScores + Score;
        true ->
          0
      end,
      NewHit2 = SumHits + Gap,
      NewRes2 = SumResponses + Response,
      triviajabber_scores:insert(Slug, Player, GameScore2, NewHit2, NewRes2),
      ?WARNING_MSG("update_score2(~p, ~p, hit:~p, res:~p) = ~p",
          [Player, Score, NewHit2, NewRes2, GameScore2]),
      AddTag2 = questionranking_player_tag(
          Player, Time, DecPos, Score),
      update_score(Slug, Tail, [AddTag2|Ret], DecPos-1);
    Other ->
      ?ERROR_MSG("Found ~p in scoresstate: ~p", [Player, Other]),
      update_score(Slug, Tail, Ret, DecPos)
  end.

%% get all players from player_store,
%% we reset playersstate, player can answer new question.
%% So we cant get all players by playersstate.playersets
update_scoreboard(_Slug, [], Ret) ->
  lists:keysort(2, Ret);
update_scoreboard(Slug, [Head|Tail], Acc) ->
  {_Slug, Player, _Resource, _, _, _} = Head,
  Add = case triviajabber_scores:match_object({Slug, Player, '_', '_', '_'}) of
    [] ->
      ?WARNING_MSG("triviajabber_scores didnt see ~p",
          [Player]),
      {Player, 0};
    [{_, _, Score, _Hit, _Res}] ->
      {Player, Score};
    Ret2 ->
      ?ERROR_MSG("triviajabber_scores(~p): ~p", [Player, Ret2]),
      {Player, 0}
  end,
  ?WARNING_MSG("get_scoreboard : add ~p", [Add]),
  update_scoreboard(Slug, Tail, [Add|Acc]).

questionranking_player_tag(Nickname, Time, Pos, Score) ->
  {xmlelement, "player",
      [{"nickname", Nickname},
       {"score", erlang:integer_to_list(Score)},
       {"pos", erlang:integer_to_list(Pos)},
       {"time", erlang:integer_to_list(Time)}
      ],
      []
  }.

scoreboard_items([], Ret, _) ->
  Ret;
scoreboard_items([Head|Tail], Ret, Pos) ->
  {Player, Score} = Head,
  Add = {xmlelement, "player",
      [{"nickname", Player},
       {"score", erlang:integer_to_list(Score)},
       {"pos", erlang:integer_to_list(Pos)}
      ],
      []
  },
  scoreboard_items(Tail, [Add|Ret], Pos-1).

%% return answer option id (string)
find_answer([], _) ->
  ?ERROR_MSG("!! Not found answer in permutation !!", []),
  "0";
find_answer([Head|Tail], Asw) ->
  case Head of
    {xmlelement, "answer",
        [{"id", CountStr}],
        [{xmlcdata, Asw}]} ->
      CountStr;
    _ ->
      find_answer(Tail, Asw)
  end.

%% get all currents players in slug
current_players(List) ->
  lists:map(fun(Item) ->
    {_Slug, Player, Resource, _Fifty, _Clair, _Rollback} = Item,
    {Player, Resource}
  end, List).

zeroscores_ranks(ZeroRanks, []) ->
  ZeroRanks;
zeroscores_ranks(ZeroRanks, [{Player, _Resource}|Rest]) ->
  NewRank = {xmlelement, "player",
      [{"nickname", Player},
       {"score", "0"}
      ],
      []
  },
  zeroscores_ranks([NewRank|ZeroRanks], Rest).
  

%% if someone went out and joined again, server doesn't recognize immediately.
%% So there are many same players in triviajabber_scores, we count as one player.
sameplayers([], {Scores, Hits, Responses}) ->
  {Scores, Hits, Responses};
sameplayers([Head|Tail], {Scores, Hits, Responses}) ->
  {_, _, OneScore, OneHit, OneResponse} = Head,
  sameplayers(Tail, {Scores + OneScore,
      Hits + OneHit, Responses + OneResponse}).

%% redis_store_scores
redis_store_scores_alltime(Server, Alltime, Player, RedisData) ->
  {Score, Hits, Responses} = RedisData,
  mod_triviajabber:redis_zincrby(Server, Alltime, Score, Player),
  AlltimeNick = Alltime ++ ":" ++ Player,
  mod_triviajabber:redis_hincrby(Server, AlltimeNick, "hits", Hits),
  mod_triviajabber:redis_hincrby(Server, AlltimeNick, "responses", Responses),
  mod_triviajabber:redis_hincrby(Server, AlltimeNick, "gplayed", 1),
  ok.

redis_store_game(Server, GameCounterStr, Player, RedisData) ->
  {Score, Hits, Responses} = RedisData,
  mod_triviajabber:redis_zadd(Server, GameCounterStr, Score, Player),
  GameCounterNick = GameCounterStr ++ ":" ++ Player,
  mod_triviajabber:redis_hmset(Server, GameCounterNick, Hits, Responses),
  ok.
