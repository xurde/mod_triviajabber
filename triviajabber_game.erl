%%%----------------------------------------------------------------------
%%% File    : triviajabber_game.erl
%%% Author  : Phong C. <od06@htklabs.com>
%%% Purpose : game manager: each process handles each game
%%% Created : Apr 16, 2013
%%%
%%%

-module(triviajabber_game).
-author('od06@htklabs.com').

-behavior(gen_mod).
-behavior(gen_server).

%% API
-export([start/2, stop/1, start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([take_new_player/2, remove_old_player/1]).

-include("ejabberd.hrl").

-define(PROCNAME, ejabberd_triviapad_game).
-define(DEFAULT_MINPLAYERS, 1).

-record(gamestate, {host, minplayers = ?DEFAULT_MINPLAYERS}).

start(Host, Opts) ->
  ?WARNING_MSG("start game manager", []),
  triviajabber_store:init(),
  MinPlayers = gen_mod:get_opt(minplayers, Opts, ?DEFAULT_MINPLAYERS),
  {ok, #gamestate{host = Host, minplayers = MinPlayers}}.
  
stop(Host) ->
  ?WARNING_MSG("stop game manager", []),
  triviajabber_store:close(),
  Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
  gen_server:call(Proc, stop),
  supervisor:delete_child(ejabberd_sup, Proc).

handle_cast({joined, Slug}, State) ->
  ?WARNING_MSG("~p child knows [incoming] -> ~p, state ~p", [self(), Slug, State]),
  {noreply, State};
handle_cast({left, Slug}, State) ->
  ?WARNING_MSG("~p child knows [outcoming] <- ~p, state ~p", [self(), Slug, State]),
  {noreply, State};
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_call(stop, _From, State) ->
  ?WARNING_MSG("Stopping manager ...~nState:~p~n", [State]),
  {stop, normal, ok, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

start_child(Host, Slug) ->
  Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
  ChildSpec =
    {Proc,
     {?MODULE, start_link, [Host, [{slug, Slug}]]},
     temporary,
     1000,
     worker,
     [?MODULE]},
  supervisor:start_child(ejabberd_sup, ChildSpec).

start_link(Host, Opts) ->
  ?WARNING_MSG("start_child -> start_link ~p, ~p", [Host, Opts]),
  Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
  gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

init([Host, Opts]) ->
  Slug = gen_mod:get_opt(slug, Opts, ""),
  ?WARNING_MSG("child in ~p processes ~p", [Host, Slug]),
  {ok, self()}.

%% ------------------------------------
%% Game manager is notified when
%% player has joined/left.
%% ------------------------------------

%% New player has joined game room (slug)
%% If there's no process handle this game, create new one.
take_new_player(Host, Slug) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, Pid} ->
      ?WARNING_MSG("<notify> process ~p: someone joined  ~p", [Pid, Slug]),
      gen_server:cast(Pid, {joined, Slug}),
      ok;
    {null, not_found, not_found} ->
      {ok, Pid} = start_child(Host, Slug),
      triviajabber_store:insert(Slug, Pid),
      ?WARNING_MSG("new process ~p handles ~p", [Pid, Slug]),
      ok;
    Error ->
      ?ERROR_MSG("[player joined] lookup : ~p", [Error])  
  end.
%% Old player joined game room (slug),
%% After he requested, he has left.
remove_old_player(Slug) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, Pid} ->
      ?WARNING_MSG("<notify> process ~p: someone left ~p", [Pid, Slug]),
      gen_server:cast(Pid, {left, Slug}),
      ok;
    {null, not_found, not_found} ->
      ?ERROR_MSG("there no process to handle ~p", [Slug]),
      ok;
    Error ->
      ?ERROR_MSG("[player left] lookup : ~p", [Error])
  end.
