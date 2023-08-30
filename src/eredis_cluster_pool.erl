-module(eredis_cluster_pool).

-behaviour(gen_server).

%% Callback
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% API.
-export([start_link/1]).
-export([create/1, create/2]).
-export([stop_pool/1]).
-export([transaction/2]).
-export([reconnect/2]).

-include("eredis_cluster.hrl").
-include_lib("kernel/include/logger.hrl").

-define(ETS_TAB, eredis_cluster_monitor).

-spec create(Node :: #node{}) -> {ok, PoolName :: atom()} | {error, PoolName :: atom()}.
create(Node) ->
    create(get_name(Node#node.cluster_name,
        Node#node.address,
        Node#node.port),
        Node).

-spec create(PoolName :: atom(), Node :: #node{}) ->
    {ok, PoolName :: atom()} | {error, PoolName :: atom()}.
create(PoolName, #node{address = Host,
    port = Port,
    password = Password,
    size = Size,
    max_overflow = MaxOverflow}) ->
    case whereis(PoolName) of
        undefined ->
            WorkerArgs = [Host, Port, Password],

            PoolArgs = [{name, {local, PoolName}},
                {worker_module, eredis_cluster},
                {size, Size},
                {max_overflow, MaxOverflow}],

            %% 不再使用supervisor
            case poolboy:start_link(PoolArgs, WorkerArgs) of
                {ok, Pid} ->
                    {ok, PoolName, Pid};
                _ ->
                    {error, undefined, undefined}
            end;
        Pid ->
            {ok, PoolName, Pid}
    end.

reconnect(ClusterName, Version) ->
    gen_server:call(ClusterName, {reconnect, ClusterName, Version}).

-spec transaction(PoolName :: atom(), fun((Worker :: pid()) -> redis_result())) ->
    redis_result().
transaction(PoolName, Transaction) ->
    try
        poolboy:transaction(PoolName, Transaction)
    catch
        exit:_ ->
            {error, no_connection}
    end.

-spec stop_pool(PoolName :: atom()) -> ok.
stop_pool(PoolName) ->
    % supervisor:terminate_child(?MODULE,PoolName),
    % supervisor:delete_child(?MODULE,PoolName),
    poolboy:stop(PoolName),
    ok.

-spec get_name(Cluster :: atom(), Host :: string(), Port :: integer()) -> PoolName :: atom().
get_name(Cluster, Host, Port) ->
    list_to_atom(lists:concat([
        atom_to_list(Cluster), "#",
        Host, "#",
        integer_to_list(Port)])).

%% ------------------------------------------------------------------
%%    api
%% ------------------------------------------------------------------

start_link(#{cluster_name := ClusterName} = ClusterConfig) ->
    gen_server:start_link({local, ClusterName}, ?MODULE, ClusterConfig, []).

%% =============================================================================
%% Private
%% @doc Get cluster pool by slot. Optionally, a memoized Cluster can be provided
%% to prevent from querying ets inside loops.
%% @end
%% =============================================================================
-spec reload_slots_map(Cluster :: #cluster{}) -> NewCluster :: #cluster{}.
reload_slots_map(Cluster) ->
    ok = close_all_connection(Cluster),

    ClusterSlots = get_cluster_slots(Cluster#cluster.init_nodes),
    SlotsMaps = parse_cluster_slots(ClusterSlots, Cluster#cluster.init_nodes),
    ConnectedSlotsMaps = connect_all_slots(SlotsMaps),

    NewCluster = Cluster#cluster{
        slots_maps = ConnectedSlotsMaps,
        version = Cluster#cluster.version + 1
    },
    true = ets:insert(?ETS_TAB, NewCluster),

    ?LOG_INFO("redis cluster [~p] connected.", [Cluster#cluster.cluster_name]),
    NewCluster.

-spec get_cluster_slots([#node{}]) -> [[bitstring() | [bitstring()]]].
get_cluster_slots([]) ->
    throw({error, cannot_connect_to_cluster});
get_cluster_slots([Node | T]) ->
    case catch safe_eredis_start_link(Node) of
        {ok, Connection} ->
            case eredis:q(Connection, ["CLUSTER", "SLOTS"]) of
                {ok, ClusterInfo} ->
                    eredis:stop(Connection),
                    ClusterInfo;
                {error, Reason} ->
                    throw({error, Reason});
                _ ->
                    eredis:stop(Connection),
                    get_cluster_slots(T)
            end;
        _ ->
            get_cluster_slots(T)
    end.

safe_eredis_start_link(#node{address = Address,
    port = Port,
    password = Password}) ->
    eredis_cluster:start_link([Address, Port, Password]).

-spec parse_cluster_slots([[bitstring() | [bitstring()]]], [#node{}, ...]) -> [#slots_map{}].
parse_cluster_slots(ClusterInfo, Nodes) ->
    parse_cluster_slots(ClusterInfo, Nodes, 1, []).

parse_cluster_slots([[StartSlot, EndSlot | [[Address, Port, Id] | _]] | T], Nodes, Index, Acc) ->
    case lists:keyfind(Address, #node.address, Nodes) of
        false ->
            [Node | _] = Nodes;
        #node{} = Node ->
            Node
    end,
    SlotsMap =
        #slots_map{
            id = Id,
            index = Index,
            start_slot = binary_to_integer(StartSlot),
            end_slot = binary_to_integer(EndSlot),
            node = Node#node{
                address = binary_to_list(Address),
                port = binary_to_integer(Port)
            }
        },
    parse_cluster_slots(T, Nodes, Index + 1, [SlotsMap | Acc]);
parse_cluster_slots([], _Nodes, _Index, Acc) ->
    lists:reverse(Acc).


-spec close_all_connection(#cluster{}) -> ok.
close_all_connection(#cluster{slots_maps = SlotsMaps}) ->
    [close_connection(SlotsMap) || SlotsMap <- SlotsMaps],
    ok.

-spec close_connection(#slots_map{}) -> ok.
close_connection(#slots_map{pool = Pool}) ->
    Pid = erlang:whereis(Pool),
    if
        undefined =:= Pid -> ok;
        true ->
            catch poolboy:stop(Pool)
    end,
    ok.

-spec connect_all_slots([#slots_map{}]) -> [integer()].
connect_all_slots(SlotsMapList) ->
    lists:foldl(
        fun(#slots_map{node = Node} = SlotsMap, Acc) ->
            {_, PoolName, Pid} = eredis_cluster_pool:create(Node),
            [SlotsMap#slots_map{pool = PoolName, pid = Pid} | Acc]
        end, [], SlotsMapList).

%%@private 格式化配置参数
init_nodes([], _ClusterName, _Password, _Size, _MaxOverflow) -> [];
init_nodes(InitNodes, ClusterName, Password, Size, MaxOverflow) ->
    init_nodes(InitNodes, ClusterName, Password, Size, MaxOverflow, []).

init_nodes([NodeArgs | Rest], ClusterName, Password, Size, MaxOverflow, Nodes) ->
    Host = proplists:get_value(host, NodeArgs, "127.0.0.1"),
    Port = proplists:get_value(port, NodeArgs, 6379),
    Node = #node{
        cluster_name = ClusterName,
        address = Host,
        port = Port,
        password = Password,
        size = Size,
        max_overflow = MaxOverflow
    },
    init_nodes(Rest, ClusterName, Password, Size, MaxOverflow, [Node | Nodes]);
init_nodes([], _ClusterName, _Password, _Size, _MaxOverflow, Nodes) ->
    Nodes.

%%@doc 启动定时器
-spec start_timer(#cluster{}) -> #cluster{}.
start_timer(#cluster{tref = undefined} = Cluster) ->
    TRef = erlang:start_timer(5000, self(), reconnect),
    Cluster#cluster{tref = TRef};
start_timer(#cluster{tref = TRef} = Cluster) ->
    erlang:cancel_timer(TRef),
    TRef1 = erlang:start_timer(5000, self(), reconnect),
    Cluster#cluster{tref = TRef1}.

%% ------------------------------------------------------------------
%%    回调函数
%% ------------------------------------------------------------------
init(#{cluster_name := ClusterName,
    nodes := Nodes} = Opts) ->
    Password = maps:get(password, Opts, ""),
    Size = maps:get(size, Opts, 5),
    MaxOverflow = maps:get(max_overflow, Opts, 0),
    Cluster = #cluster{
        cluster_name = ClusterName,
        slots_maps = [],
        init_nodes = init_nodes(Nodes, ClusterName, Password, Size, MaxOverflow),
        version = 0
    },
    NewCluster = reload_slots_map(Cluster),
    process_flag(trap_exit, true),
    {ok, NewCluster}.

handle_call({reconnect, ClusterName, Version}, _From, Cluster) ->
    case ets:lookup(?ETS_TAB, ClusterName) of
        %% check version, avoid repetition
        [#cluster{version = Version} = Cluster] ->
            {reply, ok, reload_slots_map(Cluster)};
        [] ->
            {reply, reconnecting, Cluster};
        _ ->
            {reply, ok, Cluster}
    end;

handle_call(_Request, _From, Cluster) ->
    {reply, {error, unknown_call}, Cluster}.

handle_cast(_Msg, Cluster) ->
    {noreply, Cluster}.

handle_info({'EXIT', _NodePid, normal}, Cluster) ->
    {noreply, Cluster};

handle_info({'EXIT', _NodePid, Reason}, Cluster) ->
    ets:delete(?ETS_TAB, Cluster#cluster.cluster_name),
    ?LOG_ERROR("eredis cluster disconnected, node pid:~p, reason : ~p.", [_NodePid, Reason]),
    % redis update cluster status and master-slave info after several seconds
    {noreply, start_timer(Cluster)};

handle_info({timeout, TRef, reconnect}, #cluster{tref = TRef} = Cluster) ->
    ?LOG_INFO("eredis cluster reconnect, Cluster:~p.", [Cluster]),
    {noreply, reload_slots_map(Cluster#cluster{tref = undefined})};

handle_info(_Info, Cluster) ->
    {noreply, Cluster}.

terminate(_Reason, Cluster) ->
%%    ets:delete(?ETS_TAB, Cluster#cluster.cluster_name),
    close_all_connection(Cluster),
    ok.

code_change(_OldVsn, Cluster, _Extra) ->
    {ok, Cluster}.
