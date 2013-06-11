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
-export([take_new_player/8, remove_old_player/1,
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
-define(KILLAFTER, 2000).
-define(DELAYNEXT1, 1500).
-define(DELAYNEXT2, 3000).
-define(REASONABLE, 5000).
-define(COUNTDOWNSTR, "Game is about to start. Please wait for other players to join.").

-record(gamestate, {host, slug, pool_id, time_start,
    questions, seconds, final_players, maxplayers,
    minplayers = ?DEFAULT_MINPLAYERS, started = ?READY}).
-record(answer1state, {slug, rightqueue}).
-record(answer0state, {slug, wrongqueue}).
%% how players have answer current question
-record(statistic, {slug, opt1, opt2, opt3, opt4}).
%% set of players who have answered current question
-record(playersstate, {slug, playersets}).
%% score, hits, responses of player in current game
-record(scoresstate, {player, score, hits, responses}).

%% when new player has joined game room,
%% check if there are enough players to start
handle_cast({joined, Slug, PoolId, NewComer}, #gamestate{
    host = Host, time_start = TimeStart,
    slug = Slug, pool_id = PoolId,
    questions = Questions, seconds = Seconds,
    final_players = Final, started = Started,
    maxplayers = MaxPlayers, minplayers = MinPlayers}) ->
  ?WARNING_MSG("~p child knows [incoming] -> ~p, min ~p, final ~p",
      [self(), Slug, MinPlayers, Final+1]),
  mnesia:dirty_write(#scoresstate{
      player = NewComer,
      score = 0, hits = 0,
      responses = 0
  }),
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
           started = NewStarted,
           maxplayers = NewMax, minplayers = MinPlayers},
       {noreply, NewState1};
    Yes ->  
      NewState3 = #gamestate{
          host = Host, slug = Slug, time_start = TimeStart,
          questions = Questions, seconds = Seconds,
          pool_id = PoolId, final_players = Final+1,
          started = Yes,
          maxplayers = NewMax, minplayers = MinPlayers},
      {noreply, NewState3}
  end;

%% when one player has left
handle_cast({left, Slug}, #gamestate{
    host = Host, time_start = TimeStart,
    slug = Slug, pool_id = PoolId,
    questions = Questions, seconds = Seconds,
    final_players = Final, started = Started,
    maxplayers = MaxPlayers, minplayers = MinPlayers}) ->
  ?WARNING_MSG("~p child knows [outcoming] <- ~p", [self(), Slug]),
  NewState =  #gamestate{host = Host,
      slug = Slug, pool_id = PoolId, time_start = TimeStart,
      questions = Questions, seconds = Seconds,
      final_players = Final-1, started = Started,
      maxplayers = MaxPlayers, minplayers = MinPlayers},
  {noreply, NewState};
handle_cast({answer, Player, Answer, QuestionId, ClientTime}, #gamestate{
    host = _Host, slug = Slug, time_start = _TimeStart,
    questions = _Questions, seconds = StrSeconds,
    pool_id = _PoolId, final_players = _Final,
    started = _Started, maxplayers = _MaxPlayers, 
    minplayers = _MinPlayers} = State) ->
  case onetime_answer(Slug, Player) of
    {atomic, true} ->
% using questionstate
      case triviajabber_question:match_object(
          {self(), '_', '_', QuestionId, '_', '_', '_', '_', '_', '_'}) of
        [{_Pid, _Question, Answer, QuestionId, Stamp1, _, _, _, _, _}] ->
          case reasonable_hittime(Stamp1, ClientTime, StrSeconds) of
            "toolate" ->
              ?ERROR_MSG("late to give right answer", []);
            "error" ->
              ?ERROR_MSG("reasonable_hittime1 ERROR", []);
            {HitTimeY, reset} ->
              ?WARNING_MSG("(RR) right answer. hittime ~p",
                  [HitTimeY]),
              onetime_delelement(Slug, Player),
              %% push into true queue
              push_right_answer(Slug, Player, HitTimeY),
              statistic_answer(Slug, Answer);
            {HitTimeX, no} ->
              ?WARNING_MSG("(RN) right answer. hittime ~p",
                  [HitTimeX]),
              %% push into true queue
              push_right_answer(Slug, Player, HitTimeX),
              statistic_answer(Slug, Answer)
          end;
        [{_Pid, _Question, A1, QuestionId, Stamp0, _, _, _, _, _}] ->
          case reasonable_hittime(Stamp0, ClientTime, StrSeconds) of
            "toolate" ->
              ?ERROR_MSG("late to give right answer", []);
            "error" ->
              ?ERROR_MSG("reasonable_hittime2 ERROR", []);
            {HitTime0X, reset} ->
              ?WARNING_MSG("(WR) wrong answer. Correct: ~p. hittime ~p",
                  [A1, HitTime0X]),
              onetime_delelement(Slug, Player),
              %% push into wrong queue
              push_wrong_answer(Slug, Player, HitTime0X),
              statistic_answer(Slug, Answer);
            {HitTime0Y, no} ->
              ?WARNING_MSG("(WN) wrong answer. Correct: ~p. hittime ~p",
                  [A1, HitTime0Y]),
              %% push into wrong queue
              push_wrong_answer(Slug, Player, HitTime0Y),
              statistic_answer(Slug, Answer)
          end;
        [] ->
          ?WARNING_MSG("~p has answered late, but we dont count", [Player]),
          onetime_delelement(Slug, Player);
        Ret ->
          ?WARNING_MSG("~p answered uncorrectly: ~p",
              [Player, Ret])
      end;
    {atomic, false} ->
      ?WARNING_MSG("~p answered, slug ~p doesnt handle more",
          [Player, Slug]);
    Ret -> %% never reach here
      ?ERROR_MSG("onetime_answer(~p, ~p) = ~p",
          [Slug, Player, Ret])
  end,
  {noreply, State};
handle_cast({rollback, Player}, #gamestate{
    host = _Host, slug = Slug, time_start = _TimeStart,
    questions = _Questions, seconds = _StrSeconds,
    pool_id = _PoolId, final_players = _Final,
    started = _Started, maxplayers = _MaxPlayers,
    minplayers = _MinPlayers} = State) ->
  %% remove from queue
  onetime_delelement(Slug, Player),
  pop_current_answer(Slug, Player),
  {noreply, State};
handle_cast(Msg, State) ->
  ?WARNING_MSG("async msg: ~p\nstate ~p", [Msg, State]),
  {noreply, State}.

%% client request game status
handle_call(gamestatus, _From, #gamestate{
    host = _Host, slug = _Slug, time_start = _TimeStart,
    questions = Questions, seconds = _StrSeconds,
    pool_id = _PoolId, final_players = Final,
    started = _Started, maxplayers = _MaxPlayers, 
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
    minplayers = _MinPlayers} = State) ->
  Reply = case triviajabber_question:lookup(self()) of
    {ok, _, Question, _AnswerId, _QuesId, _Time, _QPhrase,
        _O1, _O2, _O3, _O4} ->
      ?WARNING_MSG("before dirty_read statistic of ~p question", [Question]),
      case mnesia:dirty_read(statistic, Slug) of
        [] ->
          {ok, Question, 0, 0, 0, 0};
        [E] ->
          #statistic{slug = _, opt1 = O1,
              opt2 = O2, opt3 = O3, opt4 = O4} = E,
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

handle_info({specialone, Player, Resource}, #gamestate{
    host = Host, slug = Slug, time_start = _TimeStart,
    questions = _Questions, seconds = StrSeconds,
    pool_id = _PoolId, final_players = _Final,
    started = _Started, maxplayers = _MaxPlayers,
    minplayers = _MinPlayers} = State) ->
  CountdownPacket = {xmlelement, "message",
     [{"type", "chat"}, {"id", randoms:get_string()}],
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
      erlang:send_after(Seconds * 1000, self(), countdown);
    {RetSeconds, Reason} ->
      ?ERROR_MSG("Error0 to convert seconds to integer {~p, ~p}",
          [RetSeconds, Reason]);
    Ret ->
      ?ERROR_MSG("Error0 to convert seconds to integer ~p",
          [Ret])
  end,
  {noreply, State};
handle_info(countdown, #gamestate{
    host = Host, slug = Slug, time_start = _TimeStart,
    questions = Questions, seconds = StrSeconds,
    pool_id = PoolId, final_players = Final,
    started = _Started, maxplayers = _MaxPlayers,
    minplayers = _MinPlayers} = State) ->
  QuestionIds = question_ids(Host, PoolId, Questions),
  ?WARNING_MSG("from ~p (~p), list ~p", [Slug, Questions, QuestionIds]),
  case QuestionIds of
    [] ->
      ?ERROR_MSG("~p (~p) has no question after returning permutation",
          [Slug, PoolId]),
      {stop, normal, State};
    [{UniqueQuestion}] ->
      send_status(Host, Slug, Final, Questions, 1),
      send_question(Host, Final, Questions,
          Slug, UniqueQuestion, StrSeconds, 1),
      next_question(StrSeconds, [], 1),
      {noreply, State};
    [{Head}|Tail] ->
      send_status(Host, Slug, Final, Questions, 1),
      send_question(Host, Final, Questions,
          Slug, Head, StrSeconds, 1),
      next_question(StrSeconds, Tail, 2),
      {noreply, State}
  end;
handle_info({questionslist, QuestionIds, Step}, #gamestate{
    host = Host, slug = Slug, time_start = TimeStart,
    pool_id = PoolId, questions = Questions,
    seconds = StrSeconds, final_players = Final,
    started = _Started, maxplayers = MaxPlayers,
    minplayers = _MinPlayers} = State) ->
  case QuestionIds of
    [] ->
      finish_game(Host, Slug, PoolId, Final, Step, Questions,
          TimeStart, MaxPlayers),
      {stop, normal, State};
    [{LastQuestion}] ->
      send_status(Host, Slug, Final, Questions, Step),
      send_question(Host, Final, Questions,
          Slug, LastQuestion, StrSeconds, Step),
      next_question(StrSeconds, [], Step + 1),
      {noreply, State};
    [{Head}|Tail] ->
      send_status(Host, Slug, Final, Questions, Step),
      send_question(Host, Final, Questions,
          Slug, Head, StrSeconds, Step),
      next_question(StrSeconds, Tail, Step + 1),
      {noreply, State}
  end;
handle_info({rankinggame, List, RankingGame}, #gamestate{
    host = Host, slug = Slug, time_start = _TimeStart,
    pool_id = _PoolId, questions = _Questions,
    seconds = _StrSeconds, final_players = _Final,
    started = _Started, maxplayers = _MaxPlayers,
    minplayers = _MinPlayers} = State) ->
  ?WARNING_MSG("ranking-game ...", []),
  broadcast_msg(Host, Slug, List, RankingGame),
  {noreply, State};
handle_info({nextquestion, QLst, Qst, Step, Asw}, #gamestate{
    host = Host, slug = Slug, time_start = _TimeStart,
    pool_id = _PoolId, questions = _Questions,
    seconds = StrSeconds, final_players = _Final,
    started = _Started, maxplayers = _MaxPlayers,
    minplayers = _MinPlayers} = State) ->
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
  mnesia:clear_table(playersstate),
  CurrentTime = get_timestamp(),
  SecretId = find_answer(OptList, Asw),
  ?WARNING_MSG("nextquestion ~p ... secret(~p) = ~p", [Step, Asw, SecretId]),
  [Opt1, Opt2, Opt3, Opt4] = RevertOpts,
  triviajabber_question:insert(self(), Step, SecretId, MsgId, CurrentTime, Qst,
      Opt1, Opt2, Opt3, Opt4),
  List = player_store:match_object({Slug, '_', '_', '_', '_', '_'}),
  broadcast_msg(Host, Slug, List, QuestionPacket),
  {noreply, State};
handle_info(killafter, #gamestate{
    host = Host, slug = Slug, time_start = TimeStart,
    pool_id = PoolId, questions = Questions,
    seconds = _StrSeconds, final_players = Final,
    started = Started, maxplayers = MaxPlayers,
    minplayers = _MinPlayers} = State) ->
  if
    Started =:= "yes", Questions > 0 ->
      finish_game(Host, Slug, PoolId, Final, 1, Questions,
          TimeStart, MaxPlayers);
    true ->
      %% Don't update Redis when game hasn't been started
      ok
  end,
%%  recycle_game(self(), Slug),
  {stop, normal, State};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(Reason, #gamestate{
      slug = Slug}) ->
  Pid = self(),
  ?WARNING_MSG("terminate ~p(~p): ~p", [Pid, Slug, Reason]),
  mnesia:delete_table(answer1state),
  mnesia:delete_table(answer0state),
  mnesia:delete_table(statistic),
  mnesia:delete_table(playersstate),
  mnesia:delete_table(scoresstate),
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
  mnesia:create_table(answer1state, [{attributes,
      record_info(fields, answer1state)}]),
  mnesia:clear_table(answer1state),
  mnesia:create_table(answer0state, [{attributes,
      record_info(fields, answer0state)}]),
  mnesia:clear_table(answer0state),
  mnesia:create_table(statistic, [{attributes,
      record_info(fields, statistic)}]),
  mnesia:clear_table(statistic),
  mnesia:create_table(playersstate, [{attributes,
      record_info(fields, playersstate)}]),
  mnesia:clear_table(playersstate),
  mnesia:create_table(scoresstate, [{attributes,
      record_info(fields, scoresstate)}]),
  mnesia:clear_table(scoresstate),

  Slug = gen_mod:get_opt(slug, Opts, ""),
  MinPlayers = gen_mod:get_opt(minplayers, Opts, 1),
  PoolId = gen_mod:get_opt(pool_id, Opts, 1),
  Questions = gen_mod:get_opt(questions, Opts, 0),
  Seconds = gen_mod:get_opt(seconds, Opts, -1),
  FirstPlayer = gen_mod:get_opt(player, Opts, ""),
  ?WARNING_MSG("@@@ child ~p processes {~p, ~p, ~p, ~p}",
      [self(), Slug, PoolId, Questions, Seconds]),
  mnesia:dirty_write(#scoresstate{
      player = FirstPlayer,
      score = 0, hits = 0,
      responses = 0
  }),

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
      maxplayers = 1,
      started = Started}
  }.

%%% ------------------------------------
%%% Game manager is notified when
%%% player has joined/left.
%%% ------------------------------------

%% New player has joined game room (slug)
%% If there's no process handle this game, create new one.
take_new_player(Host, Slug, PoolId, Player, Resource,
    Questions, Seconds, MinPlayers) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, PoolId, Pid} ->
      ?WARNING_MSG("B. <notify> process ~p: someone joined  ~p", [Pid, Slug]),
      gen_server:cast(Pid, {joined, Slug, PoolId, Player}),
      ok;
    {null, not_found} ->
      Opts = [{slug, Slug}, {pool_id, PoolId},
              {questions, Questions}, {seconds, Seconds},
              {player, Player}, {resource, Resource},
              {minplayers, MinPlayers}],
      {ok, Pid} = start_link(Host, Opts),
      ?WARNING_MSG("C. new process ~p handles ~p", [Pid, Opts]),
      triviajabber_store:insert(Slug, PoolId, Pid),
      ok;
    {error, Any} ->
      ?ERROR_MSG("D. [player joined] lookup : ~p", [Any]);
    Error ->
      ?ERROR_MSG("E. [player joined] lookup : ~p", [Error])  
  end.
%% Old player joined game room (slug),
%% After he requested, he has left.
remove_old_player(Slug) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, _PoolId, Pid} ->
      case player_store:match_object({Slug, '_', '_', '_', '_', '_'}) of
        [] ->
          ?WARNING_MSG("manager ~p kills idle process ~p", [self(), Pid]),
          %% kill empty slug in 1500 miliseconds
          erlang:send_after(?KILLAFTER, Pid, killafter);
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
     [{"type", "chat"}, {"id", randoms:get_string()}],
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
  lists:foreach(fun(To) ->
    GameServer = "triviajabber." ++ Server,
    From = jlib:make_jid(Slug, GameServer, Slug),
    ejabberd_router:route(From, To, Packet)
  end, List).

%% send first question
send_question(Server, _, _, Slug,
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
send_question(Server, Final, Questions, Slug,
    QuestionId, _Seconds, Step) ->
  case get_question_info(Server, QuestionId) of
    {ok, Qst, Asw, QLst} ->
      Random = randoms:get_string(),
      
      PreviousQuestionStep = erlang:integer_to_list(Step-1),
      MsgQId = "ranking-question" ++ Random,
      RankingQuestion = {xmlelement, "message",
        [{"type", "ranking"}, {"id", MsgQId}],
        [{xmlelement, "rank",
            [{"type", "question"},
             {"count", PreviousQuestionStep},
             {"total", Questions}],
            result_previous_question(Slug, Final)
         }
        ]
      },
      
      List = player_store:match_object({Slug, '_', '_', '_', '_', '_'}),
      %% then broadcast result previous question
      broadcast_msg(Server, Slug, List, RankingQuestion),
      
      RGame = update_scoreboard(List, []),
      SortScoreboard = scoreboard_items(RGame, []),
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
      erlang:send_after(?DELAYNEXT1, self(),
          {rankinggame, List, RankingGame}),
      %% delay to broadcast next question
      erlang:send_after(?DELAYNEXT2, self(),
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

onetime_delelement(Slug, Player) ->
  Fun = fun() ->
    case mnesia:read(playersstate, Slug) of
      [] ->
        ?ERROR_MSG("onetime_delelement: slug ~p is empty", [Slug]);
      [E] ->
        Playersets = E#playersstate.playersets,
        NewSets = sets:del_element(Player, Playersets),
        mnesia:write(#playersstate{
            slug = Slug,
            playersets = NewSets
        });
      Ret ->
        ?ERROR_MSG("onetime_delelement: slug ~p, error ~p", [Slug, Ret])
    end
  end,
  mnesia:transaction(Fun).

%% check one answer for one player
onetime_answer(Slug, Player) ->
  Fun = fun() ->
    case mnesia:read(playersstate, Slug) of
      [] ->
        Reset = sets:new(),
        mnesia:write(#playersstate{
            slug = Slug,
            playersets = sets:add_element(Player, Reset)
        }),
        true; 
      [E] ->
        Playersets = E#playersstate.playersets,
        case sets:is_element(Player, Playersets) of
          true ->
            false;
          false ->
            NewSets = sets:add_element(Player, Playersets),
            mnesia:write(#playersstate{
              slug = Slug,
              playersets = NewSets
            }),
            true;
          Ret ->
            ?WARNING_MSG("sets:is_element(~p) = ~p", [Player, Ret]), 
            false
        end;
      Ret ->
        ?ERROR_MSG("playersstate keeps ~p", [Ret]),
        mnesia:write(#playersstate{
            slug = Slug,
            playersets = sets:new()
        }),
        true
    end
  end,
  mnesia:transaction(Fun).

%% how people answered current question
statistic_answer(Slug, AnswerIdStr) ->
  Fun = fun() ->
    {Opt1, Opt2, Opt3, Opt4} =
      case mnesia:read(statistic, Slug) of
        [] ->
          {0, 0, 0, 0};
        [E] ->
          #statistic{slug = _, opt1 = O1,
              opt2 = O2, opt3 = O3, opt4 = O4} = E,
          {O1, O2, O3, O4}
      end,
    {U1, U2, U3, U4} = statistic_update(AnswerIdStr,
        Opt1, Opt2, Opt3, Opt4),
    ?WARNING_MSG("statistic ~p, ~p, ~p, ~p", [U1, U2, U3, U4]),
    mnesia:write(#statistic{
        slug = Slug,
        opt1 = U1, opt2 = U2,
        opt3 = U3, opt4 = U4
    })
  end,
  mnesia:transaction(Fun).

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
push_right_answer(Slug, Player, HitTime) ->
  ?WARNING_MSG("push_right(~p, ~p)", [Player, HitTime]),
  Fun = fun() ->
    NewQu = case mnesia:read(answer1state, Slug) of
      [] ->
        Reset = queue:new(),
        queue:in({Player, HitTime}, Reset);
      [E] ->
        Right = E#answer1state.rightqueue,
        queue:in({Player, HitTime}, Right);
      Ret ->
        ?ERROR_MSG("answer1state keeps ~p", [Ret]),
        queue:new()
    end,
    mnesia:write(#answer1state{
      slug = Slug,
      rightqueue = NewQu
    })
  end,
  mnesia:transaction(Fun).

get_right_answers(Slug) ->
  case mnesia:dirty_read(answer1state, Slug) of
    [] ->
      queue:new();
    [E] ->
      E#answer1state.rightqueue;
    _ ->
      queue:new()
  end. 

%% push wrong answer
push_wrong_answer(Slug, Player, HitTime) ->
  Fun = fun() ->
    NewQu = case mnesia:read(answer0state, Slug) of
      [] ->
        Reset = queue:new(),
        queue:in({Player, HitTime}, Reset);
      [E] ->
        Wrong = E#answer0state.wrongqueue,
        queue:in({Player, HitTime}, Wrong);
      Ret ->
        ?ERROR_MSG("answer0state keeps ~p", [Ret]),
        queue:new()
    end,
    mnesia:write(#answer0state{
        slug = Slug,
        wrongqueue = NewQu
    })
  end,
  mnesia:transaction(Fun).

get_wrong_answers(Slug) ->
  case mnesia:dirty_read(answer0state, Slug) of
    [] ->
      queue:new();
    [E] ->
      E#answer0state.wrongqueue;
    _ ->
      queue:new()
  end.

%% pop current answer
pop_current_answer(Slug, Player) ->
  Fun = fun() ->
    case mnesia:read(answer0state, Slug) of
      [] ->
        filter_right_queue(Slug, Player);
      [E] ->
        Wrong = E#answer0state.wrongqueue,
        Answer0List = queue:to_list(Wrong),
        FiltedList = filter_list_answer(Player, Answer0List),
        if
          FiltedList == Answer0List ->
            filter_right_queue(Slug, Player);        
          true ->
            NewQueue0 = queue:from_list(FiltedList),
            mnesia:write(#answer0state{
                slug = Slug,
                wrongqueue = NewQueue0
            })
        end
    end
  end,
  mnesia:transaction(Fun).

filter_list_answer(Player, List) ->
  lists:filter(fun({Name, _Hit}) ->
    if
      Name =:= Player -> false;
      true -> true
    end
  end, List).

filter_right_queue(Slug, Player) ->
  case mnesia:read(answer1state, Slug) of
    [] ->
      ok;
    [E] ->
      Right = E#answer1state.rightqueue,
      Answer1List = queue:to_list(Right),
      FiltedList = filter_list_answer(Player, Answer1List),
      if
        FiltedList == Answer1List ->
          ok;
        true ->
          NewQueue1 = queue:from_list(FiltedList),
          mnesia:write(#answer1state{
              slug = Slug,
              rightqueue = NewQueue1
          })
      end
  end.

%% result of previous question
result_previous_question(Slug, Final) ->
  %% get 2 queues
  SortedQ1 = get_right_answers(Slug),
  SortedQ0 = get_wrong_answers(Slug),
  PosRanking = positive_scores(SortedQ1, Final, [], 1),
  Ranking = negative_scores(SortedQ0, Final, PosRanking, 1),
  PlayersTag = update_score(Ranking, []),
  %% who don't give answer, dont change his score
  mnesia:clear_table(answer1state),
  mnesia:clear_table(answer0state),
  mnesia:clear_table(statistic),
  PlayersTag.

%% next question will be sent in seconds
next_question(StrSeconds, Tail, Step) ->
  case string:to_integer(StrSeconds) of
    {Seconds, []} ->
      erlang:send_after(Seconds * 1000 + ?DELAYNEXT1, self(),
          {questionslist, Tail, Step});
    {RetSeconds, Reason} ->
      ?ERROR_MSG("Error to convert seconds to integer {~p, ~p}",
          [RetSeconds, Reason]);
    Ret ->
      ?ERROR_MSG("Error to convert seconds to integer ~p",
          [Ret])
  end.

finish_game(Server, Slug, _PoolId, _Final, 1, _Questions,
    TimeStart, MaxPlayers) ->
  LastId = traverse_scoresstate1(Server, TimeStart, Slug, MaxPlayers),
  if
    LastId > 0 ->
      Last = erlang:integer_to_list(LastId),
      GameCounterStr = "game-" ++ Slug ++ "-" ++ Last,
      traverse_scoresstate2(Server, GameCounterStr);
    true ->
      ?ERROR_MSG("Slug ~p insert row into games table returning ~p", [LastId])
  end;
finish_game(Server, Slug, PoolId, Final, Step, Questions,
    TimeStart, MaxPlayers) ->
  ?WARNING_MSG("game ~p (pool ~p) finished, final ~p",
      [Slug, PoolId, Final]),
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
          result_previous_question(Slug, Final)
       }
      ]
  },

  List = player_store:match_object({Slug, '_', '_', '_', '_', '_'}),
  %% then broadcast result previous question
  broadcast_msg(Server, Slug, List, RankingQuestion),
  MsgGId = "ranking-game" ++ Random,
  RGame = update_scoreboard(List, []),
  SortScoreboard = scoreboard_items(RGame, []),
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
      traverse_scoresstate2(Server, GameCounterStr);
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
  Iterator =  fun(Rec, [{Max, Total}])->
    #scoresstate{
        player = Player,
        score = Score,
        hits = Hits,
        responses = Response
    } = Rec,
    %% redis store_scores
    ?WARNING_MSG("store_scores ~p: ~p, ~p, ~p", [Player, Score, Hits, Response]),
    RedisData = {Score, Hits, Responses},
    case RedisData of
      {0, 0, 0} ->
        ok; %% dont have to update
      _ ->
        Alltime = Raddress ++ "-alltime",
        redis_store_scores_alltime(Server, Alltime, Player, Score, Hits, Responses),
        Yearly = Raddress ++ "-year:" ++ erlang:integer_to_list(Year),
        redis_store_scores_alltime(Server, Yearly, Player, Score, Hits, Responses),
        Monthly = Raddress ++ "-month:" ++ erlang:integer_to_list(Month),
        redis_store_scores_alltime(Server, Monthly, Player, Score, Hits, Responses),
        Weekly = Raddress ++ "-week:" ++ erlang:integer_to_list(Week),
        redis_store_scores_alltime(Server, Weekly, Player, Score, Hits, Responses),
        Daily = Raddress ++ "-day:" ++ erlang:integer_to_list(Day),
        redis_store_scores_alltime(Server, Daily, Player, Score, Hits, Responses)
    end,
    NewMax = if
      Score > Max -> Score;
      true -> Max
    end,
    [{NewMax, Total + Score}]
  end,

  case fold_table(scoresstate, Iterator, [{0, 0}]) of
    [{WinnerScore, TotalScore}] ->
      ?WARNING_MSG("triviajabber_games: ~p, ~p, ~p, ~p", [Slug, MaxPlayers, WinnerScore, TotalScore]),
      mod_triviajabber:games_table(Server, Date, Time, Slug,
          MaxPlayers, WinnerScore, TotalScore);
    Error ->
      ?ERROR_MSG("interate scoresstate: ~p", [Error]),
      -6
  end.

%% store_game
traverse_scoresstate2(Server, GameCounterStr) ->
  Iterator =  fun(Rec, _) ->
    #scoresstate{
        player = Player,
        score = Score,
        hits = Hits,
        responses = Response
    } = Rec,
    RedisData = {Score, Hits, Response},
    case RedisData of
      {0, 0, 0} ->
        ok; %% dont have to update
      _ ->
        redis_store_game(Server, GameCounterStr, Player, RedisData)
    end,
    []
  end,
  fold_table(scoresstate, Iterator, []).

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
          ["select question_id from triviajabber_questions "
           "where pool_id='", PoolId, "' order by rand() "
           "limit ", Questions]) of
        {selected, ["question_id"], []} ->
          ?ERROR_MSG("pool_id ~p has no question", [PoolId]),
          [];
        {selected, ["question_id"], QuestionsList}
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
       "from triviajabber_questions where question_id='", QuestionId, "'"]) of
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
       "from triviajabber_questions where question_id='", QuestionId, "'"]) of
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
      Ret;
    false ->
      Score = Final / Position,
      {{value, {Player, HitTime}}, Tail} = queue:out(Queue),
      Add = {Player,
          HitTime,
          erlang:round(Score),
          Position},
      positive_scores(Tail, Final, [Add|Ret], Position+1);
    _ ->
      Ret
  end.

negative_scores(Queue, Final, Ret, Position) ->
  case queue:is_empty(Queue) of
    true ->
      Ret;
    false ->
      Score = Final / (Position * -2),
      {{value, {Player, HitTime}}, Tail} = queue:out(Queue),
      Add = {Player,
          HitTime,
          erlang:round(Score),
          Position},
      negative_scores(Tail, Final, [Add|Ret], Position+1);
    _ ->
      Ret
  end.

update_score([], Ret) ->
  Ret;
update_score([{Player, Time, Score, Pos}|Tail], Ret) ->
  {Gap, Response} = if
    Score > 0 ->
      {1, 1}; %% one hit, one response
    Score < 0 ->
      {0, 1}; %% no hit, one response
    true ->
      {0, 0} %% no hit, no response
  end,
  case mnesia:dirty_read(scoresstate, Player) of
    [] ->
      ?ERROR_MSG("Dont find ~p in scoresstate", [Player]),
      mnesia:dirty_write(#scoresstate{
        player = Player,
        score = Score, hits = Gap,
        responses = Response
      }),
      update_score(Tail, Ret);
    [E] ->
      GameScore = if %% only show positive score
        E#scoresstate.score + Score > 0 ->
          E#scoresstate.score + Score;
        true ->
          0
      end,
      NewHit = E#scoresstate.hits + Gap,
      NewRes = E#scoresstate.responses + Response,
      mnesia:dirty_write(#scoresstate{
        player = Player,
        score = GameScore, hits = NewHit,
        responses = NewRes
      }),
      ?WARNING_MSG("update_score(~p, ~p, hit:~p, res:~p) = ~p",
          [Player, Score, NewHit, NewRes, GameScore]),
      AddTag = questionranking_player_tag(
          Player, Time, Pos, Score),
      update_score(Tail, [AddTag|Ret]);
    Ret ->
      ?ERROR_MSG("Found ~p in scoresstate: ~p", [Player, Ret]),
      update_score(Tail, Ret)
  end.

%% get all players from player_store,
%% we reset playersstate, player can answer new question.
%% So we cant get all players by playersstate.playersets
update_scoreboard([], Ret) ->
  lists:keysort(2, Ret);
update_scoreboard([Head|Tail], Acc) ->
  {_Slug, Player, _Resource, _, _, _} = Head,
  Add = case mnesia:dirty_read(scoresstate, Player) of
    [] ->
      ?WARNING_MSG("dirty_read(scoresstate): didnt see ~p",
          [Player]),
      {Player, 0};
    [E2] ->
      Score = E2#scoresstate.score,
      {Player, Score};
    Ret2 ->
      ?ERROR_MSG("dirty_read(scoresstate): ~p", [Ret2]),
      {Player, 0}
  end,
  ?WARNING_MSG("get_scoreboard : add ~p", [Add]),
  update_scoreboard(Tail, [Add|Acc]).

questionranking_player_tag(Nickname, Time, Pos, Score) ->
  {xmlelement, "player",
      [{"nickname", Nickname},
       {"score", erlang:integer_to_list(Score)},
       {"pos", erlang:integer_to_list(Pos)},
       {"time", erlang:integer_to_list(Time)}
      ],
      []
  }.

scoreboard_items([], Ret) ->
  Ret;
scoreboard_items([Head|Tail], Ret) ->
  {Player, Score} = Head,
  Add = {xmlelement, "player",
      [{"nickname", Player},
       {"score", erlang:integer_to_list(Score)}
      ],
      []
  },
  scoreboard_items(Tail, [Add|Ret]).

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

%% iterate TableName
fold_table(TableName, Iterator, Acc) ->
  case mnesia:is_transaction() of
    true ->
      mnesia:foldl(Iterator, Acc, TableName);
    false ->
      Exec = fun({Fun,Tab}) -> mnesia:foldl(Fun, Acc, Tab) end,
      mnesia:activity(transaction,Exec,[{Iterator, TableName}],mnesia_frag)
  end.

%% redis_store_scores
redis_store_scores_alltime(Server, Alltime, Player, RedisData) ->
  {Score, Hits, Response} = RedisData,
  mod_triviajabber:redis_zincrby(Server, Alltime, Score, Player),
  AlltimeNick = Alltime ++ ":" ++ Player,
  mod_triviajabber:redis_hincrby(Server, AlltimeNick, "hits", Hits),
  mod_triviajabber:redis_hincrby(Server, AlltimeNick, "responses", Responses),
  mod_triviajabber:redis_hincrby(Server, AlltimeNick, "gplayed", 1),
  ok.

redis_store_game(Server, GameCounterStr, Player, RedisData) ->
  {Score, Hits, Response} = RedisData,
  mod_triviajabber:redis_zadd(Server, GameCounterStr, Score, Player),
  GameCounterNick = GameCounterStr ++ ":" ++ Player,
  mod_triviajabber:redis_hmset(Server, GameCounterNick, Hits, Responses),
  ok.
