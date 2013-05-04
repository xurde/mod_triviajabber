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

-export([init/0, close/0, insert/5, delete/1, lookup/1]).

init() ->
  ets:new(?MODULE, [public, named_table]).

close() ->
  ets:delete_all_objects(?MODULE),
  ets:delete(?MODULE).

insert(Pid, Question, Answer, QuestionId, TimeStamp) ->
  ets:insert(?MODULE, {Pid, Question, Answer, QuestionId, TimeStamp}),
  {ok, Pid, Question, Answer, QuestionId, TimeStamp}.

lookup(Pid) ->
  case ets:lookup(?MODULE, Pid) of
    [{Pid, Question, Answer, QuestionId, TimeStamp}] ->
      {ok, Pid, Question, Answer, QuestionId, TimeStamp};
    [] ->
      {null, not_found};
    Any ->
      {error, Any}
  end.

delete(Pid) ->
  ets:delete(?MODULE, Pid).
