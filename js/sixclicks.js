var lissn=lissn||{};

lissn.chat={
  connection:   null,
  jid:"",
  features:     null,
  startquestion: 0,
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
      lissn.chat.join_game_iq(gameid, 'join_game');
    });

    $("#leavegame").click(function(ev) {
      var gameid = $("#leavegameid").val();
      lissn.chat.join_game_iq(gameid, 'leave_game');
    });

    $("#discoitems").click(function(ev) {
      lissn.chat.disco_items_iq();
    });

    $("#answergame").click(function(ev) {
      var answergameid = $("#answergameid").val();
      var gameid = $("#gameid").val();
      lissn.chat.answer_msg(answergameid, gameid);
    });

    $("#joinmuc").click(function(ev) {
      var muc = $("#joinmucid").val();
      lissn.chat.join_muc(muc);
    });

    $("#statusgame").click(function(ev) {
      var gameid = $("#statusgameid").val();
      lissn.chat.join_game_iq(gameid, 'status_game');
    });

    $("#fifty").click(function(ev) {
      var slug = $("#gameid").val();
      console.log("gameid = " + slug);
      lissn.chat.lifeline_iq(slug, "fifty");
    });
  },

  rawInput:function(data) {
    var restype = $(data).attr('type');
    if (restype === "question") {
      lissn.chat.startquestion = new Date().getTime();
      $(".question-log").text(data);
      var qId = $(data).attr('id');
      $("#trackanswer").text(qId);
    } else if (restype === "ranking") {
      var ranktag = $(data).find("rank");
      var rtype = ranktag.attr('type');
      if (rtype === "question")
        $(".question-ranking").text(data);
      else if (rtype === "game")
        $(".game-ranking").text(data);
    } else
      $(".response-log").text(data);
  },

  rawOutput:function(data) {
    var anstype = $(data).attr('type');
    if (anstype === "answer") {
      $(".answer-log").text(data);
//    } else if (anstype === "ranking") {
//      $(".game-ranking").text(data);
    } else
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

  lifeline_iq: function(gameId, event_node) {
    var command_id =lissn.chat.connection.getUniqueId("command");
    var command_attrs = {
        'xmlns': 'http://jabber.org/protocol/commands',
        'node' : event_node,
        'action' : 'execute'
    };
    var lifelineIq = $iq({
      'to': gameId + "@triviajabber." + lissn.chat.domainName,
      'from': lissn.chat.connection.jid,
      'id': command_id,
      'type': 'set'
    })
      .c('command', command_attrs)
      .c('x', {'xmlns': 'jabber:x:data', 'type': 'submit'});

    command_callback = function(e) {
      return true;
    };
    lissn.chat.connection.addHandler(command_callback, 'jabber:client', 'iq', 'result', command_id, null);
    lissn.chat.connection.send(lifelineIq.tree());
  },

  join_game_iq: function(game, event_node) {
//  event_node = 'join_game';
//  event_node = 'leave_game';
//  event_node = 'status_game';
    var command_id =lissn.chat.connection.getUniqueId("command");
    var command_attrs = {
        'xmlns': 'http://jabber.org/protocol/commands',
        'node' : event_node,
        'action' : 'execute'
    };

    var commandIq = $iq({
      'to': game + "@triviajabber."+lissn.chat.domainName,
      'from': lissn.chat.connection.jid,
      'id': command_id,
      'type': 'set'
    })
      .c('command', command_attrs)
      .c('x', {'xmlns': 'jabber:x:data', 'type': 'submit'});

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
  
  join_muc: function(muc) {
    var myarray = lissn.chat.jid.split("@");
    var mucJid = muc + "@" + lissn.chat.conference + "/" + myarray[0];
    var mucpre = $pres({to: mucJid})
        .c('x', {xmlns: Strophe.NS.MUC});
    lissn.chat.connection.send(mucpre);
  },

  answer_msg: function(myans, slug) {
    var hittime = new Date().getTime() - lissn.chat.startquestion;
    var qId = $("#trackanswer").text();
    var toSlug = slug + "@triviajabber."+lissn.chat.domainName;
    var answer_attr = {
      "id": myans,
      "time": hittime
    };
    var answer_msg = $msg({to: toSlug, "type": "answer", "id": qId})
        .c("answer", answer_attr);

    lissn.chat.connection.send(answer_msg);
  }
}; // end lissn.chat

$(document).ready(function(){
  lissn.chat.init();
});

window.onbeforeunload=function(){
  lissn.chat.disconnect();
};
