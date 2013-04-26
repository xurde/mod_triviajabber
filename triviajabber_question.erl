%%%----------------------------------------------------------------------
%%% File    : triviajabber_question.erl
%%% Author  : Phong C. <od06@htklabs.com>
%%% Purpose : store current question and answer of game
%% that Pid is processing
%%% Created : Apr 26, 2013
%%%
%%%

-module(triviajabber_question).
-author('od06@htklabs.com').

-export([init/0, close/0, insert/3, delete/1, lookup/1]).

init() ->
  ets:new(?MODULE, [public, named_table]).

close() ->
  ets:delete_all_objects(?MODULE),
  ets:delete(?MODULE).

insert(Pid, Question, Answer) ->
  ets:insert(?MODULE, {Pid, Question, Answer}),
  {ok, Pid, Question, Answer}.

lookup(Pid) ->
  case ets:lookup(?MODULE, Pid) of
    [{Pid, Question, Answer}] ->
      {ok, Pid, Question, Answer};
    [] ->
      {null, not_found, not_found, not_found};
    Any ->
      {error, lookup, Pid, Any}
  end.

delete(Pid) ->
  ets:delete(?MODULE, Pid).
