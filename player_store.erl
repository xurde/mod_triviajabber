%%%----------------------------------------------------------------------
%%% File    : player_store.erl
%%% Author  : Phong C. <od06@htklabs.com>
%%% Purpose : store players in Slug game
%%% Created : Apr 16, 2013
%%%
%%%

-module(player_store).
-author('od06@htklabs.com').

-export([init/0, close/0, insert/3, delete/3,
         match_delete/1, match_object/1]).

init() ->
  dets:open_file(?MODULE, [{ram_file, true}]).

close() ->
  dets:delete_all_objects(?MODULE),
  dets:close(?MODULE).

insert(Slug, Player, Resource) ->
  dets:insert(?MODULE, {Slug, Player, Resource}),
  {ok, Slug, Player, Resource}.

delete(Slug, Player, Resource) ->
  dets:delete(?MODULE, {Slug, Player, Resource}).

match_delete(Pattern) ->
  dets:match_delete(?MODULE, Pattern).

match_object(Pattern) ->
  dets:match_object(?MODULE, Pattern).
