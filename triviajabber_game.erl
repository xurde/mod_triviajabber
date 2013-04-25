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
-export([take_new_player/6, remove_old_player/1]).

-include("ejabberd.hrl").
-include("jlib.hrl").

-define(PROCNAME, ejabberd_triviapad_game).
-define(DEFAULT_MINPLAYERS, 1).
-define(READY, "no").
-define(COUNTDOWN, 3000).

-record(gamestate, {host, slug, pool_id, questions, seconds,
    minplayers = ?DEFAULT_MINPLAYERS, started = ?READY}).

%% when new player has joined game room,
%% check if there are enough players to start
handle_cast({joined, Slug, PoolId},
    #gamestate{
        host = Host,
        slug = Slug, pool_id = PoolId,
        questions = Questions, seconds = Seconds,
        started = Started,
        minplayers = MinPlayers} = State) ->
  ?WARNING_MSG("~p child knows [incoming] -> ~p, min ~p", [self(), Slug, MinPlayers]),
  case Started of
    "no" ->
       List = player_store:match_object({Slug, '_', '_'}),
       ?WARNING_MSG("~p hasnt started, ~p", [Slug, List]),
       if
         erlang:length(List) >= MinPlayers ->
           ?WARNING_MSG("new commer fills enough players to start game", []),
           will_send_question(Host, Slug),
           NewState = #gamestate{
               host = Host, slug = Slug,
               questions = Questions, seconds = Seconds,
               pool_id = PoolId,
               started = "yes", minplayers = MinPlayers},
           {noreply, NewState};
         true ->
           ?WARNING_MSG("still not enough players to start game", []),
           {noreply, State}
       end;
    Yes ->  
      ?WARNING_MSG("has game ~p started ? ~p", [Slug, Yes]),
      {noreply, State}
  end;
%% when one player has left
handle_cast({left, Slug}, State) ->
  ?WARNING_MSG("~p child knows [outcoming] <- ~p, state ~p", [self(), Slug, State]),
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
    questions = Questions, seconds = Seconds,
    pool_id = PoolId} = State) ->
  QuestionIds = question_ids(Host, PoolId, Questions),
  ?WARNING_MSG("from ~p (~p), list ~p", [Slug, Questions, QuestionIds]),
  case QuestionIds of
    [] ->
      ?ERROR_MSG("~p (~p) has no question after returning permutation",
          [Slug, PoolId]),
      {stop, error, State};
    [{UniqueQuestion}] ->
      send_question(Host, Slug, UniqueQuestion, Seconds);
    [{Head}|Tail] ->
      send_question(Host, Slug, Head, Seconds),
      erlang:send_after(Seconds * 1000, self(), {questionslist, Tail}),
      {noreply, State}
  end;
handle_info({questionslist, QuestionIds}, #gamestate{
    host = Host, slug = Slug,
    questions = Questions, seconds = Seconds,
    pool_id = PoolId} = State) ->
  case QuestionIds of
    [] ->
      %% TODO: cannot happen, however we handle when
      %% all questions were be sent
      ok;
    [{LastQuestion}] ->
      send_question(Host, Slug, LastQuestion, Seconds);
    [{Head}|Tail] ->
      send_question(Host, Slug, Head, Seconds),
      erlang:send_after(Seconds * 1000, self(), {questionslist, Tail}),
  end,
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

start_link(Host, Opts) ->
  Slug = gen_mod:get_opt(slug, Opts, ""),
  %% each child has each process name ejabberd_triviapad_game_<Slug>
  Proc = gen_mod:get_module_proc(Slug, ?PROCNAME),
  gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

init([Host, Opts]) ->
  Slug = gen_mod:get_opt(slug, Opts, ""),
  MinPlayers = gen_mod:get_opt(minplayers, Opts, 1),
  PoolId = gen_mod:get_opt(pool_id, Opts, 1),
  Questions = gen_mod:get_opt(questions, Opts, 0),
  Seconds = gen_mod:get_opt(seconds, Opts, -1),
  ?WARNING_MSG("@@@@@@@@ child ~p processes {~p, ~p, ~p, ~p}", [self(), Slug, PoolId, Questions, Seconds]),
  Started = if
    MinPlayers =:= 1 ->
      will_send_question(Host, Slug),
      "yes";
    true ->
     "no"
  end,
  {ok, #gamestate{
      host = Host,
      slug = Slug, pool_id = PoolId,
      questions = Questions, seconds = Seconds,
      minplayers = MinPlayers,
      started = Started}
  }.

%%% ------------------------------------
%%% Game manager is notified when
%%% player has joined/left.
%%% ------------------------------------

%% New player has joined game room (slug)
%% If there's no process handle this game, create new one.
take_new_player(Host, Slug, PoolId,
    Questions, Seconds, MinPlayers) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, PoolId, Pid} ->
      ?WARNING_MSG("B. <notify> process ~p: someone joined  ~p", [Pid, Slug]),
      gen_server:cast(Pid, {joined, Slug, PoolId}),
      ok;
    {null, not_found, not_found, not_found} ->
      Opts = [{slug, Slug}, {pool_id, PoolId},
              {questions, Questions}, {seconds, Seconds},
              {minplayers, MinPlayers}],
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
          gen_server:call(Pid, stop);
        Res ->
          ?WARNING_MSG("async notify ~p", [Res]),
          gen_server:cast(Pid, {left, Slug})
      end;
    {null, not_found, not_found, not_found} ->
      ?ERROR_MSG("there no process to handle ~p", [Slug]),
      ok;
    Error ->
      ?ERROR_MSG("[player left] lookup : ~p", [Error])
  end.

%%% ------------------------------------
%%% Child handles a game
%%% ------------------------------------

%% send countdown chat message when there are enough players
will_send_question(Server, Slug) ->
  CountdownPacket = {xmlelement, "message",
     [{"type", "chat"}, {"id", randoms:get_string()}],
     [{xmlelement, "countdown", [], [{xmlcdata, "3 seconds"}]}]
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

generate_opt_list([], Ret, _) ->
  Ret;
generate_opt_list([Head|Tail], Ret, Count) ->
  CountStr = erlang:integer_to_list(Count),
  AddOne = {xmlelement, "answer",
      [{"id", CountStr}],
      [{xmlcdata, Head}]},
  generate_opt_list(Tail, [AddOne|Ret], Count+1).

%% send question to all player in slug
send_question(Server, Slug, QuestionId, Seconds) ->
  case get_question_info(Server, QuestionId) of
    {ok, Qst, QLst} ->
      MsgId = Slug ++ randoms:get_string(),
      OptList = generate_opt_list(QLst, [], 1),
%  QuestionPacket = {xmlelement, "message",
%      [{"type", "question"}, {"id", MsgId}],
%      [{xmlelement, "question",
%          [{"time", Seconds}],
%          [{xmlcdata, "What color was Santiago’s white horse?"}]
%       },
%       {xmlelement, "answers",
%          [],
%          [
%           {xmlelement, "option", [{"id", "1"}], [{xmlcdata, "White"}]},
%           {xmlelement, "option", [{"id", "2"}], [{xmlcdata, "Black"}]},
%           {xmlelement, "option", [{"id", "3"}], [{xmlcdata, "White with black dots"}]}
%          ]
%       }
%      ]
%  },
      QuestionPacket = {xmlelement, "message",
        [{"type", "question"}, {"id", MsgId}],
        [{xmlelement, "question",
            [{"time", Seconds}], [{xmlcdata, Qst}]
         },
         {xmlelement, "answers",
            [], [OptList]
         }
        ]
      },
      List = player_store:match_object({Slug, '_', '_'}),
      lists:foreach(fun({_, Player, Resource}) ->
        To = jlib:make_jid(Player, Server, Resource),
        GameServer = "triviajabber." ++ Server,
        From = jlib:make_jid(Slug, GameServer, Slug),
        ejabberd_router:route(From, To, QuestionPacket)
      end, List);
    _ ->
      error
  end.

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
  Query =
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
      {ok, Q, List};
    Res ->
      ?ERROR_MSG("Query question ~p failed: ~p", [QuestionId, Res]),
      error
  catch
    Res2:Desc2 ->
      ?ERROR_MSG("Exception when get question info ~p",
          [QuestionId]),
      error
  end.
