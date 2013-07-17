-module(triviajabber_scores).
-author('od06@htklabs.com').

-export([init/0, close/0, delete/1,
    insert/5]).

init() ->
  ets:new(?MODULE, [public, named_table]).

close() ->
  ets:delete_all_objects(?MODULE),
  ets:delete(?MODULE).

delete(Slug) ->
  ets:delete(?MODULE, Slug).

insert(Slug, Player, Score, Hits, Responses) ->
  ets:insert(?MODULE, {Slug, Player, Score, Hits, Responses}),
  {ok, Slug, Player, Score, Hits, Responses}.


