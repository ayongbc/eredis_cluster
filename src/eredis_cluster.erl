-module(eredis_cluster).
-behaviour(application).

% Application.
-export([start/2]).
-export([stop/1]).

% API.
-export([start/0, stop/0, connect/1, connect/2]). % Application Management.

-export([start_link/1]). % poolboy eredis worker start_link/1 function

% Generic redis call
-export([q/2, qp/2, qw/2, qk/3, qa/2, qmn/2, transaction/2, transaction/3]).

% Specific redis command implementation
-export([flushdb/1]).

% Helper functions
-export([update_key/3]).
-export([update_hash_field/4]).
-export([optimistic_locking_transaction/4]).
-export([eval/5]).

-export_type([cluster_options/0, cluster_option/0, node_opts/0, node_opt/0]).

-include("eredis_cluster.hrl").

-type cluster_options() :: [cluster_option()].

-type cluster_option() :: {cluster_name, atom()} |
{nodes, node_opts()} |
{password, string()} |
{size, non_neg_integer()} |
{max_overflow, non_neg_integer()}.

-type node_opts() :: [node_opt()].

-type node_opt() :: {host, string()} |
{port, non_neg_integer()}.

-spec start(StartType :: application:start_type(), StartArgs :: term()) ->
    {ok, pid()}.
start(_Type, _Args) ->
    eredis_cluster_sup:start_link().

-spec stop(State :: term()) -> ok.
stop(_State) ->
    ok.

-spec start() -> ok | {error, Reason :: term()}.
start() ->
    application:start(?MODULE).

-spec stop() -> ok | {error, Reason :: term()}.
stop() ->
    application:stop(?MODULE).

start_link([Host, Port, Password]) ->
    %% SELECT is not allowed in cluster mode.
    %% Only database num 0 is available.
    eredis:start_link(Host, Port, 0, Password, no_reconnect).

%% =============================================================================
%% @doc Connect to a set of init node, useful if the cluster configuration is
%% not known at startup
%% @end
%% =============================================================================
-spec connect(Options) -> Result when
    Options :: cluster_options(),
    Result :: ok | {error, term()}.
connect(Options) ->
    case proplists:get_value(cluster_name, Options) of
        undefined ->
            {error, "lack of cluster_name"};
        ClusterName when is_atom(ClusterName) ->
            ok = eredis_cluster_monitor:connect(Options);
        _ ->
            {error, "cluster_name type error"}
    end.

-spec connect(ClusterName, Options) -> Result when
    ClusterName :: atom(),
    Options :: cluster_options(),
    Result :: ok | {error, term()}.
connect(ClusterName, Options) ->
    Options1 = proplists:delete(cluster_name, Options),
    connect([{cluster_name, ClusterName} | Options1]).

%% =============================================================================
%% @doc Wrapper function to execute a pipeline command as a transaction Command
%% (it will add MULTI and EXEC command)
%% @end
%% =============================================================================
-spec transaction(atom(), redis_pipeline_command()) -> redis_transaction_result().
transaction(ClusterName, Commands) ->
    Result = q(ClusterName, [["multi"] | Commands] ++ [["exec"]]),
    lists:last(Result).

%% =============================================================================
%% @doc Execute a function on a pool worker. This function should be use when
%% transaction method such as WATCH or DISCARD must be used. The pool used to
%% execute the transaction is specified by giving a key that this pool is
%% containing.
%% @end
%% =============================================================================
-spec transaction(atom(), fun((Worker :: pid()) -> redis_result()), anystring()) -> any().
transaction(ClusterName, Transaction, PoolKey) ->
    Slot = get_key_slot(PoolKey),
    transaction(ClusterName, Transaction, Slot, undefined, 0).

transaction(ClusterName, Transaction, Slot, undefined, _) ->
    query(ClusterName, Transaction, Slot, 0);
transaction(ClusterName, Transaction, Slot, ExpectedValue, Counter) ->
    case query(ClusterName, Transaction, Slot, 0) of
        ExpectedValue ->
            transaction(ClusterName, Transaction, Slot, ExpectedValue, Counter - 1);
        {ExpectedValue, _} ->
            transaction(ClusterName, Transaction, Slot, ExpectedValue, Counter - 1);
        Payload ->
            Payload
    end.

%% =============================================================================
%% @doc Multi node query
%% @end
%% =============================================================================
-spec qmn(atom(), redis_pipeline_command()) -> redis_pipeline_result().
qmn(ClusterName, Commands) -> qmn(ClusterName, Commands, 0).

qmn(_, _, ?REDIS_CLUSTER_REQUEST_TTL) ->
    {error, no_connection};
qmn(ClusterName, Commands, Counter) ->
    %% Throttle retries
    throttle_retries(Counter),

    case split_by_pools(ClusterName, Commands) of
        undefined ->
            qmn(ClusterName, Commands, Counter + 1);
        {CommandsByPools, MappingInfo, Version} ->
            case qmn2(CommandsByPools, MappingInfo, [], Version) of
                retry -> qmn(ClusterName, Commands, Counter + 1);
                Res -> Res
            end
    end.

qmn2([{ClusterName, Pool, PoolCommands} | T1], [{Pool, Mapping} | T2], Acc, Version) ->
    Transaction = fun(Worker) -> qw(Worker, PoolCommands) end,
    Result = eredis_cluster_pool:transaction(Pool, Transaction),
    case handle_transaction_result(ClusterName, Result, Version, check_pipeline_result) of
        retry -> retry;
        Res ->
            MappedRes = lists:zip(Mapping, Res),
            qmn2(T1, T2, MappedRes ++ Acc, Version)
    end;
qmn2([], [], Acc, _) ->
    SortedAcc =
        lists:sort(
            fun({Index1, _}, {Index2, _}) ->
                Index1 < Index2
            end, Acc),
    [Res || {_, Res} <- SortedAcc].

split_by_pools(ClusterName, Commands) ->
    case eredis_cluster_monitor:get_state(ClusterName) of
        undefined ->
            undefined;
        State ->
            split_by_pools(ClusterName, Commands, 1, [], [], State)
    end.

split_by_pools(ClusterName, [Command | T], Index, CmdAcc, MapAcc, State) ->
    Key = get_key_from_command(Command),
    Slot = get_key_slot(Key),
    {Pool, _Version} = eredis_cluster_monitor:get_pool_by_slot(Slot, State),
    {NewAcc1, NewAcc2} =
        case lists:keyfind(Pool, 1, CmdAcc) of
            false ->
                {[{ClusterName, Pool, [Command]} | CmdAcc], [{Pool, [Index]} | MapAcc]};
            {Pool, CmdList} ->
                CmdList2 = [Command | CmdList],
                CmdAcc2 = lists:keydelete(Pool, 1, CmdAcc),
                {Pool, MapList} = lists:keyfind(Pool, 1, MapAcc),
                MapList2 = [Index | MapList],
                MapAcc2 = lists:keydelete(Pool, 1, MapAcc),
                {[{ClusterName, Pool, CmdList2} | CmdAcc2], [{Pool, MapList2} | MapAcc2]}
        end,
    split_by_pools(ClusterName, T, Index + 1, NewAcc1, NewAcc2, State);
split_by_pools(ClusterName, [], _Index, CmdAcc, MapAcc, State) ->
    CmdAcc2 = [{ClusterName, Pool, lists:reverse(Commands)} || {Pool, Commands} <- CmdAcc],
    MapAcc2 = [{ClusterName, Pool, lists:reverse(Mapping)} || {Pool, Mapping} <- MapAcc],
    {CmdAcc2, MapAcc2, eredis_cluster_monitor:get_state_version(State)}.

%% =============================================================================
%% @doc Wrapper function for command using pipelined commands
%% @end
%% =============================================================================
-spec qp(atom(), redis_pipeline_command()) -> redis_pipeline_result().
qp(ClusterName, Commands) -> q(ClusterName, Commands).

%% =============================================================================
%% @doc This function execute simple or pipelined command on a single redis node
%% the node will be automatically found according to the key used in the command
%% @end
%% =============================================================================
-spec q(atom(), redis_command()) -> redis_result().
q(ClusterName, Command) ->
    query(ClusterName, Command).

-spec qk(atom(), redis_command(), bitstring()) -> redis_result().
qk(ClusterName, Command, PoolKey) ->
    query(ClusterName, Command, PoolKey).

query(ClusterName, Command) ->
    PoolKey = get_key_from_command(Command),
    query(ClusterName, Command, PoolKey).

query(_, _, undefined) ->
    {error, invalid_cluster_command};
query(ClusterName, Command, PoolKey) ->
    Slot = get_key_slot(PoolKey),
    Transaction = fun(Worker) -> qw(Worker, Command) end,
    query(ClusterName, Transaction, Slot, 0).

query(_, _, _, ?REDIS_CLUSTER_REQUEST_TTL) ->
    {error, no_connection};
query(ClusterName, Transaction, Slot, Counter) ->
    %% Throttle retries
    throttle_retries(Counter),

    case eredis_cluster_monitor:get_pool_by_slot(ClusterName, Slot) of
        undefined ->
            query(ClusterName, Transaction, Slot, Counter + 1);
        {Pool, Version} ->
            Result = eredis_cluster_pool:transaction(Pool, Transaction),
            case handle_transaction_result(ClusterName, Result, Version) of
                retry -> query(ClusterName, Transaction, Slot, Counter + 1);
                Result -> Result
            end
    end.

handle_transaction_result(ClusterName, Result, Version) ->
    case Result of
        % If we detect a node went down, we should probably refresh the slot
        % mapping.
        {error, no_connection} ->
            eredis_cluster_pool:reconnect(ClusterName, Version),
            retry;

        % If the tcp connection is closed (connection timeout), the redis worker
        % will try to reconnect, thus the connection should be recovered for
        % the next request. We don't need to refresh the slot mapping in this
        % case
        {error, tcp_closed} ->
            retry;

        % Redis explicitly say our slot mapping is incorrect, we need to refresh
        % it
        {error, <<"MOVED ", _/binary>>} ->
            eredis_cluster_pool:reconnect(ClusterName, Version),
            retry;
        {error, <<"READONLY ", _/binary>>} ->
            eredis_cluster_pool:reconnect(ClusterName, Version),
            retry;
        {error, <<"CLUSTERDOWN ", _/binary>>} ->
            eredis_cluster_pool:reconnect(ClusterName, Version),
            retry;
        {error, <<"TRYAGAIN ", _/binary>>} ->
            eredis_cluster_pool:reconnect(ClusterName, Version),
            retry;
        Payload when is_list(Payload) ->
            Pred =
                fun
                    ({error, <<"MOVED ", _/binary>>}) ->
                        true;
                    ({error, <<"READONLY ", _/binary>>}) ->
                        true;
                    ({error, <<"CLUSTERDOWN ", _/binary>>}) ->
                        true;
                    ({error, <<"TRYAGAIN ", _/binary>>}) ->
                        true;
                    (_) ->
                        false
                end,
            case lists:any(Pred, Payload) of
                false -> Payload;
                true ->
                    eredis_cluster_pool:reconnect(ClusterName, Version),
                    retry
            end;
        Payload ->
            Payload
    end.
handle_transaction_result(ClusterName, Result, Version, check_pipeline_result) ->
    case handle_transaction_result(ClusterName, Result, Version) of
        retry -> retry;
        Payload when is_list(Payload) ->
            Pred =
                fun
                    ({error, <<"MOVED ", _/binary>>}) ->
                        true;
                    ({error, <<"READONLY ", _/binary>>}) ->
                        true;
                    ({error, <<"CLUSTERDOWN ", _/binary>>}) ->
                        true;
                    ({error, <<"TRYAGAIN ", _/binary>>}) ->
                        true;
                    (_) ->
                        false
                end,
            case lists:any(Pred, Payload) of
                false -> Payload;
                true ->
                    eredis_cluster_pool:reconnect(ClusterName, Version),
                    retry
            end;
        Payload -> Payload
    end.

-spec throttle_retries(integer()) -> ok.
throttle_retries(0) -> ok;
throttle_retries(_) -> timer:sleep(?REDIS_RETRY_DELAY).

%% =============================================================================
%% @doc Update the value of a key by applying the function passed in the
%% argument. The operation is done atomically
%% @end
%% =============================================================================
-spec update_key(ClusterName :: atom(), Key :: anystring(), UpdateFunction :: fun((any()) -> any())) ->
    redis_transaction_result().
update_key(ClusterName, Key, UpdateFunction) ->
    UpdateFunction2 = fun(GetResult) ->
        {ok, Var} = GetResult,
        UpdatedVar = UpdateFunction(Var),
        {[["SET", Key, UpdatedVar]], UpdatedVar}
                      end,
    case optimistic_locking_transaction(ClusterName, Key, ["GET", Key], UpdateFunction2) of
        {ok, {_, NewValue}} ->
            {ok, NewValue};
        Error ->
            Error
    end.

%% =============================================================================
%% @doc Update the value of a field stored in a hash by applying the function
%% passed in the argument. The operation is done atomically
%% @end
%% =============================================================================
-spec update_hash_field(ClusterName :: atom(), Key :: anystring(), Field :: anystring(),
    UpdateFunction :: fun((any()) -> any())) -> redis_transaction_result().
update_hash_field(ClusterName, Key, Field, UpdateFunction) ->
    UpdateFunction2 = fun(GetResult) ->
        {ok, Var} = GetResult,
        UpdatedVar = UpdateFunction(Var),
        {[["HSET", Key, Field, UpdatedVar]], UpdatedVar}
                      end,
    case optimistic_locking_transaction(ClusterName, Key, ["HGET", Key, Field], UpdateFunction2) of
        {ok, {[FieldPresent], NewValue}} ->
            {ok, {FieldPresent, NewValue}};
        Error ->
            Error
    end.

%% =============================================================================
%% @doc Optimistic locking transaction helper, based on Redis documentation :
%% http://redis.io/topics/transactions
%% @end
%% =============================================================================
-spec optimistic_locking_transaction(ClusterName :: atom(), Key :: anystring(), redis_command(),
    UpdateFunction :: fun((redis_result()) -> redis_pipeline_command())) ->
    {redis_transaction_result(), any()}.
optimistic_locking_transaction(ClusterName, WatchedKey, GetCommand, UpdateFunction) ->
    Slot = get_key_slot(WatchedKey),
    Transaction = fun(Worker) ->
        %% Watch given key
        qw(Worker, ["WATCH", WatchedKey]),
        %% Get necessary information for the modifier function
        GetResult = qw(Worker, GetCommand),
        %% Execute the pipelined command as a redis transaction
        {UpdateCommand, Result} = case UpdateFunction(GetResult) of
                                      {Command, Var} ->
                                          {Command, Var};
                                      Command ->
                                          {Command, undefined}
                                  end,
        RedisResult = qw(Worker, [["MULTI"]] ++ UpdateCommand ++ [["EXEC"]]),
        {lists:last(RedisResult), Result}
                  end,
    case transaction(ClusterName, Transaction, Slot, {ok, undefined}, ?OL_TRANSACTION_TTL) of
        {{ok, undefined}, _} ->
            {error, resource_busy};
        {{ok, TransactionResult}, UpdateResult} ->
            {ok, {TransactionResult, UpdateResult}};
        {Error, _} ->
            Error
    end.

%% =============================================================================
%% @doc Eval command helper, to optimize the query, it will try to execute the
%% script using its hashed value. If no script is found, it will load it and
%% try again.
%% @end
%% =============================================================================
-spec eval(atom(), bitstring(), bitstring(), [bitstring()], [bitstring()]) ->
    redis_result().
eval(ClusterName, Script, ScriptHash, Keys, Args) ->
    KeyNb = length(Keys),
    EvalShaCommand = ["EVALSHA", ScriptHash, KeyNb] ++ Keys ++ Args,
    Key = if
              KeyNb == 0 -> "A"; %Random key
              true -> hd(Keys)
          end,
    case qk(ClusterName, EvalShaCommand, Key) of
        {error, <<"NOSCRIPT", _/binary>>} ->
            LoadCommand = ["SCRIPT", "LOAD", Script],
            EvalShaCommand2 = [LoadCommand, EvalShaCommand],
            [_, Result] = qk(ClusterName, EvalShaCommand2, Key),
            Result;
        Result ->
            Result
    end.


%% =============================================================================
%% @doc Perform a given query on all node of a redis cluster
%% @end
%% =============================================================================
-spec qa(atom(), redis_command()) -> ok | {error, Reason :: bitstring()}.
qa(ClusterName, Command) ->
    Pools = eredis_cluster_monitor:get_all_pools(ClusterName),
    Transaction = fun(Worker) -> qw(Worker, Command) end,
    [eredis_cluster_pool:transaction(Pool, Transaction) || Pool <- Pools].

%% =============================================================================
%% @doc Wrapper function to be used for direct call to a pool worker in the
%% function passed to the transaction/2 method
%% @end
%% =============================================================================
-spec qw(Worker :: pid(), redis_command()) -> redis_result().
qw(Worker, [[X | _] | _] = Command) when is_list(X); is_binary(X) ->
    eredis:qp(Worker, Command);
qw(Worker, Command) ->
    eredis:q(Worker, Command).

%% =============================================================================
%% @doc Perform flushdb command on each node of the redis cluster
%% @end
%% =============================================================================
-spec flushdb(ClusterName :: atom()) -> ok | {error, Reason :: bitstring()}.
flushdb(ClusterName) ->
    Result = qa(ClusterName, ["FLUSHDB"]),
    case proplists:lookup(error, Result) of
        none ->
            ok;
        Error ->
            Error
    end.

%% =============================================================================
%% @doc Return the hash slot from the key
%% @end
%% =============================================================================
-spec get_key_slot(Key :: anystring()) -> Slot :: integer().
get_key_slot(Key) when is_bitstring(Key) ->
    get_key_slot(bitstring_to_list(Key));
get_key_slot(Key) ->
    KeyToBeHased =
        case string:chr(Key, ${) of
            0 ->
                Key;
            Start ->
                case string:chr(string:substr(Key, Start + 1), $}) of
                    0 ->
                        Key;
                    Length ->
                        if
                            Length =:= 1 ->
                                Key;
                            true ->
                                string:substr(Key, Start + 1, Length - 1)
                        end
                end
        end,
    eredis_cluster_hash:hash(KeyToBeHased).

%% =============================================================================
%% @doc Return the first key in the command arguments.
%% In a normal query, the second term will be returned
%%
%% If it is a pipeline query we will use the second term of the first term, we
%% will assume that all keys are in the same server and the query can be
%% performed
%%
%% If the pipeline query starts with multi (transaction), we will look at the
%% second term of the second command
%%
%% For eval and evalsha command we will look at the fourth term.
%%
%% For commands that don't make sense in the context of cluster
%% return value will be undefined.
%% @end
%% =============================================================================
-spec get_key_from_command(redis_command()) -> string() | undefined.
get_key_from_command([[X | Y] | Z]) when is_bitstring(X) ->
    get_key_from_command([[bitstring_to_list(X) | Y] | Z]);
get_key_from_command([[X | Y] | Z]) when is_list(X) ->
    case string:to_lower(X) of
        "multi" ->
            get_key_from_command(Z);
        _ ->
            get_key_from_command([X | Y])
    end;
get_key_from_command([Term1, Term2 | Rest]) when is_bitstring(Term1) ->
    get_key_from_command([bitstring_to_list(Term1), Term2 | Rest]);
get_key_from_command([Term1, Term2 | Rest]) when is_bitstring(Term2) ->
    get_key_from_command([Term1, bitstring_to_list(Term2) | Rest]);
get_key_from_command([Term1, Term2 | Rest]) ->
    case string:to_lower(Term1) of
        "info" ->
            undefined;
        "config" ->
            undefined;
        "shutdown" ->
            undefined;
        "slaveof" ->
            undefined;
        "eval" ->
            get_key_from_rest(Rest);
        "evalsha" ->
            get_key_from_rest(Rest);
        _ ->
            Term2
    end;
get_key_from_command(_) ->
    undefined.

%% =============================================================================
%% @doc Get key for command where the key is in th 4th position (eval and
%% evalsha commands)
%% @end
%% =============================================================================
-spec get_key_from_rest([anystring()]) -> string() | undefined.
get_key_from_rest([_, KeyName | _]) when is_bitstring(KeyName) ->
    bitstring_to_list(KeyName);
get_key_from_rest([_, KeyName | _]) when is_list(KeyName) ->
    KeyName;
get_key_from_rest(_) ->
    undefined.
