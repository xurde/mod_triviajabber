%%%----------------------------------------------------------------------
%%% File    : triviajabber_game.erl
%%% Author  : Phong C. <od06@htklabs.com>
%%% Purpose : handle game
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

-export([take_new_player/2]).

-include("ejabberd.hrl").

-define(PROCNAME, ejabberd_triviapad_game).

start(_Host, _Opts) ->
  ?WARNING_MSG("start game manager", []),
  triviajabber_store:init(),
  ok.
  
stop(Host) ->
  ?WARNING_MSG("stop game manager", []),
  triviajabber_store:close(),
  Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
  gen_server:call(Proc, stop),
  supervisor:delete_child(ejabberd_sup, Proc).

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
  ?WARNING_MSG("child init ~p, ~p", [Host, Opts]),
  {ok, self()}.

%% New player has joined game room (slug)
%% If there's no process handle this game, create new one.
take_new_player(Host, Slug) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, Pid} ->
      ?WARNING_MSG("process ~p has handled ~p slug", [Pid, Slug]),
      ok;
    {null, not_found, not_found} ->
      {ok, Pid} = start_child(Host, Slug),
       triviajabber_store:insert(Slug, Pid),
      ?WARNING_MSG("new process ~p handles ~p", [Pid, Slug]),
      ok;
    Error ->
      ?ERROR_MSG("triviajabber_store:lookup : ~p", [Error])  
  end.
