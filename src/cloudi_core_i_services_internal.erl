%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI Internal Service==
%%% Erlang process which manages internal service requests and info messages
%%% for modules that implement the cloudi_service behavior.
%%% @end
%%%
%%% MIT License
%%%
%%% Copyright (c) 2011-2018 Michael Truog <mjtruog at protonmail dot com>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a
%%% copy of this software and associated documentation files (the "Software"),
%%% to deal in the Software without restriction, including without limitation
%%% the rights to use, copy, modify, merge, publish, distribute, sublicense,
%%% and/or sell copies of the Software, and to permit persons to whom the
%%% Software is furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
%%% DEALINGS IN THE SOFTWARE.
%%%
%%% @author Michael Truog <mjtruog at protonmail dot com>
%%% @copyright 2011-2018 Michael Truog
%%% @version 1.7.4 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_core_i_services_internal).
-author('mjtruog at protonmail dot com').

-behaviour(gen_server).

%% external interface
-export([start_link/19,
         get_status/1,
         get_status/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/2]).

%% duo_mode callbacks
-export([duo_mode_loop_init/1,
         duo_mode_loop/1]).

%% duo_mode sys callbacks
-export([system_continue/3,
         system_terminate/4,
         system_code_change/4]).

%% cloudi_core_i_services_internal callbacks (request pid and info pid)
-export([handle_module_request_loop_hibernate/2,
         handle_module_info_loop_hibernate/2]).

-include("cloudi_logger.hrl").
-include("cloudi_core_i_configuration.hrl").
-include("cloudi_core_i_constants.hrl").

-record(state,
    {
        % state record fields common for cloudi_core_i_services_common.hrl:

        % ( 2) self() value cached
        dispatcher :: pid(),
        % ( 3) timeout enforcement for any outgoing service requests
        send_timeouts = #{}
            :: #{cloudi:trans_id() :=
                 {active | passive | {pid(), any()},
                  pid() | undefined, reference()}} |
               list({cloudi:trans_id(),
                     {active | passive | {pid(), any()},
                      pid() | undefined, reference()}}),
        % ( 4) if a sent service request timeout is greater than or equal to
        % the service configuration option request_timeout_immediate_max,
        % monitor the destination process with the sent service request
        % transaction id
        send_timeout_monitors = #{}
            :: #{pid() := {reference(), list(cloudi:trans_id())}} |
               list({pid(), {reference(), list(cloudi:trans_id())}}),
        % ( 5) timeout enforcement for any incoming service requests
        recv_timeouts = #{}
            :: undefined |
               #{cloudi:trans_id() := reference()} |
               list({cloudi:trans_id(), reference()}),
        % ( 6) timeout enforcement for any responses to
        % asynchronous outgoing service requests
        async_responses = #{}
            :: #{cloudi:trans_id() :=
                 {cloudi:response_info(), cloudi:response()}} |
               list({cloudi:trans_id(),
                     {cloudi:response_info(), cloudi:response()}}),
        % ( 7) pending update configuration
        update_plan = undefined
            :: undefined | #config_service_update{},
        % ( 8) is the request/info pid busy?
        queue_requests = true
            :: undefined | boolean(),
        % ( 9) queued incoming service requests
        queued = pqueue4:new()
            :: undefined |
               pqueue4:pqueue4(
                   cloudi:message_service_request()) |
               list({cloudi:priority_value(), any()}),

        % state record fields unique to the dispatcher Erlang process:

        % (10) queued size in bytes
        queued_size = 0 :: non_neg_integer(),
        % (11) erlang:system_info(wordsize) cached
        queued_word_size :: pos_integer(),
        % (12) queued incoming Erlang process messages
        queued_info = queue:new()
            :: undefined | queue:queue(any()) |
               list(any()),
        % (13) service module
        module :: module(),
        % (14) state internal to the service module source code
        service_state = undefined :: any(),
        % (15) 0-based index of the process in all service instance processes
        process_index :: non_neg_integer(),
        % (16) current count of all Erlang processes for the service instance
        process_count :: pos_integer(),
        % (17) subscribe/unsubscribe name prefix set in service configuration
        prefix :: cloudi:service_name_pattern(),
        % (18) default timeout for send_async set in service configuration
        timeout_async
            :: cloudi_service_api:timeout_send_async_value_milliseconds(),
        % (19) default timeout for send_sync set in service configuration
        timeout_sync
            :: cloudi_service_api:timeout_send_sync_value_milliseconds(),
        % (20) cloudi_service_terminate timeout set by max_r and max_t
        timeout_term
            :: cloudi_service_api:timeout_terminate_value_milliseconds(),
        % (21) duo_mode_pid if duo_mode == true, else dispatcher pid
        receiver_pid :: pid(),
        % (22) separate Erlang process for incoming throughput
        duo_mode_pid :: undefined | pid(),
        % (23) separate Erlang process for service request memory usage
        request_pid = undefined :: undefined | pid(),
        % (24) separate Erlang process for Erlang message memory usage
        info_pid = undefined :: undefined | pid(),
        % (25) transaction id (UUIDv1) generator
        uuid_generator :: uuid:state(),
        % (26) how service destination lookups occur for a service request send
        dest_refresh :: cloudi_service_api:dest_refresh(),
        % (27) cached cpg data for lazy destination refresh methods
        cpg_data
            :: undefined | cpg_data:state() |
               list({cloudi:service_name_pattern(), any()}),
        % (28) ACL lookup for denied destinations
        dest_deny
            :: undefined | trie:trie() |
               list({cloudi:service_name_pattern(), any()}),
        % (29) ACL lookup for allowed destinations
        dest_allow
            :: undefined | trie:trie() |
               list({cloudi:service_name_pattern(), any()}),
        % (30) service configuration options
        options
            :: #config_service_options{} |
               cloudi_service_api:service_options_internal()
    }).

% used when duo_mode is true (the duo_mode pid is also a permanent info pid)
-record(state_duo,
    {
        % ( 2) self() value cached
        duo_mode_pid :: pid(),
        % ( 3) timeout enforcement for any incoming service requests
        recv_timeouts = #{}
            :: #{cloudi:trans_id() := reference()} |
               list({cloudi:trans_id(), reference()}),
        % ( 4) pending update configuration
        update_plan = undefined
            :: undefined | #config_service_update{},
        % ( 5) is the request pid busy?
        queue_requests = true :: boolean(),
        % ( 6) queued incoming service requests
        queued = pqueue4:new()
            :: pqueue4:pqueue4(
                   cloudi:message_service_request()) |
               list({cloudi:priority_value(), any()}),
        % ( 7) queued size in bytes
        queued_size = 0 :: non_neg_integer(),
        % ( 8) erlang:system_info(wordsize) cached
        queued_word_size :: pos_integer(),
        % ( 9) queued incoming Erlang process messages
        queued_info = queue:new()
            :: queue:queue(any()) |
               list(any()),
        % (10) service module
        module :: module(),
        % (11) state internal to the service module source code
        service_state = undefined :: any(),
        % (12) cloudi_service_terminate timeout set by max_r and max_t
        timeout_term :: pos_integer(),
        % (13) separate Erlang process for outgoing throughput
        dispatcher :: pid(),
        % (14) separate Erlang process for service request memory usage
        request_pid = undefined :: undefined | pid(),
        % (15) service configuration options
        options
            :: #config_service_options{} |
               cloudi_service_api:service_options_internal()
    }).

-include("cloudi_core_i_services_common.hrl").

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

start_link(ProcessIndex, ProcessCount, TimeStart, TimeRestart, Restarts,
           GroupLeader, Module, Args, Timeout, [PrefixC | _] = Prefix,
           TimeoutAsync, TimeoutSync, TimeoutTerm,
           DestRefresh, DestDeny, DestAllow,
           #config_service_options{
               scope = Scope,
               dispatcher_pid_options = PidOptions} = ConfigOptions, ID,
           Parent)
    when is_integer(ProcessIndex), is_integer(ProcessCount),
         is_integer(TimeStart), is_integer(Restarts),
         is_atom(Module), is_list(Args), is_integer(Timeout),
         is_integer(PrefixC),
         is_integer(TimeoutAsync), is_integer(TimeoutSync),
         is_integer(TimeoutTerm), is_pid(Parent) ->
    true = (DestRefresh =:= immediate_closest) orelse
           (DestRefresh =:= lazy_closest) orelse
           (DestRefresh =:= immediate_furthest) orelse
           (DestRefresh =:= lazy_furthest) orelse
           (DestRefresh =:= immediate_random) orelse
           (DestRefresh =:= lazy_random) orelse
           (DestRefresh =:= immediate_local) orelse
           (DestRefresh =:= lazy_local) orelse
           (DestRefresh =:= immediate_remote) orelse
           (DestRefresh =:= lazy_remote) orelse
           (DestRefresh =:= immediate_newest) orelse
           (DestRefresh =:= lazy_newest) orelse
           (DestRefresh =:= immediate_oldest) orelse
           (DestRefresh =:= lazy_oldest) orelse
           (DestRefresh =:= none),
    case cpg:scope_exists(Scope) of
        ok ->
            gen_server:start_link(?MODULE,
                                  [ProcessIndex, ProcessCount,
                                   TimeStart, TimeRestart, Restarts,
                                   GroupLeader, Module, Args, Timeout, Prefix,
                                   TimeoutAsync, TimeoutSync, TimeoutTerm,
                                   DestRefresh, DestDeny, DestAllow,
                                   ConfigOptions, ID, Parent],
                                  [{timeout, Timeout + ?TIMEOUT_DELTA},
                                   {spawn_opt,
                                    spawn_opt_options_before(PidOptions)}]);
        {error, Reason} ->
            {error, {service_options_scope_invalid, Reason}}
    end.

get_status(Dispatcher) ->
    get_status(Dispatcher, 5000).

get_status(Dispatcher, Timeout) ->
    gen_server:call(Dispatcher, {get_status, Timeout}, Timeout).

%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

init([ProcessIndex, ProcessCount, TimeStart, TimeRestart, Restarts,
      GroupLeader, Module, Args, Timeout, Prefix,
      TimeoutAsync, TimeoutSync, TimeoutTerm,
      DestRefresh, DestDeny, DestAllow,
      #config_service_options{
          dispatcher_pid_options = PidOptions,
          info_pid_options = InfoPidOptions,
          duo_mode = DuoMode} = ConfigOptions, ID, Parent]) ->
    ok = spawn_opt_options_after(PidOptions),
    Uptime = uptime(TimeStart, TimeRestart, Restarts),
    erlang:put(?SERVICE_ID_PDICT_KEY, ID),
    erlang:put(?SERVICE_UPTIME_PDICT_KEY, Uptime),
    erlang:put(?SERVICE_FILE_PDICT_KEY, Module),
    Dispatcher = self(),
    if
        GroupLeader =:= undefined ->
            ok;
        is_pid(GroupLeader) ->
            erlang:group_leader(GroupLeader, Dispatcher)
    end,
    quickrand:seed(),
    WordSize = erlang:system_info(wordsize),
    NewConfigOptions = check_init_send(ConfigOptions),
    DuoModePid = if
        DuoMode =:= true ->
            spawn_opt_proc_lib(fun() ->
                erlang:put(?SERVICE_ID_PDICT_KEY, ID),
                erlang:put(?SERVICE_UPTIME_PDICT_KEY, Uptime),
                erlang:put(?SERVICE_FILE_PDICT_KEY, Module),
                duo_mode_loop_init(#state_duo{duo_mode_pid = self(),
                                              queued_word_size = WordSize,
                                              module = Module,
                                              timeout_term = TimeoutTerm,
                                              dispatcher = Dispatcher,
                                              options = NewConfigOptions})
            end, InfoPidOptions);
        true ->
            undefined
    end,
    ReceiverPid = if
        is_pid(DuoModePid) ->
            DuoModePid;
        true ->
            Dispatcher
    end,
    {ok, MacAddress} = application:get_env(cloudi_core, mac_address),
    {ok, TimestampType} = application:get_env(cloudi_core, timestamp_type),
    UUID = uuid:new(Dispatcher, [{timestamp_type, TimestampType},
                                          {mac_address, MacAddress}]),
    Groups = destination_refresh_groups(DestRefresh, undefined),
    State = #state{dispatcher = Dispatcher,
                   queued_word_size = WordSize,
                   module = Module,
                   process_index = ProcessIndex,
                   process_count = ProcessCount,
                   prefix = Prefix,
                   timeout_async = TimeoutAsync,
                   timeout_sync = TimeoutSync,
                   timeout_term = TimeoutTerm,
                   receiver_pid = ReceiverPid,
                   duo_mode_pid = DuoModePid,
                   uuid_generator = UUID,
                   dest_refresh = DestRefresh,
                   cpg_data = Groups,
                   dest_deny = DestDeny,
                   dest_allow = DestAllow,
                   options = NewConfigOptions},
    ReceiverPid ! {'cloudi_service_init_execute', Args, Timeout,
                   cloudi_core_i_services_internal_init:
                   process_dictionary_get(),
                   State},
    % no process dictionary or state modifications below

    % send after 'cloudi_service_init_execute' to avoid race with
    % cloudi_core_i_services_monitor:process_init_begin/1
    ok = cloudi_core_i_services_internal_sup:
         process_started(Parent, Dispatcher, ReceiverPid),

    #config_service_options{
        dest_refresh_start = Delay,
        scope = Scope} = NewConfigOptions,
    destination_refresh(DestRefresh, Dispatcher, Delay, Scope),
    {ok, State}.

handle_call(process_index, _,
            #state{process_index = ProcessIndex} = State) ->
    hibernate_check({reply, ProcessIndex, State});

handle_call(process_count, _,
            #state{process_count = ProcessCount} = State) ->
    hibernate_check({reply, ProcessCount, State});

handle_call(process_count_max, _,
            #state{process_count = ProcessCount,
                   options = #config_service_options{
                       count_process_dynamic = CountProcessDynamic}} = State) ->
    if
        CountProcessDynamic =:= false ->
            hibernate_check({reply, ProcessCount, State});
        true ->
            Format = cloudi_core_i_rate_based_configuration:
                     count_process_dynamic_format(CountProcessDynamic),
            {_, ProcessCountMax} = lists:keyfind(count_max, 1, Format),
            hibernate_check({reply, ProcessCountMax, State})
    end;

handle_call(process_count_min, _,
            #state{process_count = ProcessCount,
                   options = #config_service_options{
                       count_process_dynamic = CountProcessDynamic}} = State) ->
    if
        CountProcessDynamic =:= false ->
            hibernate_check({reply, ProcessCount, State});
        true ->
            CountProcessDynamicFormat =
                cloudi_core_i_rate_based_configuration:
                count_process_dynamic_format(CountProcessDynamic),
            {_, ProcessCountMin} = lists:keyfind(count_min, 1,
                                                 CountProcessDynamicFormat),
            hibernate_check({reply, ProcessCountMin, State})
    end;

handle_call(self, _,
            #state{receiver_pid = ReceiverPid} = State) ->
    hibernate_check({reply, ReceiverPid, State});

handle_call({monitor, Pid}, _, State) ->
    hibernate_check({reply, erlang:monitor(process, Pid), State});

handle_call({demonitor, MonitorRef}, _, State) ->
    hibernate_check({reply, erlang:demonitor(MonitorRef), State});

handle_call({demonitor, MonitorRef, Options}, _, State) ->
    hibernate_check({reply, erlang:demonitor(MonitorRef, Options), State});

handle_call(dispatcher, _,
            #state{dispatcher = Dispatcher} = State) ->
    hibernate_check({reply, Dispatcher, State});

handle_call({'subscribe', Suffix}, _,
            #state{prefix = Prefix,
                   receiver_pid = ReceiverPid,
                   options = #config_service_options{
                       count_process_dynamic = CountProcessDynamic,
                       scope = Scope}} = State) ->
    Result = case cloudi_core_i_rate_based_configuration:
                  count_process_dynamic_terminated(CountProcessDynamic) of
        false ->
            Pattern = Prefix ++ Suffix,
            _ = trie:is_pattern(Pattern),
            cpg:join(Scope, Pattern,
                              ReceiverPid, infinity);
        true ->
            error
    end,
    hibernate_check({reply, Result, State});

handle_call({'subscribe_count', Suffix}, _,
            #state{prefix = Prefix,
                   receiver_pid = ReceiverPid,
                   options = #config_service_options{
                       scope = Scope}} = State) ->
    Pattern = Prefix ++ Suffix,
    _ = trie:is_pattern(Pattern),
    Count = cpg:join_count(Scope, Pattern,
                                    ReceiverPid, infinity),
    hibernate_check({reply, Count, State});

handle_call({'unsubscribe', Suffix}, _,
            #state{prefix = Prefix,
                   receiver_pid = ReceiverPid,
                   options = #config_service_options{
                       count_process_dynamic = CountProcessDynamic,
                       scope = Scope}} = State) ->
    Result = case cloudi_core_i_rate_based_configuration:
                  count_process_dynamic_terminated(CountProcessDynamic) of
        false ->
            Pattern = Prefix ++ Suffix,
            _ = trie:is_pattern(Pattern),
            cpg:leave(Scope, Pattern,
                               ReceiverPid, infinity);
        true ->
            error
    end,
    hibernate_check({reply, Result, State});

handle_call({'get_pid', Name}, Client,
            #state{timeout_sync = TimeoutSync} = State) ->
    handle_call({'get_pid', Name, TimeoutSync}, Client, State);

handle_call({'get_pid', Name, Timeout}, Client,
            #state{dest_deny = DestDeny,
                   dest_allow = DestAllow} = State) ->
    hibernate_check(case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_get_pid(Name, Timeout, Client, State);
        false ->
            {reply, {error, timeout}, State}
    end);

handle_call({'get_pids', Name}, Client,
            #state{timeout_sync = TimeoutSync} = State) ->
    handle_call({'get_pids', Name, TimeoutSync}, Client, State);

handle_call({'get_pids', Name, Timeout}, Client,
            #state{dest_deny = DestDeny,
                   dest_allow = DestAllow} = State) ->
    hibernate_check(case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_get_pids(Name, Timeout, Client, State);
        false ->
            {reply, {error, timeout}, State}
    end);

handle_call({'send_async', Name, RequestInfo, Request,
             undefined, Priority}, Client,
            #state{timeout_async = TimeoutAsync} = State) ->
    handle_call({'send_async', Name, RequestInfo, Request,
                 TimeoutAsync, Priority}, Client, State);

handle_call({'send_async', Name, RequestInfo, Request,
             Timeout, undefined}, Client,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    handle_call({'send_async', Name, RequestInfo, Request,
                 Timeout, PriorityDefault}, Client, State);

handle_call({'send_async', Name, RequestInfo, Request,
             Timeout, Priority}, Client,
            #state{dest_deny = DestDeny,
                   dest_allow = DestAllow} = State) ->
    hibernate_check(case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_send_async(Name, RequestInfo, Request,
                              Timeout, Priority, Client, State);
        false ->
            {reply, {error, timeout}, State}
    end);

handle_call({'send_async', Name, RequestInfo, Request,
             undefined, Priority, PatternPid}, Client,
            #state{timeout_async = TimeoutAsync} = State) ->
    handle_call({'send_async', Name, RequestInfo, Request,
                 TimeoutAsync, Priority, PatternPid}, Client, State);

handle_call({'send_async', Name, RequestInfo, Request,
             Timeout, undefined, PatternPid}, Client,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    handle_call({'send_async', Name, RequestInfo, Request,
                 Timeout, PriorityDefault, PatternPid}, Client, State);

handle_call({'send_async', Name, RequestInfo, Request,
             Timeout, Priority, {Pattern, Pid}}, _,
            State) ->
    hibernate_check(handle_send_async_pid(Name, Pattern, RequestInfo, Request,
                                          Timeout, Priority, Pid, State));

handle_call({'send_async_active', Name, RequestInfo, Request,
             undefined, Priority}, Client,
            #state{timeout_async = TimeoutAsync} = State) ->
    handle_call({'send_async_active', Name, RequestInfo, Request,
                 TimeoutAsync, Priority}, Client, State);

handle_call({'send_async_active', Name, RequestInfo, Request,
             Timeout, undefined}, Client,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    handle_call({'send_async_active', Name, RequestInfo, Request,
                 Timeout, PriorityDefault}, Client, State);

handle_call({'send_async_active', Name, RequestInfo, Request,
             Timeout, Priority}, Client,
            #state{dest_deny = DestDeny,
                   dest_allow = DestAllow} = State) ->
    hibernate_check(case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_send_async_active(Name, RequestInfo, Request,
                                     Timeout, Priority, Client, State);
        false ->
            {reply, {error, timeout}, State}
    end);

handle_call({'send_async_active', Name, RequestInfo, Request,
             undefined, Priority, PatternPid}, Client,
            #state{timeout_async = TimeoutAsync} = State) ->
    handle_call({'send_async_active', Name, RequestInfo, Request,
                 TimeoutAsync, Priority, PatternPid}, Client, State);

handle_call({'send_async_active', Name, RequestInfo, Request,
             Timeout, undefined, PatternPid}, Client,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    handle_call({'send_async_active', Name, RequestInfo, Request,
                 Timeout, PriorityDefault, PatternPid}, Client, State);

handle_call({'send_async_active', Name, RequestInfo, Request,
             Timeout, Priority, {Pattern, Pid}}, _,
            State) ->
    hibernate_check(handle_send_async_active_pid(Name, Pattern,
                                                 RequestInfo, Request,
                                                 Timeout, Priority,
                                                 undefined, Pid, State));

handle_call({'send_async_active', Name, RequestInfo, Request,
             undefined, Priority, TransId, PatternPid}, Client,
            #state{timeout_async = TimeoutAsync} = State) ->
    handle_call({'send_async_active', Name, RequestInfo, Request,
                 TimeoutAsync, Priority, TransId, PatternPid}, Client, State);

handle_call({'send_async_active', Name, RequestInfo, Request,
             Timeout, undefined, TransId, PatternPid}, Client,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    handle_call({'send_async_active', Name, RequestInfo, Request,
                 Timeout, PriorityDefault, TransId, PatternPid}, Client, State);

handle_call({'send_async_active', Name, RequestInfo, Request,
             Timeout, Priority, TransId, {Pattern, Pid}}, _,
            State) ->
    hibernate_check(handle_send_async_active_pid(Name, Pattern,
                                                 RequestInfo, Request,
                                                 Timeout, Priority,
                                                 TransId, Pid, State));

handle_call({'send_sync', Name, RequestInfo, Request,
             undefined, Priority}, Client,
            #state{timeout_sync = TimeoutSync} = State) ->
    handle_call({'send_sync', Name, RequestInfo, Request,
                 TimeoutSync, Priority}, Client, State);

handle_call({'send_sync', Name, RequestInfo, Request,
             Timeout, undefined}, Client,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    handle_call({'send_sync', Name, RequestInfo, Request,
                 Timeout, PriorityDefault}, Client, State);

handle_call({'send_sync', Name, RequestInfo, Request,
             Timeout, Priority}, Client,
            #state{dest_deny = DestDeny,
                   dest_allow = DestAllow} = State) ->
    hibernate_check(case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_send_sync(Name, RequestInfo, Request,
                             Timeout, Priority, Client, State);
        false ->
            {reply, {error, timeout}, State}
    end);

handle_call({'send_sync', Name, RequestInfo, Request,
             undefined, Priority, PatternPid}, Client,
            #state{timeout_sync = TimeoutSync} = State) ->
    handle_call({'send_sync', Name, RequestInfo, Request,
                 TimeoutSync, Priority, PatternPid}, Client, State);

handle_call({'send_sync', Name, RequestInfo, Request,
             Timeout, undefined, PatternPid}, Client,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    handle_call({'send_sync', Name, RequestInfo, Request,
                 Timeout, PriorityDefault, PatternPid}, Client, State);

handle_call({'send_sync', Name, RequestInfo, Request,
             Timeout, Priority, {Pattern, Pid}}, Client,
            State) ->
    hibernate_check(handle_send_sync_pid(Name, Pattern,
                                         RequestInfo, Request,
                                         Timeout, Priority,
                                         Pid, Client, State));

handle_call({'mcast_async', Name, RequestInfo, Request,
             undefined, Priority}, Client,
            #state{timeout_async = TimeoutAsync} = State) ->
    handle_call({'mcast_async', Name, RequestInfo, Request,
                 TimeoutAsync, Priority}, Client, State);

handle_call({'mcast_async', Name, RequestInfo, Request,
             Timeout, undefined}, Client,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    handle_call({'mcast_async', Name, RequestInfo, Request,
                 Timeout, PriorityDefault}, Client, State);

handle_call({'mcast_async', Name, RequestInfo, Request,
             Timeout, Priority}, Client,
            #state{dest_deny = DestDeny,
                   dest_allow = DestAllow} = State) ->
    hibernate_check(case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_mcast_async(Name, RequestInfo, Request,
                               Timeout, Priority, Client, State);
        false ->
            {reply, {error, timeout}, State}
    end);

handle_call({'mcast_async_active', Name, RequestInfo, Request,
             undefined, Priority}, Client,
            #state{timeout_async = TimeoutAsync} = State) ->
    handle_call({'mcast_async_active', Name, RequestInfo, Request,
                 TimeoutAsync, Priority}, Client, State);

handle_call({'mcast_async_active', Name, RequestInfo, Request,
             Timeout, undefined}, Client,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    handle_call({'mcast_async_active', Name, RequestInfo, Request,
                 Timeout, PriorityDefault}, Client, State);

handle_call({'mcast_async_active', Name, RequestInfo, Request,
             Timeout, Priority}, Client,
            #state{dest_deny = DestDeny,
                   dest_allow = DestAllow} = State) ->
    hibernate_check(case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_mcast_async_active(Name, RequestInfo, Request,
                                      Timeout, Priority, Client, State);
        false ->
            {reply, {error, timeout}, State}
    end);

handle_call({'recv_async', TransId, Consume}, Client,
            #state{timeout_sync = TimeoutSync} = State) ->
    handle_call({'recv_async', TimeoutSync, TransId, Consume}, Client, State);

handle_call({'recv_async', Timeout, TransId, Consume}, Client,
            #state{async_responses = AsyncResponses} = State) ->
    hibernate_check(if
        TransId == <<0:128>> ->
            case maps:to_list(AsyncResponses) of
                [] when Timeout >= ?RECV_ASYNC_INTERVAL ->
                    erlang:send_after(?RECV_ASYNC_INTERVAL, self(),
                                      {'cloudi_service_recv_async_retry',
                                       Timeout - ?RECV_ASYNC_INTERVAL,
                                       TransId, Consume, Client}),
                    {noreply, State};
                [] ->
                    {reply, {error, timeout}, State};
                L when Consume =:= true ->
                    TransIdPick = ?RECV_ASYNC_STRATEGY(L),
                    {ResponseInfo, Response} = maps:get(TransIdPick,
                                                        AsyncResponses),
                    {reply, {ok, ResponseInfo, Response, TransIdPick},
                     State#state{
                         async_responses = maps:remove(TransIdPick,
                                                       AsyncResponses)}};
                L when Consume =:= false ->
                    TransIdPick = ?RECV_ASYNC_STRATEGY(L),
                    {ResponseInfo, Response} = maps:get(TransIdPick,
                                                        AsyncResponses),
                    {reply, {ok, ResponseInfo, Response, TransIdPick},
                     State}
            end;
        true ->
            case maps:find(TransId, AsyncResponses) of
                error when Timeout >= ?RECV_ASYNC_INTERVAL ->
                    erlang:send_after(?RECV_ASYNC_INTERVAL, self(),
                                      {'cloudi_service_recv_async_retry',
                                       Timeout - ?RECV_ASYNC_INTERVAL,
                                       TransId, Consume, Client}),
                    {noreply, State};
                error ->
                    {reply, {error, timeout}, State};
                {ok, {ResponseInfo, Response}} when Consume =:= true ->
                    {reply, {ok, ResponseInfo, Response, TransId},
                     State#state{
                         async_responses = maps:remove(TransId,
                                                       AsyncResponses)}};
                {ok, {ResponseInfo, Response}} when Consume =:= false ->
                    {reply, {ok, ResponseInfo, Response, TransId},
                     State}
            end
    end);

handle_call({'recv_asyncs', Results, Consume}, Client,
            #state{timeout_sync = TimeoutSync} = State) ->
    handle_call({'recv_asyncs', TimeoutSync, Results, Consume},
                Client, State);

handle_call({'recv_asyncs', Timeout, Results, Consume}, Client,
            #state{async_responses = AsyncResponses} = State) ->
    hibernate_check(case recv_asyncs_pick(Results, Consume, AsyncResponses) of
        {true, _, NewResults, NewAsyncResponses} ->
            {reply, {ok, NewResults},
             State#state{async_responses = NewAsyncResponses}};
        {false, _, NewResults, NewAsyncResponses}
            when Timeout >= ?RECV_ASYNC_INTERVAL ->
            erlang:send_after(?RECV_ASYNC_INTERVAL, self(),
                              {'cloudi_service_recv_asyncs_retry',
                               Timeout - ?RECV_ASYNC_INTERVAL,
                               NewResults, Consume, Client}),
            {noreply, State#state{async_responses = NewAsyncResponses}};
        {false, false, NewResults, NewAsyncResponses} ->
            {reply, {ok, NewResults},
             State#state{async_responses = NewAsyncResponses}};
        {false, true, _, _} ->
            {reply, {error, timeout}, State}
    end);

handle_call(prefix, _,
            #state{prefix = Prefix} = State) ->
    hibernate_check({reply, Prefix, State});

handle_call(timeout_async, _,
            #state{timeout_async = TimeoutAsync} = State) ->
    hibernate_check({reply, TimeoutAsync, State});

handle_call(timeout_sync, _,
            #state{timeout_sync = TimeoutSync} = State) ->
    hibernate_check({reply, TimeoutSync, State});

handle_call(priority_default, _,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    hibernate_check({reply, PriorityDefault, State});

handle_call(destination_refresh_immediate, _,
            #state{dest_refresh = DestRefresh} = State) ->
    Immediate = (DestRefresh =:= immediate_closest orelse
                 DestRefresh =:= immediate_furthest orelse
                 DestRefresh =:= immediate_random orelse
                 DestRefresh =:= immediate_local orelse
                 DestRefresh =:= immediate_remote orelse
                 DestRefresh =:= immediate_newest orelse
                 DestRefresh =:= immediate_oldest),
    hibernate_check({reply, Immediate, State});

handle_call(destination_refresh_lazy, _,
            #state{dest_refresh = DestRefresh} = State) ->
    Lazy = (DestRefresh =:= lazy_closest orelse
            DestRefresh =:= lazy_furthest orelse
            DestRefresh =:= lazy_random orelse
            DestRefresh =:= lazy_local orelse
            DestRefresh =:= lazy_remote orelse
            DestRefresh =:= lazy_newest orelse
            DestRefresh =:= lazy_oldest),
    hibernate_check({reply, Lazy, State});

handle_call(duo_mode, _,
            #state{options = #config_service_options{
                       duo_mode = DuoMode}} = State) ->
    hibernate_check({reply, DuoMode, State});

handle_call({source_subscriptions, Pid}, _,
            #state{options = #config_service_options{
                       scope = Scope}} = State) ->
    Subscriptions = cpg:which_groups(Scope, Pid, infinity),
    hibernate_check({reply, Subscriptions, State});

handle_call(context_options, _,
            #state{timeout_async = TimeoutAsync,
                   timeout_sync = TimeoutSync,
                   dest_refresh = DestRefresh,
                   uuid_generator = UUID,
                   cpg_data = Groups,
                   options = #config_service_options{
                       priority_default = PriorityDefault,
                       dest_refresh_start = DestRefreshStart,
                       dest_refresh_delay = DestRefreshDelay,
                       request_name_lookup = RequestNameLookup,
                       scope = Scope}} = State) ->
    Options = [{dest_refresh, DestRefresh},
               {dest_refresh_start, DestRefreshStart},
               {dest_refresh_delay, DestRefreshDelay},
               {request_name_lookup, RequestNameLookup},
               {timeout_async, TimeoutAsync},
               {timeout_sync, TimeoutSync},
               {priority_default, PriorityDefault},
               {uuid, UUID},
               {groups, Groups},
               {groups_scope, Scope}],
    hibernate_check({reply, Options, State});

handle_call(trans_id, _,
            #state{uuid_generator = UUID} = State) ->
    {TransId, NewUUID} = uuid:get_v1(UUID),
    hibernate_check({reply, TransId, State#state{uuid_generator = NewUUID}});

handle_call({get_status, Timeout}, _,
            #state{dispatcher = Dispatcher,
                   duo_mode_pid = DuoModePid} = State) ->
    % provide something close to the dispatcher's status to have more
    % consistency between the DuoModePid, if it exists
    PDict = erlang:get(),
    Result = {{status,
               Dispatcher,
               {module, gen_server},
               [PDict,
                running,
                undefined, % Parent
                undefined, % Debug
                format_status(normal, [PDict, State])]},
              format_status_duo_mode(DuoModePid, Timeout)},
    hibernate_check({reply, Result, State});

handle_call(Request, _, State) ->
    {stop, cloudi_string:format("Unknown call \"~w\"", [Request]),
     error, State}.

handle_cast(Request, State) ->
    {stop, cloudi_string:format("Unknown cast \"~w\"", [Request]), State}.

handle_info({'cloudi_service_request_success', RequestResponse,
             NewServiceState},
            #state{dispatcher = Dispatcher} = State) ->
    case RequestResponse of
        undefined ->
            ok;
        {'cloudi_service_return_async', _, _, _, _, _, _, Source} = T ->
            Source ! T;
        {'cloudi_service_return_sync', _, _, _, _, _, _, Source} = T ->
            Source ! T;
        {'cloudi_service_forward_async_retry', _, _, _, _, _, _, _, _, _} = T ->
            Dispatcher ! T;
        {'cloudi_service_forward_sync_retry', _, _, _, _, _, _, _, _, _} = T ->
            Dispatcher ! T
    end,
    NewState = process_queues(State#state{service_state = NewServiceState}),
    hibernate_check({noreply, NewState});

handle_info({'cloudi_service_info_success',
             NewServiceState}, State) ->
    NewState = process_queues(State#state{service_state = NewServiceState}),
    hibernate_check({noreply, NewState});

handle_info({'cloudi_service_request_failure',
             Type, Error, Stack, NewServiceState}, State) ->
    Reason = if
        Type =:= stop ->
            true = Stack =:= undefined,
            case Error of
                shutdown ->
                    ?LOG_WARN("request stop shutdown", []);
                {shutdown, ShutdownReason} ->
                    ?LOG_WARN("request stop shutdown (~p)",
                              [ShutdownReason]);
                _ ->
                    ?LOG_ERROR("request stop ~p", [Error])
            end,
            Error;
        true ->
            ?LOG_ERROR("request ~p ~p~n~p", [Type, Error, Stack]),
            {Type, {Error, Stack}}
    end,
    {stop, Reason, State#state{service_state = NewServiceState}};

handle_info({'cloudi_service_info_failure',
             Type, Error, Stack, NewServiceState}, State) ->
    Reason = if
        Type =:= stop ->
            true = Stack =:= undefined,
            case Error of
                shutdown ->
                    ?LOG_WARN("info stop shutdown", []);
                {shutdown, ShutdownReason} ->
                    ?LOG_WARN("info stop shutdown (~p)",
                              [ShutdownReason]);
                _ ->
                    ?LOG_ERROR("info stop ~p", [Error])
            end,
            Error;
        true ->
            ?LOG_ERROR("info ~p ~p~n~p", [Type, Error, Stack]),
            {Type, {Error, Stack}}
    end,
    {stop, Reason, State#state{service_state = NewServiceState}};

handle_info({'cloudi_service_get_pid_retry', Name, Timeout, Client}, State) ->
    hibernate_check(handle_get_pid(Name, Timeout,
                                   Client, State));

handle_info({'cloudi_service_get_pids_retry', Name, Timeout, Client}, State) ->
    hibernate_check(handle_get_pids(Name, Timeout,
                                    Client, State));

handle_info({'cloudi_service_send_async_retry',
             Name, RequestInfo, Request, Timeout, Priority, Client}, State) ->
    hibernate_check(handle_send_async(Name, RequestInfo, Request,
                                      Timeout, Priority,
                                      Client, State));

handle_info({'cloudi_service_send_async_active_retry',
             Name, RequestInfo, Request, Timeout, Priority, Client}, State) ->
    hibernate_check(handle_send_async_active(Name, RequestInfo, Request,
                                             Timeout, Priority,
                                             Client, State));

handle_info({'cloudi_service_send_sync_retry',
             Name, RequestInfo, Request, Timeout, Priority, Client}, State) ->
    hibernate_check(handle_send_sync(Name, RequestInfo, Request,
                                     Timeout, Priority, Client, State));

handle_info({'cloudi_service_mcast_async_retry',
             Name, RequestInfo, Request, Timeout, Priority, Client}, State) ->
    hibernate_check(handle_mcast_async(Name, RequestInfo, Request,
                                       Timeout, Priority, Client, State));

handle_info({'cloudi_service_mcast_async_active_retry',
             Name, RequestInfo, Request, Timeout, Priority, Client}, State) ->
    hibernate_check(handle_mcast_async_active(Name, RequestInfo, Request,
                                              Timeout, Priority,
                                              Client, State));

handle_info({'cloudi_service_forward_async_retry', Name, Pattern,
             NextName, NextRequestInfo, NextRequest,
             Timeout, Priority, TransId, Source},
            #state{dest_refresh = DestRefresh,
                   cpg_data = Groups,
                   dest_deny = DestDeny,
                   dest_allow = DestAllow,
                   options = #config_service_options{
                       request_name_lookup = RequestNameLookup,
                       response_timeout_immediate_max =
                           ResponseTimeoutImmediateMax,
                       scope = Scope}} = State) ->
    case destination_allowed(NextName, DestDeny, DestAllow) of
        true ->
            case destination_get(DestRefresh, Scope, NextName, Source,
                                 Groups, Timeout) of
                {error, timeout} ->
                    ok;
                {error, _} when RequestNameLookup =:= async ->
                    if
                        Timeout >= ResponseTimeoutImmediateMax ->
                            Source ! {'cloudi_service_return_async',
                                      Name, Pattern, <<>>, <<>>,
                                      Timeout, TransId, Source};
                        true ->
                            ok
                    end,
                    ok;
                {error, _} when Timeout >= ?FORWARD_ASYNC_INTERVAL ->
                    erlang:send_after(?FORWARD_ASYNC_INTERVAL, self(),
                                      {'cloudi_service_forward_async_retry',
                                       Name, Pattern,
                                       NextName, NextRequestInfo, NextRequest,
                                       Timeout - ?FORWARD_ASYNC_INTERVAL,
                                       Priority, TransId, Source}),
                    ok;
                {error, _} ->
                    ok;
                {ok, NextPattern, NextPid} when Timeout >= ?FORWARD_DELTA ->
                    NextPid ! {'cloudi_service_send_async',
                               NextName, NextPattern,
                               NextRequestInfo, NextRequest,
                               Timeout - ?FORWARD_DELTA,
                               Priority, TransId, Source};
                _ ->
                    ok
            end;
        false ->
            ok
    end,
    hibernate_check({noreply, State});

handle_info({'cloudi_service_forward_sync_retry', Name, Pattern,
             NextName, NextRequestInfo, NextRequest,
             Timeout, Priority, TransId, Source},
            #state{dest_refresh = DestRefresh,
                   cpg_data = Groups,
                   dest_deny = DestDeny,
                   dest_allow = DestAllow,
                   options = #config_service_options{
                       request_name_lookup = RequestNameLookup,
                       response_timeout_immediate_max =
                           ResponseTimeoutImmediateMax,
                       scope = Scope}} = State) ->
    case destination_allowed(NextName, DestDeny, DestAllow) of
        true ->
            case destination_get(DestRefresh, Scope, NextName, Source,
                                 Groups, Timeout) of
                {error, timeout} ->
                    ok;
                {error, _} when RequestNameLookup =:= async ->
                    if
                        Timeout >= ResponseTimeoutImmediateMax ->
                            Source ! {'cloudi_service_return_sync',
                                      Name, Pattern, <<>>, <<>>,
                                      Timeout, TransId, Source};
                        true ->
                            ok
                    end,
                    ok;
                {error, _} when Timeout >= ?FORWARD_SYNC_INTERVAL ->
                    erlang:send_after(?FORWARD_SYNC_INTERVAL, self(),
                                      {'cloudi_service_forward_sync_retry',
                                       Name, Pattern,
                                       NextName, NextRequestInfo, NextRequest,
                                       Timeout - ?FORWARD_SYNC_INTERVAL,
                                       Priority, TransId, Source}),
                    ok;
                {error, _} ->
                    ok;
                {ok, NextPattern, NextPid} when Timeout >= ?FORWARD_DELTA ->
                    NextPid ! {'cloudi_service_send_sync',
                               NextName, NextPattern,
                               NextRequestInfo, NextRequest,
                               Timeout - ?FORWARD_DELTA,
                               Priority, TransId, Source};
                _ ->
                    ok
            end;
        false ->
            ok
    end,
    hibernate_check({noreply, State});

handle_info({'cloudi_service_recv_async_retry',
             Timeout, TransId, Consume, Client},
            #state{async_responses = AsyncResponses} = State) ->
    hibernate_check(if
        TransId == <<0:128>> ->
            case maps:to_list(AsyncResponses) of
                [] when Timeout >= ?RECV_ASYNC_INTERVAL ->
                    erlang:send_after(?RECV_ASYNC_INTERVAL, self(),
                                      {'cloudi_service_recv_async_retry',
                                       Timeout - ?RECV_ASYNC_INTERVAL,
                                       TransId, Consume, Client}),
                    {noreply, State};
                [] ->
                    gen_server:reply(Client, {error, timeout}),
                    {noreply, State};
                L when Consume =:= true ->
                    TransIdPick = ?RECV_ASYNC_STRATEGY(L),
                    {ResponseInfo, Response} = maps:get(TransIdPick,
                                                        AsyncResponses),
                    gen_server:reply(Client,
                                     {ok, ResponseInfo, Response, TransIdPick}),
                    {noreply, State#state{
                        async_responses = maps:remove(TransIdPick,
                                                      AsyncResponses)}};
                L when Consume =:= false ->
                    TransIdPick = ?RECV_ASYNC_STRATEGY(L),
                    {ResponseInfo, Response} = maps:get(TransIdPick,
                                                        AsyncResponses),
                    gen_server:reply(Client,
                                     {ok, ResponseInfo, Response, TransIdPick}),
                    {noreply, State}
            end;
        true ->
            case maps:find(TransId, AsyncResponses) of
                error when Timeout >= ?RECV_ASYNC_INTERVAL ->
                    erlang:send_after(?RECV_ASYNC_INTERVAL, self(),
                                      {'cloudi_service_recv_async_retry',
                                       Timeout - ?RECV_ASYNC_INTERVAL,
                                       TransId, Consume, Client}),
                    {noreply, State};
                error ->
                    gen_server:reply(Client, {error, timeout}),
                    {noreply, State};
                {ok, {ResponseInfo, Response}} when Consume =:= true ->
                    gen_server:reply(Client,
                                     {ok, ResponseInfo, Response, TransId}),
                    {noreply, State#state{
                        async_responses = maps:remove(TransId,
                                                      AsyncResponses)}};
                {ok, {ResponseInfo, Response}} when Consume =:= false ->
                    gen_server:reply(Client,
                                     {ok, ResponseInfo, Response, TransId}),
                    {noreply, State}
            end
    end);

handle_info({'cloudi_service_recv_asyncs_retry',
             Timeout, Results, Consume, Client},
            #state{async_responses = AsyncResponses} = State) ->
    hibernate_check(case recv_asyncs_pick(Results, Consume, AsyncResponses) of
        {true, _, NewResults, NewAsyncResponses} ->
            gen_server:reply(Client, {ok, NewResults}),
            {noreply, State#state{async_responses = NewAsyncResponses}};
        {false, _, NewResults, NewAsyncResponses}
            when Timeout >= ?RECV_ASYNC_INTERVAL ->
            erlang:send_after(?RECV_ASYNC_INTERVAL, self(),
                              {'cloudi_service_recv_asyncs_retry',
                               Timeout - ?RECV_ASYNC_INTERVAL,
                               NewResults, Consume, Client}),
            {noreply, State#state{async_responses = NewAsyncResponses}};
        {false, false, NewResults, NewAsyncResponses} ->
            gen_server:reply(Client, {ok, NewResults}),
            {noreply, State#state{async_responses = NewAsyncResponses}};
        {false, true, _, _} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State}
    end);

handle_info({'cloudi_service_send_async',
             Name, Pattern, RequestInfo, Request,
             Timeout, Priority, TransId, Source},
            #state{dispatcher = Dispatcher,
                   queue_requests = false,
                   module = Module,
                   service_state = ServiceState,
                   request_pid = RequestPid,
                   options = #config_service_options{
                       rate_request_max = RateRequest,
                       response_timeout_immediate_max =
                           ResponseTimeoutImmediateMax} = ConfigOptions
                   } = State) ->
    {RateRequestOk, NewRateRequest} = if
        RateRequest =/= undefined ->
            cloudi_core_i_rate_based_configuration:
            rate_request_request(RateRequest);
        true ->
            {true, RateRequest}
    end,
    if
        RateRequestOk =:= true ->
            NewConfigOptions =
                check_incoming(true, ConfigOptions#config_service_options{
                                         rate_request_max = NewRateRequest}),
            hibernate_check({noreply,
                             State#state{
                                 queue_requests = true,
                                 request_pid = handle_module_request_loop_pid(
                                     RequestPid,
                                     {'cloudi_service_request_loop',
                                      'send_async', Name, Pattern,
                                      RequestInfo, Request,
                                      Timeout, Priority, TransId, Source,
                                      ServiceState, Dispatcher,
                                      Module, NewConfigOptions},
                                     NewConfigOptions, Dispatcher),
                                 options = NewConfigOptions}});
        RateRequestOk =:= false ->
            if
                Timeout >= ResponseTimeoutImmediateMax ->
                    Source ! {'cloudi_service_return_async',
                              Name, Pattern, <<>>, <<>>,
                              Timeout, TransId, Source};
                true ->
                    ok
            end,
            hibernate_check({noreply,
                             State#state{
                                 options = ConfigOptions#config_service_options{
                                     rate_request_max = NewRateRequest}}})
    end;

handle_info({'cloudi_service_send_sync',
             Name, Pattern, RequestInfo, Request,
             Timeout, Priority, TransId, Source},
            #state{dispatcher = Dispatcher,
                   queue_requests = false,
                   module = Module,
                   service_state = ServiceState,
                   request_pid = RequestPid,
                   options = #config_service_options{
                       rate_request_max = RateRequest,
                       response_timeout_immediate_max =
                           ResponseTimeoutImmediateMax} = ConfigOptions
                   } = State) ->
    {RateRequestOk, NewRateRequest} = if
        RateRequest =/= undefined ->
            cloudi_core_i_rate_based_configuration:
            rate_request_request(RateRequest);
        true ->
            {true, RateRequest}
    end,
    if
        RateRequestOk =:= true ->
            NewConfigOptions =
                check_incoming(true, ConfigOptions#config_service_options{
                                         rate_request_max = NewRateRequest}),
            hibernate_check({noreply,
                             State#state{
                                 queue_requests = true,
                                 request_pid = handle_module_request_loop_pid(
                                     RequestPid,
                                     {'cloudi_service_request_loop',
                                      'send_sync', Name, Pattern,
                                      RequestInfo, Request,
                                      Timeout, Priority, TransId, Source,
                                      ServiceState, Dispatcher,
                                      Module, NewConfigOptions},
                                     NewConfigOptions, Dispatcher),
                                 options = NewConfigOptions}});
        RateRequestOk =:= false ->
            if
                Timeout >= ResponseTimeoutImmediateMax ->
                    Source ! {'cloudi_service_return_sync',
                              Name, Pattern, <<>>, <<>>,
                              Timeout, TransId, Source};
                true ->
                    ok
            end,
            hibernate_check({noreply,
                             State#state{
                                 options = ConfigOptions#config_service_options{
                                     rate_request_max = NewRateRequest}}})
    end;

handle_info({SendType, Name, Pattern, _, _, 0, _, TransId, Source},
            #state{queue_requests = true,
                   options = #config_service_options{
                       response_timeout_immediate_max =
                           ResponseTimeoutImmediateMax}} = State)
    when SendType =:= 'cloudi_service_send_async';
         SendType =:= 'cloudi_service_send_sync' ->
    if
        0 =:= ResponseTimeoutImmediateMax ->
            if
                SendType =:= 'cloudi_service_send_async' ->
                    Source ! {'cloudi_service_return_async',
                              Name, Pattern, <<>>, <<>>,
                              0, TransId, Source};
                SendType =:= 'cloudi_service_send_sync' ->
                    Source ! {'cloudi_service_return_sync',
                              Name, Pattern, <<>>, <<>>,
                              0, TransId, Source}
            end;
        true ->
            ok
    end,
    hibernate_check({noreply, State});

handle_info({SendType, Name, Pattern, _, _,
             Timeout, Priority, TransId, Source} = T,
            #state{queue_requests = true,
                   queued = Queue,
                   queued_size = QueuedSize,
                   queued_word_size = WordSize,
                   options = #config_service_options{
                       queue_limit = QueueLimit,
                       queue_size = QueueSize,
                       rate_request_max = RateRequest,
                       response_timeout_immediate_max =
                           ResponseTimeoutImmediateMax} = ConfigOptions
                   } = State)
    when SendType =:= 'cloudi_service_send_async';
         SendType =:= 'cloudi_service_send_sync' ->
    QueueLimitOk = if
        QueueLimit =/= undefined ->
            pqueue4:len(Queue) < QueueLimit;
        true ->
            true
    end,
    {QueueSizeOk, Size} = if
        QueueSize =/= undefined ->
            QueueElementSize = erlang_term:byte_size({0, T}, WordSize),
            {(QueuedSize + QueueElementSize) =< QueueSize, QueueElementSize};
        true ->
            {true, 0}
    end,
    {RateRequestOk, NewRateRequest} = if
        RateRequest =/= undefined ->
            cloudi_core_i_rate_based_configuration:
            rate_request_request(RateRequest);
        true ->
            {true, RateRequest}
    end,
    NewState = State#state{
        options = ConfigOptions#config_service_options{
            rate_request_max = NewRateRequest}},
    hibernate_check(if
        QueueLimitOk, QueueSizeOk, RateRequestOk ->
            {noreply,
             recv_timeout_start(Timeout, Priority, TransId,
                                Size, T, NewState)};
        true ->
            if
                Timeout >= ResponseTimeoutImmediateMax ->
                    if
                        SendType =:= 'cloudi_service_send_async' ->
                            Source ! {'cloudi_service_return_async',
                                      Name, Pattern, <<>>, <<>>,
                                      Timeout, TransId, Source};
                        SendType =:= 'cloudi_service_send_sync' ->
                            Source ! {'cloudi_service_return_sync',
                                      Name, Pattern, <<>>, <<>>,
                                      Timeout, TransId, Source}
                    end;
                true ->
                    ok
            end,
            {noreply, NewState}
    end);

handle_info({'cloudi_service_recv_timeout', Priority, TransId, Size},
            #state{recv_timeouts = RecvTimeouts,
                   queue_requests = QueueRequests,
                   queued = Queue,
                   queued_size = QueuedSize} = State) ->
    {NewQueue, NewQueuedSize} = if
        QueueRequests =:= true ->
            F = fun({_, {_, _, _, _, _, _, _, Id, _}}) -> Id == TransId end,
            {Removed,
             NextQueue} = pqueue4:remove_unique(F, Priority, Queue),
            NextQueuedSize = if
                Removed =:= true ->
                    QueuedSize - Size;
                Removed =:= false ->
                    % false if a timer message was sent while cancelling
                    QueuedSize
            end,
            {NextQueue, NextQueuedSize};
        true ->
            {Queue, QueuedSize}
    end,
    hibernate_check({noreply,
                     State#state{
                         recv_timeouts = maps:remove(TransId, RecvTimeouts),
                         queued = NewQueue,
                         queued_size = NewQueuedSize}});

handle_info({'cloudi_service_return_async',
             Name, Pattern, ResponseInfo, Response,
             OldTimeout, TransId, Source},
            #state{send_timeouts = SendTimeouts,
                   receiver_pid = ReceiverPid,
                   options = #config_service_options{
                       request_timeout_immediate_max =
                           RequestTimeoutImmediateMax,
                       response_timeout_adjustment =
                           ResponseTimeoutAdjustment}} = State) ->
    true = Source =:= ReceiverPid,
    hibernate_check(case maps:find(TransId, SendTimeouts) of
        error ->
            % send_async timeout already occurred
            {noreply, State};
        {ok, {active, Pid, Tref}}
            when ResponseInfo == <<>>, Response == <<>> ->
            if
                ResponseTimeoutAdjustment;
                OldTimeout >= RequestTimeoutImmediateMax ->
                    cancel_timer_async(Tref);
                true ->
                    ok
            end,
            ReceiverPid ! {'timeout_async_active', TransId},
            {noreply, send_timeout_end(TransId, Pid, State)};
        {ok, {active, Pid, Tref}} ->
            Timeout = if
                ResponseTimeoutAdjustment;
                OldTimeout >= RequestTimeoutImmediateMax ->
                    case erlang:cancel_timer(Tref) of
                        false ->
                            0;
                        V ->
                            V
                    end;
                true ->
                    OldTimeout
            end,
            ReceiverPid ! {'return_async_active', Name, Pattern,
                           ResponseInfo, Response, Timeout, TransId},
            {noreply, send_timeout_end(TransId, Pid, State)};
        {ok, {passive, Pid, Tref}}
            when ResponseInfo == <<>>, Response == <<>> ->
            if
                ResponseTimeoutAdjustment;
                OldTimeout >= RequestTimeoutImmediateMax ->
                    cancel_timer_async(Tref);
                true ->
                    ok
            end,
            {noreply, send_timeout_end(TransId, Pid, State)};
        {ok, {passive, Pid, Tref}} ->
            Timeout = if
                ResponseTimeoutAdjustment;
                OldTimeout >= RequestTimeoutImmediateMax ->
                    case erlang:cancel_timer(Tref) of
                        false ->
                            0;
                        V ->
                            V
                    end;
                true ->
                    OldTimeout
            end,
            {noreply, send_timeout_end(TransId, Pid,
                async_response_timeout_start(ResponseInfo, Response, Timeout,
                                             TransId, State))}
    end);

handle_info({'cloudi_service_return_sync',
             _, _, ResponseInfo, Response,
             OldTimeout, TransId, Source},
            #state{send_timeouts = SendTimeouts,
                   receiver_pid = ReceiverPid,
                   options = #config_service_options{
                       request_timeout_immediate_max =
                           RequestTimeoutImmediateMax,
                       response_timeout_adjustment =
                           ResponseTimeoutAdjustment}} = State) ->
    true = Source =:= ReceiverPid,
    hibernate_check(case maps:find(TransId, SendTimeouts) of
        error ->
            % send_async timeout already occurred
            {noreply, State};
        {ok, {Client, Pid, Tref}} ->
            if
                ResponseTimeoutAdjustment;
                OldTimeout >= RequestTimeoutImmediateMax ->
                    cancel_timer_async(Tref);
                true ->
                    ok
            end,
            if
                ResponseInfo == <<>>, Response == <<>> ->
                    gen_server:reply(Client, {error, timeout});
                ResponseInfo == <<>> ->
                    gen_server:reply(Client, {ok, Response});
                true ->
                    gen_server:reply(Client, {ok, ResponseInfo, Response})
            end,
            {noreply, send_timeout_end(TransId, Pid, State)}
    end);

handle_info({'cloudi_service_send_async_timeout', TransId},
            #state{send_timeouts = SendTimeouts,
                   receiver_pid = ReceiverPid} = State) ->
    hibernate_check(case maps:find(TransId, SendTimeouts) of
        error ->
            % timer may have sent before being cancelled
            {noreply, State};
        {ok, {active, Pid, _}} ->
            ReceiverPid ! {'timeout_async_active', TransId},
            {noreply, send_timeout_end(TransId, Pid, State)};
        {ok, {passive, Pid, _}} ->
            {noreply, send_timeout_end(TransId, Pid, State)}
    end);

handle_info({'cloudi_service_send_sync_timeout', TransId},
            #state{send_timeouts = SendTimeouts} = State) ->
    hibernate_check(case maps:find(TransId, SendTimeouts) of
        error ->
            % timer may have sent before being cancelled
            {noreply, State};
        {ok, {Client, Pid, _}} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, send_timeout_end(TransId, Pid, State)}
    end);

handle_info({'cloudi_service_recv_async_timeout', TransId},
            #state{async_responses = AsyncResponses} = State) ->
    hibernate_check({noreply,
                     State#state{
                         async_responses =
                             maps:remove(TransId, AsyncResponses)}});

handle_info({'cloudi_service_send_async_minimal',
             Name, RequestInfo, Request,
             Timeout, Destination, ReceiverPid},
            #state{uuid_generator = UUID,
                   dest_refresh = DestRefresh,
                   cpg_data = Groups,
                   dest_deny = DestDeny,
                   dest_allow = DestAllow,
                   options = #config_service_options{
                       priority_default = PriorityDefault,
                       request_name_lookup = RequestNameLookup,
                       scope = Scope}} = State) ->
    hibernate_check(case Destination of
        {Pattern, Pid} ->
            {TransId, NewUUID} = uuid:get_v1(UUID),
            ReceiverPid ! {'cloudi_service_send_async_minimal',
                           TransId},
            Pid ! {'cloudi_service_send_async',
                   Name, Pattern, RequestInfo, Request,
                   Timeout, PriorityDefault, TransId, ReceiverPid},
            {noreply, State#state{uuid_generator = NewUUID}};
        undefined ->
            case destination_allowed(Name, DestDeny, DestAllow) of
                true ->
                    case destination_get(DestRefresh, Scope, Name, ReceiverPid,
                                         Groups, Timeout) of
                        {error, timeout} ->
                            ReceiverPid ! {'cloudi_service_send_async_minimal',
                                           timeout},
                            {noreply, State};
                        {error, _} when RequestNameLookup =:= async ->
                            ReceiverPid ! {'cloudi_service_send_async_minimal',
                                           timeout},
                            {noreply, State};
                        {error, _} when Timeout >= ?SEND_ASYNC_INTERVAL ->
                            erlang:send_after(?SEND_ASYNC_INTERVAL, self(),
                                              {'cloudi_service_send_async_minimal',
                                               Name, RequestInfo, Request,
                                               Timeout - ?SEND_ASYNC_INTERVAL,
                                               Destination, ReceiverPid}),
                            {noreply, State};
                        {error, _} ->
                            ReceiverPid ! {'cloudi_service_send_async_minimal',
                                           timeout},
                            {noreply, State};
                        {ok, Pattern, Pid} ->
                            {TransId, NewUUID} = uuid:get_v1(UUID),
                            ReceiverPid ! {'cloudi_service_send_async_minimal',
                                           TransId},
                            Pid ! {'cloudi_service_send_async',
                                   Name, Pattern, RequestInfo, Request,
                                   Timeout, PriorityDefault,
                                   TransId, ReceiverPid},
                            {noreply, State#state{uuid_generator = NewUUID}}
                    end;
                false ->
                    ReceiverPid ! {'cloudi_service_send_async_minimal',
                                   timeout},
                    {noreply, State}
            end
    end);

handle_info({'cloudi_service_send_sync_minimal',
             Name, RequestInfo, Request,
             Timeout, Destination, ReceiverPid},
            #state{uuid_generator = UUID,
                   dest_refresh = DestRefresh,
                   cpg_data = Groups,
                   dest_deny = DestDeny,
                   dest_allow = DestAllow,
                   options = #config_service_options{
                       priority_default = PriorityDefault,
                       request_name_lookup = RequestNameLookup,
                       scope = Scope}} = State) ->
    hibernate_check(case Destination of
        {Pattern, Pid} ->
            {TransId, NewUUID} = uuid:get_v1(UUID),
            ReceiverPid ! {'cloudi_service_send_sync_minimal',
                           TransId},
            Pid ! {'cloudi_service_send_sync',
                   Name, Pattern, RequestInfo, Request,
                   Timeout, PriorityDefault, TransId, ReceiverPid},
            {noreply, State#state{uuid_generator = NewUUID}};
        undefined ->
            case destination_allowed(Name, DestDeny, DestAllow) of
                true ->
                    case destination_get(DestRefresh, Scope, Name, ReceiverPid,
                                         Groups, Timeout) of
                        {error, timeout} ->
                            ReceiverPid ! {'cloudi_service_send_sync_minimal',
                                           timeout},
                            {noreply, State};
                        {error, _} when RequestNameLookup =:= async ->
                            ReceiverPid ! {'cloudi_service_send_sync_minimal',
                                           timeout},
                            {noreply, State};
                        {error, _} when Timeout >= ?SEND_SYNC_INTERVAL ->
                            erlang:send_after(?SEND_SYNC_INTERVAL, self(),
                                              {'cloudi_service_send_sync_minimal',
                                               Name, RequestInfo, Request,
                                               Timeout - ?SEND_SYNC_INTERVAL,
                                               Destination, ReceiverPid}),
                            {noreply, State};
                        {error, _} ->
                            ReceiverPid ! {'cloudi_service_send_sync_minimal',
                                           timeout},
                            {noreply, State};
                        {ok, Pattern, Pid} ->
                            {TransId, NewUUID} = uuid:get_v1(UUID),
                            ReceiverPid ! {'cloudi_service_send_sync_minimal',
                                           TransId},
                            Pid ! {'cloudi_service_send_sync',
                                   Name, Pattern, RequestInfo, Request,
                                   Timeout, PriorityDefault,
                                   TransId, ReceiverPid},
                            {noreply, State#state{uuid_generator = NewUUID}}
                    end;
                false ->
                    ReceiverPid ! {'cloudi_service_send_sync_minimal',
                                   timeout},
                    {noreply, State}
            end
    end);

handle_info({cloudi_cpg_data, Groups},
            #state{dispatcher = Dispatcher,
                   dest_refresh = DestRefresh,
                   options = #config_service_options{
                       dest_refresh_delay = Delay,
                       scope = Scope}} = State) ->
    destination_refresh(DestRefresh, Dispatcher, Delay, Scope),
    hibernate_check({noreply, State#state{cpg_data = Groups}});

handle_info('cloudi_hibernate_rate',
            #state{duo_mode_pid = undefined,
                   request_pid = RequestPid,
                   info_pid = InfoPid,
                   options = #config_service_options{
                       hibernate = Hibernate} = ConfigOptions} = State) ->
    {Value, NewHibernate} = cloudi_core_i_rate_based_configuration:
                            hibernate_reinit(Hibernate),
    if
        is_pid(RequestPid) ->
            RequestPid ! {'cloudi_hibernate', Value};
        true ->
            ok
    end,
    if
        is_pid(InfoPid) ->
            InfoPid ! {'cloudi_hibernate', Value};
        true ->
            ok
    end,
    hibernate_check({noreply,
                     State#state{
                         options = ConfigOptions#config_service_options{
                             hibernate = NewHibernate}}});

handle_info({'cloudi_hibernate', Hibernate},
            #state{duo_mode_pid = DuoModePid,
                   options = ConfigOptions} = State) ->
    true = is_pid(DuoModePid),
    % force the hibernate state
    hibernate_check({noreply,
                     State#state{
                         options = ConfigOptions#config_service_options{
                             hibernate = Hibernate}}});

handle_info('cloudi_count_process_dynamic_rate',
            #state{dispatcher = Dispatcher,
                   duo_mode_pid = undefined,
                   options = #config_service_options{
                       count_process_dynamic =
                           CountProcessDynamic} = ConfigOptions} = State) ->
    NewCountProcessDynamic = cloudi_core_i_rate_based_configuration:
                             count_process_dynamic_reinit(Dispatcher,
                                                          CountProcessDynamic),
    hibernate_check({noreply,
                     State#state{
                         options = ConfigOptions#config_service_options{
                             count_process_dynamic =
                                 NewCountProcessDynamic}}});

handle_info({'cloudi_count_process_dynamic_update', ProcessCount}, State) ->
    hibernate_check({noreply, State#state{process_count = ProcessCount}});

handle_info('cloudi_count_process_dynamic_terminate',
            #state{receiver_pid = ReceiverPid,
                   options = #config_service_options{
                       count_process_dynamic = CountProcessDynamic,
                       scope = Scope} = ConfigOptions} = State) ->
    cpg:leave(Scope, ReceiverPid, infinity),
    NewCountProcessDynamic =
        cloudi_core_i_rate_based_configuration:
        count_process_dynamic_terminate_set(ReceiverPid, CountProcessDynamic),
    hibernate_check({noreply,
                     State#state{
                         options = ConfigOptions#config_service_options{
                             count_process_dynamic =
                                 NewCountProcessDynamic}}});

handle_info('cloudi_count_process_dynamic_terminate_check',
            #state{dispatcher = Dispatcher,
                   queue_requests = QueueRequests,
                   duo_mode_pid = undefined} = State) ->
    if
        QueueRequests =:= false ->
            {stop, {shutdown, cloudi_count_process_dynamic_terminate}, State};
        QueueRequests =:= true ->
            erlang:send_after(?COUNT_PROCESS_DYNAMIC_INTERVAL, Dispatcher,
                              'cloudi_count_process_dynamic_terminate_check'),
            hibernate_check({noreply, State})
    end;

handle_info('cloudi_count_process_dynamic_terminate_now',
            #state{duo_mode_pid = undefined} = State) ->
    {stop, {shutdown, cloudi_count_process_dynamic_terminate}, State};

handle_info('cloudi_rate_request_max_rate',
            #state{duo_mode_pid = undefined,
                   options = #config_service_options{
                       rate_request_max =
                           RateRequest} = ConfigOptions} = State) ->
    NewRateRequest = cloudi_core_i_rate_based_configuration:
                     rate_request_reinit(RateRequest),
    hibernate_check({noreply,
                     State#state{
                         options = ConfigOptions#config_service_options{
                             rate_request_max = NewRateRequest}}});

handle_info({'EXIT', _, shutdown},
            #state{duo_mode_pid = DuoModePid} = State) ->
    % CloudI Service shutdown
    if
        is_pid(DuoModePid) ->
            erlang:exit(DuoModePid, shutdown);
        true ->
            ok
    end,
    {stop, shutdown, State};

handle_info({'EXIT', _, {shutdown, _} = Shutdown},
            #state{duo_mode_pid = DuoModePid} = State) ->
    % CloudI Service shutdown w/reason
    if
        is_pid(DuoModePid) ->
            erlang:exit(DuoModePid, shutdown);
        true ->
            ok
    end,
    {stop, Shutdown, State};

handle_info({'EXIT', _, restart},
            #state{duo_mode_pid = DuoModePid} = State) ->
    % CloudI Service API requested a restart
    if
        is_pid(DuoModePid) ->
            erlang:exit(DuoModePid, restart);
        true ->
            ok
    end,
    {stop, restart, State};

handle_info({'EXIT', DuoModePid, Reason},
            #state{duo_mode_pid = DuoModePid} = State) ->
    ?LOG_ERROR("~p duo_mode exited: ~p", [DuoModePid, Reason]),
    {stop, Reason, State};

handle_info({'EXIT', RequestPid,
             {'cloudi_service_request_success', _RequestResponse,
              _NewServiceState} = Result},
            #state{request_pid = RequestPid} = State) ->
    handle_info(Result, State#state{request_pid = undefined});

handle_info({'EXIT', RequestPid,
             {'cloudi_service_request_failure',
              _Type, _Error, _Stack, _NewServiceState} = Result},
            #state{request_pid = RequestPid} = State) ->
    handle_info(Result, State#state{request_pid = undefined});

handle_info({'EXIT', RequestPid, Reason},
            #state{request_pid = RequestPid} = State) ->
    ?LOG_ERROR("~p request exited: ~p", [RequestPid, Reason]),
    {stop, Reason, State};

handle_info({'EXIT', InfoPid,
             {'cloudi_service_info_success',
              _NewServiceState} = Result},
            #state{info_pid = InfoPid} = State) ->
    handle_info(Result, State#state{info_pid = undefined});

handle_info({'EXIT', InfoPid,
             {'cloudi_service_info_failure',
              _Type, _Error, _Stack, _NewServiceState} = Result},
            #state{info_pid = InfoPid} = State) ->
    handle_info(Result, State#state{info_pid = undefined});

handle_info({'EXIT', InfoPid, Reason},
            #state{info_pid = InfoPid} = State) ->
    ?LOG_ERROR("~p info exited: ~p", [InfoPid, Reason]),
    {stop, Reason, State};

handle_info({'EXIT', Dispatcher, Reason},
            #state{dispatcher = Dispatcher} = State) ->
    ?LOG_ERROR("~p service exited: ~p", [Dispatcher, Reason]),
    {stop, Reason, State};

handle_info({'EXIT', Pid, Reason}, State) ->
    ?LOG_ERROR("~p forced exit: ~p", [Pid, Reason]),
    {stop, Reason, State};

handle_info({'cloudi_service_update', UpdatePending, UpdatePlan},
            #state{dispatcher = Dispatcher,
                   update_plan = undefined,
                   queue_requests = QueueRequests,
                   duo_mode_pid = undefined} = State) ->
    #config_service_update{sync = Sync} = UpdatePlan,
    NewUpdatePlan = if
        Sync =:= true, QueueRequests =:= true ->
            UpdatePlan#config_service_update{update_pending = UpdatePending,
                                             queue_requests = QueueRequests};
        true ->
            UpdatePending ! {'cloudi_service_update', Dispatcher},
            UpdatePlan#config_service_update{queue_requests = QueueRequests}
    end,
    hibernate_check({noreply, State#state{update_plan = NewUpdatePlan,
                                          queue_requests = true}});

handle_info({'cloudi_service_update_now', UpdateNow, UpdateStart},
            #state{update_plan = UpdatePlan,
                   duo_mode_pid = undefined} = State) ->
    #config_service_update{queue_requests = QueueRequests} = UpdatePlan,
    NewUpdatePlan = UpdatePlan#config_service_update{
                        update_now = UpdateNow,
                        update_start = UpdateStart},
    NewState = State#state{update_plan = NewUpdatePlan},
    if
        QueueRequests =:= true ->
            hibernate_check({noreply, NewState});
        QueueRequests =:= false ->
            hibernate_check({noreply, process_update(NewState)})
    end;

handle_info({'cloudi_service_update_state',
             #config_service_update{options = ConfigOptions} = UpdatePlan},
            #state{duo_mode_pid = DuoModePid} = State) ->
    true = is_pid(DuoModePid),
    NewState = update_state(State#state{options = ConfigOptions}, UpdatePlan),
    hibernate_check({noreply, NewState});

handle_info({'cloudi_service_init_execute', Args, Timeout,
             ProcessDictionary, State},
            #state{dispatcher = Dispatcher,
                   queue_requests = true,
                   module = Module,
                   prefix = Prefix,
                   duo_mode_pid = undefined,
                   options = #config_service_options{
                       init_pid_options = PidOptions}} = State) ->
    ok = initialize_wait(Timeout),
    {ok, DispatcherProxy} = cloudi_core_i_services_internal_init:
                            start_link(Timeout, PidOptions,
                                       ProcessDictionary, State),
    Result = try Module:cloudi_service_init(Args, Prefix, Timeout,
                                            DispatcherProxy)
    catch
        ?STACKTRACE(ErrorType, Error, ErrorStackTrace)
            ?LOG_ERROR_SYNC("init ~p ~p~n~p",
                            [ErrorType, Error, ErrorStackTrace]),
            {stop, {ErrorType, {Error, ErrorStackTrace}}}
    end,
    {NewProcessDictionary,
     #state{options = ConfigOptions} = NextState} =
        cloudi_core_i_services_internal_init:
        stop_link(DispatcherProxy),
    ok = cloudi_core_i_services_internal_init:
         process_dictionary_set(NewProcessDictionary),
    hibernate_check(case Result of
        {ok, ServiceState} ->
            NewConfigOptions = check_init_receive(ConfigOptions),
            #config_service_options{
                aspects_init_after = Aspects} = NewConfigOptions,
            case aspects_init(Aspects, Args, Prefix, Timeout,
                              ServiceState, Dispatcher) of
                {ok, NewServiceState} ->
                    erlang:process_flag(trap_exit, true),
                    ok = cloudi_core_i_services_monitor:
                         process_init_end(Dispatcher),
                    NewState = NextState#state{service_state = NewServiceState,
                                               options = NewConfigOptions},
                    {noreply, process_queues(NewState)};
                {stop, Reason, NewServiceState} ->
                    {stop, Reason,
                     NextState#state{service_state = NewServiceState,
                                     duo_mode_pid = undefined,
                                     options = NewConfigOptions}}
            end;
        {stop, Reason, ServiceState} ->
            {stop, Reason, NextState#state{service_state = ServiceState,
                                           duo_mode_pid = undefined}};
        {stop, Reason} ->
            {stop, Reason, NextState#state{service_state = undefined,
                                           duo_mode_pid = undefined}}
    end);

handle_info({'cloudi_service_init_state', NewProcessDictionary, NewState},
            #state{duo_mode_pid = DuoModePid}) ->
    true = is_pid(DuoModePid),
    ok = cloudi_core_i_services_internal_init:
         process_dictionary_set(NewProcessDictionary),
    erlang:process_flag(trap_exit, true),
    hibernate_check({noreply, NewState});

handle_info({'DOWN', _MonitorRef, process, Pid, _Info} = Request, State) ->
    case send_timeout_dead(Pid, State) of
        {true, NewState} ->
            hibernate_check({noreply, NewState});
        {false, #state{duo_mode_pid = DuoModePid} = NewState} ->
            if
                DuoModePid =:= undefined ->
                    handle_info_message(Request, NewState);
                is_pid(DuoModePid) ->
                    DuoModePid ! Request,
                    hibernate_check({noreply, NewState})
            end
    end;

handle_info({ReplyRef, _}, State) when is_reference(ReplyRef) ->
    % gen_server:call/3 had a timeout exception that was caught but the
    % reply arrived later and must be discarded
    hibernate_check({noreply, State});

handle_info(Request, #state{duo_mode_pid = DuoModePid} = State) ->
    if
        DuoModePid =:= undefined ->
            handle_info_message(Request, State);
        is_pid(DuoModePid) ->
            % should never happen, but random code could
            % send random messages to the dispatcher Erlang process
            ?LOG_ERROR("Unknown info \"~w\"", [Request]),
            hibernate_check({noreply, State})
    end.

terminate(Reason,
          #state{dispatcher = Dispatcher,
                 module = Module,
                 service_state = ServiceState,
                 timeout_term = TimeoutTerm,
                 duo_mode_pid = undefined,
                 options = #config_service_options{
                     aspects_terminate_before = Aspects}}) ->
    _ = cloudi_core_i_services_monitor:
        process_terminate_begin(Dispatcher, Reason),
    {ok, NewServiceState} = aspects_terminate(Aspects, Reason, TimeoutTerm,
                                              ServiceState),
    _ = Module:cloudi_service_terminate(Reason, TimeoutTerm, NewServiceState),
    ok;

terminate(_, _) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.

-ifdef(VERBOSE_STATE).
format_status(_Opt, [_PDict, State]) ->
    [{data,
      [{"State", State}]}].
-else.
format_status(_Opt,
              [_PDict,
               #state{send_timeouts = SendTimeouts,
                      send_timeout_monitors = SendTimeoutMonitors,
                      recv_timeouts = RecvTimeouts,
                      async_responses = AsyncResponses,
                      queued = Queue,
                      queued_info = QueueInfo,
                      cpg_data = Groups,
                      dest_deny = DestDeny,
                      dest_allow = DestAllow,
                      options = ConfigOptions} = State]) ->
    NewRecvTimeouts = if
        RecvTimeouts =:= undefined ->
            undefined;
        true ->
            maps:to_list(RecvTimeouts)
    end,
    NewQueue = if
        Queue =:= undefined ->
            undefined;
        true ->
            pqueue4:to_plist(Queue)
    end,
    NewQueueInfo = if
        QueueInfo =:= undefined ->
            undefined;
        true ->
            queue:to_list(QueueInfo)
    end,
    NewGroups = case Groups of
        undefined ->
            undefined;
        {GroupsDictI, GroupsData} ->
            GroupsDictI:to_list(GroupsData)
    end,
    NewDestDeny = if
        DestDeny =:= undefined ->
            undefined;
        true ->
            trie:to_list(DestDeny)
    end,
    NewDestAllow = if
        DestAllow =:= undefined ->
            undefined;
        true ->
            trie:to_list(DestAllow)
    end,
    NewConfigOptions = cloudi_core_i_configuration:
                       services_format_options_internal(ConfigOptions),
    [{data,
      [{"State",
        State#state{send_timeouts = maps:to_list(SendTimeouts),
                    send_timeout_monitors = maps:to_list(SendTimeoutMonitors),
                    recv_timeouts = NewRecvTimeouts,
                    async_responses = maps:to_list(AsyncResponses),
                    queued = NewQueue,
                    queued_info = NewQueueInfo,
                    cpg_data = NewGroups,
                    dest_deny = NewDestDeny,
                    dest_allow = NewDestAllow,
                    options = NewConfigOptions}}]}];
format_status(_Opt,
              [_PDict, _SysState, _Parent, _Debug,
               #state_duo{} = State]) ->
    [{data,
      [{"State",
        duo_mode_format_state(State)}]}].
-endif.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

initialize_wait(Timeout) ->
    receive
        cloudi_service_init_begin ->
            ok
    after
        Timeout ->
            erlang:exit(timeout)
    end.

handle_get_pid(Name, Timeout, Client,
               #state{receiver_pid = ReceiverPid,
                      dest_refresh = DestRefresh,
                      cpg_data = Groups,
                      options = #config_service_options{
                          request_name_lookup = RequestNameLookup,
                          scope = Scope}} = State) ->
    case destination_get(DestRefresh, Scope, Name, ReceiverPid,
                         Groups, Timeout) of
        {error, timeout} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when RequestNameLookup =:= async ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when Timeout >= ?SEND_SYNC_INTERVAL ->
            erlang:send_after(?SEND_SYNC_INTERVAL, self(),
                              {'cloudi_service_get_pid_retry',
                               Name, Timeout - ?SEND_SYNC_INTERVAL, Client}),
            {noreply, State};
        {error, _} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {ok, Pattern, Pid} ->
            gen_server:reply(Client, {ok, {Pattern, Pid}}),
            {noreply, State}
    end.

handle_get_pids(Name, Timeout, Client,
                #state{receiver_pid = ReceiverPid,
                       dest_refresh = DestRefresh,
                       cpg_data = Groups,
                       options = #config_service_options{
                           request_name_lookup = RequestNameLookup,
                           scope = Scope}} = State) ->
    case destination_all(DestRefresh, Scope, Name, ReceiverPid,
                         Groups, Timeout) of
        {error, timeout} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when RequestNameLookup =:= async ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when Timeout >= ?SEND_SYNC_INTERVAL ->
            erlang:send_after(?SEND_SYNC_INTERVAL, self(),
                              {'cloudi_service_get_pids_retry',
                               Name, Timeout - ?SEND_SYNC_INTERVAL, Client}),
            {noreply, State};
        {error, _} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {ok, Pattern, Pids} ->
            gen_server:reply(Client,
                             {ok, [{Pattern, Pid} || Pid <- Pids]}),
            {noreply, State}
    end.

handle_send_async(Name, RequestInfo, Request,
                  Timeout, Priority, Client,
                  #state{receiver_pid = ReceiverPid,
                         uuid_generator = UUID,
                         dest_refresh = DestRefresh,
                         cpg_data = Groups,
                         options = #config_service_options{
                             request_name_lookup = RequestNameLookup,
                             scope = Scope}} = State) ->
    case destination_get(DestRefresh, Scope, Name, ReceiverPid,
                         Groups, Timeout) of
        {error, timeout} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when RequestNameLookup =:= async ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when Timeout >= ?SEND_ASYNC_INTERVAL ->
            erlang:send_after(?SEND_ASYNC_INTERVAL, self(),
                              {'cloudi_service_send_async_retry',
                               Name, RequestInfo, Request,
                               Timeout - ?SEND_ASYNC_INTERVAL,
                               Priority, Client}),
            {noreply, State};
        {error, _} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {ok, Pattern, Pid} ->
            {TransId, NewUUID} = uuid:get_v1(UUID),
            Pid ! {'cloudi_service_send_async',
                   Name, Pattern, RequestInfo, Request,
                   Timeout, Priority, TransId, ReceiverPid},
            gen_server:reply(Client, {ok, TransId}),
            {noreply,
             send_async_timeout_start(Timeout, TransId, Pid,
                                      State#state{uuid_generator = NewUUID})}
    end.

handle_send_async_pid(Name, Pattern, RequestInfo, Request,
                      Timeout, Priority, Pid,
                      #state{receiver_pid = ReceiverPid,
                             uuid_generator = UUID} = State) ->
    {TransId, NewUUID} = uuid:get_v1(UUID),
    Pid ! {'cloudi_service_send_async',
           Name, Pattern, RequestInfo, Request,
           Timeout, Priority, TransId, ReceiverPid},
    {reply, {ok, TransId},
     send_async_timeout_start(Timeout, TransId, Pid,
                              State#state{uuid_generator = NewUUID})}.

handle_send_async_active(Name, RequestInfo, Request,
                         Timeout, Priority, Client,
                         #state{receiver_pid = ReceiverPid,
                                uuid_generator = UUID,
                                dest_refresh = DestRefresh,
                                cpg_data = Groups,
                                options = #config_service_options{
                                    request_name_lookup = RequestNameLookup,
                                    scope = Scope}} = State) ->
    case destination_get(DestRefresh, Scope, Name, ReceiverPid,
                         Groups, Timeout) of
        {error, timeout} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when RequestNameLookup =:= async ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when Timeout >= ?SEND_ASYNC_INTERVAL ->
            erlang:send_after(?SEND_ASYNC_INTERVAL, self(),
                              {'cloudi_service_send_async_active_retry',
                               Name, RequestInfo, Request,
                               Timeout - ?SEND_ASYNC_INTERVAL,
                               Priority, Client}),
            {noreply, State};
        {error, _} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {ok, Pattern, Pid} ->
            {TransId, NewUUID} = uuid:get_v1(UUID),
            Pid ! {'cloudi_service_send_async',
                   Name, Pattern, RequestInfo, Request,
                   Timeout, Priority, TransId, ReceiverPid},
            gen_server:reply(Client, {ok, TransId}),
            {noreply,
             send_async_active_timeout_start(Timeout, TransId, Pid,
                                             State#state{
                                                 uuid_generator = NewUUID})}
    end.

handle_send_async_active_pid(Name, Pattern, RequestInfo, Request,
                             Timeout, Priority, OldTransId, Pid,
                             #state{receiver_pid = ReceiverPid,
                                    uuid_generator = UUID} = State) ->
    {TransId, NewUUID} = if
        OldTransId =:= undefined ->
            uuid:get_v1(UUID);
        true ->
            {OldTransId, UUID}
    end,
    Pid ! {'cloudi_service_send_async',
           Name, Pattern, RequestInfo, Request,
           Timeout, Priority, TransId, ReceiverPid},
    {reply, {ok, TransId},
     send_async_active_timeout_start(Timeout, TransId, Pid,
                                     State#state{uuid_generator = NewUUID})}.

handle_send_sync(Name, RequestInfo, Request,
                 Timeout, Priority, Client,
                 #state{receiver_pid = ReceiverPid,
                        uuid_generator = UUID,
                        dest_refresh = DestRefresh,
                        cpg_data = Groups,
                        options = #config_service_options{
                            request_name_lookup = RequestNameLookup,
                            scope = Scope}} = State) ->
    case destination_get(DestRefresh, Scope, Name, ReceiverPid,
                         Groups, Timeout) of
        {error, timeout} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when RequestNameLookup =:= async ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when Timeout >= ?SEND_SYNC_INTERVAL ->
            erlang:send_after(?SEND_SYNC_INTERVAL, self(),
                              {'cloudi_service_send_sync_retry',
                               Name, RequestInfo, Request,
                               Timeout - ?SEND_SYNC_INTERVAL,
                               Priority, Client}),
            {noreply, State};
        {error, _} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {ok, Pattern, Pid} ->
            {TransId, NewUUID} = uuid:get_v1(UUID),
            Pid ! {'cloudi_service_send_sync',
                   Name, Pattern, RequestInfo, Request,
                   Timeout, Priority, TransId, ReceiverPid},
            {noreply,
             send_sync_timeout_start(Timeout, TransId, Pid, Client,
                                     State#state{uuid_generator = NewUUID})}
    end.

handle_send_sync_pid(Name, Pattern, RequestInfo, Request,
                     Timeout, Priority, Pid, Client,
                     #state{receiver_pid = ReceiverPid,
                            uuid_generator = UUID} = State) ->
    {TransId, NewUUID} = uuid:get_v1(UUID),
    Pid ! {'cloudi_service_send_sync',
           Name, Pattern, RequestInfo, Request,
           Timeout, Priority, TransId, ReceiverPid},
    {noreply,
     send_sync_timeout_start(Timeout, TransId, Pid, Client,
                             State#state{uuid_generator = NewUUID})}.

handle_mcast_async_pids(_Name, _Pattern, _RequestInfo, _Request,
                        _Timeout, _Priority,
                        TransIdList, [], Client,
                        State) ->
    gen_server:reply(Client, {ok, lists:reverse(TransIdList)}),
    State;

handle_mcast_async_pids(Name, Pattern, RequestInfo, Request,
                        Timeout, Priority,
                        TransIdList, [Pid | PidList], Client,
                        #state{receiver_pid = ReceiverPid,
                               uuid_generator = UUID} = State) ->
    {TransId, NewUUID} = uuid:get_v1(UUID),
    Pid ! {'cloudi_service_send_async',
           Name, Pattern, RequestInfo, Request,
           Timeout, Priority, TransId, ReceiverPid},
    NewState = send_async_timeout_start(Timeout,
                                        TransId,
                                        Pid,
                                        State#state{uuid_generator = NewUUID}),
    handle_mcast_async_pids(Name, Pattern, RequestInfo, Request,
                            Timeout, Priority,
                            [TransId | TransIdList], PidList, Client,
                            NewState).

handle_mcast_async(Name, RequestInfo, Request,
                   Timeout, Priority, Client,
                   #state{receiver_pid = ReceiverPid,
                          dest_refresh = DestRefresh,
                          cpg_data = Groups,
                          options = #config_service_options{
                              request_name_lookup = RequestNameLookup,
                              scope = Scope}} = State) ->
    case destination_all(DestRefresh, Scope, Name, ReceiverPid,
                         Groups, Timeout) of
        {error, timeout} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when RequestNameLookup =:= async ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when Timeout >= ?MCAST_ASYNC_INTERVAL ->
            erlang:send_after(?MCAST_ASYNC_INTERVAL, self(),
                              {'cloudi_service_mcast_async_retry',
                               Name, RequestInfo, Request,
                               Timeout - ?MCAST_ASYNC_INTERVAL,
                               Priority, Client}),
            {noreply, State};
        {error, _} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {ok, Pattern, PidList} ->
            {noreply,
             handle_mcast_async_pids(Name, Pattern, RequestInfo, Request,
                                     Timeout, Priority,
                                     [], PidList, Client, State)}
    end.

handle_mcast_async_pids_active(_Name, _Pattern, _RequestInfo, _Request,
                               _Timeout, _Priority,
                               TransIdList, [], Client,
                               State) ->
    gen_server:reply(Client, {ok, lists:reverse(TransIdList)}),
    State;

handle_mcast_async_pids_active(Name, Pattern, RequestInfo, Request,
                               Timeout, Priority,
                               TransIdList, [Pid | PidList], Client,
                               #state{receiver_pid = ReceiverPid,
                                      uuid_generator = UUID} = State) ->
    {TransId, NewUUID} = uuid:get_v1(UUID),
    Pid ! {'cloudi_service_send_async',
           Name, Pattern, RequestInfo, Request,
           Timeout, Priority, TransId, ReceiverPid},
    NewState = send_async_active_timeout_start(Timeout, TransId, Pid,
                                               State#state{
                                                   uuid_generator = NewUUID}),
    handle_mcast_async_pids_active(Name, Pattern, RequestInfo, Request,
                                   Timeout, Priority,
                                   [TransId | TransIdList], PidList, Client,
                                   NewState).

handle_mcast_async_active(Name, RequestInfo, Request,
                          Timeout, Priority, Client,
                          #state{receiver_pid = ReceiverPid,
                                 dest_refresh = DestRefresh,
                                 cpg_data = Groups,
                                 options = #config_service_options{
                                     request_name_lookup = RequestNameLookup,
                                     scope = Scope}} = State) ->
    case destination_all(DestRefresh, Scope, Name, ReceiverPid,
                         Groups, Timeout) of
        {error, timeout} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when RequestNameLookup =:= async ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when Timeout >= ?MCAST_ASYNC_INTERVAL ->
            erlang:send_after(?MCAST_ASYNC_INTERVAL, self(),
                              {'cloudi_service_mcast_async_active_retry',
                               Name, RequestInfo, Request,
                               Timeout - ?MCAST_ASYNC_INTERVAL,
                               Priority, Client}),
            {noreply, State};
        {error, _} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {ok, Pattern, PidList} ->
            {noreply,
             handle_mcast_async_pids_active(Name, Pattern, RequestInfo, Request,
                                            Timeout, Priority,
                                            [], PidList, Client, State)}
    end.

handle_module_request(Type, Name, Pattern, RequestInfo, Request,
                      Timeout, Priority, TransId, Source,
                      ServiceState, Dispatcher, Module,
                      #config_service_options{
                          request_timeout_adjustment =
                              RequestTimeoutAdjustment,
                          aspects_request_before =
                              AspectsBefore,
                          aspects_request_after =
                              AspectsAfter} = ConfigOptions) ->
    RequestTimeoutF = request_timeout_adjustment_f(RequestTimeoutAdjustment),
    try aspects_request_before(AspectsBefore, Type,
                               Name, Pattern, RequestInfo, Request,
                               Timeout, Priority, TransId, Source,
                               ServiceState, Dispatcher) of
        {ok, NextServiceState} ->
            case handle_module_request_f(Type, Name, Pattern,
                                         RequestInfo, Request,
                                         Timeout, Priority, TransId, Source,
                                         NextServiceState, Dispatcher, Module,
                                         ConfigOptions) of
                {'cloudi_service_request_success',
                 {ReturnType, NextName, NextPattern,
                  ResponseInfo, Response,
                  NextTimeout, TransId, Source},
                 NewServiceState}
                when ReturnType =:= 'cloudi_service_return_async';
                     ReturnType =:= 'cloudi_service_return_sync' ->
                    Result = {reply, ResponseInfo, Response},
                    try aspects_request_after(AspectsAfter, Type,
                                              Name, Pattern,
                                              RequestInfo, Request,
                                              Timeout, Priority,
                                              TransId, Source,
                                              Result, NewServiceState,
                                              Dispatcher) of
                        {ok, FinalServiceState} ->
                            NewTimeout = if
                                NextTimeout == Timeout ->
                                    RequestTimeoutF(Timeout);
                                true ->
                                    NextTimeout
                            end,
                            {'cloudi_service_request_success',
                             {ReturnType, NextName, NextPattern,
                              ResponseInfo, Response,
                              NewTimeout, TransId, Source},
                             FinalServiceState};
                        {stop, Reason, FinalServiceState} ->
                            {'cloudi_service_request_failure',
                             stop, Reason, undefined, FinalServiceState}
                    catch
                        ?STACKTRACE(ErrorType, Error, ErrorStackTrace)
                            {'cloudi_service_request_failure',
                             ErrorType, Error, ErrorStackTrace,
                             NewServiceState}
                    end;
                {'cloudi_service_request_success',
                 {ForwardType, Name, Pattern,
                  NextName, NextRequestInfo, NextRequest,
                  NextTimeout, NextPriority, TransId, Source},
                 NewServiceState}
                when ForwardType =:= 'cloudi_service_forward_async_retry';
                     ForwardType =:= 'cloudi_service_forward_sync_retry' ->
                    Result = {forward, NextName,
                              NextRequestInfo, NextRequest,
                              NextTimeout, NextPriority},
                    try aspects_request_after(AspectsAfter, Type,
                                              Name, Pattern,
                                              RequestInfo, Request,
                                              Timeout, Priority,
                                              TransId, Source,
                                              Result, NewServiceState,
                                              Dispatcher) of
                        {ok, FinalServiceState} ->
                            NewTimeout = if
                                NextTimeout == Timeout ->
                                    RequestTimeoutF(Timeout);
                                true ->
                                    NextTimeout
                            end,
                            {'cloudi_service_request_success',
                             {ForwardType, Name, Pattern,
                              NextName, NextRequestInfo, NextRequest,
                              NewTimeout, NextPriority, TransId, Source},
                             FinalServiceState};
                        {stop, Reason, FinalServiceState} ->
                            {'cloudi_service_request_failure',
                             stop, Reason, undefined, FinalServiceState}
                    catch
                        ?STACKTRACE(ErrorType, Error, ErrorStackTrace)
                            {'cloudi_service_request_failure',
                             ErrorType, Error, ErrorStackTrace,
                             NewServiceState}
                    end;
                {'cloudi_service_request_success',
                 undefined,
                 NewServiceState} ->
                    Result = noreply,
                    try aspects_request_after(AspectsAfter, Type,
                                              Name, Pattern,
                                              RequestInfo, Request,
                                              Timeout, Priority,
                                              TransId, Source,
                                              Result, NewServiceState,
                                              Dispatcher) of
                        {ok, FinalServiceState} ->
                            {'cloudi_service_request_success',
                             undefined,
                             FinalServiceState};
                        {stop, Reason, FinalServiceState} ->
                            {'cloudi_service_request_failure',
                             stop, Reason, undefined, FinalServiceState}
                    catch
                        ?STACKTRACE(ErrorType, Error, ErrorStackTrace)
                            {'cloudi_service_request_failure',
                             ErrorType, Error, ErrorStackTrace,
                             NewServiceState}
                    end;
                {'cloudi_service_request_failure', _, _, _, _} = Error ->
                    Error
            end;
        {stop, Reason, NextServiceState} ->
            {'cloudi_service_request_failure',
             stop, Reason, undefined, NextServiceState}
    catch
        ?STACKTRACE(ErrorType, Error, ErrorStackTrace)
            {'cloudi_service_request_failure',
             ErrorType, Error, ErrorStackTrace, ServiceState}
    end.

handle_module_request_f('send_async', Name, Pattern, RequestInfo, Request,
                        Timeout, Priority, TransId, Source,
                        ServiceState, Dispatcher, Module,
                        #config_service_options{
                            response_timeout_immediate_max =
                                ResponseTimeoutImmediateMax}) ->
    try Module:cloudi_service_handle_request('send_async',
                                             Name, Pattern,
                                             RequestInfo, Request,
                                             Timeout, Priority,
                                             TransId, Source,
                                             ServiceState,
                                             Dispatcher) of
        {reply, <<>>, NewServiceState} ->
            if
                Timeout < ResponseTimeoutImmediateMax ->
                    {'cloudi_service_request_success',
                     undefined, NewServiceState};
                true ->
                    {'cloudi_service_request_success',
                     {'cloudi_service_return_async', Name, Pattern,
                      <<>>, <<>>, Timeout, TransId, Source},
                     NewServiceState}
            end;
        {reply, Response, NewServiceState} ->
            {'cloudi_service_request_success',
             {'cloudi_service_return_async', Name, Pattern,
              <<>>, Response, Timeout, TransId, Source},
             NewServiceState};
        {reply, <<>>, <<>>, NewServiceState} ->
            if
                Timeout < ResponseTimeoutImmediateMax ->
                    {'cloudi_service_request_success',
                     undefined, NewServiceState};
                true ->
                    {'cloudi_service_request_success',
                     {'cloudi_service_return_async', Name, Pattern,
                      <<>>, <<>>, Timeout, TransId, Source},
                     NewServiceState}
            end;
        {reply, ResponseInfo, Response, NewServiceState} ->
            {'cloudi_service_request_success',
             {'cloudi_service_return_async', Name, Pattern,
              ResponseInfo, Response, Timeout, TransId, Source},
             NewServiceState};
        {forward, _, _, _, NextTimeout, NextPriority, NewServiceState}
            when NextPriority < ?PRIORITY_HIGH;
                 NextPriority > ?PRIORITY_LOW;
                 NextTimeout < 0 ->
            try erlang:exit(badarg)
            catch
                ?STACKTRACE(exit, badarg, ErrorStackTrace)
                    {'cloudi_service_request_failure',
                     exit, badarg, ErrorStackTrace, NewServiceState}
            end;
        {forward, NextName, NextRequestInfo, NextRequest,
                  NextTimeout, NextPriority, NewServiceState} ->
            {'cloudi_service_request_success',
             {'cloudi_service_forward_async_retry', Name, Pattern,
              NextName, NextRequestInfo, NextRequest,
              NextTimeout, NextPriority, TransId, Source},
             NewServiceState};
        {forward, NextName, NextRequestInfo, NextRequest,
                  NewServiceState} ->
            {'cloudi_service_request_success',
             {'cloudi_service_forward_async_retry', Name, Pattern,
              NextName, NextRequestInfo, NextRequest,
              Timeout, Priority, TransId, Source},
             NewServiceState};
        {noreply, NewServiceState} ->
            {'cloudi_service_request_success', undefined, NewServiceState};
        {stop, Reason, NewServiceState} ->
            {'cloudi_service_request_failure',
             stop, Reason, undefined, NewServiceState}
    catch
        throw:{cloudi_service_return, {<<>>}} ->
            if
                Timeout < ResponseTimeoutImmediateMax ->
                    {'cloudi_service_request_success',
                     undefined, ServiceState};
                true ->
                    {'cloudi_service_request_success',
                     {'cloudi_service_return_async', Name, Pattern,
                      <<>>, <<>>, Timeout, TransId, Source},
                     ServiceState}
            end;
        throw:{cloudi_service_return, {Response}} ->
            {'cloudi_service_request_success',
             {'cloudi_service_return_async', Name, Pattern,
              <<>>, Response, Timeout, TransId, Source},
             ServiceState};
        throw:{cloudi_service_return, {<<>>, <<>>}} ->
            if
                Timeout < ResponseTimeoutImmediateMax ->
                    {'cloudi_service_request_success',
                     undefined, ServiceState};
                true ->
                    {'cloudi_service_request_success',
                     {'cloudi_service_return_async', Name, Pattern,
                      <<>>, <<>>, Timeout, TransId, Source},
                     ServiceState}
            end;
        throw:{cloudi_service_return, {ResponseInfo, Response}} ->
            {'cloudi_service_request_success',
             {'cloudi_service_return_async', Name, Pattern,
              ResponseInfo, Response,
              Timeout, TransId, Source},
             ServiceState};
        throw:{cloudi_service_return,
               {ReturnType, Name, Pattern,
                ResponseInfo, Response,
                NextTimeout, TransId, Source}}
            when ReturnType =:= 'cloudi_service_return_async' ->
            if
                ResponseInfo == <<>>, Response == <<>> ->
                    if
                        NextTimeout < ResponseTimeoutImmediateMax ->
                            {'cloudi_service_request_success',
                             undefined, ServiceState};
                        true ->
                            {'cloudi_service_request_success',
                             {ReturnType, Name, Pattern,
                              <<>>, <<>>, NextTimeout, TransId, Source},
                             ServiceState}
                    end;
                true ->
                    {'cloudi_service_request_success',
                     {ReturnType, Name, Pattern,
                      ResponseInfo, Response,
                      NextTimeout, TransId, Source},
                     ServiceState}
            end;
        throw:{cloudi_service_forward,
               {ForwardType, NextName,
                NextRequestInfo, NextRequest,
                NextTimeout, NextPriority, TransId, Source}}
            when ForwardType =:= 'cloudi_service_forward_async_retry' ->
            {'cloudi_service_request_success',
             {ForwardType, Name, Pattern,
              NextName, NextRequestInfo, NextRequest,
              NextTimeout, NextPriority, TransId, Source},
             ServiceState};
        ?STACKTRACE(ErrorType, Error, ErrorStackTrace)
            {'cloudi_service_request_failure',
             ErrorType, Error, ErrorStackTrace, ServiceState}
    end;

handle_module_request_f('send_sync', Name, Pattern, RequestInfo, Request,
                        Timeout, Priority, TransId, Source,
                        ServiceState, Dispatcher, Module,
                        #config_service_options{
                            response_timeout_immediate_max =
                                ResponseTimeoutImmediateMax}) ->
    try Module:cloudi_service_handle_request('send_sync',
                                             Name, Pattern,
                                             RequestInfo, Request,
                                             Timeout, Priority,
                                             TransId, Source,
                                             ServiceState,
                                             Dispatcher) of
        {reply, <<>>, NewServiceState} ->
            if
                Timeout < ResponseTimeoutImmediateMax ->
                    {'cloudi_service_request_success',
                     undefined, NewServiceState};
                true ->
                    {'cloudi_service_request_success',
                     {'cloudi_service_return_sync', Name, Pattern,
                      <<>>, <<>>, Timeout, TransId, Source},
                     NewServiceState}
            end;
        {reply, Response, NewServiceState} ->
            {'cloudi_service_request_success',
             {'cloudi_service_return_sync', Name, Pattern,
              <<>>, Response, Timeout, TransId, Source},
             NewServiceState};
        {reply, <<>>, <<>>, NewServiceState} ->
            if
                Timeout < ResponseTimeoutImmediateMax ->
                    {'cloudi_service_request_success',
                     undefined, NewServiceState};
                true ->
                    {'cloudi_service_request_success',
                     {'cloudi_service_return_sync', Name, Pattern,
                      <<>>, <<>>, Timeout, TransId, Source},
                     NewServiceState}
            end;
        {reply, ResponseInfo, Response, NewServiceState} ->
            {'cloudi_service_request_success',
             {'cloudi_service_return_sync', Name, Pattern,
              ResponseInfo, Response, Timeout, TransId, Source},
             NewServiceState};
        {forward, _, _, _, NextTimeout, NextPriority, NewServiceState}
            when NextPriority < ?PRIORITY_HIGH;
                 NextPriority > ?PRIORITY_LOW;
                 NextTimeout < 0 ->
            try erlang:exit(badarg)
            catch
                ?STACKTRACE(exit, badarg, ErrorStackTrace)
                    {'cloudi_service_request_failure',
                     exit, badarg, ErrorStackTrace, NewServiceState}
            end;
        {forward, NextName, NextRequestInfo, NextRequest,
                  NextTimeout, NextPriority, NewServiceState} ->
            {'cloudi_service_request_success',
             {'cloudi_service_forward_sync_retry', Name, Pattern,
              NextName, NextRequestInfo, NextRequest,
              NextTimeout, NextPriority, TransId, Source},
             NewServiceState};
        {forward, NextName, NextRequestInfo, NextRequest,
                  NewServiceState} ->
            {'cloudi_service_request_success',
             {'cloudi_service_forward_sync_retry', Name, Pattern,
              NextName, NextRequestInfo, NextRequest,
              Timeout, Priority, TransId, Source},
             NewServiceState};
        {noreply, NewServiceState} ->
            {'cloudi_service_request_success', undefined, NewServiceState};
        {stop, Reason, NewServiceState} ->
            {'cloudi_service_request_failure',
             stop, Reason, undefined, NewServiceState}
    catch
        throw:{cloudi_service_return, {<<>>}} ->
            if
                Timeout < ResponseTimeoutImmediateMax ->
                    {'cloudi_service_request_success',
                     undefined, ServiceState};
                true ->
                    {'cloudi_service_request_success',
                     {'cloudi_service_return_sync', Name, Pattern,
                      <<>>, <<>>, Timeout, TransId, Source},
                     ServiceState}
            end;
        throw:{cloudi_service_return, {Response}} ->
            {'cloudi_service_request_success',
             {'cloudi_service_return_sync', Name, Pattern,
              <<>>, Response, Timeout, TransId, Source},
             ServiceState};
        throw:{cloudi_service_return, {<<>>, <<>>}} ->
            if
                Timeout < ResponseTimeoutImmediateMax ->
                    {'cloudi_service_request_success',
                     undefined, ServiceState};
                true ->
                    {'cloudi_service_request_success',
                     {'cloudi_service_return_sync', Name, Pattern,
                      <<>>, <<>>, Timeout, TransId, Source},
                     ServiceState}
            end;
        throw:{cloudi_service_return, {ResponseInfo, Response}} ->
            {'cloudi_service_request_success',
             {'cloudi_service_return_sync', Name, Pattern,
              ResponseInfo, Response,
              Timeout, TransId, Source},
             ServiceState};
        throw:{cloudi_service_return,
               {ReturnType, Name, Pattern,
                ResponseInfo, Response,
                NextTimeout, TransId, Source}}
            when ReturnType =:= 'cloudi_service_return_sync' ->
            if
                ResponseInfo == <<>>, Response == <<>> ->
                    if
                        NextTimeout < ResponseTimeoutImmediateMax ->
                            {'cloudi_service_request_success',
                             undefined, ServiceState};
                        true ->
                            {'cloudi_service_request_success',
                             {ReturnType, Name, Pattern,
                              <<>>, <<>>, NextTimeout, TransId, Source},
                             ServiceState}
                    end;
                true ->
                    {'cloudi_service_request_success',
                     {ReturnType, Name, Pattern,
                      ResponseInfo, Response,
                      NextTimeout, TransId, Source},
                     ServiceState}
            end;
        throw:{cloudi_service_forward,
               {ForwardType, NextName,
                NextRequestInfo, NextRequest,
                NextTimeout, NextPriority, TransId, Source}}
            when ForwardType =:= 'cloudi_service_forward_sync_retry' ->
            {'cloudi_service_request_success',
             {ForwardType, Name, Pattern,
              NextName, NextRequestInfo, NextRequest,
              NextTimeout, NextPriority, TransId, Source},
             ServiceState};
        ?STACKTRACE(ErrorType, Error, ErrorStackTrace)
            {'cloudi_service_request_failure',
             ErrorType, Error, ErrorStackTrace, ServiceState}
    end.

handle_module_info(Request, ServiceState, Dispatcher, Module,
                   #config_service_options{
                       aspects_info_before =
                           AspectsBefore,
                       aspects_info_after =
                           AspectsAfter}) ->
    try aspects_info(AspectsBefore,
                     Request, ServiceState, Dispatcher) of
        {ok, NextServiceState} ->
            try Module:cloudi_service_handle_info(Request,
                                                  NextServiceState,
                                                  Dispatcher) of
                {noreply, NewServiceState} ->
                    try aspects_info(AspectsAfter,
                                     Request, NewServiceState, Dispatcher) of
                        {ok, FinalServiceState} ->
                            {'cloudi_service_info_success',
                             FinalServiceState};
                        {stop, Reason, FinalServiceState} ->
                            {'cloudi_service_info_failure',
                             stop, Reason, undefined,
                             FinalServiceState}
                    catch
                        ?STACKTRACE(ErrorType, Error, ErrorStackTrace)
                            {'cloudi_service_info_failure',
                             ErrorType, Error, ErrorStackTrace,
                             NewServiceState}
                    end;
                {stop, Reason, NewServiceState} ->
                    {'cloudi_service_info_failure',
                     stop, Reason, undefined, NewServiceState}
            catch
                ?STACKTRACE(ErrorType, Error, ErrorStackTrace)
                    {'cloudi_service_info_failure',
                     ErrorType, Error, ErrorStackTrace, ServiceState}
            end;
        {stop, Reason, NextServiceState} ->
            {'cloudi_service_info_failure',
             stop, Reason, undefined, NextServiceState}
    catch
        ?STACKTRACE(ErrorType, Error, ErrorStackTrace)
            {'cloudi_service_info_failure',
             ErrorType, Error, ErrorStackTrace, ServiceState}
    end.

send_async_active_timeout_start(Timeout, TransId, Pid,
                                #state{dispatcher = Dispatcher,
                                       send_timeouts = SendTimeouts,
                                       send_timeout_monitors =
                                           SendTimeoutMonitors,
                                       options = #config_service_options{
                                           request_timeout_immediate_max =
                                               RequestTimeoutImmediateMax}} =
                                    State)
    when is_integer(Timeout), is_binary(TransId), is_pid(Pid),
         Timeout >= RequestTimeoutImmediateMax ->
    NewSendTimeoutMonitors = case maps:find(Pid, SendTimeoutMonitors) of
        {ok, {MonitorRef, TransIdList}} ->
            maps:put(Pid,
                     {MonitorRef,
                      lists:umerge(TransIdList, [TransId])},
                     SendTimeoutMonitors);
        error ->
            MonitorRef = erlang:monitor(process, Pid),
            maps:put(Pid, {MonitorRef, [TransId]}, SendTimeoutMonitors)
    end,
    State#state{
        send_timeouts = maps:put(TransId,
            {active, Pid,
             erlang:send_after(Timeout, Dispatcher,
                               {'cloudi_service_send_async_timeout', TransId})},
            SendTimeouts),
        send_timeout_monitors = NewSendTimeoutMonitors};

send_async_active_timeout_start(Timeout, TransId, _Pid,
                                #state{dispatcher = Dispatcher,
                                       send_timeouts = SendTimeouts} = State)
    when is_integer(Timeout), is_binary(TransId) ->
    State#state{
        send_timeouts = maps:put(TransId,
            {active, undefined,
             erlang:send_after(Timeout, Dispatcher,
                               {'cloudi_service_send_async_timeout', TransId})},
            SendTimeouts)}.

recv_timeout_start(Timeout, Priority, TransId, Size, T,
                   #state{recv_timeouts = RecvTimeouts,
                          queued = Queue,
                          queued_size = QueuedSize,
                          receiver_pid = ReceiverPid} = State)
    when is_integer(Timeout), is_integer(Priority), is_binary(TransId) ->
    State#state{
        recv_timeouts = maps:put(TransId,
            erlang:send_after(Timeout, ReceiverPid,
                {'cloudi_service_recv_timeout', Priority, TransId, Size}),
            RecvTimeouts),
        queued = pqueue4:in({Size, T}, Priority, Queue),
        queued_size = QueuedSize + Size}.

duo_recv_timeout_start(Timeout, Priority, TransId, Size, T,
                       #state_duo{duo_mode_pid = DuoModePid,
                                  recv_timeouts = RecvTimeouts,
                                  queued = Queue,
                                  queued_size = QueuedSize} = State)
    when is_integer(Timeout), is_integer(Priority), is_binary(TransId) ->
    State#state_duo{
        recv_timeouts = maps:put(TransId,
            erlang:send_after(Timeout, DuoModePid,
                {'cloudi_service_recv_timeout', Priority, TransId, Size}),
            RecvTimeouts),
        queued = pqueue4:in({Size, T}, Priority, Queue),
        queued_size = QueuedSize + Size}.

recv_asyncs_pick(Results, Consume, AsyncResponses) ->
    recv_asyncs_pick(Results, [], true, false, Consume, AsyncResponses).

recv_asyncs_pick([], L, Done, FoundOne, _Consume, NewAsyncResponses) ->
    {Done, not FoundOne, lists:reverse(L), NewAsyncResponses};

recv_asyncs_pick([{<<>>, <<>>, TransId} = Entry | Results], L,
                 Done, FoundOne, Consume, AsyncResponses) ->
    case maps:find(TransId, AsyncResponses) of
        error ->
            recv_asyncs_pick(Results,
                             [Entry | L],
                             false, FoundOne, Consume, AsyncResponses);
        {ok, {ResponseInfo, Response}} ->
            NewAsyncResponses = if
                Consume =:= true ->
                    maps:remove(TransId, AsyncResponses);
                Consume =:= false ->
                    AsyncResponses
            end,
            recv_asyncs_pick(Results,
                             [{ResponseInfo, Response, TransId} | L],
                             Done, true, Consume, NewAsyncResponses)
    end;

recv_asyncs_pick([{_, _, _} = Entry | Results], L,
                 Done, _FoundOne, Consume, AsyncResponses) ->
    recv_asyncs_pick(Results, [Entry | L],
                     Done, true, Consume, AsyncResponses).

process_queue(#state{dispatcher = Dispatcher,
                     recv_timeouts = RecvTimeouts,
                     queue_requests = true,
                     queued = Queue,
                     queued_size = QueuedSize,
                     module = Module,
                     service_state = ServiceState,
                     request_pid = RequestPid,
                     options = ConfigOptions} = State) ->
    case pqueue4:out(Queue) of
        {empty, NewQueue} ->
            State#state{queue_requests = false,
                        queued = NewQueue};
        {{value,
          {Size,
           {'cloudi_service_send_async', Name, Pattern,
            RequestInfo, Request,
            _, Priority, TransId, Source}}}, NewQueue} ->
            Timeout = case erlang:cancel_timer(maps:get(TransId,
                                                        RecvTimeouts)) of
                false ->
                    0;
                V ->
                    V
            end,
            NewConfigOptions = check_incoming(true, ConfigOptions),
            State#state{
                recv_timeouts = maps:remove(TransId, RecvTimeouts),
                queued = NewQueue,
                queued_size = QueuedSize - Size,
                request_pid = handle_module_request_loop_pid(RequestPid,
                    {'cloudi_service_request_loop',
                     'send_async', Name, Pattern,
                     RequestInfo, Request,
                     Timeout, Priority, TransId, Source,
                     ServiceState, Dispatcher,
                     Module, NewConfigOptions}, NewConfigOptions, Dispatcher),
                options = NewConfigOptions};
        {{value,
          {Size,
           {'cloudi_service_send_sync', Name, Pattern,
            RequestInfo, Request,
            _, Priority, TransId, Source}}}, NewQueue} ->
            Timeout = case erlang:cancel_timer(maps:get(TransId,
                                                        RecvTimeouts)) of
                false ->
                    0;
                V ->
                    V
            end,
            NewConfigOptions = check_incoming(true, ConfigOptions),
            State#state{
                recv_timeouts = maps:remove(TransId, RecvTimeouts),
                queued = NewQueue,
                queued_size = QueuedSize - Size,
                request_pid = handle_module_request_loop_pid(RequestPid,
                    {'cloudi_service_request_loop',
                     'send_sync', Name, Pattern,
                     RequestInfo, Request,
                     Timeout, Priority, TransId, Source,
                     ServiceState, Dispatcher,
                     Module, NewConfigOptions}, NewConfigOptions, Dispatcher),
                options = NewConfigOptions}
    end.

handle_info_message(Request,
                    #state{queue_requests = true,
                           queued_info = QueueInfo,
                           duo_mode_pid = undefined} = State) ->
    hibernate_check({noreply,
                     State#state{
                         queued_info = queue:in(Request, QueueInfo)}});
handle_info_message(Request,
                    #state{dispatcher = Dispatcher,
                           module = Module,
                           service_state = ServiceState,
                           info_pid = InfoPid,
                           duo_mode_pid = undefined,
                           options = ConfigOptions} = State) ->
    NewConfigOptions = check_incoming(false, ConfigOptions),
    hibernate_check({noreply,
                     State#state{
                         queue_requests = true,
                         info_pid = handle_module_info_loop_pid(InfoPid,
                             {'cloudi_service_info_loop',
                              Request, ServiceState, Dispatcher,
                              Module, NewConfigOptions},
                              NewConfigOptions, Dispatcher),
                         options = NewConfigOptions}}).

process_queue_info(#state{dispatcher = Dispatcher,
                          queue_requests = true,
                          queued_info = QueueInfo,
                          module = Module,
                          service_state = ServiceState,
                          info_pid = InfoPid,
                          options = ConfigOptions} = State) ->
    case queue:out(QueueInfo) of
        {empty, NewQueueInfo} ->
            State#state{queue_requests = false,
                        queued_info = NewQueueInfo};
        {{value, Request}, NewQueueInfo} ->
            NewConfigOptions = check_incoming(false, ConfigOptions),
            State#state{
                queued_info = NewQueueInfo,
                info_pid = handle_module_info_loop_pid(InfoPid,
                    {'cloudi_service_info_loop',
                     Request, ServiceState, Dispatcher,
                     Module, NewConfigOptions}, NewConfigOptions, Dispatcher),
                options = NewConfigOptions}
    end.

process_update(#state{dispatcher = Dispatcher,
                      update_plan = UpdatePlan,
                      service_state = ServiceState} = State) ->
    #config_service_update{update_now = UpdateNow,
                           queue_requests = false} = UpdatePlan,
    NewState = case update(ServiceState, State, UpdatePlan) of
        {ok, NextServiceState, NextState} ->
            UpdateNow ! {'cloudi_service_update_now', Dispatcher, ok},
            NextState#state{service_state = NextServiceState};
        {error, _} = Error ->
            UpdateNow ! {'cloudi_service_update_now', Dispatcher, Error},
            State
    end,
    process_queues(NewState#state{update_plan = undefined}).

process_queues(#state{dispatcher = Dispatcher,
                      update_plan = UpdatePlan} = State)
    when is_record(UpdatePlan, config_service_update) ->
    #config_service_update{update_pending = UpdatePending,
                           update_now = UpdateNow} = UpdatePlan,
    NewUpdatePlan = if
        is_pid(UpdatePending) ->
            UpdatePending ! {'cloudi_service_update', Dispatcher},
            UpdatePlan#config_service_update{update_pending = undefined,
                                             queue_requests = false};
        UpdatePending =:= undefined ->
            UpdatePlan#config_service_update{queue_requests = false}
    end,
    if
        is_pid(UpdateNow) ->
            process_update(State#state{update_plan = NewUpdatePlan});
        UpdateNow =:= undefined ->
            State#state{update_plan = NewUpdatePlan}
    end;
process_queues(State) ->
    % info messages should be processed before service requests
    NewState = process_queue_info(State),
    #state{queue_requests = QueueRequests} = NewState,
    if
        QueueRequests =:= false ->
            process_queue(NewState#state{queue_requests = true});
        true ->
            NewState
    end.

-compile({inline, [{hibernate_check, 1}]}).

hibernate_check({reply, _,
                 #state{options = #config_service_options{
                            hibernate = false}}} = NoHibernate) ->
    NoHibernate;

hibernate_check({noreply,
                 #state{options = #config_service_options{
                            hibernate = false}}} = NoHibernate) ->
    NoHibernate;

hibernate_check({stop, _, _} = NoHibernate) ->
    NoHibernate;

hibernate_check({reply, Reply,
                 #state{options = #config_service_options{
                            hibernate = true}} = State}) ->
    {reply, Reply, State, hibernate};

hibernate_check({noreply,
                 #state{options = #config_service_options{
                            hibernate = true}} = State}) ->
    {noreply, State, hibernate};

hibernate_check({reply, Reply,
                 #state{options = #config_service_options{
                            hibernate = Hibernate}} = State} = NoHibernate)
    when is_tuple(Hibernate) ->
    case cloudi_core_i_rate_based_configuration:
         hibernate_check(Hibernate) of
        false ->
            NoHibernate;
        true ->
            {reply, Reply, State, hibernate}
    end;

hibernate_check({noreply,
                 #state{options = #config_service_options{
                            hibernate = Hibernate}} = State} = NoHibernate)
    when is_tuple(Hibernate) ->
    case cloudi_core_i_rate_based_configuration:
         hibernate_check(Hibernate) of
        false ->
            NoHibernate;
        true ->
            {noreply, State, hibernate}
    end.

handle_module_request_loop_pid(OldRequestPid, ModuleRequest,
                               #config_service_options{
                                   request_pid_uses =
                                       RequestPidUses,
                                   request_pid_options =
                                       RequestPidOptions,
                                   hibernate =
                                       Hibernate}, ResultPid) ->
    if
        OldRequestPid =:= undefined ->
            case cloudi_core_i_rate_based_configuration:
                 hibernate_check(Hibernate) of
                false ->
                    spawn_opt_erlang(fun() ->
                        handle_module_request_loop_normal(RequestPidUses,
                                                          ModuleRequest,
                                                          ResultPid)
                    end, RequestPidOptions);
                true ->
                    spawn_opt_erlang(fun() ->
                        handle_module_request_loop_hibernate(RequestPidUses,
                                                             ModuleRequest,
                                                             ResultPid)
                    end, RequestPidOptions)
            end;
        is_pid(OldRequestPid) ->
            OldRequestPid ! ModuleRequest,
            OldRequestPid
    end.

handle_module_request_loop_normal(Uses, ResultPid) ->
    receive
        'cloudi_service_request_loop_exit' ->
            ok;
        {'cloudi_hibernate', false} ->
            handle_module_request_loop_normal(Uses, ResultPid);
        {'cloudi_hibernate', true} ->
            erlang:hibernate(?MODULE, handle_module_request_loop_hibernate,
                             [Uses, ResultPid]);
        {'cloudi_service_request_loop',
         _Type, _Name, _Pattern,
         _RequestInfo, _Request,
         _Timeout, _Priority, _TransId, _Source,
         _ServiceState, _Dispatcher,
         _Module, _ConfigOptions} = ModuleRequest ->
            handle_module_request_loop_normal(Uses,
                                              ModuleRequest,
                                              ResultPid)
    end.

handle_module_request_loop_hibernate(Uses, ResultPid) ->
    receive
        'cloudi_service_request_loop_exit' ->
            ok;
        {'cloudi_hibernate', false} ->
            handle_module_request_loop_normal(Uses, ResultPid);
        {'cloudi_hibernate', true} ->
            erlang:hibernate(?MODULE, handle_module_request_loop_hibernate,
                             [Uses, ResultPid]);
        {'cloudi_service_request_loop',
         _Type, _Name, _Pattern,
         _RequestInfo, _Request,
         _Timeout, _Priority, _TransId, _Source,
         _ServiceState, _Dispatcher,
         _Module, _ConfigOptions} = ModuleRequest ->
            handle_module_request_loop_hibernate(Uses,
                                                 ModuleRequest,
                                                 ResultPid)
    end.

handle_module_request_loop_normal(Uses,
                                  {'cloudi_service_request_loop',
                                   Type, Name, Pattern,
                                   RequestInfo, Request,
                                   Timeout, Priority, TransId, Source,
                                   ServiceState, Dispatcher,
                                   Module, ConfigOptions},
                                  ResultPid) ->
    Result = handle_module_request(Type, Name, Pattern,
                                   RequestInfo, Request,
                                   Timeout, Priority, TransId, Source,
                                   ServiceState, Dispatcher,
                                   Module, ConfigOptions),
    if
        Uses == 1 ->
            erlang:exit(Result);
        is_integer(Uses) ->
            ResultPid ! Result,
            handle_module_request_loop_normal(Uses - 1, ResultPid);
        Uses =:= infinity ->
            ResultPid ! Result,
            handle_module_request_loop_normal(Uses, ResultPid)
    end.

handle_module_request_loop_hibernate(Uses,
                                     {'cloudi_service_request_loop',
                                      Type, Name, Pattern,
                                      RequestInfo, Request,
                                      Timeout, Priority, TransId, Source,
                                      ServiceState, Dispatcher,
                                      Module, ConfigOptions},
                                     ResultPid) ->
    Result = handle_module_request(Type, Name, Pattern,
                                   RequestInfo, Request,
                                   Timeout, Priority, TransId, Source,
                                   ServiceState, Dispatcher,
                                   Module, ConfigOptions),
    if
        Uses == 1 ->
            erlang:exit(Result);
        is_integer(Uses) ->
            ResultPid ! Result,
            erlang:hibernate(?MODULE, handle_module_request_loop_hibernate,
                             [Uses - 1, ResultPid]);
        Uses =:= infinity ->
            ResultPid ! Result,
            erlang:hibernate(?MODULE, handle_module_request_loop_hibernate,
                             [Uses, ResultPid])
    end.

handle_module_info_loop_pid(OldInfoPid, ModuleInfo,
                            #config_service_options{
                                info_pid_uses =
                                    InfoPidUses,
                                info_pid_options =
                                    InfoPidOptions,
                                hibernate =
                                    Hibernate}, ResultPid) ->
    if
        OldInfoPid =:= undefined ->
            case cloudi_core_i_rate_based_configuration:
                 hibernate_check(Hibernate) of
                false ->
                    spawn_opt_erlang(fun() ->
                        handle_module_info_loop_normal(InfoPidUses,
                                                       ModuleInfo,
                                                       ResultPid)
                    end, InfoPidOptions);
                true ->
                    spawn_opt_erlang(fun() ->
                        handle_module_info_loop_hibernate(InfoPidUses,
                                                          ModuleInfo,
                                                          ResultPid)
                    end, InfoPidOptions)
            end;
        is_pid(OldInfoPid) ->
            OldInfoPid ! ModuleInfo,
            OldInfoPid
    end.

handle_module_info_loop_normal(Uses, ResultPid) ->
    receive
        'cloudi_service_info_loop_exit' ->
            ok;
        {'cloudi_hibernate', false} ->
            handle_module_info_loop_normal(Uses, ResultPid);
        {'cloudi_hibernate', true} ->
            erlang:hibernate(?MODULE, handle_module_info_loop_hibernate,
                             [Uses, ResultPid]);
        {'cloudi_service_info_loop',
         _Request, _ServiceState, _Dispatcher,
         _Module, _ConfigOptions} = ModuleInfo ->
            handle_module_info_loop_normal(Uses,
                                           ModuleInfo,
                                           ResultPid)
    end.

handle_module_info_loop_hibernate(Uses, ResultPid) ->
    receive
        'cloudi_service_info_loop_exit' ->
            ok;
        {'cloudi_hibernate', false} ->
            handle_module_info_loop_normal(Uses, ResultPid);
        {'cloudi_hibernate', true} ->
            erlang:hibernate(?MODULE, handle_module_info_loop_hibernate,
                             [Uses, ResultPid]);
        {'cloudi_service_info_loop',
         _Request, _ServiceState, _Dispatcher,
         _Module, _ConfigOptions} = ModuleInfo ->
            handle_module_info_loop_hibernate(Uses,
                                              ModuleInfo,
                                              ResultPid)
    end.

handle_module_info_loop_normal(Uses,
                               {'cloudi_service_info_loop',
                                Request, ServiceState, Dispatcher,
                                Module, ConfigOptions},
                               ResultPid) ->
    Result = handle_module_info(Request, ServiceState, Dispatcher,
                                Module, ConfigOptions),
    if
        Uses == 1 ->
            erlang:exit(Result);
        is_integer(Uses) ->
            ResultPid ! Result,
            handle_module_info_loop_normal(Uses - 1, ResultPid);
        Uses =:= infinity ->
            ResultPid ! Result,
            handle_module_info_loop_normal(Uses, ResultPid)
    end.

handle_module_info_loop_hibernate(Uses,
                                  {'cloudi_service_info_loop',
                                   Request, ServiceState, Dispatcher,
                                   Module, ConfigOptions},
                                  ResultPid) ->
    Result = handle_module_info(Request, ServiceState, Dispatcher,
                                Module, ConfigOptions),
    if
        Uses == 1 ->
            erlang:exit(Result);
        is_integer(Uses) ->
            ResultPid ! Result,
            erlang:hibernate(?MODULE, handle_module_info_loop_hibernate,
                             [Uses - 1, ResultPid]);
        Uses =:= infinity ->
            ResultPid ! Result,
            erlang:hibernate(?MODULE, handle_module_info_loop_hibernate,
                             [Uses, ResultPid])
    end.

% duo_mode specific logic

format_status_duo_mode(undefined, _) ->
    undefined;
format_status_duo_mode(DuoModePid, Timeout)
    when is_pid(DuoModePid) ->
    case catch sys:get_status(DuoModePid, Timeout) of
        {status, _, _, _} = Status ->
            Status;
        _ ->
            timeout
    end.

duo_mode_loop_init(#state_duo{duo_mode_pid = DuoModePid,
                              module = Module,
                              dispatcher = Dispatcher} = State) ->
    receive
        {'cloudi_service_init_execute', Args, Timeout,
         DispatcherProcessDictionary,
         #state{prefix = Prefix,
                options = #config_service_options{
                    init_pid_options = PidOptions}} = DispatcherState} ->
            ok = initialize_wait(Timeout),
            {ok, DispatcherProxy} = cloudi_core_i_services_internal_init:
                                    start_link(Timeout, PidOptions,
                                               DispatcherProcessDictionary,
                                               DispatcherState),
            Result = try Module:cloudi_service_init(Args, Prefix, Timeout,
                                                    DispatcherProxy)
            catch
                ?STACKTRACE(ErrorType, Error, ErrorStackTrace)
                    ?LOG_ERROR_SYNC("init ~p ~p~n~p",
                                    [ErrorType, Error, ErrorStackTrace]),
                    {stop, {ErrorType, {Error, ErrorStackTrace}}}
            end,
            {NewDispatcherProcessDictionary,
             #state{recv_timeouts = RecvTimeouts,
                    queue_requests = QueueRequests,
                    queued = Queued,
                    queued_info = QueuedInfo,
                    options = ConfigOptions} = NextDispatcherState} =
                cloudi_core_i_services_internal_init:
                stop_link(DispatcherProxy),
            case Result of
                {ok, ServiceState} ->
                    NewConfigOptions = check_init_receive(ConfigOptions),
                    #config_service_options{
                        hibernate = Hibernate,
                        aspects_init_after = Aspects} = NewConfigOptions,
                    % duo_mode_pid takes control of any state that may
                    % have been updated during initialization that is now
                    % only relevant to the duo_mode pid
                    NextState = State#state_duo{
                        recv_timeouts = RecvTimeouts,
                        queue_requests = QueueRequests,
                        queued = Queued,
                        queued_info = QueuedInfo,
                        options = NewConfigOptions},
                    NewDispatcherConfigOptions =
                        duo_mode_dispatcher_options(NewConfigOptions),
                    NewDispatcherState = NextDispatcherState#state{
                        recv_timeouts = undefined,
                        queue_requests = undefined,
                        queued = undefined,
                        queued_info = undefined,
                        options = NewDispatcherConfigOptions},
                    case aspects_init(Aspects, Args, Prefix, Timeout,
                                      ServiceState, Dispatcher) of
                        {ok, NewServiceState} ->
                            erlang:process_flag(trap_exit, true),
                            Dispatcher ! {'cloudi_service_init_state',
                                          NewDispatcherProcessDictionary,
                                          NewDispatcherState},
                            ok = cloudi_core_i_services_monitor:
                                 process_init_end(DuoModePid),
                            NewState = NextState#state_duo{
                                           service_state = NewServiceState},
                            FinalState = duo_process_queues(NewState),
                            case cloudi_core_i_rate_based_configuration:
                                 hibernate_check(Hibernate) of
                                false ->
                                    duo_mode_loop(FinalState);
                                true ->
                                    proc_lib:hibernate(?MODULE,
                                                       duo_mode_loop,
                                                       [FinalState])
                            end;
                        {stop, Reason, NewServiceState} ->
                            NewState = NextState#state_duo{
                                           service_state = NewServiceState},
                            duo_mode_loop_terminate(Reason, NewState)
                    end;
                {stop, Reason, ServiceState} ->
                    NewState = State#state_duo{service_state = ServiceState},
                    duo_mode_loop_terminate(Reason, NewState);
                {stop, Reason} ->
                    NewState = State#state_duo{service_state = undefined},
                    duo_mode_loop_terminate(Reason, NewState)
            end
    end.

duo_mode_loop(#state_duo{} = State) ->
    receive
        Request ->
            % mimic a gen_server:handle_info/2 for code reuse
            case duo_handle_info(Request, State) of
                {stop, Reason, NewState} ->
                    duo_mode_loop_terminate(Reason, NewState);
                {noreply, #state_duo{options = #config_service_options{
                                         hibernate = Hibernate}} = NewState} ->
                    case cloudi_core_i_rate_based_configuration:
                         hibernate_check(Hibernate) of
                        false ->
                            duo_mode_loop(NewState);
                        true ->
                            proc_lib:hibernate(?MODULE,
                                               duo_mode_loop,
                                               [NewState])
                    end
            end
    end.

system_continue(_Dispatcher, _Debug, State) ->
    duo_mode_loop(State).

system_terminate(Reason, _Dispatcher, _Debug, State) ->
    duo_mode_loop_terminate(Reason, State).

system_code_change(State, _Module, _OldVsn, _Extra) ->
    {ok, State}.

-ifdef(VERBOSE_STATE).
duo_mode_format_state(State) ->
    State.
-else.
duo_mode_format_state(#state_duo{recv_timeouts = RecvTimeouts,
                                 queued = Queue,
                                 queued_info = QueueInfo,
                                 options = ConfigOptions} = State) ->
    State#state_duo{recv_timeouts = maps:to_list(RecvTimeouts),
                    queued = pqueue4:to_plist(Queue),
                    queued_info = queue:to_list(QueueInfo),
                    options = cloudi_core_i_configuration:
                              services_format_options_internal(ConfigOptions)}.
-endif.

duo_mode_loop_terminate(Reason,
                        #state_duo{duo_mode_pid = DuoModePid,
                                   module = Module,
                                   service_state = ServiceState,
                                   timeout_term = TimeoutTerm,
                                   options = #config_service_options{
                                       aspects_terminate_before = Aspects}}) ->
    _ = cloudi_core_i_services_monitor:
        process_terminate_begin(DuoModePid, Reason),
    {ok, NewServiceState} = aspects_terminate(Aspects, Reason, TimeoutTerm,
                                              ServiceState),
    _ = Module:cloudi_service_terminate(Reason, TimeoutTerm, NewServiceState),
    erlang:process_flag(trap_exit, false),
    erlang:exit(DuoModePid, Reason).

duo_mode_dispatcher_options(ConfigOptions) ->
    ConfigOptions#config_service_options{
        rate_request_max = undefined,
        count_process_dynamic = false,
        hibernate = false}.

duo_handle_info({'cloudi_service_return_async',
                 _, _, _, _, _, _, Source} = T,
                #state_duo{duo_mode_pid = DuoModePid,
                           dispatcher = Dispatcher} = State) ->
    true = Source =:= DuoModePid,
    Dispatcher ! T,
    {noreply, State};

duo_handle_info({'cloudi_service_return_sync',
                 _, _, _, _, _, _, Source} = T,
                #state_duo{duo_mode_pid = DuoModePid,
                           dispatcher = Dispatcher} = State) ->
    true = Source =:= DuoModePid,
    Dispatcher ! T,
    {noreply, State};

duo_handle_info({'cloudi_service_request_success', RequestResponse,
                 NewServiceState},
                #state_duo{dispatcher = Dispatcher} = State) ->
    case RequestResponse of
        undefined ->
            ok;
        {'cloudi_service_return_async', _, _, _, _, _, _, Source} = T ->
            Source ! T;
        {'cloudi_service_return_sync', _, _, _, _, _, _, Source} = T ->
            Source ! T;
        {'cloudi_service_forward_async_retry', _, _, _, _, _, _, _, _, _} = T ->
            Dispatcher ! T;
        {'cloudi_service_forward_sync_retry', _, _, _, _, _, _, _, _, _} = T ->
            Dispatcher ! T
    end,
    NewState = State#state_duo{service_state = NewServiceState},
    {noreply, duo_process_queues(NewState)};

duo_handle_info({'cloudi_service_request_failure',
                 Type, Error, Stack, NewServiceState}, State) ->
    Reason = if
        Type =:= stop ->
            true = Stack =:= undefined,
            case Error of
                shutdown ->
                    ?LOG_WARN("duo_mode request stop shutdown", []);
                {shutdown, ShutdownReason} ->
                    ?LOG_WARN("duo_mode request stop shutdown (~p)",
                              [ShutdownReason]);
                _ ->
                    ?LOG_ERROR("duo_mode request stop ~p", [Error])
            end,
            Error;
        true ->
            ?LOG_ERROR("duo_mode request ~p ~p~n~p", [Type, Error, Stack]),
            {Type, {Error, Stack}}
    end,
    {stop, Reason, State#state_duo{service_state = NewServiceState}};

duo_handle_info({'EXIT', RequestPid,
                 {'cloudi_service_request_success', _RequestResponse,
                  _NewServiceState} = Result},
                #state_duo{request_pid = RequestPid} = State) ->
    duo_handle_info(Result, State#state_duo{request_pid = undefined});

duo_handle_info({'EXIT', RequestPid,
                 {'cloudi_service_request_failure',
                  _Type, _Error, _Stack, _NewServiceState} = Result},
                #state_duo{request_pid = RequestPid} = State) ->
    duo_handle_info(Result, State#state_duo{request_pid = undefined});

duo_handle_info({'EXIT', RequestPid, Reason},
                #state_duo{request_pid = RequestPid} = State) ->
    ?LOG_ERROR("~p duo_mode request exited: ~p", [RequestPid, Reason]),
    {stop, Reason, State};

duo_handle_info({'EXIT', _, shutdown}, State) ->
    % CloudI Service shutdown
    {stop, shutdown, State};

duo_handle_info({'EXIT', _, {shutdown, _}}, State) ->
    % CloudI Service shutdown w/reason
    {stop, shutdown, State};

duo_handle_info({'EXIT', _, restart}, State) ->
    % CloudI Service API requested a restart
    {stop, restart, State};

duo_handle_info({'EXIT', Dispatcher, Reason},
                #state_duo{dispatcher = Dispatcher} = State) ->
    ?LOG_ERROR("~p duo_mode dispatcher exited: ~p", [Dispatcher, Reason]),
    {stop, Reason, State};

duo_handle_info({'EXIT', Pid, Reason}, State) ->
    ?LOG_ERROR("~p forced exit: ~p", [Pid, Reason]),
    {stop, Reason, State};

duo_handle_info({'cloudi_service_send_async',
                 Name, Pattern, RequestInfo, Request,
                 Timeout, Priority, TransId, Source},
                #state_duo{duo_mode_pid = DuoModePid,
                           queue_requests = false,
                           module = Module,
                           service_state = ServiceState,
                           dispatcher = Dispatcher,
                           request_pid = RequestPid,
                           options = #config_service_options{
                               rate_request_max = RateRequest,
                               response_timeout_immediate_max =
                                   ResponseTimeoutImmediateMax} = ConfigOptions
                           } = State) ->
    {RateRequestOk, NewRateRequest} = if
        RateRequest =/= undefined ->
            cloudi_core_i_rate_based_configuration:
            rate_request_request(RateRequest);
        true ->
            {true, RateRequest}
    end,
    if
        RateRequestOk =:= true ->
            NewConfigOptions =
                check_incoming(true, ConfigOptions#config_service_options{
                                         rate_request_max = NewRateRequest}),
            {noreply, State#state_duo{
                queue_requests = true,
                request_pid = handle_module_request_loop_pid(RequestPid,
                    {'cloudi_service_request_loop',
                     'send_async', Name, Pattern,
                     RequestInfo, Request,
                     Timeout, Priority, TransId, Source,
                     ServiceState, Dispatcher,
                     Module, NewConfigOptions}, NewConfigOptions, DuoModePid),
                options = NewConfigOptions}};
        RateRequestOk =:= false ->
            if
                Timeout >= ResponseTimeoutImmediateMax ->
                    Source ! {'cloudi_service_return_async',
                              Name, Pattern, <<>>, <<>>,
                              Timeout, TransId, Source};
                true ->
                    ok
            end,
            {noreply, State#state_duo{
                options = ConfigOptions#config_service_options{
                    rate_request_max = NewRateRequest}}}
    end;

duo_handle_info({'cloudi_service_send_sync',
                 Name, Pattern, RequestInfo, Request,
                 Timeout, Priority, TransId, Source},
                #state_duo{duo_mode_pid = DuoModePid,
                           queue_requests = false,
                           module = Module,
                           service_state = ServiceState,
                           dispatcher = Dispatcher,
                           request_pid = RequestPid,
                           options = #config_service_options{
                               rate_request_max = RateRequest,
                               response_timeout_immediate_max =
                                   ResponseTimeoutImmediateMax} = ConfigOptions
                           } = State) ->
    {RateRequestOk, NewRateRequest} = if
        RateRequest =/= undefined ->
            cloudi_core_i_rate_based_configuration:
            rate_request_request(RateRequest);
        true ->
            {true, RateRequest}
    end,
    if
        RateRequestOk =:= true ->
            NewConfigOptions =
                check_incoming(true, ConfigOptions#config_service_options{
                                         rate_request_max = NewRateRequest}),
            {noreply, State#state_duo{
                queue_requests = true,
                request_pid = handle_module_request_loop_pid(RequestPid,
                    {'cloudi_service_request_loop',
                     'send_sync', Name, Pattern,
                     RequestInfo, Request,
                     Timeout, Priority, TransId, Source,
                     ServiceState, Dispatcher,
                     Module, NewConfigOptions}, NewConfigOptions, DuoModePid),
                options = NewConfigOptions}};
        RateRequestOk =:= false ->
            if
                Timeout >= ResponseTimeoutImmediateMax ->
                    Source ! {'cloudi_service_return_sync',
                              Name, Pattern, <<>>, <<>>,
                              Timeout, TransId, Source};
                true ->
                    ok
            end,
            {noreply, State#state_duo{
                options = ConfigOptions#config_service_options{
                    rate_request_max = NewRateRequest}}}
    end;

duo_handle_info({SendType, Name, Pattern, _, _,
                 0, _, TransId, Source},
                #state_duo{queue_requests = true,
                           options = #config_service_options{
                               response_timeout_immediate_max =
                                   ResponseTimeoutImmediateMax}} = State)
    when SendType =:= 'cloudi_service_send_async';
         SendType =:= 'cloudi_service_send_sync' ->
    if
        0 =:= ResponseTimeoutImmediateMax ->
            if
                SendType =:= 'cloudi_service_send_async' ->
                    Source ! {'cloudi_service_return_async',
                              Name, Pattern, <<>>, <<>>,
                              0, TransId, Source};
                SendType =:= 'cloudi_service_send_sync' ->
                    Source ! {'cloudi_service_return_sync',
                              Name, Pattern, <<>>, <<>>,
                              0, TransId, Source}
            end;
        true ->
            ok
    end,
    {noreply, State};

duo_handle_info({SendType, Name, Pattern, _, _,
                 Timeout, Priority, TransId, Source} = T,
                #state_duo{queue_requests = true,
                           queued = Queue,
                           queued_size = QueuedSize,
                           queued_word_size = WordSize,
                           options = #config_service_options{
                               queue_limit = QueueLimit,
                               queue_size = QueueSize,
                               rate_request_max = RateRequest,
                               response_timeout_immediate_max =
                                   ResponseTimeoutImmediateMax} = ConfigOptions
                           } = State)
    when SendType =:= 'cloudi_service_send_async';
         SendType =:= 'cloudi_service_send_sync' ->
    QueueLimitOk = if
        QueueLimit =/= undefined ->
            pqueue4:len(Queue) < QueueLimit;
        true ->
            true
    end,
    {QueueSizeOk, Size} = if
        QueueSize =/= undefined ->
            QueueElementSize = erlang_term:byte_size({0, T}, WordSize),
            {(QueuedSize + QueueElementSize) =< QueueSize, QueueElementSize};
        true ->
            {true, 0}
    end,
    {RateRequestOk, NewRateRequest} = if
        RateRequest =/= undefined ->
            cloudi_core_i_rate_based_configuration:
            rate_request_request(RateRequest);
        true ->
            {true, RateRequest}
    end,
    NewState = State#state_duo{
        options = ConfigOptions#config_service_options{
            rate_request_max = NewRateRequest}},
    if
        QueueLimitOk, QueueSizeOk, RateRequestOk ->
            {noreply,
             duo_recv_timeout_start(Timeout, Priority, TransId,
                                    Size, T, NewState)};
        true ->
            if
                Timeout >= ResponseTimeoutImmediateMax ->
                    if
                        SendType =:= 'cloudi_service_send_async' ->
                            Source ! {'cloudi_service_return_async',
                                      Name, Pattern, <<>>, <<>>,
                                      Timeout, TransId, Source};
                        SendType =:= 'cloudi_service_send_sync' ->
                            Source ! {'cloudi_service_return_sync',
                                      Name, Pattern, <<>>, <<>>,
                                      Timeout, TransId, Source}
                    end;
                true ->
                    ok
            end,
            {noreply, NewState}
    end;

duo_handle_info({'cloudi_service_recv_timeout', Priority, TransId, Size},
                #state_duo{recv_timeouts = RecvTimeouts,
                           queue_requests = QueueRequests,
                           queued = Queue,
                           queued_size = QueuedSize} = State) ->
    {NewQueue, NewQueuedSize} = if
        QueueRequests =:= true ->
            F = fun({_, {_, _, _, _, _, _, _, Id, _}}) -> Id == TransId end,
            {Removed,
             NextQueue} = pqueue4:remove_unique(F, Priority, Queue),
            NextQueuedSize = if
                Removed =:= true ->
                    QueuedSize - Size;
                Removed =:= false ->
                    % false if a timer message was sent while cancelling
                    QueuedSize
            end,
            {NextQueue, NextQueuedSize};
        true ->
            {Queue, QueuedSize}
    end,
    {noreply,
     State#state_duo{recv_timeouts = maps:remove(TransId, RecvTimeouts),
                     queued = NewQueue,
                     queued_size = NewQueuedSize}};

duo_handle_info('cloudi_hibernate_rate',
                #state_duo{dispatcher = Dispatcher,
                           request_pid = RequestPid,
                           options = #config_service_options{
                               hibernate = Hibernate} = ConfigOptions
                           } = State) ->
    {Value, NewHibernate} = cloudi_core_i_rate_based_configuration:
                            hibernate_reinit(Hibernate),
    Dispatcher ! {'cloudi_hibernate', Value},
    if
        is_pid(RequestPid) ->
            RequestPid ! {'cloudi_hibernate', Value};
        true ->
            ok
    end,
    {noreply,
     State#state_duo{options = ConfigOptions#config_service_options{
                         hibernate = NewHibernate}}};

duo_handle_info('cloudi_count_process_dynamic_rate',
                #state_duo{dispatcher = Dispatcher,
                           options = #config_service_options{
                               count_process_dynamic =
                                   CountProcessDynamic} = ConfigOptions
                           } = State) ->
    NewCountProcessDynamic = cloudi_core_i_rate_based_configuration:
                             count_process_dynamic_reinit(Dispatcher,
                                                          CountProcessDynamic),
    {noreply,
     State#state_duo{options = ConfigOptions#config_service_options{
                         count_process_dynamic = NewCountProcessDynamic}}};

duo_handle_info({'cloudi_count_process_dynamic_update', _} = Update,
                #state_duo{dispatcher = Dispatcher} = State) ->
    Dispatcher ! Update,
    {noreply, State};

duo_handle_info('cloudi_count_process_dynamic_terminate_check',
                #state_duo{duo_mode_pid = DuoModePid,
                           queue_requests = QueueRequests} = State) ->
    % count_process_dynamic does not have terminate set within the duo_mode_pid
    % (not yet necessary)
    if
        QueueRequests =:= false ->
            {stop, {shutdown, cloudi_count_process_dynamic_terminate}, State};
        QueueRequests =:= true ->
            erlang:send_after(?COUNT_PROCESS_DYNAMIC_INTERVAL, DuoModePid,
                              'cloudi_count_process_dynamic_terminate_check'),
            {noreply, State}
    end;

duo_handle_info('cloudi_count_process_dynamic_terminate_now', State) ->
    {stop, {shutdown, cloudi_count_process_dynamic_terminate}, State};

duo_handle_info('cloudi_rate_request_max_rate',
                #state_duo{options = #config_service_options{
                               rate_request_max = RateRequest} = ConfigOptions
                           } = State) ->
    NewRateRequest = cloudi_core_i_rate_based_configuration:
                     rate_request_reinit(RateRequest),
    {noreply,
     State#state_duo{options = ConfigOptions#config_service_options{
                         rate_request_max = NewRateRequest}}};

duo_handle_info({'cloudi_service_update', UpdatePending, UpdatePlan},
                #state_duo{duo_mode_pid = DuoModePid,
                           update_plan = undefined,
                           queue_requests = QueueRequests} = State) ->
    #config_service_update{sync = Sync} = UpdatePlan,
    NewUpdatePlan = if
        Sync =:= true, QueueRequests =:= true ->
            UpdatePlan#config_service_update{update_pending = UpdatePending,
                                             queue_requests = QueueRequests};
        true ->
            UpdatePending ! {'cloudi_service_update', DuoModePid},
            UpdatePlan#config_service_update{queue_requests = QueueRequests}
    end,
    {noreply, State#state_duo{update_plan = NewUpdatePlan,
                              queue_requests = true}};

duo_handle_info({'cloudi_service_update_now', UpdateNow, UpdateStart},
                #state_duo{update_plan = UpdatePlan} = State) ->
    #config_service_update{queue_requests = QueueRequests} = UpdatePlan,
    NewUpdatePlan = UpdatePlan#config_service_update{
                        update_now = UpdateNow,
                        update_start = UpdateStart},
    NewState = State#state_duo{update_plan = NewUpdatePlan},
    if
        QueueRequests =:= true ->
            {noreply, NewState};
        QueueRequests =:= false ->
            {noreply, duo_process_update(NewState)}
    end;

duo_handle_info({system, From, Msg},
                #state_duo{dispatcher = Dispatcher} = State) ->
    case Msg of
        get_state ->
            sys:handle_system_msg(get_state, From, Dispatcher, ?MODULE, [],
                                  State);
        {replace_state, StateFun} ->
            NewState = try StateFun(State) catch _:_ -> State end,
            sys:handle_system_msg(replace_state, From, Dispatcher, ?MODULE, [],
                                  NewState);
        _ ->
            sys:handle_system_msg(Msg, From, Dispatcher, ?MODULE, [],
                                  State)
    end;

duo_handle_info({ReplyRef, _}, State) when is_reference(ReplyRef) ->
    % gen_server:call/3 had a timeout exception that was caught but the
    % reply arrived later and must be discarded
    {noreply, State};

duo_handle_info(Request,
                #state_duo{queue_requests = true,
                           queued_info = QueueInfo} = State) ->
    {noreply, State#state_duo{queued_info = queue:in(Request, QueueInfo)}};

duo_handle_info(Request,
                #state_duo{module = Module,
                           service_state = ServiceState,
                           dispatcher = Dispatcher,
                           options = ConfigOptions} = State) ->
    NewConfigOptions = check_incoming(false, ConfigOptions),
    case handle_module_info(Request, ServiceState, Dispatcher,
                            Module, NewConfigOptions) of
        {'cloudi_service_info_success', NewServiceState} ->
            {noreply,
             State#state_duo{service_state = NewServiceState,
                             options = NewConfigOptions}};
        {'cloudi_service_info_failure',
         stop, Reason, undefined, NewServiceState} ->
            ?LOG_ERROR("duo_mode info stop ~p", [Reason]),
            {stop, Reason,
             State#state_duo{service_state = NewServiceState,
                             options = NewConfigOptions}};
        {'cloudi_service_info_failure',
         Type, Error, Stack, NewServiceState} ->
            ?LOG_ERROR("duo_mode info ~p ~p~n~p", [Type, Error, Stack]),
            {stop, {Type, {Error, Stack}},
             State#state_duo{service_state = NewServiceState,
                             options = NewConfigOptions}}
    end.

duo_process_queue_info(#state_duo{queue_requests = true,
                                  queued_info = QueueInfo,
                                  module = Module,
                                  service_state = ServiceState,
                                  dispatcher = Dispatcher,
                                  options = ConfigOptions} = State) ->
    case queue:out(QueueInfo) of
        {empty, NewQueueInfo} ->
            State#state_duo{queue_requests = false,
                            queued_info = NewQueueInfo};
        {{value, Request}, NewQueueInfo} ->
            NewConfigOptions = check_incoming(false, ConfigOptions),
            case handle_module_info(Request, ServiceState, Dispatcher,
                                    Module, NewConfigOptions) of
                {'cloudi_service_info_success', NewServiceState} ->
                    duo_process_queue_info(
                        State#state_duo{queued_info = NewQueueInfo,
                                        service_state = NewServiceState,
                                        options = NewConfigOptions});
                {'cloudi_service_info_failure',
                 stop, Reason, undefined, NewServiceState} ->
                    ?LOG_ERROR("duo_mode info stop ~p", [Reason]),
                    {stop, Reason,
                     State#state_duo{service_state = NewServiceState,
                                     queued_info = NewQueueInfo,
                                     options = NewConfigOptions}};
                {'cloudi_service_info_failure',
                 Type, Error, Stack, NewServiceState} ->
                    ?LOG_ERROR("duo_mode info ~p ~p~n~p", [Type, Error, Stack]),
                    {stop, {Type, {Error, Stack}},
                     State#state_duo{service_state = NewServiceState,
                                     queued_info = NewQueueInfo,
                                     options = NewConfigOptions}}
            end
    end.

duo_process_queue(#state_duo{duo_mode_pid = DuoModePid,
                             recv_timeouts = RecvTimeouts,
                             queue_requests = true,
                             queued = Queue,
                             queued_size = QueuedSize,
                             module = Module,
                             service_state = ServiceState,
                             dispatcher = Dispatcher,
                             request_pid = RequestPid,
                             options = ConfigOptions} = State) ->
    case pqueue4:out(Queue) of
        {empty, NewQueue} ->
            State#state_duo{queue_requests = false,
                            queued = NewQueue};
        {{value,
          {Size,
           {'cloudi_service_send_async', Name, Pattern,
            RequestInfo, Request,
            _, Priority, TransId, Source}}}, NewQueue} ->
            Timeout = case erlang:cancel_timer(maps:get(TransId,
                                                        RecvTimeouts)) of
                false ->
                    0;
                V ->
                    V
            end,
            NewConfigOptions = check_incoming(true, ConfigOptions),
            State#state_duo{
                recv_timeouts = maps:remove(TransId, RecvTimeouts),
                queued = NewQueue,
                queued_size = QueuedSize - Size,
                request_pid = handle_module_request_loop_pid(RequestPid,
                    {'cloudi_service_request_loop',
                     'send_async', Name, Pattern,
                     RequestInfo, Request,
                     Timeout, Priority, TransId, Source,
                     ServiceState, Dispatcher,
                     Module, NewConfigOptions}, NewConfigOptions, DuoModePid),
                options = NewConfigOptions};
        {{value,
          {Size,
           {'cloudi_service_send_sync', Name, Pattern,
            RequestInfo, Request,
            _, Priority, TransId, Source}}}, NewQueue} ->
            Timeout = case erlang:cancel_timer(maps:get(TransId,
                                                        RecvTimeouts)) of
                false ->
                    0;
                V ->
                    V
            end,
            NewConfigOptions = check_incoming(true, ConfigOptions),
            State#state_duo{
                recv_timeouts = maps:remove(TransId, RecvTimeouts),
                queued = NewQueue,
                queued_size = QueuedSize - Size,
                request_pid = handle_module_request_loop_pid(RequestPid,
                    {'cloudi_service_request_loop',
                     'send_sync', Name, Pattern,
                     RequestInfo, Request,
                     Timeout, Priority, TransId, Source,
                     ServiceState, Dispatcher,
                     Module, NewConfigOptions}, NewConfigOptions, DuoModePid),
                options = NewConfigOptions}
    end.

duo_process_update(#state_duo{duo_mode_pid = DuoModePid,
                              update_plan = UpdatePlan,
                              service_state = ServiceState} = State) ->
    #config_service_update{update_now = UpdateNow,
                           queue_requests = false} = UpdatePlan,
    NewState = case update(ServiceState, State, UpdatePlan) of
        {ok, NextServiceState, NextState} ->
            UpdateNow ! {'cloudi_service_update_now', DuoModePid, ok},
            NextState#state_duo{service_state = NextServiceState};
        {error, _} = Error ->
            UpdateNow ! {'cloudi_service_update_now', DuoModePid, Error},
            State
    end,
    duo_process_queues(NewState#state_duo{update_plan = undefined}).

duo_process_queues(#state_duo{duo_mode_pid = DuoModePid,
                              update_plan = UpdatePlan} = State)
    when is_record(UpdatePlan, config_service_update) ->
    #config_service_update{update_pending = UpdatePending,
                           update_now = UpdateNow} = UpdatePlan,
    NewUpdatePlan = if
        is_pid(UpdatePending) ->
            UpdatePending ! {'cloudi_service_update', DuoModePid},
            UpdatePlan#config_service_update{update_pending = undefined,
                                             queue_requests = false};
        UpdatePending =:= undefined ->
            UpdatePlan#config_service_update{queue_requests = false}
    end,
    NewState = State#state_duo{update_plan = NewUpdatePlan},
    if
        is_pid(UpdateNow) ->
            duo_process_update(NewState);
        UpdateNow =:= undefined ->
            NewState
    end;
duo_process_queues(State) ->
    % info messages should be processed before service requests
    NewState = duo_process_queue_info(State),
    #state_duo{queue_requests = QueueRequests} = NewState,
    if
        QueueRequests =:= false ->
            duo_process_queue(NewState#state_duo{queue_requests = true});
        true ->
            NewState
    end.

aspects_init([], _, _, _, ServiceState, _) ->
    {ok, ServiceState};
aspects_init([{M, F} | L], Args, Prefix, Timeout, ServiceState, Dispatcher) ->
    case M:F(Args, Prefix, Timeout, ServiceState, Dispatcher) of
        {ok, NewServiceState} ->
            aspects_init(L, Args, Prefix, Timeout, NewServiceState, Dispatcher);
        {stop, _, _} = Stop ->
            Stop
    end;
aspects_init([F | L], Args, Prefix, Timeout, ServiceState, Dispatcher) ->
    case F(Args, Prefix, Timeout, ServiceState, Dispatcher) of
        {ok, NewServiceState} ->
            aspects_init(L, Args, Prefix, Timeout, NewServiceState, Dispatcher);
        {stop, _, _} = Stop ->
            Stop
    end.

aspects_request_before([], _, _, _, _, _, _, _, _, _, ServiceState, _) ->
    {ok, ServiceState};
aspects_request_before([{M, F} | L], Type, Name, Pattern, RequestInfo, Request,
                       Timeout, Priority, TransId, Source,
                       ServiceState, Dispatcher) ->
    case M:F(Type, Name, Pattern, RequestInfo, Request,
             Timeout, Priority, TransId, Source, ServiceState, Dispatcher) of
        {ok, NewServiceState} ->
            aspects_request_before(L, Type, Name, Pattern, RequestInfo, Request,
                                   Timeout, Priority, TransId, Source,
                                   NewServiceState, Dispatcher);
        {stop, _, _} = Stop ->
            Stop
    end;
aspects_request_before([F | L], Type, Name, Pattern, RequestInfo, Request,
                       Timeout, Priority, TransId, Source,
                       ServiceState, Dispatcher) ->
    case F(Type, Name, Pattern, RequestInfo, Request,
           Timeout, Priority, TransId, Source, ServiceState, Dispatcher) of
        {ok, NewServiceState} ->
            aspects_request_before(L, Type, Name, Pattern, RequestInfo, Request,
                                   Timeout, Priority, TransId, Source,
                                   NewServiceState, Dispatcher);
        {stop, _, _} = Stop ->
            Stop
    end.

aspects_request_after([], _, _, _, _, _, _, _, _, _, _, ServiceState, _) ->
    {ok, ServiceState};
aspects_request_after([{M, F} | L], Type, Name, Pattern, RequestInfo, Request,
                      Timeout, Priority, TransId, Source,
                      Result, ServiceState, Dispatcher) ->
    case M:F(Type, Name, Pattern, RequestInfo, Request,
             Timeout, Priority, TransId, Source,
             Result, ServiceState, Dispatcher) of
        {ok, NewServiceState} ->
            aspects_request_after(L, Type, Name, Pattern, RequestInfo, Request,
                                  Timeout, Priority, TransId, Source,
                                  Result, NewServiceState, Dispatcher);
        {stop, _, _} = Stop ->
            Stop
    end;
aspects_request_after([F | L], Type, Name, Pattern, RequestInfo, Request,
                      Timeout, Priority, TransId, Source,
                      Result, ServiceState, Dispatcher) ->
    case F(Type, Name, Pattern, RequestInfo, Request,
           Timeout, Priority, TransId, Source,
           Result, ServiceState, Dispatcher) of
        {ok, NewServiceState} ->
            aspects_request_after(L, Type, Name, Pattern, RequestInfo, Request,
                                  Timeout, Priority, TransId, Source,
                                  Result, NewServiceState, Dispatcher);
        {stop, _, _} = Stop ->
            Stop
    end.

aspects_info([], _, ServiceState, _) ->
    {ok, ServiceState};
aspects_info([{M, F} | L], Request, ServiceState, Dispatcher) ->
    case M:F(Request, ServiceState, Dispatcher) of
        {ok, NewServiceState} ->
            aspects_info(L, Request, NewServiceState, Dispatcher);
        {stop, _, _} = Stop ->
            Stop
    end;
aspects_info([F | L], Request, ServiceState, Dispatcher) ->
    case F(Request, ServiceState, Dispatcher) of
        {ok, NewServiceState} ->
            aspects_info(L, Request, NewServiceState, Dispatcher);
        {stop, _, _} = Stop ->
            Stop
    end.

spawn_opt_proc_lib(F, Options0) ->
    spawn_opt_pid(proc_lib, F, Options0).

spawn_opt_erlang(F, Options0) ->
    spawn_opt_pid(erlang, F, Options0).

spawn_opt_pid(M, F, Options) ->
    M:spawn_opt(fun() ->
        spawn_opt_options_after(Options),
        F()
    end, spawn_opt_options_before(Options)).

update(_, _, #config_service_update{type = Type})
    when Type =/= internal ->
    {error, type};
update(_, _, #config_service_update{update_start = false}) ->
    {error, update_start_failed};
update(ServiceState, State,
       #config_service_update{
           module_state = undefined} = UpdatePlan) ->
    {ok, ServiceState, update_state(State, UpdatePlan)};
update(ServiceState, State,
       #config_service_update{
           module = Module,
           module_state = ModuleState,
           module_version_old = OldModuleVersion} = UpdatePlan) ->
    NewModuleVersion = reltool_util:module_version(Module),
    try ModuleState(OldModuleVersion,
                    NewModuleVersion,
                    ServiceState) of
        {ok, NewServiceState} ->
            {ok, NewServiceState, update_state(State, UpdatePlan)};
        {error, _} = Error ->
            Error;
        Invalid ->
            {error, {result, Invalid}}
    catch
        Type:Error ->
            {error, {Type, Error}}
    end.

update_state(#state{dispatcher = Dispatcher,
                    timeout_async = OldTimeoutAsync,
                    timeout_sync = OldTimeoutSync,
                    request_pid = OldRequestPid,
                    info_pid = OldInfoPid,
                    dest_refresh = OldDestRefresh,
                    cpg_data = OldGroups,
                    dest_deny = OldDestDeny,
                    dest_allow = OldDestAllow,
                    options = OldConfigOptions} = State,
             #config_service_update{
                 dest_refresh = NewDestRefresh,
                 timeout_async = NewTimeoutAsync,
                 timeout_sync = NewTimeoutSync,
                 dest_list_deny = NewDestListDeny,
                 dest_list_allow = NewDestListAllow,
                 options_keys = OptionsKeys,
                 options = NewConfigOptions}) ->
    DestRefresh = if
        NewDestRefresh =:= undefined ->
            OldDestRefresh;
        is_atom(NewDestRefresh) ->
            NewDestRefresh
    end,
    Groups = destination_refresh_groups(DestRefresh, OldGroups),
    TimeoutAsync = if
        NewTimeoutAsync =:= undefined ->
            OldTimeoutAsync;
        is_integer(NewTimeoutAsync) ->
            NewTimeoutAsync
    end,
    TimeoutSync = if
        NewTimeoutSync =:= undefined ->
            OldTimeoutSync;
        is_integer(NewTimeoutSync) ->
            NewTimeoutSync
    end,
    DestDeny = if
        NewDestListDeny =:= invalid ->
            OldDestDeny;
        NewDestListDeny =:= undefined ->
            undefined;
        is_list(NewDestListDeny) ->
            trie:new(NewDestListDeny)
    end,
    DestAllow = if
        NewDestListAllow =:= invalid ->
            OldDestAllow;
        NewDestListAllow =:= undefined ->
            undefined;
        is_list(NewDestListAllow) ->
            trie:new(NewDestListAllow)
    end,
    NewRequestPid = case cloudi_lists:member_any([request_pid_uses,
                                                  request_pid_options],
                                                 OptionsKeys) of
        true when is_pid(OldRequestPid) ->
            OldRequestPid ! 'cloudi_service_request_loop_exit',
            undefined;
        _ ->
            OldRequestPid
    end,
    NewInfoPid = case cloudi_lists:member_any([info_pid_uses,
                                               info_pid_options],
                                              OptionsKeys) of
        true when is_pid(OldInfoPid) ->
            OldInfoPid ! 'cloudi_service_info_loop_exit',
            undefined;
        _ ->
            OldInfoPid
    end,
    case lists:member(monkey_chaos, OptionsKeys) of
        true ->
            #config_service_options{
                monkey_chaos = OldMonkeyChaos} = OldConfigOptions,
            cloudi_core_i_runtime_testing:
            monkey_chaos_destroy(OldMonkeyChaos);
        false ->
            ok
    end,
    ConfigOptions0 = cloudi_core_i_configuration:
                     service_options_copy(OptionsKeys,
                                          OldConfigOptions,
                                          NewConfigOptions),
    ConfigOptions1 = case lists:member(rate_request_max, OptionsKeys) of
        true ->
            #config_service_options{
                rate_request_max = RateRequest} = ConfigOptions0,
            NewRateRequest = if
                RateRequest =/= undefined ->
                    cloudi_core_i_rate_based_configuration:
                    rate_request_init(RateRequest);
                true ->
                    RateRequest
            end,
            ConfigOptions0#config_service_options{
                rate_request_max = NewRateRequest};
        false ->
            ConfigOptions0
    end,
    ConfigOptionsN = case lists:member(hibernate, OptionsKeys) of
        true ->
            #config_service_options{
                hibernate = Hibernate} = ConfigOptions1,
            NewHibernate = if
                not is_boolean(Hibernate) ->
                    cloudi_core_i_rate_based_configuration:
                    hibernate_init(Hibernate);
                true ->
                    Hibernate
            end,
            ConfigOptions1#config_service_options{
                hibernate = NewHibernate};
        false ->
            ConfigOptions1
    end,
    if
        (OldDestRefresh =:= immediate_closest orelse
         OldDestRefresh =:= immediate_furthest orelse
         OldDestRefresh =:= immediate_random orelse
         OldDestRefresh =:= immediate_local orelse
         OldDestRefresh =:= immediate_remote orelse
         OldDestRefresh =:= immediate_newest orelse
         OldDestRefresh =:= immediate_oldest) andalso
        (NewDestRefresh =:= lazy_closest orelse
         NewDestRefresh =:= lazy_furthest orelse
         NewDestRefresh =:= lazy_random orelse
         NewDestRefresh =:= lazy_local orelse
         NewDestRefresh =:= lazy_remote orelse
         NewDestRefresh =:= lazy_newest orelse
         NewDestRefresh =:= lazy_oldest) ->
            #config_service_options{
                dest_refresh_delay = Delay,
                scope = Scope} = ConfigOptionsN,
            destination_refresh(DestRefresh, Dispatcher, Delay, Scope);
        true ->
            ok
    end,
    State#state{timeout_async = TimeoutAsync,
                timeout_sync = TimeoutSync,
                request_pid = NewRequestPid,
                info_pid = NewInfoPid,
                dest_refresh = DestRefresh,
                cpg_data = Groups,
                dest_deny = DestDeny,
                dest_allow = DestAllow,
                options = ConfigOptionsN};
update_state(#state_duo{dispatcher = Dispatcher,
                        request_pid = OldRequestPid,
                        options = OldConfigOptions} = State,
             #config_service_update{
                 options_keys = OptionsKeys,
                 options = NewConfigOptions} = UpdatePlan) ->
    NewRequestPid = case cloudi_lists:member_any([request_pid_uses,
                                                  request_pid_options],
                                                 OptionsKeys) of
        true when is_pid(OldRequestPid) ->
            OldRequestPid ! 'cloudi_service_request_loop_exit',
            undefined;
        _ ->
            OldRequestPid
    end,
    case lists:member(monkey_chaos, OptionsKeys) of
        true ->
            #config_service_options{
                monkey_chaos = OldMonkeyChaos} = OldConfigOptions,
            cloudi_core_i_runtime_testing:
            monkey_chaos_destroy(OldMonkeyChaos);
        false ->
            ok
    end,
    % info_pid_options won't change, due to info_pid_uses == infinity
    % info_pid_uses won't change, due to duo_mode == true
    % (so these changes would require a service restart after the update)
    ConfigOptions0 = cloudi_core_i_configuration:
                     service_options_copy(OptionsKeys --
                                          [info_pid_uses,
                                           info_pid_options],
                                          OldConfigOptions,
                                          NewConfigOptions),
    ConfigOptions1 = case lists:member(rate_request_max, OptionsKeys) of
        true ->
            #config_service_options{
                rate_request_max = RateRequest} = ConfigOptions0,
            NewRateRequest = if
                RateRequest =/= undefined ->
                    cloudi_core_i_rate_based_configuration:
                    rate_request_init(RateRequest);
                true ->
                    RateRequest
            end,
            ConfigOptions0#config_service_options{
                rate_request_max = NewRateRequest};
        false ->
            ConfigOptions0
    end,
    ConfigOptionsN = case lists:member(hibernate, OptionsKeys) of
        true ->
            #config_service_options{
                hibernate = Hibernate} = ConfigOptions1,
            NewHibernate = if
                not is_boolean(Hibernate) ->
                    cloudi_core_i_rate_based_configuration:
                    hibernate_init(Hibernate);
                true ->
                    Hibernate
            end,
            ConfigOptions1#config_service_options{
                hibernate = NewHibernate};
        false ->
            ConfigOptions1
    end,
    Dispatcher ! {'cloudi_service_update_state',
                  UpdatePlan#config_service_update{
                      options_keys = [],
                      options = duo_mode_dispatcher_options(ConfigOptionsN)}},
    State#state_duo{request_pid = NewRequestPid,
                    options = ConfigOptionsN}.

