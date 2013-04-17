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

%% API
-export([start_link/2, start/2, stop/1]).

%% Hooks
-export([user_offline/3, user_offline/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% helper
%%-export([remove_player_from_games/1]).

%% spawn
-export([iq_disco_items/3]).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("adhoc.hrl").
-include_lib("qlc.hrl").

%% Helpers

-define(PROCNAME, ejabberd_mod_triviajabber).
-define(DEFAULT_MINPLAYERS, 1).
-define(DEFAULT_GAME_SERVICE, "triviajabber").
-define(DEFAULT_ROOM_SERVICE, "rooms").
-define(JOIN_EVENT_NODE, "join_game").

-record(sixclicksstate, {host, route, minplayers = ?DEFAULT_MINPLAYERS}).

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
  player_store:close(),
  ejabberd_hooks:delete(sm_remove_connection_hook, Host,
      ?MODULE, user_offline, 100),
  ejabberd_hooks:delete(unset_presence_hook, Host,
      ?MODULE, user_offline, 100),
  Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
  ?DEBUG("Stopping server ~p~n", [Proc]),
  gen_server:call(Proc, stop),
  supervisor:delete_child(ejabberd_sup, Proc).

%% "unavailable" hook
user_offline(_Sid, Jid, _SessionInfo) ->
  ?DEBUG("~p has gone offline", [Jid]),
  remove_player_from_games(Jid).

user_offline(User, Server, Resource, _Status) ->
  Jid = jlib:make_jid(User, Server, Resource),
  remove_player_from_games(Jid).

%% FIXME
remove_player_from_games(Jid) ->
  User = Jid#jid.user,
  Res = Jid#jid.resource,
  player_store:match_delete({'_', User, Res}).

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
  ?WARNING_MSG("Service name ~p, Host ~p", [ServiceName, Host]),
  MinPlayers = gen_mod:get_opt(minplayers, Opts, ?DEFAULT_MINPLAYERS),
  %%Route = ServiceName ++ ".@" ++ Host,
  Route = gen_mod:get_opt_host(Host, Opts, ServiceName ++ ".@HOST@"),
  ?WARNING_MSG("init ~p, min ~p", [Route, MinPlayers]),
  ejabberd_hooks:add(sm_remove_connection_hook, Host,
                               ?MODULE, user_offline, 100),
  ejabberd_hooks:add(unset_presence_hook, Host,
                               ?MODULE, user_offline, 100),

  ejabberd_router:register_route(Route),
  {ok, #sixclicksstate{host = Host, route = Route,
                       minplayers = MinPlayers}
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
  ?WARNING_MSG("handle_info ~p: ~p~n", [From, Packet]),
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
      ?WARNING_MSG("[empty To] Name ~p, Attrs ~p", [Name, Attrs]),
      case Name of
        "iq" ->
          case jlib:iq_query_info(Packet) of
            #iq{type = get, xmlns = ?NS_DISCO_ITEMS} = IQ ->
              spawn(?MODULE, iq_disco_items,
                  [From, To, IQ]); %% TODO: fill arguments
            #iq{type = set, xmlns = ?NS_COMMANDS} = IQ ->
              Res = case iq_command(From, To, IQ, State) of
                      {error, Error} ->
                        jlib:make_error_reply(Packet, Error);
                      {result, IQRes} ->
                        jlib:iq_to_xml(IQ#iq{type = result,
                                             sub_el = [IQRes]})
                    end,
              ?WARNING_MSG("Roomfinder response:~p~n", [Res]),
              ejabberd_router:route(To, From, Res);
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
      ?WARNING_MSG("[~p] Name ~p, Attrs ~p", [To, Name, Attrs]),
      case xml:get_attr_s("type", Attrs) of
        "error" ->
          ok;
        "result" ->
          ok;
        _ ->
          Err = jlib:make_error_reply(Packet, ?ERR_ITEM_NOT_FOUND),
          ejabberd_router:route(To, From, Err)
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
    From, _SixClicks, Options, State) ->
  {Items, Message} = execute_command(Command, From, Options, State),
  ?WARNING_MSG("Items ~p, Message ~p", [Items, Message]),
  Result =
    {xmlelement, "x",
      [{"xmlns", ?NS_XDATA}, {"type", "result"}],
      [{xmlelement, "title", [], [{xmlcdata, Message}]},
       {xmlelement,"item", Items, [{xmlelement,"value", [], [{xmlcdata, "done"}]}]
%%         [{xmlelement,"field",
%%          [{"var","status"}],
%%          [{xmlelement,"value", [], [{xmlcdata, "done"}]}]}]
       }
      ]
    },
  adhoc:produce_response(Request, #adhoc_response{status = completed, elements = [Result]}).

send_initial_form(#adhoc_request{node = ?JOIN_EVENT_NODE} = Request) ->
  Form =
    {xmlelement, "x",
     [{"xmlns", ?NS_XDATA},
      {"type", "form"}],
     [{xmlelement, "title", [], [{xmlcdata, "Enter game id"}]},
      {xmlelement, "field",
       [{"var", "game_id"},
        {"type", "text-single"},
        {"label", "Event id"}],
       [{xmlelement, "required", [], []}]}
     ]
    },
  adhoc:produce_response(Request,
      #adhoc_response{status = executing,
                      elements = [Form]}).

%% disco#items iq
iq_disco_items(From, To, IQ) ->
  Server = From#jid.server,
  GameService = To#jid.server,
  GamesList = game_disco_items(Server, GameService),
  ?WARNING_MSG("Games List ~p", [GamesList]),
  Res = IQ#iq{type = result,
              sub_el = [{xmlelement, "query",
                        [{"xmlns", ?NS_DISCO_ITEMS}],
                        GamesList}]},
  ejabberd_router:route(To, From, jlib:iq_to_xml(Res)).

game_disco_items(Server, GameService) ->
%%  [{xmlelement, "games",
%%    [{"group", "hardcode"}],
%%    [{xmlelement, "game",
%%      [{"name", "name1"}, {"jid", "anonymous1@dev.triviapad.com"}, {"topic", "test topic"}, {"question", "100"}, {"questions", "25"}, {"players", "108"}],
%%      []
%%     },
%%     {xmlelement, "game",
%%      [{"name", "name2"}, {"jid", "anonymous1@dev.triviapad.com"}, {"topic", "test topic 2"}, {"question", "120"}, {"questions", "60"}, {"players", "10"}],
%%      []
%%     }
%%    ]
%%  }].
  try get_all_game_rooms(Server) of
    {selected, ["name", "level",
        "questions_per_game", "slug"], []} ->
      [];
    {selected, ["name", "level",
        "questions_per_game", "slug"], GameList}
        when erlang:is_list(GameList) ->
      {Trial, Regular, Official} = filter_games(GameList, {[], [], []}),
      ?WARNING_MSG("trial ~p\n regular ~p\n official ~p", [Trial, Regular, Official]),
      OfficGames = add_games(GameService, "Official", Official, []),
      RegulGames = add_games(GameService, "Regular", Regular, OfficGames),
      TrialGames = add_games(GameService, "Trial", Trial, RegulGames),
      TrialGames;
    Reason ->
      ?ERROR_MSG("failed to query sixclicks_rooms ~p", [Reason]),
      []
  catch
    Res2:Desc2 ->
      ?ERROR_MSG("Exception [disco#items] ~p, ~p", [Res2, Desc2]),
      []
  end.

%% "Join game" command
execute_command(?JOIN_EVENT_NODE, From, Options, #sixclicksstate{host = Server} = State) ->
  [GameId] = proplists:get_value("game_id", Options),
  ?WARNING_MSG("State ~p", [State]),
  %% FIXME check game room in DB
  try get_game_room(GameId, Server) of
    {selected, ["name", "slug"], []} ->
      {[{"return", "false"}, {"desc", "null"}], "Failed to find game"};
    {selected, ["name", "slug"], [{GameName, GameId}]} ->
      Player = From#jid.user,
      Resource = From#jid.resource,
      case check_player_in_game(Server, GameId, Player, Resource) of
        "ok" ->
          {[{"return", "true"}, {"desc", GameName}], "Find game to join"};
        Err ->
          ?WARNING_MSG("You have joined this game ~p", [Err]),
          {[{"return", "fail"}, {"desc", GameName}], "You have joined this game"}
      end;
    {selected, ["name", "slug"], [{OtherName, _OtherId}]} ->
      {[{"return", "false"}, {"desc", OtherName}], "Error in database"};
    Reason ->
      ?ERROR_MSG("failed to query sixclicks_rooms ~p", [Reason]),
      {[{"return", "false"}, {"desc", "null"}], "Failed to find game"}
  catch
    Res2:Desc2 ->
      ?ERROR_MSG("Exception ~p, ~p", [Res2, Desc2]),
      {[{"return", "false"}, {"desc", "null"}], "Exception when query game room"}
  end.

%% Helpers
get_game_room(GameId, Server) ->
  ejabberd_odbc:sql_query(
      Server,
      ["select name, slug from sixclicks_rooms "
       "where slug='", GameId, "'"]
  ).

get_all_game_rooms(Server) ->
  ejabberd_odbc:sql_query(Server,
      ["select name, level, questions_per_game, slug from sixclicks_rooms"]
  ).

filter_games([], {T, R, O}) ->
  {T, R, O};
filter_games([Head|Tail], {T, R, O}) ->
  {Name, Level, Questions, Slug} = Head,
  case Level of
    "T" ->
      filter_games(Tail, {[{Name, Questions, Slug}|T], R, O});
    "R" ->
      filter_games(Tail, {T, [{Name, Questions, Slug}|R], O});
    "O" ->
      filter_games(Tail, {T, R, [{Name, Questions, Slug}|O]})
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
  lists:map(fun({Name, Questions, Slug}) ->
    Jid = Slug ++ "@" ++ GameService,
    PlayersList = player_store:match_object({Slug, '$1', '_'}),
    PlayersCount = erlang:length(PlayersList),
    ?WARNING_MSG("slug ~p, questions ~p: Players ~p (~p)", [Slug, Questions, PlayersList, PlayersCount]),
    {xmlelement, "game",
      [{"name", Name}, {"jid", Jid}, {"topic", "test topic"}, {"question", "-1"}, {"questions", Questions}, {"players", erlang:integer_to_list(PlayersCount)}],
      []
     }
  end, Items).

check_player_in_game(Server, GameId, Player, Resource) ->
  ?WARNING_MSG("check_player_in_game ~p ~p", [Player, GameId]),
  case player_store:match_object({GameId, Player, '_'}) of
    [] ->
      player_store:insert(GameId, Player, Resource),
      triviajabber_game:take_new_player(Server, GameId, Player, Resource)
      "ok";
    Res ->
      ?WARNING_MSG("check_player_in_game ~p", [Res])
  end.

  


