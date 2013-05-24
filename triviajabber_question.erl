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

-export([init/0, close/0, insert/10, delete/1,
         lookup/1, match_object/1]).

init() ->
  ets:new(?MODULE, [public, named_table]).

close() ->
  ets:delete_all_objects(?MODULE),
  ets:delete(?MODULE).

%% QPhase is question string
insert(Pid, Question, AnswerId, QuestionId, TimeStamp, QPhrase,
    Opt1, Opt2, Opt3, Opt4) ->
  ets:insert(?MODULE, {Pid, Question, AnswerId, QuestionId, TimeStamp, QPhrase,
      Opt1, Opt2, Opt3, Opt4}),
  {ok, Pid, Question, AnswerId, QuestionId, TimeStamp, QPhrase,
      Opt1, Opt2, Opt3, Opt4}.

lookup(Pid) ->
  case ets:lookup(?MODULE, Pid) of
    [{Pid, Question, AnswerId, QuestionId, TimeStamp, QPhrase,
        Opt1, Opt2, Opt3, Opt4}] ->
      {ok, Pid, Question, AnswerId, QuestionId, TimeStamp, QPhrase,
          Opt1, Opt2, Opt3, Opt4};
    [] ->
      {null, not_found};
    Any ->
      {error, Any}
  end.

match_object(Pattern) ->
  ets:match_object(?MODULE, Pattern).

delete(Pid) ->
  ets:delete(?MODULE, Pid).
