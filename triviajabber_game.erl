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
-export([take_new_player/7, remove_old_player/1,
         current_question/1, get_answer/4]).

-include("ejabberd.hrl").
-include("jlib.hrl").

-define(PROCNAME, ejabberd_triviapad_game).
-define(DEFAULT_MINPLAYERS, 1).
-define(READY, "no").
-define(COUNTDOWN, 3000).
-define(KILLAFTER, 2000).
-define(MODELAY, 1500000).
-define(COUNTDOWNSTR, "Game is about to start. Please wait for other players to join.").

-record(gamestate, {host, slug, pool_id,
    questions, seconds, final_players,
    minplayers = ?DEFAULT_MINPLAYERS, started = ?READY}).
-record(answer1state, {slug, rightqueue}).
-record(answer0state, {slug, wrongqueue}).
-record(playersstate, {slug, playersets}). 
-record(scoresstate, {player, score}).

%% when new player has joined game room,
%% check if there are enough players to start
handle_cast({joined, Slug, PoolId, NewComer}, #gamestate{
    host = Host,
    slug = Slug, pool_id = PoolId,
    questions = Questions, seconds = Seconds,
    final_players = Final, started = Started,
    minplayers = MinPlayers}) ->
  ?WARNING_MSG("~p child knows [incoming] -> ~p, min ~p, final ~p",
      [self(), Slug, MinPlayers, Final+1]),
  mnesia:dirty_write(#scoresstate{
      player = NewComer,
      score = 0
  }),
  
  case Started of
    "no" ->
       List = player_store:match_object({Slug, '_', '_'}),
       if
         erlang:length(List) >= MinPlayers ->
           ?WARNING_MSG("new commer fills enough players to start game", []),
           triviajabber_question:insert(self(), 0, null, null, 0),
           will_send_question(Host, Slug),
           NewState1 = #gamestate{
               host = Host, slug = Slug,
               questions = Questions, seconds = Seconds,
               pool_id = PoolId, final_players = Final+1,
               started = "yes", minplayers = MinPlayers},
           {noreply, NewState1};
         true ->
           ?WARNING_MSG("still not enough players to start game", []),
           NewState2 = #gamestate{
               host = Host, slug = Slug,
               questions = Questions, seconds = Seconds,
               pool_id = PoolId, final_players = Final+1,
               started = "no", minplayers = MinPlayers},
           {noreply, NewState2}
       end;
    Yes ->  
      ?WARNING_MSG("has game ~p started ? ~p", [Slug, Yes]),
      NewState3 = #gamestate{
               host = Host, slug = Slug,
               questions = Questions, seconds = Seconds,
               pool_id = PoolId, final_players = Final+1,
               started = Yes, minplayers = MinPlayers},
      {noreply, NewState3}
  end;

%% when one player has left
handle_cast({left, Slug}, State) ->
  ?WARNING_MSG("~p child knows [outcoming] <- ~p, state ~p", [self(), Slug, State]),
  {noreply, State};
handle_cast({answer, Player, Answer, QuestionId}, #gamestate{
    host = _Host, slug = Slug,
    questions = _Questions, seconds = _StrSeconds,
    pool_id = _PoolId, final_players = _Final,
    started = _Started, minplayers = _MinPlayers} = State) ->
  case onetime_answer(Slug, Player) of
    {atomic, true} ->
      case triviajabber_question:lookup(self()) of
        {ok, _Pid, _Question, Answer, QuestionId, Stamp1} ->
          HitTime = get_hittime(Stamp1),
          %% push into true queue
          push_right_answer(Slug, Player, HitTime);
        {ok, _Pid, _Question, A1, QuestionId, Stamp0} ->
          ?WARNING_MSG("wrong answer. Correct: ~p", [A1]),
          HitTime0 = get_hittime(Stamp0),
          %% push into wrong queue
          push_wrong_answer(Slug, Player, HitTime0);
        {ok, _, Q2, A2, QId2, _} ->
          ?WARNING_MSG("late answer, currently ~p, ~p, ~p",
              [Q2, A2, QId2]);
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
handle_cast(Msg, State) ->
  ?WARNING_MSG("async msg: ~p\nstate ~p", [Msg, State]),
  {noreply, State}.

%% when module kills child because game room is empty
handle_call(stop, _From, State) ->
  ?WARNING_MSG("Stopping manager ...~nState:~p~n", [State]),
  {stop, normal, State}.

handle_info(countdown, #gamestate{
    host = Host, slug = Slug,
    questions = Questions, seconds = StrSeconds,
    pool_id = PoolId, final_players = Final,
    started = _Started, minplayers = _MinPlayers} = State) ->
  QuestionIds = question_ids(Host, PoolId, Questions),
  ?WARNING_MSG("from ~p (~p), list ~p", [Slug, Questions, QuestionIds]),
  case QuestionIds of
    [] ->
      ?ERROR_MSG("~p (~p) has no question after returning permutation",
          [Slug, PoolId]),
      {stop, normal, State};
    [{UniqueQuestion}] ->
      send_question(Host, Final, Questions,
          Slug, UniqueQuestion, StrSeconds, 1),
      next_question(StrSeconds, [], 1),
      {noreply, State};
    [{Head}|Tail] ->
      send_question(Host, Final, Questions,
          Slug, Head, StrSeconds, 1),
      next_question(StrSeconds, Tail, 2),
      {noreply, State}
  end;
handle_info({questionslist, QuestionIds, Step}, #gamestate{
    host = Host, slug = Slug,
    pool_id = PoolId, questions = Questions,
    seconds = StrSeconds, final_players = Final,
    started = _Started, minplayers = _MinPlayers} = State) ->
  case QuestionIds of
    [] ->
      finish_game(Host, Slug, PoolId, Final, Step, Questions),
      {stop, normal, State};
    [{LastQuestion}] ->
      send_question(Host, Final, Questions,
          Slug, LastQuestion, StrSeconds, Step),
      next_question(StrSeconds, [], Step + 1),
      {noreply, State};
    [{Head}|Tail] ->
      send_question(Host, Final, Questions,
          Slug, Head, StrSeconds, Step),
      next_question(StrSeconds, Tail, Step + 1),
      {noreply, State}
  end;
handle_info(killafter, #gamestate{
    host = Host, slug = Slug,
    pool_id = PoolId, questions = Questions,
    seconds = _StrSeconds, final_players = Final,
    started = Started, minplayers = _MinPlayers} = State) ->
  if
    Started =:= "yes", Questions > 0 ->
      finish_game(Host, Slug, PoolId, Final, 1, Questions);
    true ->
      ok
  end,
  recycle_game(self(), Slug),
  {stop, normal, State};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(Reason, #gamestate{
      slug = Slug}) ->
  Pid = self(),
  ?WARNING_MSG("terminate ~p(~p): ~p", [Pid, Slug, Reason]),
  mnesia:delete_table(answer1state),
  mnesia:delete_table(answer0state),
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
      score = 0
  }),

  Started = if
    MinPlayers =:= 1 ->
      triviajabber_question:insert(self(), 0, null, null, 0),
      will_send_question(Host, Slug),
      "yes";
    true ->
      triviajabber_question:insert(self(), -1, null, null, 0),
      "no"
  end,
  {ok, #gamestate{
      host = Host,
      slug = Slug, pool_id = PoolId,
      questions = Questions, seconds = Seconds,
      final_players = 1, minplayers = MinPlayers,
      started = Started}
  }.

%%% ------------------------------------
%%% Game manager is notified when
%%% player has joined/left.
%%% ------------------------------------

%% New player has joined game room (slug)
%% If there's no process handle this game, create new one.
take_new_player(Host, Slug, PoolId, Player,
    Questions, Seconds, MinPlayers) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, PoolId, Pid} ->
      ?WARNING_MSG("B. <notify> process ~p: someone joined  ~p", [Pid, Slug]),
      gen_server:cast(Pid, {joined, Slug, PoolId, Player}),
      ok;
    {null, not_found, not_found, not_found} ->
      Opts = [{slug, Slug}, {pool_id, PoolId},
              {questions, Questions}, {seconds, Seconds},
              {player, Player}, {minplayers, MinPlayers}],
      {ok, Pid} = start_link(Host, Opts),
      ?WARNING_MSG("C. new process ~p handles ~p", [Pid, Opts]),
      triviajabber_store:insert(Slug, PoolId, Pid),
      ok;
    Error ->
      ?ERROR_MSG("D. [player joined] lookup : ~p", [Error])  
  end.
%% Old player joined game room (slug),
%% After he requested, he has left.
remove_old_player(Slug) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, _PoolId, Pid} ->
      case player_store:match_object({Slug, '_', '_'}) of
        [] ->
          ?WARNING_MSG("manager ~p kills idle process ~p", [self(), Pid]),
          %% kill empty slug in 1500 miliseconds
          erlang:send_after(?KILLAFTER, Pid, killafter);
        Res ->
          ?WARNING_MSG("sync notify ~p", [Res]),
          gen_server:cast(Pid, {left, Slug})
      end;
    {null, not_found, not_found, not_found} ->
      ?ERROR_MSG("there no process to handle ~p", [Slug]),
      ok;
    Error ->
      ?ERROR_MSG("[player left] lookup : ~p", [Error])
  end.

%% get_current_question
current_question(Slug) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, _PoolId, Pid} ->
      case triviajabber_question:lookup(Pid) of
        {ok, _Pid, Question, _Answer, _QuestionId, _Time} ->
          {ok, Question};
        Ret ->
          {error, Ret}
      end;
    {null, not_found} ->
      {failed, null};
    Error ->
      ?ERROR_MSG("find pid of slug ~p: ~p", [Slug, Error]),
      {error, Error}
  end.

%% check answer from player
get_answer(Player, Slug, Answer, QuestionId) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, _PoolId, Pid} ->
      ?WARNING_MSG("~p answers ~p(~p): ~p",
          [Player, Slug, Pid, Answer]),
      gen_server:cast(Pid, {answer, Player, Answer, QuestionId});
    {null, not_found, not_found, not_found} ->
      ?ERROR_MSG("there's no process handle ~p", [Slug]);
    Error ->
      ?ERROR_MSG("there's no process handle ~p: ~p",
          [Slug, Error])
  end.
    
%%% ------------------------------------
%%% Child handles a game
%%% ------------------------------------

%% send countdown chat message when there are enough players
will_send_question(Server, Slug) ->
  CountdownPacket = {xmlelement, "message",
     [{"type", "chat"}, {"id", randoms:get_string()}],
     [{xmlelement, "countdown",
         [{"secs", "30"}],
         [{xmlcdata, ?COUNTDOWNSTR}]}]
  },
  List = player_store:match_object({Slug, '_', '_'}),
  lists:foreach(
    fun({_, Player, Resource}) ->
      To = jlib:make_jid(Player, Server, Resource),
      GameServer = "triviajabber." ++ Server,
      From = jlib:make_jid(Slug, GameServer, Slug),
      ejabberd_router:route(From, To, CountdownPacket)
    end,
  List),
  erlang:send_after(?COUNTDOWN, self(), countdown),
  ok.

%% send first question
send_question(Server, _, _, Slug,
    QuestionId, Seconds, 1) ->
  case get_question_info(Server, QuestionId) of
    {ok, Qst, Asw, QLst} ->
      MsgId = Slug ++ randoms:get_string(),
      QLstLen = erlang:length(QLst),
      OptList = generate_opt_list(QLst, [], QLstLen),
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
      triviajabber_question:insert(self(), 1, SecretId, MsgId, CurrentTime),
      %% broadcast first question
      List = player_store:match_object({Slug, '_', '_'}),
      lists:foreach(fun({_, Player, Resource}) ->
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
    QuestionId, Seconds, Step) ->
  case get_question_info(Server, QuestionId) of
    {ok, Qst, Asw, QLst} ->
      Random = randoms:get_string(),
      
      %% it's too late to answer, module informs result of previous question.
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
      
      List = player_store:match_object({Slug, '_', '_'}),
      %% then broadcast result previous question
      broadcast_msg(Server, Slug, List, RankingQuestion),

      MsgGId = "ranking-game" ++ Random,
      RGame = get_scoreboard(Slug),
      RGameSize = erlang:length(RGame),
      SortScoreboard = sort_scoreboard(RGame, [], RGameSize),
      ?WARNING_MSG("sort_scoreboard ~p", [SortScoreboard]),
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

      %% replace current question by next question,
      MsgId = Slug ++ Random,
      QLstLen = erlang:length(QLst),
      OptList = generate_opt_list(QLst, [], QLstLen),
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
      ?WARNING_MSG("prepare for step ~p", [Step]),
      CurrentTime = get_timestamp(),
      SecretId = find_answer(OptList, Asw),
      triviajabber_question:insert(self(), Step, SecretId, MsgId, CurrentTime),
      broadcast_msg(Server, Slug, List, QuestionPacket);
    _ ->
      error
  end.

%broadcast_ranking_msg(Server, Slug, List, RQuestion, RGame) ->
%  ?WARNING_MSG("RankingGame ~p", [RGame]),
%  lists:foreach(fun({_, Player, Resource}) ->
%    To = jlib:make_jid(Player, Server, Resource),
%    GameServer = "triviajabber." ++ Server,
%    From = jlib:make_jid(Slug, GameServer, Slug),
%    ejabberd_router:route(From, To, RQuestion),
%    ejabberd_router:route(From, To, RGame)
%  end, List).

broadcast_msg(Server, Slug, List, Packet) ->
  lists:foreach(fun({_, Player, Resource}) ->
    To = jlib:make_jid(Player, Server, Resource),
    GameServer = "triviajabber." ++ Server,
    From = jlib:make_jid(Slug, GameServer, Slug),
    ejabberd_router:route(From, To, Packet)
  end, List).

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
  PlayersTag.

%% next question will be sent in seconds
next_question(StrSeconds, Tail, Step) ->
  case string:to_integer(StrSeconds) of
    {Seconds, []} ->
      erlang:send_after(Seconds * 1000 + ?KILLAFTER, self(),
          {questionslist, Tail, Step});
    {RetSeconds, Reason} ->
      ?ERROR_MSG("Error to convert seconds to integer {~p, ~p}",
          [RetSeconds, Reason]);
    Ret ->
      ?ERROR_MSG("Error to convert seconds to integer ~p",
          [Ret])
  end.

finish_game(_, _Slug, _PoolId, _Final, 1, _Questions) ->
  %% TODO: update scores of players in DB
  ok;
finish_game(Server, Slug, PoolId, Final, Step, Questions) ->
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

  List = player_store:match_object({Slug, '_', '_'}),
  %% then broadcast result previous question
  broadcast_msg(Server, Slug, List, RankingQuestion),
  MsgGId = "ranking-game" ++ Random,
  RGame = get_scoreboard(Slug),
  RGameSize = erlang:length(RGame),
  SortScoreboard = sort_scoreboard(RGame, [], RGameSize),
  ?WARNING_MSG("sort_scoreboard0 ~p", [SortScoreboard]),
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
  ok.

recycle_game(Pid, Slug) ->
  player_store:match_delete({Slug, '_', '_'}),
  triviajabber_store:delete(Slug),
  triviajabber_question:delete(Pid).

% [
%  {xmlelement, "option", [{"id", "1"}], [{xmlcdata, "White"}]},
%  {xmlelement, "option", [{"id", "2"}], [{xmlcdata, "Black"}]},
%  {xmlelement, "option", [{"id", "3"}], [{xmlcdata, "White with black dots"}]}
%  {xmlelement, "option", [{"id", "4"}], [{xmlcdata, "Brown"}]},
% ]
generate_opt_list([], Ret, _) ->
  Ret;
generate_opt_list([Head|Tail], Ret, Count) ->
  CountStr = erlang:integer_to_list(Count),
  AddOne = {xmlelement, "answer",
      [{"id", CountStr}],
      [{xmlcdata, Head}]},
  generate_opt_list(Tail, [AddOne|Ret], Count-1).

%% get permutation of question_id from pool
question_ids(Server, PoolId, Questions) ->
  if
    Questions > 0 ->
      try ejabberd_odbc:sql_query(Server,
          ["select question_id from sixclicks_questions "
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
       "from sixclicks_questions where question_id='", QuestionId, "'"]) of
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

get_timestamp() ->
  {Mega,Sec,Micro} = erlang:now(),
  (Mega*1000000+Sec)*1000000+Micro.

get_hittime(Stamp) ->
  CurrentTime = get_timestamp(),
  if
    CurrentTime - Stamp > ?MODELAY ->
      CurrentTime - Stamp - ?MODELAY;
    true ->
      0
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
  case mnesia:dirty_read(scoresstate, Player) of
    [] ->
      ?ERROR_MSG("Dont find ~p in scoresstate", [Player]),
      mnesia:dirty_write(#scoresstate{
        player = Player,
        score = Score
      }),
      update_score(Tail, Ret);
    [E] ->
      GameScore = E#scoresstate.score + Score,
      mnesia:dirty_write(#scoresstate{
        player = Player,
        score = GameScore
      }),
      ?WARNING_MSG("update_score(~p, ~p)", [Player, Score]),
      AddTag = questionranking_player_tag(
          Player, Time, Pos, Score),
      update_score(Tail, [AddTag|Ret]);
    Ret ->
      ?ERROR_MSG("Found ~p in scoresstate: ~p", [Player, Ret]),
      update_score(Tail, Ret)
  end.

get_scoreboard(Slug) ->
  %% TODO: get scoreboard
  GameRanking = case mnesia:dirty_read(playersstate, Slug) of
    [] ->
      [];
    [E] ->
      Playersets = E#playersstate.playersets,
      AllPlayers = sets:fold(
        fun(Player, Acc) ->
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
          [Add|Acc]
        end,
      [], Playersets),
      lists:keysort(2, AllPlayers);
    Ret ->
      ?ERROR_MSG("dirty_read(playersstate): ~p", [Ret]), 
      []
  end,
  mnesia:clear_table(playersstate),
  GameRanking.

questionranking_player_tag(Nickname, Time, Pos, Score) ->
  {xmlelement, "player",
      [{"nickname", Nickname},
       {"score", erlang:integer_to_list(Score)},
       {"pos", erlang:integer_to_list(Pos)},
       {"time", erlang:integer_to_list(Time)}
      ],
      []
  }.

sort_scoreboard([], Ret, _) ->
  Ret;
sort_scoreboard([Head|Tail], Ret, Size) ->
  {Player, Score} = Head,
  Add = {xmlelement, "player",
      [{"nickname", Player},
       {"score", erlang:integer_to_list(Score)}
      ],
      []
  },
  sort_scoreboard(Tail, [Add|Ret], Size-1).

find_answer([], _) ->
  ?ERROR_MSG("!! Not found answer in permutation !!", []),
  "0";
find_answer([Head|Tail], Asw) ->
  case Head of
    {xmlelement, "answer",
        [{"id", CountStr}],
        [{xmlcdata, Asw}]} ->
      ?WARNING_MSG("found answerid = ~p", [CountStr]),
      CountStr;
    _ ->
      find_answer(Tail, Asw)
  end.
