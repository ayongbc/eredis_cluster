%%% ------------------------------------------------------------------
%%% Licensed under the Apache License, Version 2.0 (the 'License');
%%%  you may not use this file except in compliance with the License.
%%%  You may obtain a copy of the License at
%%%
%%%      http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Copyright (c) 2019 dwg <bypf2009@vip.qq.com>
%%%
%%%  Unless required by applicable law or agreed to in writing, software
%%%  distributed under the License is distributed on an 'AS IS' BASIS,
%%%  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%%  See the License for the specific language governing permissions and
%%%  limitations under the License.
%%%
%%% @doc
%%% @author  dwg <'bypf2009@vip.qq.com'>
%%% @copyright 2019 dwg <bypf2009@vip.qq.com>
%%% @end
%%% created|changed : 2019-10-28 15:36
%%% coding : utf-8
%%% ------------------------------------------------------------------
-module(eredis_cluster_pool_worker).
-author("dwg").

-export([start_link/1]).

start_link([Host, Port, DataBase, Password, ReconnectSleep]) ->
    eredis:start_link(Host, Port, DataBase, Password, ReconnectSleep).
