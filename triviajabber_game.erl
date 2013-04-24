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
-export([take_new_player/3, remove_old_player/1]).

-include("ejabberd.hrl").
-include("jlib.hrl").

-define(PROCNAME, ejabberd_triviapad_game).
-define(DEFAULT_MINPLAYERS, 1).
-define(READY, "no").
-define(COUNTDOWN, 3000).

-record(gamestate, {host, slug, minplayers = ?DEFAULT_MINPLAYERS, started = ?READY}).

%% when new player has joined game room,
%% check if there are enough players to start
handle_cast({joined, Slug},
    #gamestate{
        host = Host,
        slug = Slug,
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
               host = Host,
               slug = Slug,
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
  {stop, normal, ok, State}.

handle_info(question, #gamestate{slug = Slug} = State) ->
  List = player_store:match_object({Slug, '_', '_'}),
  lists:foreach(
    fun({XSlug, Player, Resource}) ->
      ?WARNING_MSG("<~p> first question to ~p/~p", [XSlug, Player, Resource])
      
    end,
  List),
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
  ?WARNING_MSG("@@@@@@@@ child ~p processes {~p, ~p}", [self(), Slug, MinPlayers]),
  Started = if
    MinPlayers =:= 1 ->
      will_send_question(Host, Slug),
      "yes";
    true ->
     "no"
  end,
  {ok, #gamestate{
      host = Host,
      slug = Slug,
      minplayers = MinPlayers,
      started = Started}
  }.

%%% ------------------------------------
%%% Game manager is notified when
%%% player has joined/left.
%%% ------------------------------------

%% New player has joined game room (slug)
%% If there's no process handle this game, create new one.
take_new_player(Host, Slug, MinPlayers) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, Pid} ->
      ?WARNING_MSG("B. <notify> process ~p: someone joined  ~p", [Pid, Slug]),
      gen_server:cast(Pid, {joined, Slug}),
      ok;
    {null, not_found, not_found} ->
      Opts = [{slug, Slug}, {minplayers, MinPlayers}],
      {ok, Pid} = start_link(Host, Opts),
      ?WARNING_MSG("C. new process ~p handles ~p", [Pid, Opts]),
      triviajabber_store:insert(Slug, Pid),
      ok;
    Error ->
      ?ERROR_MSG("D. [player joined] lookup : ~p", [Error])  
  end.
%% Old player joined game room (slug),
%% After he requested, he has left.
remove_old_player(Slug) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, Pid} ->
      case player_store:match_object({Slug, '_', '_'}) of
        [] ->
          ?WARNING_MSG("manager ~p kills idle process ~p", [self(), Pid]),
          gen_server:call(Pid, stop);
        Res ->
          ?WARNING_MSG("async notify ~p", [Res]),
          gen_server:cast(Pid, {left, Slug})
      end;
    {null, not_found, not_found} ->
      ?ERROR_MSG("there no process to handle ~p", [Slug]),
      ok;
    Error ->
      ?ERROR_MSG("[player left] lookup : ~p", [Error])
  end.

%%% ------------------------------------
%%% Child handles a game
%%% ------------------------------------

will_send_question(Server, XSlug) ->
  List = player_store:match_object({XSlug, '_', '_'}),
  lists:foreach(
    fun({Slug, Player, Resource}) ->
      To = jlib:make_jid(Player, Server, Resource),
      GameServer = "triviajabber." ++ Server,
      From = jlib:make_jid(Slug, GameServer, ""),
      send_countdown_msg(From, To, "3 seconds")
    end,
  List),
  erlang:send_after(?COUNTDOWN, self(), question),
  ok.

send_countdown_msg(From, To, Txt) ->
  Packet = {xmlelement, "message",
%      [{"type", ?MODULE}, {"id", randoms:get_string()}],
%      [{xmlelement, "countdown", [], [{xmlcdata, Txt}]}]
     [{"type", "chat"}, {"id", randoms:get_string()}],
     [{xmlelement, "countdown", [], [{xmlcdata, Txt}]}]
  },
  ejabberd_router:route(From, To, Packet).
  
