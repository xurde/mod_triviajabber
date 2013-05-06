var lissn=lissn||{};

lissn.chat={
  connection:   null,
  jid:"",
  features:     null,
  appName:      'sixclicks',
  domainName: 'dev.triviapad.com',
  conference:'rooms.dev.triviapad.com',
  BOSH_URL:"http://dev.triviapad.com:5280/http-bind/",

  init:function(){
    lissn.chat.setup_namespaces();
    lissn.chat.addHandlers();
  },

  setup_namespaces: function() {
      Strophe.addNamespace('PUBSUB', 'http://jabber.org/protocol/pubsub');
      Strophe.addNamespace('PEP', 'http://jabber.org/protocol/pubsub#event');
      Strophe.addNamespace('TUNE', 'http://jabber.org/protocol/tune');
      Strophe.addNamespace('CAPS', 'http://jabber.org/protocol/caps');
      Strophe.addNamespace('CLIENT', 'jabber:client');
      Strophe.addNamespace('ROSTER', 'jabber:iq:roster');
      Strophe.addNamespace('CHATSTATES', 'http://jabber.org/protocol/chatstates');
      Strophe.addNamespace('MUC', 'http://jabber.org/protocol/muc');
      Strophe.addNamespace('MUC_USER', 'http://jabber.org/protocol/muc#user');
      Strophe.addNamespace('MUC_OWNER', 'http://jabber.org/protocol/muc#owner');
      Strophe.addNamespace("GEOLOC","http://jabber.org/protocol/geoloc");

      lissn.chat.NS={
        "CHAT":"convo_chat",
        "COMMAND":'lissn_command',
        "INFO":"lissn_infomation"
      };

  },//end setup_namespaces

  addHandlers:function(){
    $("#signin").click(function(ev) {
       if (lissn.chat.connection) {
         lissn.chat.disconnect();
         $("#signin").html("Sign in");
       } else {
         var chatjid = $("#jid").val();
         var password = $("#pass").val();
         lissn.chat.connect(chatjid, password);
       }
    });
    
    $("#joingame").click(function(ev) {
      var gameid = $("#gameid").val();
      lissn.chat.join_game_iq(gameid, true);
    });

    $("#leavegame").click(function(ev) {
      var gameid = $("#leavegameid").val();
      lissn.chat.join_game_iq(gameid, false);
    });

    $("#discoitems").click(function(ev) {
      lissn.chat.disco_items_iq();
    });

    $("#answergame").click(function(ev) {
      var answergameid = $("#answergameid").val();
      var gameid = $("#gameid").val();
      lissn.chat.answer_msg(answergameid, gameid);
    });
  },

  rawInput:function(data) {
    var restype = $(data).attr('type');
    if (restype === "question") {
      $(".question-log").text(data);
      var qId = $(data).attr('id');
      $("#trackanswer").text(qId);
    } else if (restype === "ranking") {
      $("#question-ranking").text(data);
    } else
      $(".response-log").text(data);
  },

  rawOutput:function(data) {
    var anstype = $(data).attr('type');
    if (anstype === "answer")
      $(".answer-log").text(data);
    else
      $(".request-log").text(data);
  },

  connect:function(chatjid, password){
    var conn = new Strophe.Connection(lissn.chat.BOSH_URL);
    lissn.chat.jid = chatjid+"@"+lissn.chat.domainName;
//    console.log("usr " + chatjid + ", pass " + password);
    conn.connect(lissn.chat.jid,password, function (status) {
      if (status === Strophe.Status.CONNECTED) {
        $("#signin").html("Sign out");
        lissn.chat.send_available_presence();
      }
      else if (status === Strophe.Status.DISCONNECTED || status===Strophe.Status.AUTHFAIL) {
//        console.log("[fail to connect]");
          $(".response-log").text("[disconnect]");
	lissn.chat.connection=null;
      }
    });

    conn.rawInput = lissn.chat.rawInput;
    conn.rawOutput = lissn.chat.rawOutput;
    lissn.chat.connection=conn;
  },

  disconnect:function() {
    lissn.chat.send_unavailable_presence();
    lissn.chat.connection.sync=true;
    lissn.chat.connection.flush();
    lissn.chat.connection.disconnect();
    //lissn.chat.connection=null;
  },

  join_game_iq: function(game, isJoin) {
    var event_node = null;
    if (isJoin) {
      event_node = 'join_game';
    } else {
      event_node = 'leave_game';
    }
    var command_id =lissn.chat.connection.getUniqueId("command");
    var command_attrs = {
        'xmlns': 'http://jabber.org/protocol/commands',
        'node' : event_node,
        'action' : 'execute'
    };

    var commandIq = $iq({
      'to': "triviajabber."+lissn.chat.domainName,
      'from': lissn.chat.connection.jid,
      'id': command_id,
      'type': 'set'
    })
      .c('command', command_attrs)
      .c('x', {'xmlns': 'jabber:x:data', 'type': 'submit'})
      .c('field', {'var': 'game_id'}).c('value').t(game);

    command_callback = function(e) {
      var c = $(e).find('command');
      if (c.attr("status") == "completed") {
        var returniq = c.find('x item');
        var r = returniq.attr("return");
        var d = returniq.attr("desc");
//        lissn.chat.join_game_callback_success=true;
      }
//      if(!lissn.chat.join_game_callback_success){
//        lissn.chat.join_game_callback_success=true;
//      }
      return true;
    };
    lissn.chat.connection.addHandler(command_callback, 'jabber:client', 'iq', 'result', command_id, null);
    lissn.chat.connection.send(commandIq.tree());
  },

  disco_items_iq: function() {
    var query_id =lissn.chat.connection.getUniqueId("query");
    var query_attrs = {
        'xmlns': 'http://jabber.org/protocol/disco#items',
    };
    
    var queryIq = $iq({
      'to': "triviajabber."+lissn.chat.domainName,
      'from': lissn.chat.connection.jid,
      'id': query_id,
      'type': 'get'
    }).c('query', query_attrs);

    command_callback = function(e) {
      var c = $(e).find('query');
      var namespace = c.attr("xmlns");
      // TODO: show list of games
      return true;
    };
    lissn.chat.connection.addHandler(command_callback, 'jabber:client', 'iq', 'result', query_id, null);
    lissn.chat.connection.send(queryIq.tree());
  },

  send_available_presence: function() {
    var availablePresence = $pres()
            .c('show').t('chat').up()
            .c('status').t('online');
    lissn.chat.connection.send(availablePresence);
  },

  send_unavailable_presence: function() {
    var unavailablePresence = $pres({type:"unavailable"})
	.c('show').t('gone');

    lissn.chat.connection.send(unavailablePresence);
  },

  answer_msg: function(myans, slug) {
    var qId = $("#trackanswer").text();
    var toSlug = slug + "@triviajabber."+lissn.chat.domainName;
    var answer_msg = $msg({to: toSlug, "type": "answer", "id": qId})
        .c("answer").t(myans);

    lissn.chat.connection.send(answer_msg);
  }
}; // end lissn.chat

$(document).ready(function(){
  lissn.chat.init();
});

window.onbeforeunload=function(){
  lissn.chat.disconnect();
};
