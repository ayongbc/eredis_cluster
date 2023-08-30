-module(eredis_cluster_monitor).
-behaviour(gen_server).

%% API.
-export([start_link/0]).
-export([connect/1, connect/2]).
% -export([refresh_mapping/2]).
-export([get_state/1, get_state_version/1]).
-export([get_pool_by_slot/2, get_pool_by_slot/3]).
-export([get_all_pools/1]).
-export([get_all_clusters/0]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% Type definition.
-include("eredis_cluster.hrl").

%% API.
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local,?MODULE}, ?MODULE, [], []).

-spec connect(ClusterName, ClusterOpts) -> Result when
    ClusterName :: atom(),
    ClusterOpts :: eredis_cluster:cluster_options(),
    Result :: ok | {error, term()}.
connect(ClusterName, ClusterOpts) ->
    connect([{cluster_name, ClusterName} | ClusterOpts]).

-spec connect(ClusterOpts) -> Result when
    ClusterOpts :: eredis_cluster:cluster_options(),
    Result :: ok | {error, term()}.
connect(ClusterOpts) ->
    case proplists:get_value(cluster_name, ClusterOpts) of
        undefined ->
            {error, "unknown cluster_name"};
        ClusterName when is_atom(ClusterName) ->
            gen_server:call(?MODULE,{connect, ClusterOpts},infinity);
        _ ->
            {error, "cluster_name type error"}
    end.

% refresh_mapping(ClusterName, Version) ->
%     gen_server:call(?MODULE,{reload_slots_map,ClusterName,Version}).

%% =============================================================================
%% @doc Given a slot return the link (Redis instance) to the mapped
%% node.
%% @end
%% =============================================================================

-spec get_state(atom()) -> #cluster{}.
get_state(ClusterName) ->
    case ets:lookup(?MODULE, ClusterName) of
        [#cluster{} = Cluster] ->
            {ok, Cluster};
        [] ->
            undefined
    end.

get_state_version(Cluster) ->
    Cluster#cluster.version.

-spec get_all_pools(atom()) -> [pid()].
get_all_pools(ClusterName) ->
    {ok, Cluster} = get_state(ClusterName),
    lists:filter(
        fun (#slots_map{pool=Pool}) ->
            undefined =/= Pool
        end, Cluster#cluster.slots_maps).

get_all_clusters() ->
    lists:foldl(
        fun(#cluster{cluster_name = ClusterName}, Acc) ->
            [ClusterName | Acc]
        end, [], ets:tab2list(?MODULE)).

%% =============================================================================
%% @doc Get cluster pool by slot. Optionally, a memoized Cluster can be provided
%% to prevent from querying ets inside loops.
%% @end
%% =============================================================================
-spec get_pool_by_slot(ClusterName :: atom(), Slot::integer()) ->
    {PoolName::atom() | undefined, Version::integer()} | undefined.
get_pool_by_slot(ClusterName, Slot) ->
    case get_state(ClusterName) of
        undefined ->
            undefined;
        {ok, Cluster} ->
            get_pool_by_slot(ClusterName, Slot, Cluster)
    end.

-spec get_pool_by_slot(ClusterName :: atom(), Slot::integer(), Cluster::#cluster{}) ->
    {PoolName::atom() | undefined, Version::integer()}.
get_pool_by_slot(_ClusterName, Slot, Cluster) ->
    SlotsMap = select_slot(Cluster#cluster.slots_maps, Slot),
    if
        SlotsMap#slots_map.pool =/= undefined ->
            {SlotsMap#slots_map.pool, Cluster#cluster.version};
        true ->
            {undefined, Cluster#cluster.version}
    end.

-spec select_slot([#slots_map{}, ...], non_neg_integer()) -> #slots_map{}.
select_slot([#slots_map{start_slot = S,
    end_slot = E} = SlotMap | _],
    Slot) when (S =< Slot) andalso (Slot =< E) ->
    SlotMap;
select_slot([_| Rest], Slot) ->
    select_slot(Rest, Slot).

%%
%% gen_server.
%%

init([]) ->
    ets:new(?MODULE, [public, set, named_table,
        {read_concurrency, true},
        {keypos, #cluster.cluster_name}]),

    process_flag(trap_exit, true),
    {ok, maps:new()}.

handle_call({connect, ClusterOpts}, _From, State) ->
    ClusterName = proplists:get_value(cluster_name, ClusterOpts),
    case erlang:whereis(ClusterName) of
        undefined ->
            eredis_cluster_pool:start_link(maps:from_list(ClusterOpts));
        _ ->
            ok
    end,
    {reply, ok, State#{ClusterName => ClusterOpts}};

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, State) ->
    error_logger:error_msg("process ~p 'EXIT' reason : ~p.", [Pid, Reason]),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
