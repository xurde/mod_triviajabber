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

%% API
-export([start/2, stop/1]).

-export([take_new_player/3]).

-include("ejabberd.hrl").

-define(PROCNAME, ejabberd_triviapad_game).

-record(gamestate, {host}).

start(Host, Opts) ->
  triviajabber_store:init(),
  #gamestate{host = Host},
  ok.

stop(Host) ->
  triviajabber_store:close(),
  ok.

start_child(Host, Slug) ->
  ?WARNING_MSG("start_child(~p, ~p)", [Host, Slug]),
  Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
  ChildSpec =
    {Proc,
     {?MODULE, start_link, [Host, Slug]},
     temporary,
     1000,
     worker,
     [?MODULE]},
  supervisor:start_child(ejabberd_sup, ChildSpec).

start_link(Host, Opts) ->
  Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
  gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

init([Host, Opts]) ->
  

take_new_player(Host, Slug, Player, Resource) ->
  case triviajabber_store:lookup(Slug) of
    {ok, Slug, Pid} ->
      ?WARNING_MSG("process ~p handles ~ slug", [Pid, Slug]),
      ok;
    {null, not_found, not_found} ->
      start_child(Host, Slug),
      ok  
  end.
