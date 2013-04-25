-module('permutation').
-export([permute/1, permute/2]).
 
permute(List) ->
  permute(List, length(List)).
 
permute(List, Length) ->
  Indices = [],
  Permuted_List = [],
  jumble(List, Permuted_List, Indices, Length).
 
jumble(_, Permuted_List, _, 0) ->
  Permuted_List;
 
jumble(List, Permuted_List, Indices, Length) ->
  Rand_Ind = random:uniform(length(List)),
  case lists:member(Rand_Ind, Indices) of
    true ->
      jumble(List, Permuted_List, Indices, Length);
    false ->
      New_Permutation = lists:append(Permuted_List, [lists:nth(Rand_Ind, List)]),
      New_Indices = lists:append(Indices, [Rand_Ind]),
      jumble(List, New_Permutation, New_Indices, Length - 1)
  end.
