%%%----------------------------------------------------------------------
%%% File    : player_store.erl
%%% Author  : Phong C. <od06@htklabs.com>
%%% Purpose : store players in Slug game
%%% Created : Apr 16, 2013
%%%
%%%

-module(player_store).
-author('od06@htklabs.com').

-export([init/0, close/0, insert/3,
         match_delete/1, match_object/1]).

init() ->
  ets:new(?MODULE, [bag, public, named_table]).

close() ->
  ets:delete_all_objects(?MODULE),
  ets:delete(?MODULE).

insert(Slug, Player, Resource) ->
  ets:insert(?MODULE, {Slug, Player, Resource}),
  {ok, Slug, Player, Resource}.

match_delete(Pattern) ->
  ets:match_delete(?MODULE, Pattern).

match_object(Pattern) ->
  ets:match_object(?MODULE, Pattern).
