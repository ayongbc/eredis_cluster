# eredis_cluster

erlang现在真是没有人维护了, 这个项目已经很久没有更新了, 我fork了一份, 做了一些修改, 我英文不好，只能用中文了

## 支持同时连接多个集群

    nodes要配置集群的多个节点信息，这样可以保证在某一个节点不可用的情况下集群仍然可以连接

```erlang
[
    {cluster_name, ClusterName::atom()}, % 集群连接池名字
    {nodes, [ % 同一个集群中的节点，配置多个可以保证在某一个不可用的情况下集群仍然可以连接
        [{host, Host :: string()}, {port, Port :: non_neg_integer()}],
        [{host, Host :: string()}, {port, Port :: non_neg_integer()}],
        [{host, Host :: string()}, {port, Port :: non_neg_integer()}]
    ]},
    {password, Password :: string()}, % redis密码
    {size, Size :: non_neg_integer()}, % 集群每个主节点的连接数
    {max_overflow, MaxOverflow :: non_neg_integer()} % 集群每个主节点可以溢出的连接数
]
```

## 添加几个redis cluser 故障恢复时可能出现的错误检测,出现后开始重连拉去新的集群信息

* READONLY
* CLUSTERDOWN
* TRYAGAIN


## fix get_pool_by_slot 不判断get_state返回值的bug
