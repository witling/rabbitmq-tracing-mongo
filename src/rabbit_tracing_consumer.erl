%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ Federation.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2013 GoPivotal, Inc.  All rights reserved.
%%

-module(rabbit_tracing_consumer).

-behaviour(gen_server).

-include_lib("amqp_client/include/amqp_client.hrl").

-import(rabbit_misc, [pget/2, pget/3, table_lookup/2]).

-record(state, {conn, ch, vhost, queue}).

-define(X, <<"amq.rabbitmq.trace">>).

-export([start_link/1, info_all/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

info_all(Pid) ->
    gen_server:call(Pid, info_all, infinity).

%%----------------------------------------------------------------------------

init(Args) ->
    process_flag(trap_exit, true),
    Name = pget(name, Args),
    VHost = pget(vhost, Args),
    {ok, Username0} = application:get_env(rabbitmq_tracing_mongo, username),
    Username = case is_binary(Username0) of
                   true -> Username0;
                   false -> list_to_binary(Username0)
               end,
    {ok, Conn} = amqp_connection:start(
                   #amqp_params_direct{username     = Username,
                                       virtual_host = VHost}),
    link(Conn),
    {ok, Ch} = amqp_connection:open_channel(Conn),
    link(Ch),
    #'queue.declare_ok'{queue = Q} =
        amqp_channel:call(Ch, #'queue.declare'{durable   = false,
                                               exclusive = true}),
    #'queue.bind_ok'{} =
    amqp_channel:call(
      Ch, #'queue.bind'{exchange = ?X, queue = Q,
                        routing_key = pget(pattern, Args)}),
    #'basic.qos_ok'{} =
        amqp_channel:call(Ch, #'basic.qos'{prefetch_count = 1}),
    #'basic.consume_ok'{} =
        amqp_channel:subscribe(Ch, #'basic.consume'{queue  = Q,
                                                    no_ack = false}, self()),
    {ok, Mongoip} = application:get_env(mongo_ip),
    {ok, Mongoport} = application:get_env(mongo_port),
    emongo:add_pool(pool_mongo, Mongoip, Mongoport, "rabbit_tracing_app", 5),
    rabbit_tracing_traces:announce(VHost, Name, self()),
    rabbit_log:info("Tracer started~n"),
    {ok, #state{conn = Conn, ch = Ch, vhost = VHost, queue = Q}}.

handle_call(info_all, _From, State = #state{vhost = V, queue = Q}) ->
    [QInfo] = rabbit_mgmt_db:augment_queues(
                [rabbit_mgmt_wm_queue:queue(V, Q)],
                rabbit_mgmt_util:no_range(), basic),
    {reply, [{queue, rabbit_mgmt_format:strip_pids(QInfo)}], State};

handle_call(_Req, _From, State) ->
    {reply, unknown_request, State}.

handle_cast(_C, State) ->
    {noreply, State}.

handle_info(Delivery = {#'basic.deliver'{delivery_tag = Seq}, #amqp_msg{}},
            State    = #state{ch = Ch}) ->
    emongo:insert(pool_mongo, "tracing", delivery_to_json(Delivery)),
    amqp_channel:cast(Ch, #'basic.ack'{delivery_tag = Seq}),
    {noreply, State};

handle_info(_I, State) ->
    {noreply, State}.

terminate(shutdown, #state{conn = Conn, ch = Ch}) ->
    catch amqp_channel:close(Ch),
    catch amqp_connection:close(Conn),
    rabbit_log:info("Tracer stopped~n"),
    ok;

terminate(_Reason, _State) ->
    ok.

code_change(_, State, _) -> {ok, State}.


%%----------------------------------------------------------------------------

delivery_to_json({#'basic.deliver'{routing_key = Key},
                        #amqp_msg{props   = #'P_basic'{headers = H},
                                  payload = Payload}}) ->
    {Type, Q} = case Key of
                    <<"publish.", _Rest/binary>> -> {"published", ""};
                    <<"deliver.", Rest/binary>>  -> {"received",  Rest}
                end,
    {longstr, Node} = table_lookup(H, <<"node">>),
    {longstr, X}    = table_lookup(H, <<"exchange_name">>),
    {array, Keys}   = table_lookup(H, <<"routing_keys">>),
    {table, Props}  = table_lookup(H, <<"properties">>),
    {struct, _Props} = amqp_table(Props),
    [{"timestamp", rabbit_mgmt_format:timestamp(os:timestamp())},
     {"type", Type},
     {"exchange", X},
     {"queue", Q},
     {"node", Node},
     {"properties", _Props},
     {"routing_keys", [K || {_, K} <- Keys]},
     {"payload", Payload}].

amqp_table(unknown)   -> unknown;
amqp_table(undefined) -> amqp_table([]);
amqp_table(Table)     -> {struct, [{Name, amqp_value(Type, Value)} ||
                                      {Name, Type, Value} <- Table]}.

amqp_value(array, Vs)                  -> [amqp_value(T, V) || {T, V} <- Vs];
amqp_value(table, _)                   -> "";
amqp_value(_Type, V) when is_binary(V) -> utf8_safe(V);
amqp_value(_Type, V)                   -> V.

utf8_safe(V) ->
    try
        xmerl_ucs:from_utf8(V),
        V
    catch exit:{ucs, _} ->
            Enc = base64:encode(V),
            <<"Invalid UTF-8, base64 is: ", Enc/binary>>
    end.

%%----------------------------------------------------------------------------
