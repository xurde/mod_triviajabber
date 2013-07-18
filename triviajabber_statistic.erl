-module(triviajabber_statistic).
-author('od06@htklabs.com').

-export([init/0, close/0, delete/1,
    lookup/1, insert/5]).

init() ->
  ets:new(?MODULE, [public, named_table]).

close() ->
  ets:delete_all_objects(?MODULE),
  ets:delete(?MODULE).

delete(Slug) ->
  ets:delete(?MODULE, Slug).

lookup(Slug) ->
  case ets:lookup(?MODULE, Slug) of
    [{Slug, O1, O2, O3, O4}] ->
      {ok, O1, O2, O3, O4};
    [] ->
      {null, not_found};
    Any ->
      {error, Any}
  end.

insert(Slug, Opt1, Opt2, Opt3, Opt4) ->
  ets:insert(?MODULE, {Slug, Opt1, Opt2, Opt3, Opt4}),
  {ok, Slug, Opt1, Opt2, Opt3, Opt4}.
