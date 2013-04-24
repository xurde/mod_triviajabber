%%%----------------------------------------------------------------------
%%% File    : triviajabber_store.erl
%%% Author  : Phong C. <od06@htklabs.com>
%%% Purpose : store Pid of process that handles Slug game
%%% Created : Apr 16, 2013
%%%
%%%

-module(triviajabber_store).
-author('od06@htklabs.com').

-export([init/0, close/0, insert/2, delete/1, lookup/1]).

init() ->
  ets:new(?MODULE, [public, named_table]).

close() ->
  ets:delete_all_objects(?MODULE),
  ets:delete(?MODULE).

insert(Slug, Pid) ->
  ets:insert(?MODULE, {Slug, Pid}),
  {ok, Slug, Pid}.

lookup(Slug) ->
  case ets:lookup(?MODULE, Slug) of
    [{Slug, Pid}] ->
      {ok, Slug, Pid};
    [] ->
      {null, not_found, not_found};
    Any ->
      {error, lookup, Any}
  end.

delete(Slug) ->
  ets:delete(?MODULE, Slug).

