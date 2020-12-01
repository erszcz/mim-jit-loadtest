%%==============================================================================
%% Copyright 2015-2019 Erlang Solutions Ltd.
%% Licensed under the Apache License, Version 2.0 (see LICENSE file)
%%
%% In this scenarion users are sending message to its neighbours
%% (users wiht lower and grater id defined by NUMBER_OF_*_NEIGHBOURS values)
%% Messages will be sent NUMBER_OF_SEND_MESSAGE_REPEATS to every selected neighbour
%% after every message given the script will wait SLEEP_TIME_AFTER_EVERY_MESSAGE ms
%% Message TTD is calculated by the `received_stanza_handler`.
%%
%%==============================================================================
-module(one2one).

-include_lib("exml/include/exml.hrl").

-define(HOST, <<"localhost">>). %% The virtual host served by the server
-define(SLEEP_TIME_AFTER_SCENARIO, 10000). %% wait 10s after scenario before disconnecting
-required_variable({'NUMBER_OF_PREV_NEIGHBOURS', <<"Number of users before current one to use."/utf8>>}).
-required_variable({'NUMBER_OF_NEXT_NEIGHBOURS',<<"Number of users after current one to use."/utf8>>}).
-required_variable({'NUMBER_OF_SEND_MESSAGE_REPEATS', <<"Number of send message (to all neighours) repeats"/utf8>>}).
-required_variable({'SLEEP_TIME_AFTER_EVERY_MESSAGE', <<"Wait time between sent messages (in seconds)"/utf8>>}).

-behaviour(amoc_scenario).

-compile({parse_transform, lager_transform}).

-export([start/1]).
-export([init/0]).

-type binjid() :: binary().

-spec init() -> ok.
init() ->
    lager:info("init metrics"),
    amoc_metrics:init(counters, amoc_metrics:messages_spiral_name()),
    amoc_metrics:init(times, amoc_metrics:message_ttd_histogram_name()),
    ok.

-spec start(amoc_scenario:user_id()) -> any().
start(MyId) ->
    Cfg = make_user(MyId, <<"res1">>),
    {ok, Client, _} = amoc_xmpp:connect_or_exit(Cfg),
    loop(MyId, Client).

-spec loop(amoc_scenario:user_id(), escalus:client()) -> any().
loop(MyId, Client) ->
    escalus_connection:set_filter_predicate(Client, fun is_message_with_sm_hack/1),

    send_presence_available(Client),
    escalus_connection:wait_safely(Client, 5000),

    PrevNeighbours = amoc_config:get('NUMBER_OF_PREV_NEIGHBOURS', 4),
    NextNeighbours = amoc_config:get('NUMBER_OF_NEXT_NEIGHBOURS', 4),
    NeighbourIds = lists:delete(MyId, lists:seq(max(1,MyId - PrevNeighbours),
                                                MyId + NextNeighbours)),
    SleepTimeAfterMessage = amoc_config:get('SLEEP_TIME_AFTER_EVERY_MESSAGE', 80),
    send_messages_many_times(Client, timer:seconds(SleepTimeAfterMessage), NeighbourIds),
    loop(MyId, Client).

-spec send_presence_available(escalus:client()) -> ok.
send_presence_available(Client) ->
    Pres = escalus_stanza:presence(<<"available">>),
    escalus_connection:send(Client, Pres).

-spec send_presence_unavailable(escalus:client()) -> ok.
send_presence_unavailable(Client) ->
    Pres = escalus_stanza:presence(<<"unavailable">>),
    escalus_connection:send(Client, Pres).

-spec send_messages_many_times(escalus:client(), timeout(), [binjid()]) -> ok.
send_messages_many_times(Client, MessageInterval, NeighbourIds) ->
    S = fun(_) ->
                send_messages_to_neighbors(Client, NeighbourIds, MessageInterval)
        end,
    SendMessageRepeats = amoc_config:get('NUMBER_OF_SEND_MESSAGE_REPEATS', 73),
    lists:foreach(S, lists:seq(1, SendMessageRepeats)).


-spec send_messages_to_neighbors(escalus:client(), [binjid()], timeout()) -> list().
send_messages_to_neighbors(Client, TargetIds, SleepTime) ->
    [send_message(Client, make_jid(TargetId), SleepTime)
     || TargetId <- TargetIds].

-spec send_message(escalus:client(), binjid(), timeout()) -> ok.
send_message(Client, ToId, SleepTime) ->
    MsgIn = make_message(ToId),
    TimeStamp = integer_to_binary(os:system_time(micro_seconds)),
    escalus_connection:send(Client, escalus_stanza:setattr(MsgIn, <<"timestamp">>, TimeStamp)),
    escalus_connection:wait_safely(Client, SleepTime).

-spec make_message(binjid()) -> exml:element().
make_message(ToId) ->
    Multiplier = 40 + rand:uniform(10),
    Bytes = <<"hello sir, you are a gentelman and a scholar.">>,
    Body = << <<Bytes/bytes>> || _ <- lists:seq(1, Multiplier) >>,
    Id = escalus_stanza:id(),
    escalus_stanza:set_id(escalus_stanza:chat_to(ToId, Body), Id).

-spec make_jid(amoc_scenario:user_id()) -> binjid().
make_jid(Id) ->
    BinInt = integer_to_binary(Id),
    ProfileId = <<"user_", BinInt/binary>>,
    Host = ?HOST,
    << ProfileId/binary, "@", Host/binary >>.

-spec pick_server() -> [proplists:property()].
pick_server() ->
    Servers = amoc_config:get(xmpp_servers),
    verify(Servers),
    S = length(Servers),
    N = erlang:phash2(self(), S) + 1,
    lists:nth(N, Servers).

verify(Servers) ->
    lists:foreach(
      fun(Proplist) ->
              true = proplists:is_defined(host, Proplist)
      end,
      Servers
     ).

-spec user_spec(binary(), binary(), binary()) -> escalus_users:user_spec().
user_spec(ProfileId, Password, Res) ->
    %Server = pick_server(),
    Server = [{host, <<"mongooseim-1">>}],
    [ {username, ProfileId},
      {server, ?HOST},
      {password, Password},
      {carbons, false},
      {stream_management, true},
      {starttls, required},
      {resource, Res},
      {received_stanza_handlers, [fun amoc_xmpp_handlers:measure_ttd/3]},
      {sent_stanza_handlers, [fun amoc_xmpp_handlers:measure_sent_messages/2]}
    ] ++ Server.

-spec make_user(amoc_scenario:user_id(), binary()) -> escalus_users:user_spec().
make_user(Id, R) ->
    BinId = integer_to_binary(Id),
    ProfileId = <<"user_", BinId/binary>>,
    Password = <<"password_", BinId/binary>>,
    [{socket_opts, socket_opts()} | user_spec(ProfileId, Password, R)].

-spec socket_opts() -> [gen_tcp:option()].
socket_opts() ->
    [binary,
     {reuseaddr, false},
     {nodelay, true}].

is_message_with_sm_hack(El) ->
    escalus_pred:is_message(El)
    orelse
    escalus_pred:is_sm_ack_request(El)
    orelse
    escalus_pred:is_sm_enabled(El)
    orelse
    escalus_pred:is_sm_resumed(El).
