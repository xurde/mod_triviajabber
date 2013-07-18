#!/bin/sh

CURR=${PWD}

$CURR/../../../bin/erlc triviajabber_statistic.erl && $CURR/../../../bin/erlc triviajabber_scores.erl && $CURR/../../../bin/erlc permutation.erl && $CURR/../../../bin/erlc triviajabber_question.erl && $CURR/../../../bin/erlc triviajabber_store.erl && $CURR/../../../bin/erlc -I $CURR/../include/ player_store.erl && $CURR/../../../bin/erlc -I $CURR/../include/ -I $CURR/../../stdlib-1.17.5/include/ $CURR/mod_triviajabber.erl && $CURR/../../../bin/erlc -I $CURR/../include/ triviajabber_game.erl
