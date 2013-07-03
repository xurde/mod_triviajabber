%%%----------------------------------------------------------------------
%%% File    : mod_triviajabber.erl
%%% Author  : Phong C. <od06@htklabs.com>
%%% Purpose : handle stanzas incoming to triviajabber.dev.triviapad.com
%%% Created : Apr 02, 2013
%%%
%%%

-module(mod_triviajabber).
-author('od06@htklabs.com').

-behaviour(gen_server).
-behaviour(gen_mod).

%% gen_mod callbacks
-export([start/2, stop/1]).

%% Hooks
-export([user_offline/3, user_offline/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% helpers
-export([iq_disco_items/3, get_room_occupants/2, start_link/2,
         games_table/7,
         redis_zincrby/4, redis_hincrby/4,
         redis_zadd/4, redis_hmset/4]).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("adhoc.hrl").
-include("mod_muc/mod_muc_room.hrl").
-include_lib("qlc.hrl").

%% Helpers

-define(PROCNAME, ejabberd_mod_triviajabber).
-define(DEFAULT_MINPLAYERS, 1).
-define(DEFAULT_GAME_SERVICE, "triviajabber.").
-define(DEFAULT_ROOM_SERVICE, "rooms.").
-define(JOIN_EVENT_NODE, "join_game").
-define(LEAVE_EVENT_NODE, "leave_game").
-define(STATUS_NODE, "status_game").
-define(FIFTY_NODE, "fifty").
-define(CLAIR_NODE, "clairvoyance").
-define(ROLLBACK_NODE, "rollback").

-record(sixclicksstate, {host, route,
    fifty, clairvoyance, rollback,
    minplayers = ?DEFAULT_MINPLAYERS}).
%% Copied from mod_muc/mod_muc.erl
-record(muc_online_room, {name_host, pid}).

%%==============================================================
%% API
%%==============================================================
%%--------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------
start_link(Host, Opts) ->
  Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
  gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

start(Host, Opts) ->
  player_store:init(),
  triviajabber_store:init(),
  triviajabber_question:init(),
  Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
  ChildSpec =
    {Proc,
     {?MODULE, start_link, [Host, Opts]},
     temporary,
     1000,
     worker,
     [?MODULE]},
  supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
  triviajabber_question:close(),
  triviajabber_store:close(),
  player_store:close(),
  ejabberd_hooks:delete(sm_remove_connection_hook, Host,
      ?MODULE, user_offline, 100),
  ejabberd_hooks:delete(unset_presence_hook, Host,
      ?MODULE, user_offline, 100),
  Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
  gen_server:call(Proc, stop),
  supervisor:delete_child(ejabberd_sup, Proc).

%% "unavailable" hook
user_offline(_Sid, Jid, _SessionInfo) ->
  remove_player_from_games(Jid).

user_offline(User, Server, Resource, _Status) ->
  Jid = jlib:make_jid(User, Server, Resource),
  remove_player_from_games(Jid).

remove_player_from_games(Jid) ->
  User = Jid#jid.user,
  Res = Jid#jid.resource,
  player_store:match_delete({'_', User, Res, '_', '_', '_'}).

%%==============================================================
%% gen_server callbacks
%%==============================================================

%%--------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------
init([Host, Opts]) ->
  ServiceName = proplists:get_value(gameservice, Opts, ?DEFAULT_GAME_SERVICE),
  MinPlayers = proplists:get_value(minplayers, Opts, ?DEFAULT_MINPLAYERS),
  Fifty = proplists:get_value(fifty, Opts, 1),
  Clair = proplists:get_value(clairvoyance, Opts, 1),
  Rollback = proplists:get_value(rollback, Opts, 1),
  ?WARNING_MSG("Service name ~p, Host ~p, Min ~p", [ServiceName, Host, MinPlayers]),
  Route = gen_mod:get_opt_host(Host, Opts, ServiceName ++ "@HOST@"),
%%  Route = "dev-guest.triviapad.com",
  ?WARNING_MSG("Route ~p", [Route]),
  ejabberd_hooks:add(sm_remove_connection_hook, Host,
                               ?MODULE, user_offline, 100),
  ejabberd_hooks:add(unset_presence_hook, Host,
                               ?MODULE, user_offline, 100),

  ejabberd_router:register_route(Route),
  {ok, #sixclicksstate{host = Host, route = Route,
      fifty = Fifty, clairvoyance = Clair,
      rollback = Rollback, minplayers = MinPlayers}
  }.

%%--------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) ->
%%              {reply, Reply, State} |
%%              {reply, Reply, State, Timeout} |
%%              {noreply, State} |
%%              {noreply, State, Timeout} |
%%              {stop, Reason, Reply, State} |
%%              {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------
handle_call(stop, _From, State) ->
  ?WARNING_MSG("Stopping sixclicks ...~nState:~p~n", [State]),
  {stop, normal, ok, State}.

%%--------------------------------------------------------------
%% Function: handle_cast(Msg, State) ->
%%           {noreply, State} |
%%           {noreply, State, Timeout} |
%%           {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------
handle_cast(Msg, State) ->
  ?WARNING_MSG("handle_cast ~p, ~p~n", [Msg, State]),
  {noreply, State}.

%%--------------------------------------------------------------
%% Function: handle_info(Info, State) ->
%%           {noreply, State} |
%%           {noreply, State, Timeout} |
%%           {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------
handle_info({route, From, To, {xmlelement, _Type, _Attr, _Els} = Packet}, State) ->
  %%?WARNING_MSG("handle_info ~p: ~p~n", [From, Packet]),
  case catch do_route(To, From, Packet, State) of
    {'EXIT', Reason} -> ?ERROR_MSG("~p", [Reason]);
    _ -> ok
  end,
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

%%--------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server
%% when it is about to terminate. It should be the opposite of
%% Module:init/1 and do any necessary cleaning up.
%% When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------
terminate(_Reason, #sixclicksstate{route = Route} = _State) ->
  ejabberd_router:unregister_route(Route),
  ok.

%%--------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%==============================================================
%% Internal functions
%%==============================================================

%% Route incoming packet
do_route(To, From, Packet, State) ->
    {xmlelement, Name, Attrs, _Els} = Packet,
  case To of
    #jid{luser = "", lresource = ""} ->
      case Name of
        "iq" ->
          case jlib:iq_query_info(Packet) of
            #iq{type = get, xmlns = ?NS_DISCO_ITEMS} = IQ ->
              spawn(?MODULE, iq_disco_items,
                  [From, To, IQ]);
            #iq{} ->
              Err = jlib:make_error_reply(Packet,
                  ?ERR_FEATURE_NOT_IMPLEMENTED),
              ejabberd_router:route(To, From, Err);
            _ ->
              ok
          end;
        _ ->
          ok
      end;
    _ ->
      case Name of
        "iq" ->
          case jlib:iq_query_info(Packet) of
            #iq{type = set, xmlns = ?NS_COMMANDS} = IQ ->
              Res = case iq_command(From, To, IQ, State) of
                  {error, Error} ->
                    jlib:make_error_reply(Packet, Error);
                  {result, IQRes} ->
                    jlib:iq_to_xml(IQ#iq{type = result,
                        sub_el = [IQRes]})
              end,
              ejabberd_router:route(To, From, Res);
            #iq{} ->
              Err = jlib:make_error_reply(Packet,
                  ?ERR_FEATURE_NOT_IMPLEMENTED),
              ejabberd_router:route(To, From, Err);
            _ ->
              ok
          end;
        "message" ->
          QuestionId = xml:get_attr_s("id", Attrs),
          AnswerType = xml:get_attr_s("type", Attrs),
          Triviajabber = ?DEFAULT_GAME_SERVICE ++ From#jid.server,
          TriviajabberDomain = To#jid.server,
          if
            Triviajabber =:= TriviajabberDomain, AnswerType =:= "answer" ->
              %% module handles only answer message currently
              AnswerTag = xml:get_subtag(Packet, "answer"),
              case get_answer_hittime(AnswerTag) of
                {null, null} ->
                  ?ERROR_MSG("!!! answer must have id, time", []);
                {null, _} ->
                  ?ERROR_MSG("!!! answer must have id", []);
                {AnswerStr, null} ->
                  ?WARNING_MSG("!!! answer get server time", []),
                  triviajabber_game:get_answer(
                      From#jid.user, To#jid.user,
                      AnswerStr, "hardcode", QuestionId);
                {AnswerStr2, AnswerTime} ->
                  triviajabber_game:get_answer(
                      From#jid.user, To#jid.user,
                      AnswerStr2, AnswerTime, QuestionId);
                Ret ->
                  ?ERROR_MSG("get_answer_hittime(AnswerTag) = ~p", [Ret])
              end;
            true ->
              ?WARNING_MSG("~p != ~p", [Triviajabber, TriviajabberDomain])
          end;
        _ ->
          case xml:get_attr_s("type", Attrs) of
            "error" ->
              ok;
            "result" ->
              ok;
            _ ->
              Err = jlib:make_error_reply(Packet, ?ERR_ITEM_NOT_FOUND),
              ejabberd_router:route(To, From, Err)
          end
      end
  end.

%% Command handling
iq_command(From, To, IQ, State) ->
  case adhoc:parse_request(IQ) of
    Req when is_record(Req, adhoc_request) ->
      case adhoc_request(From, To, Req, State) of
        Resp when is_record(Resp, adhoc_response) ->
          {result, [adhoc:produce_response(Req, Resp)]};
        Error ->
          Error
      end;
    Err ->
      Err
  end.

%% @doc <p>Processes an Ad Hoc Command.</p>
adhoc_request(_From, _To,
    #adhoc_request{action = "execute", xdata  = false} = Request,
    _State) ->
  {result, send_initial_form(Request)};
adhoc_request(From, To,
    #adhoc_request{action = "execute", xdata  = XData} = Request,
    State) ->
  case XData of
    {xmlelement, "x", _Attrs, _SubEls} = XEl ->
      case jlib:parse_xdata_submit(XEl) of
        invalid ->
          {error, ?ERR_BAD_REQUEST};
        Options ->
          {result, handle_request(Request, From, To, Options, State)}
      end;
    _ ->
      ?INFO_MSG("Bad XForm: ~p", [XData]),
      {error, ?ERR_BAD_REQUEST}
  end;
adhoc_request(_From,  _To, #adhoc_request{action = "cancel"}, _State) ->
  #adhoc_response{status = canceled};
adhoc_request(From, To, #adhoc_request{action = []} = R, State) ->
  adhoc_request(From, To, R#adhoc_request{action = "execute"}, State);
adhoc_request(_From, _To, Other, _State) ->
  ?WARNING_MSG("Couldn't process ad hoc command:~n~p", [Other]),
  {error, ?ERR_ITEM_NOT_FOUND}.

%% handle the request and produce adhoc response
handle_request(#adhoc_request{node = Command} = Request,
    From, SixClicks, Options, State) ->
  {Items, Message} = execute_command(Command, From, SixClicks, Options, State),
  SubX = case Command of
    ?STATUS_NODE ->
      {xmlelement, "status", Items, []};
    ?FIFTY_NODE ->
      case {Items, Message} of
        {{Step, _QPhrase, {Int1Id, _Opt1}, {Int2Id, _Opt2}},
            "reduce to 2 options"} ->
          lifeline_fifty_xml(Step, Int1Id, Int2Id); 
        _ ->
          {xmlelement,"item", Items,
              [{xmlelement,"value", [], [{xmlcdata, "done"}]}]
          }
      end;
    ?CLAIR_NODE ->
      case {Items, Message} of
        {{Question, O1, O2, O3, O4}, "players have answered"} ->
          lifeline_clairvoyance_xml(Question, O1, O2, O3, O4);
        _ ->
          {xmlelement,"item", Items,
              [{xmlelement,"value", [], [{xmlcdata, "done"}]}]
          }
      end;
%    ?ROLLBACK_NODE ->
%      case {Items, Message} of
%        {_, "another chance"} ->
%          ok;
%        _ ->
%          {xmlelement,"item", Items,
%              [{xmlelement,"value", [], [{xmlcdata, "done"}]}]
%          }
%      end;
    _ ->
      ?WARNING_MSG("~p: ~p, ~p", [Command, Items, Message]),
      {xmlelement,"item", Items,
          [{xmlelement,"value", [], [{xmlcdata, "done"}]}]
      }
  end,
  Result = {xmlelement, "x",
      [{"xmlns", ?NS_XDATA}, {"type", "result"}],
      [{xmlelement, "title", [], [{xmlcdata, Message}]}, SubX]
  },
  adhoc:produce_response(Request, #adhoc_response{status = completed, elements = [Result]}).

send_initial_form(#adhoc_request{node = EventNode} = Request) ->
 if
  EventNode =:= ?JOIN_EVENT_NODE;
      EventNode =:= ?LEAVE_EVENT_NODE;
      EventNode =:= ?STATUS_NODE;
      EventNode =:= ?FIFTY_NODE;
      EventNode =:= ?CLAIR_NODE;
      EventNode =:= ?ROLLBACK_NODE ->
    Form =
      {xmlelement, "x",
          [{"xmlns", ?NS_XDATA}, {"type", "form"}],
          [{xmlelement, "title", [], [{xmlcdata, "Enter game id"}]},
              {xmlelement, "field",
                  [{"var", "game_id"},
                   {"type", "text-single"},
                   {"label", "Event id"}],
                  [{xmlelement, "required", [], []}]
              }
          ]
      },
    adhoc:produce_response(Request,
      #adhoc_response{status = executing, elements = [Form]});
  true ->
    ok
 end.

%% disco#items iq
iq_disco_items(From, To, IQ) ->
  Server = From#jid.server,
  GameService = To#jid.server,
  GamesList = game_disco_items(Server, GameService),
  Res = IQ#iq{type = result,
              sub_el = [{xmlelement, "query",
                        [{"xmlns", ?NS_DISCO_ITEMS}],
                        GamesList}]},
  ejabberd_router:route(To, From, jlib:iq_to_xml(Res)).

game_disco_items(Server, GameService) ->
%%  [{xmlelement, "games",
%%    [{"group", "hardcode"}],
%%    [{xmlelement, "game",
%%      [{"name", "name1"}, {"slug", "name1"}, {"topic", "test topic"}, {"question", "100"}, {"questions", "25"}, {"players", "108"}],
%%      []
%%     },
%%     {xmlelement, "game",
%%      [{"name", "name2"}, {"slug", "name2"}, {"topic", "test topic 2"}, {"question", "120"}, {"questions", "60"}, {"players", "10"}],
%%      []
%%     }
%%    ]
%%  }].
  try get_all_game_rooms(Server) of
    {selected, ["name", "level", "questions_per_game",
        "slug", "topic"], []} ->
      [];
    {selected, ["name", "level", "questions_per_game",
        "slug", "topic"], GameList}
        when erlang:is_list(GameList) ->
      {Trial, Regular, Official} = filter_games(GameList, {[], [], []}),
      OfficGames = add_games(GameService, "Official", Official, []),
      RegulGames = add_games(GameService, "Unofficial", Regular, OfficGames),
      TrialGames = add_games(GameService, "Testing", Trial, RegulGames),
      TrialGames;
    Reason ->
      ?ERROR_MSG("failed to query triviajabber_rooms ~p", [Reason]),
      []
  catch
    Res2:Desc2 ->
      ?ERROR_MSG("Exception [disco#items] ~p, ~p", [Res2, Desc2]),
      []
  end.

%% "Join game" command
execute_command(?JOIN_EVENT_NODE, From, SixClicks, _Options,
    #sixclicksstate{host = Server,
    fifty = Fifty, clairvoyance = Clair, rollback = Rollback,
    minplayers = MinPlayers} = _State) ->
  SlugNode = ?DEFAULT_GAME_SERVICE ++ Server,
  case SixClicks of
    #jid{luser = GameId, lserver = SlugNode} ->
      %% check game room in DB
      try get_game_room(GameId, Server) of
        {selected, ["name", "slug", "pool_id", "questions_per_game",
            "seconds_per_question"], []} ->
          {[{"return", "false"}, {"desc", "null"}], "Failed to find game"};
        {selected, ["name", "slug", "pool_id", "questions_per_game",
            "seconds_per_question"],
            [{GameName, GameId, GamePool, GameQuestions, GameSeconds}]} ->
          Player = From#jid.user,
          Resource = From#jid.resource,
          %% then cache in player_store
          case check_player_in_game(Server, MinPlayers, GameId,
              GamePool, GameQuestions, GameSeconds, Player, Resource) of
            "ok" ->
              player_store:insert(GameId, Player, Resource, Fifty, Clair, Rollback),
              {[{"return", "true"}, {"desc", GameName}], "Found game to join"};
            Err ->
              ?WARNING_MSG("You have joined this game ~p", [Err]),
              {[{"return", "fail"}, {"desc", GameName}], "You have joined this game"}
          end;
        {selected, ["name", "slug", "pool_id", "questions_per_game",
            "seconds_per_question"], [{OtherName, _OtherId, _, _, _}]} ->
          {[{"return", "false"}, {"desc", OtherName}], "Error in database"};
        Reason ->
          ?ERROR_MSG("failed to query triviajabber_rooms ~p", [Reason]),
          {[{"return", "false"}, {"desc", "null"}], "Failed to find game"}
      catch
        Res2:Desc2 ->
        ?ERROR_MSG("Exception ~p, ~p", [Res2, Desc2]),
        {[{"return", "false"}, {"desc", "null"}], "Exception when query game room"}
      end;
    _ ->
      {[{"return", "false"}, {"desc", SlugNode}], "sent to wrong jid"}
  end;
%% "Leave game" command
execute_command(?LEAVE_EVENT_NODE, From, SixClicks, _Options,
    #sixclicksstate{host = Server}) ->
  SlugNode = ?DEFAULT_GAME_SERVICE ++ Server,
  case SixClicks of
    #jid{luser = GameId, lserver = SlugNode} ->
      Player = From#jid.user,
      Resource = From#jid.resource,
      %% check game room in cache (player_store)
      case check_player_joined_game(GameId, Player, Resource) of
        ok ->
          {[{"return", "true"}, {"desc", GameId}], "You have left"};
        notfound ->
          {[{"return", "false"}, {"desc", "null"}], "You havent joined game room"}
      end;
    _ ->
      {[{"return", "false"}, {"desc", SlugNode}], "sent to wrong jid"}
  end;
%% "status game" command
execute_command(?STATUS_NODE, From, SixClicks, _Options,
    #sixclicksstate{host = Server}) ->
  SlugNode = ?DEFAULT_GAME_SERVICE ++ Server,
  case SixClicks of
    #jid{luser = GameId, lserver = SlugNode} ->
      StateData = get_room_state(Server, GameId),
      case ?DICT:find(jlib:jid_tolower(From),
          StateData#state.users) of
        {ok, #user{jid = FoundJid}} ->
          ?WARNING_MSG("found jid ~p", [FoundJid]),
          case triviajabber_game:current_status(GameId) of
            {ok, Question, Total, Players} ->
              {[{"question", Question}, {"total", Total}, {"players", Players}],
                  "You are participant"};
            {exception, _, _} ->
              {[{"return", "false"}, {"desc", "exception"}],
                  "getting status failed"};
            {failed, noprocess} ->
              try get_questions_per_game(GameId, Server) of
                {selected, ["questions_per_game"], []} ->
                  {[{"return", "false"}, {"desc", "sql returns empty"}],
                      "queried questions_per_game"};
                {selected, ["questions_per_game"], [{GameQuestions}]} ->
                  {[{"question", "-1"}, {"total", GameQuestions}, {"players", "0"}],
                      "You are participant"};
                Reason ->
                  ?ERROR_MSG("get_questions_per_game(~p) = ~p", [GameId, Reason]),
                  {[{"return", "false"}, {"desc", "sql returns many results"}],
                      "queried questions_per_game"}
              catch
                Res3:Desc3 ->
                  ?ERROR_MSG("Exception ~p, ~p", [Res3, Desc3]),
                    {[{"return", "false"}, {"desc", "exception"}],
                        "queried questions_per_game"}
              end;
            _ ->
              {[{"return", "false"}, {"desc", "error"}], "You are participant"}
          end;
        Ret ->
          ?WARNING_MSG("notfound jid of requester ~p: ~p", [From#jid.user, Ret]),
          {[{"return", "false"}, {"desc", "null"}], "You arent participant"}
      end;
    _ ->
      {[{"return", "false"}, {"desc", SlugNode}], "sent to wrong jid"}
  end;
%% "lifeline:fifty" command
execute_command(?FIFTY_NODE, From, SixClicks, _Options,
    #sixclicksstate{host = Server}) ->
  SlugNode = ?DEFAULT_GAME_SERVICE ++ Server,
  case SixClicks of
    #jid{luser = GameId, lserver = SlugNode} ->
      Player = From#jid.user,
      Resource = From#jid.resource,
      case triviajabber_game:lifeline_fifty(GameId, Player, Resource) of
        {failed, Slug, Title} ->
          {[{"return", "false"}, {"desc", Slug}], Title};
        {ok, Question, QPhrase, Random1, Random2} ->
          {Int1Id, Opt1} = Random1,
          {Int2Id, Opt2} = Random2,
          {{Question, QPhrase, {Int1Id, Opt1}, {Int2Id, Opt2}}, "reduce to 2 options"};
        Ret ->
          ?ERROR_MSG("lifeline_fifty BUG ~p", [Ret]),
          {[{"return", "false"}, {"desc", "null"}], "lifeline_fifty has bug"}
      end;
    _ ->
      {[{"return", "false"}, {"desc", SlugNode}], "sent to wrong jid"}
  end;
%% "lifeline:clairvoyance" command
execute_command(?CLAIR_NODE, From, SixClicks, _Options,
    #sixclicksstate{host = Server}) ->
  SlugNode = ?DEFAULT_GAME_SERVICE ++ Server,
  case SixClicks of
    #jid{luser = GameId, lserver = SlugNode} ->
      Player = From#jid.user,
      Resource = From#jid.resource,
      case triviajabber_game:lifeline_clair(GameId, Player, Resource) of
        {failed, Slug, Title} ->
          {[{"return", "false"}, {"desc", Slug}], Title};
        {ok, Question, O1, O2, O3, O4} ->
          ?WARNING_MSG("players have answered ~p, ~p, ~p, ~p", [O1, O2, O3, O4]),
          {{Question, O1, O2, O3, O4}, "players have answered"};
        Ret ->
          ?ERROR_MSG("lifeline_clairvoyance BUG ~p", [Ret]),
          {[{"return", "false"}, {"desc", "null"}], "lifeline_clairvoyance has bug"}
      end;
    _ ->
      {[{"return", "false"}, {"desc", SlugNode}], "sent to wrong jid"}
  end;
%% "lifeline:rollback" command
execute_command(?ROLLBACK_NODE, From, SixClicks, _Options,
    #sixclicksstate{host = Server}) ->
%  [RollbackId] = proplists:get_value("optionid", Options),
%  ?WARNING_MSG("ROLLBACK optionId ~p", [RollbackId]),
  SlugNode = ?DEFAULT_GAME_SERVICE ++ Server,
  case SixClicks of
    #jid{luser = GameId, lserver = SlugNode} ->
      Player = From#jid.user,
      Resource = From#jid.resource,
      case triviajabber_game:lifeline_rollback(GameId, Player, Resource) of
        {ok, Slug, Msg} ->
          ?WARNING_MSG("another chance", []),
          {[{"return", "true"}, {"desc", Slug}], Msg};
        {failed, Slug2, Title} ->
          {[{"return", "false"}, {"desc", Slug2}], Title};
        HellRaiser ->
          ?ERROR_MSG("lifeline_rollback returns ~p", [HellRaiser]),
          {[{"return", "false"}, {"desc", "null"}], "hellraiser"}
      end;
    _ ->
      {[{"return", "false"}, {"desc", SlugNode}], "sent to wrong jid"}
  end.

%% Helpers
get_questions_per_game(GameId, Server) ->
  ejabberd_odbc:sql_query(Server,
      ["select questions_per_game from triviajabber_rooms "
       "where slug='", GameId, "'"]
  ).
%% Get game name, pool_id, questions_per_game, seconds_per_question
get_game_room(GameId, Server) ->
  ejabberd_odbc:sql_query(Server,
      ["select name, slug, pool_id, questions_per_game, seconds_per_question "
       "from triviajabber_rooms where slug='", GameId, "'"]
  ).

get_all_game_rooms(Server) ->
  ejabberd_odbc:sql_query(Server,
      ["select name, level, questions_per_game, "
       "slug, topic from triviajabber_rooms"]
  ).

filter_games([], {T, R, O}) ->
  {T, R, O};
filter_games([Head|Tail], {T, R, O}) ->
  {Name, Level, Questions, Slug, Topic} = Head,
  case Level of
    "Testing" ->
      filter_games(Tail,
          {[{Name, Questions, Slug, Topic}|T], R, O});
    "Unofficial" ->
      filter_games(Tail,
          {T, [{Name, Questions, Slug, Topic}|R], O});
    "Official" ->
      filter_games(Tail,
          {T, R, [{Name, Questions, Slug, Topic}|O]})
  end.

add_games(GameService, Group, G, Ret) ->
  if
    G =/= [] ->
      XmlelementGame = game_items(G, GameService),
      GElement =
        {xmlelement, "games",
          [{"group", Group}],
          XmlelementGame
        },
      [GElement | Ret];
    true ->
      Ret
  end.

game_items(Items, GameService) ->
  lists:map(fun({Name, Questions, Slug, Topic}) ->
    Jid = Slug ++ "@" ++ GameService,
    PlayersList = player_store:match_object({Slug, '_', '_', '_', '_', '_'}),
    PlayersCount = erlang:length(PlayersList),
    case triviajabber_game:current_question(Slug) of
      {ok, QuestionId} ->
        {xmlelement, "game",
          [{"name", Name}, {"slug", Slug},
           {"topic", Topic}, {"question", erlang:integer_to_list(QuestionId)},
           {"questions", Questions},
           {"players", erlang:integer_to_list(PlayersCount)}],
          []
        };
      {failed, null} ->
        {xmlelement, "game",
          [{"name", Name}, {"jid", Jid},
           {"topic", Topic}, {"question", "-1"},
           {"questions", Questions},
           {"players", erlang:integer_to_list(PlayersCount)}],
          []
        };
      Ret ->
        ?WARNING_MSG("failed to get current question (~p slug): ~p",
            [Slug, Ret]),
        {xmlelement, "game",
          [{"name", Name}, {"jid", Jid}, 
           {"topic", Topic}, {"question", "-1"}, 
           {"questions", Questions}, 
           {"players", erlang:integer_to_list(PlayersCount)}],
          []
        }
    end
  end, Items).

%% One account can log in at many resources (devices),
%% but don't allow them join in one game. They can play in diference room games.
check_player_in_game(Server, MinPlayers, GameId,
    GamePool, GameQuestions, GameSeconds, Player, Resource) ->
  ?WARNING_MSG("check_player_in_game ~p ~p", [Player, GameId]),
  case player_store:match_object({GameId, Player, '_', '_', '_', '_'}) of
    [] ->
      Delay1 = gen_mod:get_module_opt(Server, ?MODULE, delay1, 5000),
      Delay2 = gen_mod:get_module_opt(Server, ?MODULE, delay2, 5000),
      Delayb = gen_mod:get_module_opt(Server, ?MODULE, delaybetween, 5000),
      ?WARNING_MSG("insert new player ~p into ~p (delays ~p, ~p, ~p)",
          [Player, GameId, Delay1, Delay2, Delayb]),
      triviajabber_game:take_new_player(Server, GameId, GamePool,
          Player, Resource, GameQuestions, GameSeconds,
          MinPlayers, {Delay1, Delay2, Delayb}),
      "ok";
    Res ->
      ?WARNING_MSG("find ~p, but see unexpected ~p", [Player, Res]),
      "joined"
  end.
%% Check if this player at this resouce has joined game room.
check_player_joined_game(GameId, Player, Resource) ->
  case player_store:match_object ({GameId, Player, Resource, '_', '_', '_'}) of
    [{GameId, Player, Resource, _, _, _}] ->
      player_store:match_delete({GameId, Player, Resource, '_', '_', '_'}),
      triviajabber_game:remove_old_player(GameId),
      ok;
    Res ->
      ?WARNING_MSG("~p ? not found ~p/~p in ~p", [Res, Player, Resource, GameId]),
      notfound
  end.

get_answer_hittime(AnswerTag) ->
  AnswerId = case xml:get_tag_attr("id", AnswerTag) of
    {value, AnswerStr} ->
      AnswerStr;
    Ret1 ->
      ?ERROR_MSG("get_tag_attr(id) = ~p", [Ret1]),
      null
  end,
  Hittime = case xml:get_tag_attr("time", AnswerTag) of
    {value, Hit} ->
      Hit;
    Ret2 ->
      ?ERROR_MSG("get_tag_attr(time) = ~p", [Ret2]),
      null
  end,
  {AnswerId, Hittime}.

%% get all participants in MUC
get_room_occupants(Server, RoomName) ->
    MucService = ?DEFAULT_ROOM_SERVICE ++ Server,
    ?WARNING_MSG("RoomName ~p, MucService ~p", [RoomName, MucService]),
    StateData = get_room_state(Server, RoomName),
    [U#user.jid
     || {_, U} <- ?DICT:to_list(StateData#state.users)].

get_room_state(Server, RoomName) ->
    MucService = ?DEFAULT_ROOM_SERVICE ++ Server,
    case mnesia:dirty_read(muc_online_room, {RoomName, MucService}) of
        [R] ->
            RoomPid = R#muc_online_room.pid,
            get_room_state(RoomPid);
        [] ->
            #state{}
    end.

get_room_state(RoomPid) ->
    {ok, R} = gen_fsm:sync_send_all_state_event(RoomPid, get_state),
    R.

%% fill xml into lifeline iqs
lifeline_clairvoyance_xml(Question, O1, O2, O3, O4) ->
  Sum = O1 + O2 + O3 + O4,
  O1Str = erlang:integer_to_list(O1),
  O2Str = erlang:integer_to_list(O2),
  O3Str = erlang:integer_to_list(O3),
  O4Str = erlang:integer_to_list(O4),
  SumStr = erlang:integer_to_list(Sum),
  QuestionStr = erlang:integer_to_list(Question),
  {xmlelement, "lifeline", [{"type", "clairvoyance"}, {"status", "ok"}],
    [{xmlelement, "question", [{"id", QuestionStr}, {"response", SumStr}],
      [
       {xmlelement, "option", [{"id", "1"}, {"count", O1Str}], []},
       {xmlelement, "option", [{"id", "2"}, {"count", O2Str}], []},
       {xmlelement, "option", [{"id", "3"}, {"count", O3Str}], []},
       {xmlelement, "option", [{"id", "4"}, {"count", O4Str}], []}
      ]
     }
    ]
  }.

lifeline_fifty_xml(Step, Int1Id, Int2Id) ->
  Id1 = erlang:integer_to_list(Int1Id),
  Id2 = erlang:integer_to_list(Int2Id),
  QuestionIdStr = erlang:integer_to_list(Step),
  {xmlelement, "lifeline", [{"type", "fifty"}, {"status", "ok"}],
    [
     {xmlelement, "question", [{"id", QuestionIdStr}],
         [] %% Dont need question text [{xmlcdata, QPhrase}]
     },
     {xmlelement, "answers", [],
         [{xmlelement, "option", [{"id", Id1}],
             [] %% Dont need option text [{xmlcdata, Opt1}]
          },
          {xmlelement, "option", [{"id", Id2}],
             [] %% Dont need option text [{xmlcdata, Opt2}]
          }]
     }
    ]
  }.

%%% ------------------------------------
%%% Access triviajabber_games table
%%% ------------------------------------

%% {Date, Time} = erlang:universaltime().
utc_sql_datetime(Date, Time) ->
  {Year, Month, Day} = Date,
  {Hour, Minute, Second} = Time,
  lists:flatten(
      io_lib:format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w",
          [Year, Month, Day, Hour, Minute, Second])).

%% add row into triviajabber_games table
games_table(Server, Date, Time, Slug,
    MaxPlayers, WinnerScore, TotalScore) ->
  try get_games_counter(Server, Slug) of
    {selected,["id", "games_counter"],[{RoomIdStr, CounterStr}]} ->
      ?WARNING_MSG("id ~p, games_counter ~p", [RoomIdStr, CounterStr]),
      Counter = erlang:list_to_integer(CounterStr),
      IncCounter = Counter + 1,
      ?WARNING_MSG("room_id(~p), games_counter(~p), inc = ~p",
          [RoomIdStr, CounterStr, IncCounter]),
      set_games_counter(Server, Slug, IncCounter),
      try set_triviajabber_games(Server, Date, Time, RoomIdStr, IncCounter,
          MaxPlayers, WinnerScore, TotalScore) of
        {updated,1} ->
          IncCounter;
        Any ->
          ?ERROR_MSG("inser games row: ~p", [Any]),
          -1
      catch
        Res1:Desc1 ->
          ?ERROR_MSG("Exception1 ~p, ~p", [Res1, Desc1]),
          -2
      end;
    {selected,["id", "games_counter"], List} ->
      ?ERROR_MSG("[room_id, games_counter] returns list: ~p", [List]),
      -3;
    Reason ->
      ?ERROR_MSG("room_id, games_counter: ~p", [Reason]),
      -4
  catch
    Res2:Desc2 ->
      ?ERROR_MSG("Exception2 ~p, ~p", [Res2, Desc2]),
      -5
  end.

%% get games_counter
get_games_counter(Server, Slug) ->
  ejabberd_odbc:sql_query(Server,
      ["select id, games_counter from triviajabber_rooms "
          "where slug='", Slug, "'"]
  ).

%% set games_counter
set_games_counter(Server, Slug, Counter) ->
  CounterStr = erlang:integer_to_list(Counter),
  ejabberd_odbc:sql_query(Server,
      ["update triviajabber_rooms set games_counter = '", CounterStr, "' "
          "where slug='", Slug, "'"]
  ).

set_triviajabber_games(Server, Date, Time, RoomIdStr, Counter,
    MaxPlayers, WinnerScore, TotalScore) ->
  StartTime = utc_sql_datetime(Date, Time),
  {EDate, ETime} = erlang:universaltime(),
  EndTime = utc_sql_datetime(EDate, ETime),
  CounterStr = erlang:integer_to_list(Counter),
  MaxStr = erlang:integer_to_list(MaxPlayers),
  WinnerStr = erlang:integer_to_list(WinnerScore),
  TotalStr = erlang:integer_to_list(TotalScore),
  ejabberd_odbc:sql_query(Server,
      ["insert into triviajabber_games ("
          "room_id, created_at, updated_at, time_start, time_end, " 
          "counter, players_max, winner_score, total_score"
          ") values('", RoomIdStr, "', '", StartTime, "', '", EndTime,
          "', '", StartTime, "', '", EndTime, "', '",
          CounterStr, "', '", MaxStr, "', '", WinnerStr, "', '",
          TotalStr, "')"]
  ).
%%% ------------------------------------
%%% Access Redis
%%% ------------------------------------

redis_client(Server) ->
  case whereis(eredis_driver) of
    undefined ->
      case eredis:start_link(redis_host(Server), redis_port(Server), redis_db(Server)) of
        {ok, Client} ->
          register(eredis_driver, Client),
          {ok, Client};
        {error, Reason} ->
          {error, Reason}
      end;
    Pid ->
      {ok, Pid}
  end.

redis_host(Server) ->
  gen_mod:get_module_opt(Server, ?MODULE, redis_host, "127.0.0.1").

redis_port(Server) ->
  gen_mod:get_module_opt(Server, ?MODULE, redis_port, 6379).

redis_db(Server) ->
  gen_mod:get_module_opt(Server, ?MODULE, redis_db, 0).

redis_zincrby(Server, Key, Increment, Member) ->
  case redis_client(Server) of
    {ok, Client} ->
      eredis:q(Client, ["ZINCRBY", Key, Increment, Member]);
    {error, Error} ->
      ?ERROR_MSG("Cant connect to redis server: ~p", [Error]),
      error;
    Any ->
      ?ERROR_MSG("redis server: ~p", [Any]),
      unknown
  end.

redis_hincrby(Server, Key, Field, Increment) ->
  case redis_client(Server) of
    {ok, Client} ->
      eredis:q(Client, ["HINCRBY", Key, Field, Increment]);
    {error, Error} ->
      ?ERROR_MSG("Cant connect to redis server: ~p", [Error]),
      error;
    Any ->
      ?ERROR_MSG("redis server: ~p", [Any]),
      unknown
  end.

redis_zadd(Server, Key, Score, Member) ->
  case redis_client(Server) of
    {ok, Client} ->
      eredis:q(Client, ["ZADD", Key, Score, Member]);
    {error, Error} ->
      ?ERROR_MSG("Cant connect to redis server: ~p", [Error]),
      error;
    Any ->
      ?ERROR_MSG("redis server: ~p", [Any]),
      unknown
  end.

redis_hmset(Server, Key, Hits, Responses) ->
  case redis_client(Server) of
    {ok, Client} ->
      eredis:q(Client, ["HMSET", Key, "hits", Hits, "responses", Responses]);
    {error, Error} ->
      ?ERROR_MSG("Cant connect to redis server: ~p", [Error]),
      error;
    Any ->
      ?ERROR_MSG("redis server: ~p", [Any]),
      unknown
  end.
