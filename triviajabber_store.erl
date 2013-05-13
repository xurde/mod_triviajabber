%%%----------------------------------------------------------------------
%%% File    : triviajabber_store.erl
%%% Author  : Phong C. <od06@htklabs.com>
%%% Purpose : store Pid of process that handles Slug game
%%% Created : Apr 16, 2013
%%%
%%%

-module(triviajabber_store).
-author('od06@htklabs.com').

-export([init/0, close/0, insert/3, delete/1, lookup/1]).

init() ->
  ets:new(?MODULE, [public, named_table]).

close() ->
  ets:delete_all_objects(?MODULE),
  ets:delete(?MODULE).

insert(Slug, PoolId, Pid) ->
  ets:insert(?MODULE, {Slug, PoolId, Pid}),
  {ok, Slug, PoolId, Pid}.

lookup(Slug) ->
  case ets:lookup(?MODULE, Slug) of
    [{Slug, PoolId, Pid}] ->
      {ok, Slug, PoolId, Pid};
    [] ->
      {null, not_found};
    Any ->
      {error, triviajabber_store_lookup, Slug, Any}
  end.

delete(Slug) ->
  ets:delete(?MODULE, Slug).

