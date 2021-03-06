%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI Services==
%%% Manage all cloudi_core_i_spawn processes with monitors and their
%%% configuration.  Perform process restarts but do not escalate failures
%%% (only log failures).
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
%%% @version 1.7.5 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_core_i_services_monitor).
-author('mjtruog at protonmail dot com').

-behaviour(gen_server).

%% external interface
-export([start_link/0,
         monitor/13,
         process_init_begin/1,
         process_init_end/1,
         process_terminate_begin/2,
         shutdown/2,
         restart/2,
         update/2,
         search/2,
         status/2,
         pids/2,
         increase/5,
         decrease/5]).

%% gen_server callbacks
-export([init/1,
         handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("cloudi_logger.hrl").
-include("cloudi_core_i_constants.hrl").
-include("cloudi_core_i_configuration.hrl").

-record(service,
    {
        service_m :: cloudi_core_i_spawn,
        service_f :: start_internal | start_external,
        service_a :: list(),
        process_index :: non_neg_integer(),
        count_process :: pos_integer(),
        count_thread :: pos_integer(),
        scope :: atom(),
        % pids is only accurate (in this record) on the pid lookup (find2)
        % due to the overwrite of #service{} for the key1 ServiceId value
        pids :: list(pid()),
        monitor :: undefined | reference(),
        time_start
            :: cloudi_timestamp:native_monotonic(),
        time_restart
            :: undefined | cloudi_timestamp:native_monotonic(),
        time_terminate = undefined
            :: undefined | cloudi_timestamp:native_monotonic(),
        restart_count_total :: non_neg_integer(),
        restart_count = 0 :: non_neg_integer(),
        restart_times = [] :: list(cloudi_timestamp:seconds_monotonic()),
        timeout_term :: cloudi_service_api:timeout_terminate_milliseconds(),
        restart_delay :: tuple() | false,
        % from the supervisor behavior documentation:
        % If more than MaxR restarts occur within MaxT seconds,
        % the supervisor terminates all child processes...
        max_r :: non_neg_integer(),
        max_t :: non_neg_integer()
    }).

-record(pids_change,
    {
        count_process :: pos_integer(),
        count_increase = 0 :: non_neg_integer(),
        count_decrease = 0 :: non_neg_integer(),
        increase = 0 :: non_neg_integer(),
        decrease = 0 :: non_neg_integer(),
        rate = 0.0 :: float()
    }).

-record(state,
    {
        services = key2value:new(maps)
            :: key2value:
               key2value(cloudi_service_api:service_id(),
                                  pid(), #service{}),
        durations_update = cloudi_core_i_status:durations_new()
            :: cloudi_core_i_status:durations(cloudi_service_api:service_id()),
        durations_restart = cloudi_core_i_status:durations_new()
            :: cloudi_core_i_status:durations(cloudi_service_api:service_id()),
        changes = #{}
            :: #{cloudi_service_api:service_id() :=
                 list({increase | decrease, number(), number(), number()})}
    }).

-record(cloudi_service_init_end,
    {
        pid :: pid(),
        time_initialized :: cloudi_timestamp:native_monotonic()
    }).

-record(restart_stage2,
    {
        pid :: pid(),
        time_terminate :: cloudi_timestamp:native_monotonic(),
        service_id :: cloudi_service_api:service_id(),
        service :: #service{}
    }).

-record(restart_stage3,
    {
        pid :: pid(),
        time_terminate :: cloudi_timestamp:native_monotonic(),
        service_id :: cloudi_service_api:service_id(),
        service :: #service{}
    }).

-record(cloudi_service_terminate_begin,
    {
        reason :: any(),
        pid :: pid(),
        time_terminate :: cloudi_timestamp:native_monotonic()
    }).

-record(cloudi_service_terminate_end,
    {
        reason :: any(),
        pid :: pid(),
        service_id :: cloudi_service_api:service_id(),
        service :: #service{}
    }).

-define(CATCH_EXIT(F),
        try F catch exit:{Reason, _} -> {error, Reason} end).

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec monitor(M :: cloudi_core_i_spawn,
              F :: start_internal | start_external,
              A :: list(),
              ProcessIndex :: non_neg_integer(),
              CountProcess :: pos_integer(),
              CountThread :: pos_integer(),
              Scope :: atom(),
              TimeoutTerm :: cloudi_service_api:
                             timeout_terminate_value_milliseconds(),
              RestartDelay :: tuple() | false,
              MaxR :: non_neg_integer(),
              MaxT :: non_neg_integer(),
              ServiceId :: uuid:uuid(),
              Timeout :: infinity | pos_integer()) ->
    {ok, list(pid())} |
    {error, any()}.

monitor(M, F, A, ProcessIndex, CountProcess, CountThread, Scope,
        TimeoutTerm, RestartDelay, MaxR, MaxT, ServiceId, Timeout)
    when is_atom(M), is_atom(F), is_list(A),
         is_integer(ProcessIndex), ProcessIndex >= 0,
         is_integer(CountProcess), CountProcess > 0,
         is_integer(CountThread), CountThread > 0, is_atom(Scope),
         is_integer(TimeoutTerm),
         TimeoutTerm >= ?TIMEOUT_TERMINATE_MIN,
         TimeoutTerm =< ?TIMEOUT_TERMINATE_MAX,
         is_integer(MaxR), MaxR >= 0, is_integer(MaxT), MaxT >= 0,
         is_binary(ServiceId), byte_size(ServiceId) == 16 ->
    ?CATCH_EXIT(gen_server:call(?MODULE,
                                {monitor, M, F, A,
                                 ProcessIndex, CountProcess,
                                 CountThread, Scope,
                                 TimeoutTerm, RestartDelay, MaxR, MaxT,
                                 ServiceId},
                                Timeout)).

-spec process_init_begin(Pids :: list(pid() | nonempty_list(pid()))) ->
    ok.

process_init_begin([]) ->
    ok;
process_init_begin([[_ | _] = PidsService | Pids]) ->
    ok = process_init_begin(PidsService),
    process_init_begin(Pids);
process_init_begin([Pid | Pids])
    when is_pid(Pid) ->
    Pid ! cloudi_service_init_begin,
    process_init_begin(Pids).

-spec process_init_end(Pid :: pid()) ->
    ok.

process_init_end(Pid)
    when is_pid(Pid) ->
    TimeInitialized = cloudi_timestamp:native_monotonic(),
    ?MODULE !  #cloudi_service_init_end{pid = Pid,
                                        time_initialized = TimeInitialized},
    ok.

-spec process_terminate_begin(Pid :: pid(),
                              Reason :: any()) ->
    ok | {error, any()}.

process_terminate_begin(Pid, Reason)
    when is_pid(Pid) ->
    TimeTerminate = cloudi_timestamp:native_monotonic(),
    ?CATCH_EXIT(gen_server:cast(?MODULE,
                                #cloudi_service_terminate_begin{
                                    reason = Reason,
                                    pid = Pid,
                                    time_terminate = TimeTerminate})).

shutdown(ServiceId, Timeout)
    when is_binary(ServiceId), byte_size(ServiceId) == 16 ->
    ?CATCH_EXIT(gen_server:call(?MODULE,
                                {shutdown, ServiceId},
                                Timeout)).

restart(ServiceId, Timeout)
    when is_binary(ServiceId), byte_size(ServiceId) == 16 ->
    ?CATCH_EXIT(gen_server:call(?MODULE,
                                {restart, ServiceId},
                                Timeout)).

update(UpdatePlan, Timeout) ->
    ?CATCH_EXIT(gen_server:call(?MODULE,
                                {update, UpdatePlan},
                                Timeout)).

search([_ | _] = PidList, Timeout) ->
    ?CATCH_EXIT(gen_server:call(?MODULE,
                                {search, PidList},
                                Timeout)).

status([_ | _] = ServiceIdList, Timeout) ->
    ?CATCH_EXIT(gen_server:call(?MODULE,
                                {status, ServiceIdList},
                                Timeout)).

pids(ServiceId, Timeout)
    when is_binary(ServiceId), byte_size(ServiceId) == 16 ->
    ?CATCH_EXIT(gen_server:call(?MODULE,
                                {pids, ServiceId},
                                Timeout)).

increase(Pid, Period, RateCurrent, RateMax, CountProcessMax)
    when is_pid(Pid), is_integer(Period), is_number(RateCurrent),
         is_number(RateMax), is_number(CountProcessMax) ->
    ?CATCH_EXIT(gen_server:cast(?MODULE,
                                {increase,
                                 Pid, Period, RateCurrent,
                                 RateMax, CountProcessMax})).

decrease(Pid, Period, RateCurrent, RateMin, CountProcessMin)
    when is_pid(Pid), is_integer(Period), is_number(RateCurrent),
         is_number(RateMin), is_number(CountProcessMin) ->
    ?CATCH_EXIT(gen_server:cast(?MODULE,
                                {decrease,
                                 Pid, Period, RateCurrent,
                                 RateMin, CountProcessMin})).

%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

init([]) ->
    {ok, #state{}}.

handle_call({monitor, M, F, A, ProcessIndex, CountProcess, CountThread, Scope,
             TimeoutTerm, RestartDelay, MaxR, MaxT, ServiceId}, _,
            #state{services = Services} = State) ->
    TimeStart = cloudi_timestamp:native_monotonic(),
    TimeRestart = undefined,
    Restarts = 0,
    case erlang:apply(M, F, [ProcessIndex, CountProcess,
                             TimeStart, TimeRestart,
                             Restarts | A]) of
        {ok, Pid} when is_pid(Pid) ->
            Pids = [Pid],
            ServicesNew = key2value:store(ServiceId, Pid,
                new_service_process(M, F, A,
                                    ProcessIndex, CountProcess,
                                    CountThread, Scope, Pids,
                                    erlang:monitor(process, Pid),
                                    TimeStart, TimeRestart, Restarts,
                                    TimeoutTerm, RestartDelay,
                                    MaxR, MaxT), Services),
            {reply, {ok, Pids}, State#state{services = ServicesNew}};
        {ok, [Pid | _] = Pids} = Success when is_pid(Pid) ->
            ServicesNew = lists:foldl(fun(P, D) ->
                key2value:store(ServiceId, P,
                    new_service_process(M, F, A,
                                        ProcessIndex, CountProcess,
                                        CountThread, Scope, Pids,
                                        erlang:monitor(process, P),
                                        TimeStart, TimeRestart, Restarts,
                                        TimeoutTerm, RestartDelay,
                                        MaxR, MaxT), D)
            end, Services, Pids),
            {reply, Success, State#state{services = ServicesNew}};
        {error, _} = Error ->
            {reply, Error, State}
    end;

handle_call({shutdown, ServiceId}, _,
            #state{services = Services} = State) ->
    case key2value:find1(ServiceId, Services) of
        {ok, {Pids, #service{} = Service}} ->
            ServicesNew = terminate_service(Pids, undefined, Service,
                                            Services, ServiceId,
                                            undefined, true),
            {reply, {ok, Pids}, State#state{services = ServicesNew}};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call({restart, ServiceId}, _,
            #state{services = Services} = State) ->
    case key2value:find1(ServiceId, Services) of
        {ok, {Pids, _}} ->
            lists:foreach(fun(P) ->
                erlang:exit(P, restart)
            end, Pids),
            {reply, ok, State};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call({update,
             #config_service_update{
                 uuids = ServiceIdList} = UpdatePlan}, _,
            #state{services = Services,
                   durations_update = Durations} = State) ->
    case service_ids_pids(ServiceIdList, Services) of
        {ok, PidList0} ->
            T0 = cloudi_timestamp:native_monotonic(),
            {Reply, StateNew} = case update_start(PidList0, UpdatePlan) of
                {[], PidListN} ->
                    Results0 = update_before(UpdatePlan),
                    ResultsN = update_now(PidListN, Results0, true),
                    {ResultsSuccess,
                     ResultsError} = update_results(ResultsN),
                    UpdateSuccess = (ResultsError == []),
                    ServicesNew = update_after(UpdateSuccess,
                                               PidListN, ResultsSuccess,
                                               UpdatePlan, Services),
                    if
                        UpdateSuccess =:= true ->
                            {ok, State#state{services = ServicesNew}};
                        UpdateSuccess =:= false ->
                            {{error, ResultsError}, State}
                    end;
                {Results0, PidListN} ->
                    ResultsN = update_now(PidListN, Results0, false),
                    {[], ResultsError} = update_results(ResultsN),
                    {{error, ResultsError}, State}
            end,
            T1 = cloudi_timestamp:native_monotonic(),
            DurationsNew = cloudi_core_i_status:
                           durations_store(ServiceIdList, {T0, T1}, Durations),
            {reply, Reply, StateNew#state{durations_update = DurationsNew}};
        {error, Reason} ->
            {reply, {error, [Reason]}, State}
    end;

handle_call({search, PidList}, _,
            #state{services = Services} = State) ->
    ServiceIdList = lists:foldl(fun(Pid, L) ->
        case key2value:find2(Pid, Services) of
            {ok, {[ServiceId], _}} ->
                case lists:member(ServiceId, L) of
                    true ->
                        L;
                    false ->
                        [ServiceId | L]
                end;
            error ->
                L
        end
    end, [], PidList),
    {reply, {ok, lists:reverse(ServiceIdList)}, State};

handle_call({status, ServiceIdList}, _,
            #state{services = Services,
                   durations_update = DurationsUpdate,
                   durations_restart = DurationsRestart} = State) ->
    TimeNow = cloudi_timestamp:native_monotonic(),
    Reply = service_ids_status(ServiceIdList, TimeNow,
                               DurationsUpdate, DurationsRestart,
                               Services),
    {reply, Reply, State};

handle_call({pids, ServiceId}, _,
            #state{services = Services} = State) ->
    case key2value:find1(ServiceId, Services) of
        {ok, {PidList, #service{scope = Scope}}} ->
            {reply, {ok, Scope, PidList}, State};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call(Request, _, State) ->
    {stop, cloudi_string:format("Unknown call \"~w\"", [Request]),
     error, State}.

handle_cast({Direction,
             Pid, Period, RateCurrent,
             RateLimit, CountProcessLimit},
            #state{services = Services,
                   changes = Changes} = State)
    when (Direction =:= increase);
         (Direction =:= decrease) ->
    case key2value:find2(Pid, Services) of
        {ok, {[ServiceId], _}} ->
            Entry = {Direction, RateCurrent, RateLimit, CountProcessLimit},
            ChangeListNew = case maps:find(ServiceId, Changes) of
                {ok, ChangeList} ->
                    [Entry | ChangeList];
                error ->
                    erlang:send_after(Period * 1000, self(),
                                      {changes, ServiceId}),
                    [Entry]
            end,
            {noreply, State#state{changes = maps:put(ServiceId,
                                                     ChangeListNew,
                                                     Changes)}};
        error ->
            % discard old change
            {noreply, State}
    end;

handle_cast(#cloudi_service_terminate_begin{
                reason = Reason,
                pid = Pid,
                time_terminate = TimeTerminate},
            #state{services = Services} = State) ->
    case key2value:find2(Pid, Services) of
        {ok, {[ServiceId], #service{} = Service}} ->
            ok = terminate_end_enforce(TimeTerminate, self(),
                                       Reason, Pid, ServiceId, Service),
            ServicesNew = key2value:store(ServiceId, Pid,
                Service#service{time_terminate = TimeTerminate}, Services),
            {noreply, State#state{services = ServicesNew}};
        error ->
            {noreply, State}
    end;

handle_cast(Request, State) ->
    {stop, cloudi_string:format("Unknown cast \"~w\"", [Request]), State}.

handle_info({changes, ServiceId},
            #state{services = Services,
                   changes = Changes} = State) ->
    ChangesNew = maps:remove(ServiceId, Changes),
    case key2value:find1(ServiceId, Services) of
        {ok, {Pids, #service{count_thread = CountThread}}} ->
            ChangeList = maps:get(ServiceId, Changes),
            CountProcessCurrent = erlang:round(erlang:length(Pids) /
                                               CountThread),
            {I, Rate} = pids_change(ChangeList, CountProcessCurrent),
            ServicesNew = if
                I == 0 ->
                    ?LOG_TRACE("count_process_dynamic(~p):~n "
                               "constant ~p for ~p requests/second",
                               [service_id(ServiceId), CountProcessCurrent,
                                erlang:round(Rate * 10) / 10]),
                    Services;
                I > 0 ->
                    pids_increase(I, Pids, CountProcessCurrent, Rate,
                                  ServiceId, Services);
                I < 0 ->
                    pids_decrease(I, Pids, CountProcessCurrent, Rate,
                                  ServiceId, Services)
            end,
            {noreply, State#state{services = ServicesNew,
                                  changes = ChangesNew}};
        error ->
            {noreply, State#state{changes = ChangesNew}}
    end;

handle_info({'DOWN', _MonitorRef, 'process', Pid, shutdown},
            #state{services = Services} = State) ->
    case key2value:find2(Pid, Services) of
        {ok, {[ServiceId], #service{pids = Pids} = Service}} ->
            ?LOG_INFO_SYNC("Service pid ~p shutdown~n ~p",
                           [Pid, service_id(ServiceId)]),
            ServicesNew = terminate_service(Pids, undefined, Service,
                                            Services, ServiceId, Pid, false),
            {noreply,
             terminated_service(ServiceId,
                                State#state{services = ServicesNew})};
        error ->
            % Service pid has already terminated
            {noreply, State}
    end;

handle_info({'DOWN', _MonitorRef, 'process', Pid,
             {shutdown, cloudi_count_process_dynamic_terminate}},
            #state{services = Services} = State) ->
    case key2value:find2(Pid, Services) of
        {ok, {[ServiceId], #service{}}} ->
            ?LOG_INFO("Service pid ~p terminated (count_process_dynamic)~n ~p",
                      [Pid, service_id(ServiceId)]),
            ServicesNew = key2value:erase(ServiceId, Pid, Services),
            {noreply, State#state{services = ServicesNew}};
        error ->
            % Service pid has already terminated
            {noreply, State}
    end;

handle_info({'DOWN', _MonitorRef, 'process', Pid, {shutdown, Reason}},
            #state{services = Services} = State) ->
    case key2value:find2(Pid, Services) of
        {ok, {[ServiceId], #service{pids = Pids} = Service}} ->
            ?LOG_INFO_SYNC("Service pid ~p shutdown (~p)~n ~p",
                           [Pid, Reason, service_id(ServiceId)]),
            ServicesNew = terminate_service(Pids, Reason, Service,
                                            Services, ServiceId, Pid, false),
            {noreply,
             terminated_service(ServiceId,
                                State#state{services = ServicesNew})};
        error ->
            % Service pid has already terminated
            {noreply, State}
    end;

handle_info({'DOWN', _MonitorRef, 'process', Pid, Info},
            #state{services = Services} = State) ->
    case key2value:find2(Pid, Services) of
        {ok, {[ServiceId], #service{} = Service}} ->
            ?LOG_WARN("Service pid ~p error: ~p~n ~p",
                      [Pid, Info, service_id(ServiceId)]),
            case restart(Service, Services, State, ServiceId, Pid) of
                {true, StateNew} ->
                    {noreply, StateNew};
                {false, StateNew} ->
                    {noreply, terminated_service(ServiceId, StateNew)}
            end;
        error ->
            % Service pid has already terminated
            {noreply, State}
    end;

handle_info(#restart_stage2{pid = OldPid,
                            time_terminate = TimeTerminate,
                            service_id = ServiceId,
                            service = Service},
            #state{services = Services} = State) ->
    case restart_stage2(Service, Services, State,
                        ServiceId, TimeTerminate, OldPid) of
        {true, StateNew} ->
            {noreply, StateNew};
        {false, StateNew} ->
            {noreply, terminated_service(ServiceId, StateNew)}
    end;

handle_info(#restart_stage3{pid = OldPid,
                            time_terminate = TimeTerminate,
                            service_id = ServiceId,
                            service = Service},
            #state{services = Services} = State) ->
    case restart_stage3(Service, Services, State,
                        ServiceId, TimeTerminate, OldPid) of
        {true, StateNew} ->
            {noreply, StateNew};
        {false, StateNew} ->
            {noreply, terminated_service(ServiceId, StateNew)}
    end;

handle_info(#cloudi_service_terminate_end{reason = Reason,
                                          pid = Pid,
                                          service_id = ServiceId,
                                          service = Service}, State) ->
    ok = terminate_end_enforce_now(Reason, Pid, ServiceId, Service),
    {noreply, State};

handle_info(#cloudi_service_init_end{pid = Pid}, State) ->
    ok = cloudi_core_i_configurator:service_process_init_end(Pid),
    {noreply, State};

handle_info({ReplyRef, _}, State) when is_reference(ReplyRef) ->
    % gen_server:call/3 had a timeout exception that was caught but the
    % reply arrived later and must be discarded
    {noreply, State};

handle_info(Request, State) ->
    {stop, cloudi_string:format("Unknown info \"~w\"", [Request]), State}.

terminate(_, _) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

initialize_wait(Pids) ->
    MonitorPids = [{erlang:monitor(process, Pid), Pid} || Pid <- Pids],
    ok = process_init_begin(Pids),
    {initialize_wait_pids(MonitorPids, undefined), MonitorPids}.

initialize_wait_pids([], Time) ->
    if
        Time =:= undefined ->
            cloudi_timestamp:native_monotonic(); % all initializations failed
        is_integer(Time) ->
            Time
    end;
initialize_wait_pids([{MonitorRef, Pid} | MonitorPids], Time) ->
    receive
        #cloudi_service_init_end{pid = Pid,
                                 time_initialized = TimeInitialized} ->
            TimeNew = if
                Time =:= undefined ->
                    TimeInitialized;
                is_integer(Time) ->
                    erlang:max(Time, TimeInitialized)
            end,
            initialize_wait_pids(MonitorPids, TimeNew);
        {'DOWN', MonitorRef, process, Pid, _} = DOWN ->
            self() ! DOWN,
            initialize_wait_pids(MonitorPids, Time)
    end.

restart(#service{time_start = TimeStart,
                 time_restart = TimeRestart,
                 time_terminate = TimeTerminate} = Service, Services,
        #state{durations_update = DurationsUpdate} = State,
        ServiceId, OldPid) ->
    TimeTerminateNew = if
        TimeTerminate =:= undefined ->
            % service initialization did not complete
            if
                TimeRestart =:= undefined ->
                    TimeStart;
                is_integer(TimeRestart) ->
                    TimeRestart
            end;
        is_integer(TimeTerminate) ->
            TimeTerminate
    end,
    DurationsUpdateNew = cloudi_core_i_status:
                         durations_erase(ServiceId, DurationsUpdate),
    restart_stage1(Service#service{time_terminate = undefined}, Services,
                   State#state{durations_update = DurationsUpdateNew},
                   ServiceId, TimeTerminateNew, OldPid).

restart_stage1(#service{pids = Pids} = Service,
               Services, State, ServiceId, TimeTerminate, OldPid) ->
    ServicesNew = terminate_service(Pids, undefined, Service,
                                    Services, ServiceId, OldPid, true),
    restart_stage2(Service#service{pids = [],
                                   monitor = undefined},
                   ServicesNew, State, ServiceId, TimeTerminate, OldPid).

restart_stage2_async(Service, ServiceId, TimeTerminate, OldPid) ->
    self() ! #restart_stage2{pid = OldPid,
                             time_terminate = TimeTerminate,
                             service_id = ServiceId,
                             service = Service},
    ok.

restart_stage3_async(Delay, Service, ServiceId, TimeTerminate, OldPid) ->
    erlang:send_after(Delay, self(),
                      #restart_stage3{pid = OldPid,
                                      time_terminate = TimeTerminate,
                                      service_id = ServiceId,
                                      service = Service}),
    ok.

restart_stage2(#service{restart_count = 0,
                        max_r = 0},
               Services, State, ServiceId, _, OldPid) ->
    % no restarts allowed
    ?LOG_WARN_SYNC("max restarts (MaxR = 0) ~p~n ~p",
                   [OldPid, service_id(ServiceId)]),
    {false, State#state{services = Services}};

restart_stage2(#service{restart_times = RestartTimes,
                        restart_delay = RestartDelay,
                        max_t = MaxT} = Service,
               Services, State, ServiceId, TimeTerminate, OldPid) ->
    case cloudi_core_i_rate_based_configuration:
         restart_delay_value(RestartTimes, MaxT, RestartDelay) of
        false ->
            restart_stage3(Service, Services, State,
                           ServiceId, TimeTerminate, OldPid);
        {RestartCountNew,
         RestartTimesNew,
         0} ->
            restart_stage3(Service#service{restart_count = RestartCountNew,
                                           restart_times = RestartTimesNew},
                           Services, State,
                           ServiceId, TimeTerminate, OldPid);
        {RestartCountNew,
         RestartTimesNew,
         Delay} when Delay > 0 andalso Delay =< ?TIMEOUT_MAX_ERLANG ->
            restart_stage3_async(Delay,
                                 Service#service{
                                     restart_count = RestartCountNew,
                                     restart_times = RestartTimesNew},
                                 ServiceId, TimeTerminate, OldPid),
            {true, State#state{services = Services}}
    end.

restart_stage3(#service{service_m = M,
                        service_f = F,
                        service_a = A,
                        process_index = ProcessIndex,
                        count_process = CountProcess,
                        time_start = TimeStart,
                        restart_count_total = Restarts,
                        restart_count = 0,
                        restart_times = []} = Service,
               Services,
               #state{durations_restart = Durations} = State,
               ServiceId, TimeTerminate, OldPid) ->
    % first restart
    TimeRestart = cloudi_timestamp:native_monotonic(),
    SecondsNow = cloudi_timestamp:convert(TimeRestart, native, second),
    RestartTimes = [SecondsNow],
    RestartsNew = Restarts + 1,
    RestartCount = 1,
    case erlang:apply(M, F, [ProcessIndex, CountProcess,
                             TimeStart, TimeRestart, RestartsNew | A]) of
        {ok, Pid} when is_pid(Pid) ->
            ?LOG_WARN_SYNC("successful restart (R = 1)~n"
                           "                   (~p is now ~p)~n"
                           " ~p", [OldPid, Pid, service_id(ServiceId)]),
            Pids = [Pid],
            {TimeInitialized, [{MonitorRef, Pid}]} = initialize_wait(Pids),
            DurationsNew = cloudi_core_i_status:
                           durations_store([ServiceId],
                                           {TimeTerminate, TimeInitialized},
                                           Durations),
            ServicesNew = key2value:store(ServiceId, Pid,
                Service#service{pids = Pids,
                                monitor = MonitorRef,
                                time_restart = TimeInitialized,
                                restart_count_total = RestartsNew,
                                restart_count = RestartCount,
                                restart_times = RestartTimes}, Services),
            {true, State#state{services = ServicesNew,
                               durations_restart = DurationsNew}};
        {ok, [Pid | _] = Pids} when is_pid(Pid) ->
            ?LOG_WARN_SYNC("successful restart (R = 1)~n"
                           "                   (~p is now one of ~p)~n"
                           " ~p", [OldPid, Pids, service_id(ServiceId)]),
            {TimeInitialized, MonitorPids} = initialize_wait(Pids),
            DurationsNew = cloudi_core_i_status:
                           durations_store([ServiceId],
                                           {TimeTerminate, TimeInitialized},
                                           Durations),
            ServicesNew = lists:foldl(fun({MonitorRef, P}, D) ->
                key2value:store(ServiceId, P,
                    Service#service{pids = Pids,
                                    monitor = MonitorRef,
                                    time_restart = TimeInitialized,
                                    restart_count_total = RestartsNew,
                                    restart_count = RestartCount,
                                    restart_times = RestartTimes}, D)
            end, Services, MonitorPids),
            {true, State#state{services = ServicesNew,
                               durations_restart = DurationsNew}};
        {error, _} = Error ->
            ?LOG_ERROR_SYNC("failed ~p restart~n ~p",
                            [Error, service_id(ServiceId)]),
            restart_stage2_async(Service#service{
                                     time_restart = TimeRestart,
                                     restart_count_total = RestartsNew,
                                     restart_count = RestartCount,
                                     restart_times = RestartTimes},
                                 ServiceId, TimeTerminate, OldPid),
            {true, State#state{services = Services}}
    end;

restart_stage3(#service{restart_count = RestartCount,
                        restart_times = RestartTimes,
                        max_r = MaxR,
                        max_t = MaxT} = Service,
               Services, State, ServiceId, TimeTerminate, OldPid)
    when MaxR == RestartCount ->
    % last restart?
    SecondsNow = cloudi_timestamp:seconds_monotonic(),
    {RestartCountNew,
     RestartTimesNew} = cloudi_timestamp:seconds_filter_monotonic(RestartTimes,
                                                                  SecondsNow,
                                                                  MaxT),
    if
        RestartCountNew < RestartCount ->
            restart_stage3(Service#service{
                               restart_count = RestartCountNew,
                               restart_times = RestartTimesNew},
                           Services, State, ServiceId, TimeTerminate, OldPid);
        true ->
            ?LOG_WARN_SYNC("max restarts (MaxR = ~p, MaxT = ~p seconds) ~p~n"
                           " ~p", [MaxR, MaxT, OldPid, service_id(ServiceId)]),
            {false, State#state{services = Services}}
    end;

restart_stage3(#service{service_m = M,
                        service_f = F,
                        service_a = A,
                        process_index = ProcessIndex,
                        count_process = CountProcess,
                        time_start = TimeStart,
                        restart_count_total = Restarts,
                        restart_count = RestartCount,
                        restart_times = RestartTimes} = Service,
               Services,
               #state{durations_restart = Durations} = State,
               ServiceId, TimeTerminate, OldPid) ->
    % typical restart scenario
    TimeRestart = cloudi_timestamp:native_monotonic(),
    SecondsNow = cloudi_timestamp:convert(TimeRestart, native, second),
    RestartTimesNew = [SecondsNow | RestartTimes],
    RestartsNew = Restarts + 1,
    R = RestartCount + 1,
    T = SecondsNow - lists:min(RestartTimes),
    case erlang:apply(M, F, [ProcessIndex, CountProcess,
                             TimeStart, TimeRestart, RestartsNew | A]) of
        {ok, Pid} when is_pid(Pid) ->
            ?LOG_WARN_SYNC("successful restart "
                           "(R = ~p, T = ~p elapsed seconds)~n"
                           "                   (~p is now ~p)~n"
                           " ~p", [R, T, OldPid, Pid,
                                   service_id(ServiceId)]),
            Pids = [Pid],
            {TimeInitialized, [{MonitorRef, Pid}]} = initialize_wait(Pids),
            DurationsNew = cloudi_core_i_status:
                           durations_store([ServiceId],
                                           {TimeTerminate, TimeInitialized},
                                           Durations),
            ServicesNew = key2value:store(ServiceId, Pid,
                Service#service{pids = Pids,
                                monitor = MonitorRef,
                                time_restart = TimeInitialized,
                                restart_count_total = RestartsNew,
                                restart_count = R,
                                restart_times = RestartTimesNew}, Services),
            {true, State#state{services = ServicesNew,
                               durations_restart = DurationsNew}};
        {ok, [Pid | _] = Pids} when is_pid(Pid) ->
            ?LOG_WARN_SYNC("successful restart "
                           "(R = ~p, T = ~p elapsed seconds)~n"
                           "                   (~p is now one of ~p)~n"
                           " ~p", [R, T, OldPid, Pids,
                                   service_id(ServiceId)]),
            {TimeInitialized, MonitorPids} = initialize_wait(Pids),
            DurationsNew = cloudi_core_i_status:
                           durations_store([ServiceId],
                                           {TimeTerminate, TimeInitialized},
                                           Durations),
            ServicesNew = lists:foldl(fun({MonitorRef, P}, D) ->
                key2value:store(ServiceId, P,
                    Service#service{pids = Pids,
                                    monitor = MonitorRef,
                                    time_restart = TimeInitialized,
                                    restart_count_total = RestartsNew,
                                    restart_count = R,
                                    restart_times = RestartTimesNew}, D)
            end, Services, MonitorPids),
            {true, State#state{services = ServicesNew,
                               durations_restart = DurationsNew}};
        {error, _} = Error ->
            ?LOG_ERROR_SYNC("failed ~p restart~n ~p",
                            [Error, service_id(ServiceId)]),
            restart_stage2_async(Service#service{
                                     time_restart = TimeRestart,
                                     restart_count_total = RestartsNew,
                                     restart_count = R,
                                     restart_times = RestartTimesNew},
                                 ServiceId, TimeTerminate, OldPid),
            {true, State#state{services = Services}}
    end.

pids_change(ChangeList, CountProcessCurrent) ->
    pids_change_loop(ChangeList,
                     #pids_change{count_process = CountProcessCurrent}).

pids_change_loop([],
                 #pids_change{count_process = CountProcess,
                              count_increase = CountIncrease,
                              count_decrease = CountDecrease,
                              increase = Increase,
                              decrease = Decrease,
                              rate = Rate}) ->
    Change = erlang:round(if
        CountIncrease == CountDecrease ->
            CountBoth = CountIncrease + CountDecrease,
            ((Increase / CountIncrease) *
             (CountIncrease / CountBoth) +
             (Decrease / CountDecrease) *
             (CountDecrease / CountBoth)) - CountProcess;
        CountIncrease > CountDecrease ->
            (Increase / CountIncrease) - CountProcess;
        CountIncrease < CountDecrease ->
            (Decrease / CountDecrease) - CountProcess
    end),
    {Change, Rate};
pids_change_loop([{increase, RateCurrent,
                   RateMax, CountProcessMax} | ChangeList],
                 #pids_change{count_process = CountProcess,
                              count_increase = CountIncrease,
                              increase = Increase,
                              rate = Rate} = State)
    when RateCurrent > RateMax ->
    IncreaseNew = Increase + (if
        CountProcessMax =< CountProcess ->
            % if floating point CountProcess was specified in the configuration
            % and the number of schedulers changed, it would be possible to
            % have: CountProcessMax < CountProcess
            CountProcess;
        CountProcessMax > CountProcess ->
            erlang:min(cloudi_math:ceil((CountProcess * RateCurrent) /
                                        RateMax),
                       CountProcessMax)
    end),
    pids_change_loop(ChangeList,
                     State#pids_change{count_increase = (CountIncrease + 1),
                                       increase = IncreaseNew,
                                       rate = (Rate + RateCurrent)});
pids_change_loop([{decrease, RateCurrent,
                   RateMin, CountProcessMin} | ChangeList],
                 #pids_change{count_process = CountProcess,
                              count_decrease = CountDecrease,
                              decrease = Decrease,
                              rate = Rate} = State)
    when RateCurrent < RateMin ->
    DecreaseNew = Decrease + (if
        CountProcessMin >= CountProcess ->
            % if floating point CountProcess was specified in the configuration
            % and the number of schedulers changed, it would be possible to
            % have: CountProcessMin > CountProcess
            CountProcess;
        CountProcessMin < CountProcess ->
            erlang:max(cloudi_math:floor((CountProcess * RateCurrent) /
                                         RateMin),
                       CountProcessMin)
    end),
    pids_change_loop(ChangeList,
                     State#pids_change{count_decrease = (CountDecrease + 1),
                                       decrease = DecreaseNew,
                                       rate = (Rate + RateCurrent)}).

service_instance(Pids, ServiceId, Services) ->
    service_instance(Pids, [], ServiceId, Services).

service_instance([], Results, _, _) ->
    Results;
service_instance([Pid | Pids], Results, ServiceId, Services) ->
    case key2value:find2(Pid, Services) of
        {ok, {[ServiceId], #service{pids = [Pid]} = Service}} ->
            service_instance(Pids,
                             lists:keymerge(#service.process_index,
                                            Results, [Service]),
                             ServiceId, Services);
        {ok, {[ServiceId], #service{pids = ThreadPids} = Service}} ->
            service_instance(Pids -- ThreadPids,
                             lists:keymerge(#service.process_index,
                                            Results, [Service]),
                             ServiceId, Services)
    end.

pids_update(ServiceL, CountProcess, ServiceId, Services) ->
    pids_update(ServiceL, [], CountProcess, ServiceId, Services).

pids_update([], Output, _, _, Services) ->
    {Output, Services};
pids_update([#service{pids = Pids} = Service | ServiceL], Output,
            CountProcess, ServiceId, Services) ->
    ServiceNew = Service#service{count_process = CountProcess},
    ServicesNew = lists:foldl(fun(P, D) ->
        cloudi_core_i_rate_based_configuration:
        count_process_dynamic_update(P, CountProcess),
        key2value:store(ServiceId, P, ServiceNew, D)
    end, Services, Pids),
    pids_update(ServiceL, [ServiceNew | Output],
                CountProcess, ServiceId, ServicesNew).

pids_increase_loop(0, _, _, _, Services) ->
    Services;
pids_increase_loop(Count, ProcessIndex,
                   #service{service_m = M,
                            service_f = F,
                            service_a = A,
                            count_process = CountProcess,
                            count_thread = CountThread,
                            scope = Scope,
                            time_start = TimeStart,
                            time_restart = TimeRestart,
                            restart_count_total = Restarts,
                            timeout_term = TimeoutTerm,
                            restart_delay = RestartDelay,
                            max_r = MaxR,
                            max_t = MaxT} = Service, ServiceId, Services) ->
    ServicesNew = case erlang:apply(M, F, [ProcessIndex, CountProcess,
                                           TimeStart, TimeRestart,
                                           Restarts | A]) of
        {ok, Pid} when is_pid(Pid) ->
            ?LOG_INFO("~p -> ~p (count_process_dynamic)",
                      [service_id(ServiceId), Pid]),
            Pids = [Pid],
            ok = process_init_begin(Pids),
            ServicesNext = key2value:store(ServiceId, Pid,
                new_service_process(M, F, A,
                                    ProcessIndex, CountProcess,
                                    CountThread, Scope, Pids,
                                    erlang:monitor(process, Pid),
                                    TimeStart, TimeRestart, Restarts,
                                    TimeoutTerm, RestartDelay,
                                    MaxR, MaxT), Services),
            ServicesNext;
        {ok, [Pid | _] = Pids} when is_pid(Pid) ->
            ?LOG_INFO("~p -> ~p (count_process_dynamic)",
                      [service_id(ServiceId), Pids]),
            ok = process_init_begin(Pids),
            ServicesNext = lists:foldl(fun(P, D) ->
                key2value:store(ServiceId, P,
                    new_service_process(M, F, A,
                                        ProcessIndex, CountProcess,
                                        CountThread, Scope, Pids,
                                        erlang:monitor(process, P),
                                        TimeStart, TimeRestart, Restarts,
                                        TimeoutTerm, RestartDelay,
                                        MaxR, MaxT), D)
            end, Services, Pids),
            ServicesNext;
        {error, _} = Error ->
            ?LOG_ERROR("failed ~p increase (count_process_dynamic)~n ~p",
                       [Error, service_id(ServiceId)]),
            Services
    end,
    pids_increase_loop(Count - 1, ProcessIndex + 1,
                       Service, ServiceId, ServicesNew).

pids_increase(Count, OldPids, CountProcessCurrent, Rate,
              ServiceId, Services) ->
    ServiceL = service_instance(OldPids, ServiceId, Services),
    ?LOG_INFO("count_process_dynamic(~p):~n "
              "increasing ~p with ~p for ~p requests/second~n~p",
              [service_id(ServiceId), CountProcessCurrent, Count,
               erlang:round(Rate * 10) / 10,
               [P || #service{pids = P} <- ServiceL]]),
    CountProcess = CountProcessCurrent + Count,
    {ServiceLNew, % reversed
     ServicesNew} = pids_update(ServiceL, CountProcess, ServiceId, Services),
    [#service{process_index = ProcessIndex} = Service | _] = ServiceLNew,
    pids_increase_loop(Count, ProcessIndex + 1, Service,
                       ServiceId, ServicesNew).

pids_decrease_loop(0, ServiceL) ->
    ServiceL;
pids_decrease_loop(Count, [#service{pids = Pids} | ServiceL]) ->
    lists:foreach(fun(P) ->
        cloudi_core_i_rate_based_configuration:
        count_process_dynamic_terminate(P)
    end, Pids),
    pids_decrease_loop(Count + 1, ServiceL).

pids_decrease(Count, OldPids, CountProcessCurrent, Rate,
              ServiceId, Services) ->
    ServiceL = service_instance(OldPids, ServiceId, Services),
    ?LOG_INFO("count_process_dynamic(~p):~n "
              "decreasing ~p with ~p for ~p requests/second~n~p",
              [service_id(ServiceId), CountProcessCurrent, Count,
               erlang:round(Rate * 10) / 10,
               [P || #service{pids = P} <- ServiceL]]),
    CountProcess = CountProcessCurrent + Count,
    ServiceLNew = pids_decrease_loop(Count, lists:reverse(ServiceL)),
    {_,
     ServicesNew} = pids_update(ServiceLNew, CountProcess, ServiceId, Services),
    ServicesNew.

terminate_end_enforce(TimeTerminate, Self,
                      Reason, Pid, ServiceId,
                      #service{timeout_term = TimeoutTerm} = Service) ->
    Timeout = if
        TimeTerminate =:= undefined ->
            TimeoutTerm;
        is_integer(TimeTerminate) ->
            TimeoutTerm -
            cloudi_timestamp:convert(cloudi_timestamp:native_monotonic() -
                                     TimeTerminate, native, millisecond)
    end,
    if
        Timeout > 0 ->
            erlang:send_after(Timeout, Self,
                              #cloudi_service_terminate_end{
                                  reason = Reason,
                                  pid = Pid,
                                  service_id = ServiceId,
                                  service = Service}),
            ok;
        true ->
            terminate_end_enforce_now(Reason, Pid, ServiceId, Service)
    end.

terminate_end_enforce_now(Reason, Pid, ServiceId,
                          #service{timeout_term = TimeoutTerm}) ->
    case erlang:is_process_alive(Pid) of
        true ->
            ?LOG_ERROR_SYNC("Service pid ~p brutal_kill (~p)~n"
                            " ~p after ~p ms (MaxT/MaxR)",
                            [Pid, Reason, service_id(ServiceId), TimeoutTerm]),
            erlang:exit(Pid, kill);
        false ->
            ok
    end,
    ok.

terminate_service(Pids, Reason, Service, Services, ServiceId, OldPid, Block) ->
    ShutdownExit = if
        Reason =:= undefined ->
            shutdown;
        true ->
            {shutdown, Reason}
    end,
    ServicesNew = terminate_service_pids(Pids, Services, self(), ShutdownExit,
                                         Service, ServiceId, OldPid),
    if
        Block =:= true ->
            ok = terminate_service_wait(Pids, OldPid);
        Block =:= false ->
            ok
    end,
    ServicesNew.

terminate_service_pids([], Services, _, _, _, _, _) ->
    Services;
terminate_service_pids([OldPid | Pids], Services, Self, ShutdownExit,
                       Service, ServiceId, OldPid) ->
    ServicesNew = key2value:erase(ServiceId, OldPid, Services),
    terminate_service_pids(Pids, ServicesNew, Self, ShutdownExit,
                           Service, ServiceId, OldPid);
terminate_service_pids([Pid | Pids], Services, Self, ShutdownExit,
                       Service, ServiceId, OldPid) ->
    erlang:exit(Pid, ShutdownExit),
    ok = terminate_end_enforce(undefined, Self, ShutdownExit, Pid,
                               ServiceId, Service),
    ServicesNew = key2value:erase(ServiceId, Pid, Services),
    terminate_service_pids(Pids, ServicesNew, Self, ShutdownExit,
                           Service, ServiceId, OldPid).

terminate_service_wait([], _) ->
    ok;
terminate_service_wait([OldPid | Pids], OldPid) ->
    terminate_service_wait(Pids, OldPid);
terminate_service_wait([Pid | Pids], OldPid) ->
    % ensure each service process has executed its termination source code
    % (or has died due to a termination timeout)
    receive
        {'DOWN', _MonitorRef, 'process', Pid, _} ->
            terminate_service_wait(Pids, OldPid);
        #cloudi_service_terminate_end{reason = ShutdownExit,
                                      pid = Pid,
                                      service_id = ServiceId,
                                      service = Service} ->
            ok = terminate_end_enforce_now(ShutdownExit, Pid,
                                           ServiceId, Service),
            receive
                {'DOWN', _MonitorRef, 'process', Pid, _} ->
                    terminate_service_wait(Pids, OldPid)
            end
    end.

terminated_service(ServiceId,
                   #state{durations_restart = Durations} = State) ->
    ok = cloudi_core_i_configurator:service_terminated(ServiceId),
    State#state{durations_restart = cloudi_core_i_status:
                                    durations_erase(ServiceId, Durations)}.

service_ids_pids(ServiceIdList, Services) ->
    service_ids_pids(ServiceIdList, [], Services).

service_ids_pids([], Pids, _) ->
    {ok, Pids};
service_ids_pids([ServiceId | ServiceIdList], Pids, Services) ->
    case service_id_pids(ServiceId, Services) of
        {ok, PidList} ->
            service_ids_pids(ServiceIdList, Pids ++ PidList, Services);
        {error, _} = Error ->
            Error
    end.

service_id_pids(ServiceId, Services) ->
    case key2value:find1(ServiceId, Services) of
        {ok, {Pids, #service{}}} ->
            % all pids must be in process_index order
            PidsOrdered1 = lists:foldl(fun(Pid, PidsOrdered0) ->
                {_, Service} = key2value:fetch2(Pid, Services),
                #service{process_index = ProcessIndex,
                         pids = ProcessPids} = Service,
                lists:umerge(PidsOrdered0, [{ProcessIndex, ProcessPids}])
            end, [], Pids),
            PidsOrderedN = lists:flatmap(fun({_, PidList}) ->
                PidList
            end, PidsOrdered1),
            {ok, PidsOrderedN};
        error ->
            {error, not_found}
    end.

service_ids_status(ServiceIdList, TimeNow,
                   DurationsUpdate, DurationsRestart, Services) ->
    TimeDayStart = TimeNow - ?NATIVE_TIME_IN_DAY,
    TimeWeekStart = TimeNow - ?NATIVE_TIME_IN_WEEK,
    TimeMonthStart = TimeNow - ?NATIVE_TIME_IN_MONTH,
    TimeYearStart = TimeNow - ?NATIVE_TIME_IN_YEAR,
    service_ids_status(ServiceIdList, [], TimeNow,
                       TimeDayStart, TimeWeekStart,
                       TimeMonthStart, TimeYearStart,
                       DurationsUpdate, DurationsRestart, Services).

service_ids_status([], StatusList, _, _, _, _, _, _, _, _) ->
    {ok, lists:reverse(StatusList)};
service_ids_status([ServiceId | ServiceIdList], StatusList, TimeNow,
                   TimeDayStart, TimeWeekStart,
                   TimeMonthStart, TimeYearStart,
                   DurationsUpdate, DurationsRestart, Services) ->
    case service_id_status(ServiceId, TimeNow,
                           TimeDayStart, TimeWeekStart,
                           TimeMonthStart, TimeYearStart,
                           DurationsUpdate, DurationsRestart, Services) of
        {ok, Status} ->
            service_ids_status(ServiceIdList,
                               [{ServiceId, Status} | StatusList], TimeNow,
                               TimeDayStart, TimeWeekStart,
                               TimeMonthStart, TimeYearStart,
                               DurationsUpdate, DurationsRestart,
                               Services);
        {error, _} = Error ->
            Error
    end.

service_id_status(ServiceId, TimeNow,
                  TimeDayStart, TimeWeekStart, TimeMonthStart, TimeYearStart,
                  DurationsUpdate, DurationsRestart, Services) ->
    case key2value:find1(ServiceId, Services) of
        {ok, {_, #service{service_f = StartType,
                          count_process = CountProcess,
                          count_thread = CountThread,
                          time_start = TimeStart,
                          time_restart = TimeRestart,
                          restart_count_total = Restarts}}} ->
            DurationsStateUpdate = cloudi_core_i_status:
                                   durations_state(ServiceId,
                                                   DurationsUpdate),
            DurationsStateRestart = cloudi_core_i_status:
                                    durations_state(ServiceId,
                                                    DurationsRestart),
            TimeRunning = if
                TimeRestart =:= undefined ->
                    TimeStart;
                is_integer(TimeRestart) ->
                    TimeRestart
            end,
            NanoSecondsTotal = cloudi_timestamp:
                               convert(TimeNow - TimeStart,
                                       native, nanosecond),
            NanoSecondsRunning = cloudi_timestamp:
                                 convert(TimeNow - TimeRunning,
                                         native, nanosecond),
            UptimeTotal = cloudi_timestamp:
                          nanoseconds_to_string(NanoSecondsTotal),
            UptimeRunning = cloudi_timestamp:
                            nanoseconds_to_string(NanoSecondsRunning),
            {ApproximateYearUpdate,
             NanoSecondsYearUpdate} = cloudi_core_i_status:
                                      durations_sum(DurationsStateUpdate,
                                                    TimeYearStart),
            {ApproximateYearRestart,
             NanoSecondsYearRestart} = cloudi_core_i_status:
                                       durations_sum(DurationsStateRestart,
                                                     TimeYearStart),
            {ApproximateMonthUpdate,
             NanoSecondsMonthUpdate} = cloudi_core_i_status:
                                       durations_sum(DurationsStateUpdate,
                                                     TimeMonthStart),
            {ApproximateMonthRestart,
             NanoSecondsMonthRestart} = cloudi_core_i_status:
                                        durations_sum(DurationsStateRestart,
                                                      TimeMonthStart),
            {ApproximateWeekUpdate,
             NanoSecondsWeekUpdate} = cloudi_core_i_status:
                                      durations_sum(DurationsStateUpdate,
                                                    TimeWeekStart),
            {ApproximateWeekRestart,
             NanoSecondsWeekRestart} = cloudi_core_i_status:
                                       durations_sum(DurationsStateRestart,
                                                     TimeWeekStart),
            {ApproximateDayUpdate,
             NanoSecondsDayUpdate} = cloudi_core_i_status:
                                     durations_sum(DurationsStateUpdate,
                                                   TimeDayStart),
            {ApproximateDayRestart,
             NanoSecondsDayRestart} = cloudi_core_i_status:
                                      durations_sum(DurationsStateRestart,
                                                    TimeDayStart),
            Status0 = [],
            Status1 = case cloudi_core_i_status:
                           nanoseconds_to_availability_year(
                               NanoSecondsRunning,
                               ApproximateYearUpdate,
                               NanoSecondsYearUpdate) of
                ?AVAILABILITY_ZERO ->
                    Status0;
                AvailabilityYearUpdated ->
                    [{availability_year_updated,
                      AvailabilityYearUpdated} | Status0]
            end,
            Status2 = case cloudi_core_i_status:
                           nanoseconds_to_availability_year(
                               NanoSecondsRunning) of
                ?AVAILABILITY_ZERO ->
                    Status1;
                AvailabilityYearRunning ->
                    [{availability_year_running,
                      AvailabilityYearRunning} | Status1]
            end,
            Status3 = case cloudi_core_i_status:
                           nanoseconds_to_availability_year(
                               NanoSecondsTotal,
                               ApproximateYearRestart,
                               NanoSecondsYearRestart) of
                ?AVAILABILITY_ZERO ->
                    Status2;
                AvailabilityYearTotal ->
                    [{availability_year_total,
                      AvailabilityYearTotal} | Status2]
            end,
            Status4 = case cloudi_core_i_status:
                           nanoseconds_to_availability_month(
                               NanoSecondsRunning,
                               ApproximateMonthUpdate,
                               NanoSecondsMonthUpdate) of
                ?AVAILABILITY_ZERO ->
                    Status3;
                AvailabilityMonthUpdated ->
                    [{availability_month_updated,
                      AvailabilityMonthUpdated} | Status3]
            end,
            Status5 = case cloudi_core_i_status:
                           nanoseconds_to_availability_month(
                               NanoSecondsRunning) of
                ?AVAILABILITY_ZERO ->
                    Status4;
                AvailabilityMonthRunning ->
                    [{availability_month_running,
                      AvailabilityMonthRunning} | Status4]
            end,
            Status6 = case cloudi_core_i_status:
                           nanoseconds_to_availability_month(
                               NanoSecondsTotal,
                               ApproximateMonthRestart,
                               NanoSecondsMonthRestart) of
                ?AVAILABILITY_ZERO ->
                    Status5;
                AvailabilityMonthTotal ->
                    [{availability_month_total,
                      AvailabilityMonthTotal} | Status5]
            end,
            Status7 = case cloudi_core_i_status:
                           nanoseconds_to_availability_week(
                               NanoSecondsRunning,
                               ApproximateWeekUpdate,
                               NanoSecondsWeekUpdate) of
                ?AVAILABILITY_ZERO ->
                    Status6;
                AvailabilityWeekUpdated ->
                    [{availability_week_updated,
                      AvailabilityWeekUpdated} | Status6]
            end,
            Status8 = case cloudi_core_i_status:
                           nanoseconds_to_availability_week(
                               NanoSecondsRunning) of
                ?AVAILABILITY_ZERO ->
                    Status7;
                AvailabilityWeekRunning ->
                    [{availability_week_running,
                      AvailabilityWeekRunning} | Status7]
            end,
            Status9 = case cloudi_core_i_status:
                           nanoseconds_to_availability_week(
                               NanoSecondsTotal,
                               ApproximateWeekRestart,
                               NanoSecondsWeekRestart) of
                ?AVAILABILITY_ZERO ->
                    Status8;
                AvailabilityWeekTotal ->
                    [{availability_week_total,
                      AvailabilityWeekTotal} | Status8]
            end,
            Status10 = [{availability_day_total,
                         cloudi_core_i_status:
                         nanoseconds_to_availability_day(
                             NanoSecondsTotal,
                             ApproximateDayRestart,
                             NanoSecondsDayRestart)},
                        {availability_day_running,
                         cloudi_core_i_status:
                         nanoseconds_to_availability_day(
                             NanoSecondsRunning)},
                        {availability_day_updated,
                         cloudi_core_i_status:
                         nanoseconds_to_availability_day(
                             NanoSecondsRunning,
                             ApproximateDayUpdate,
                             NanoSecondsDayUpdate)} | Status9],
            Status11 = if
                TimeRunning =< TimeMonthStart,
                NanoSecondsYearUpdate > 0 ->
                    [{interrupt_year_updating,
                      cloudi_core_i_status:
                      nanoseconds_to_string(NanoSecondsYearUpdate,
                                            ApproximateYearUpdate)} |
                     Status10];
                true ->
                    Status10
            end,
            Status12 = if
                TimeRunning =< TimeWeekStart,
                NanoSecondsMonthUpdate > 0 orelse
                NanoSecondsYearUpdate > 0 ->
                    [{interrupt_month_updating,
                      cloudi_core_i_status:
                      nanoseconds_to_string(NanoSecondsMonthUpdate,
                                            ApproximateMonthUpdate)} |
                     Status11];
                true ->
                    Status11
            end,
            Status13 = if
                TimeRunning =< TimeDayStart,
                NanoSecondsWeekUpdate > 0 orelse
                NanoSecondsMonthUpdate > 0 orelse
                NanoSecondsYearUpdate > 0 ->
                    [{interrupt_week_updating,
                      cloudi_core_i_status:
                      nanoseconds_to_string(NanoSecondsWeekUpdate,
                                            ApproximateWeekUpdate)} |
                     Status12];
                true ->
                    Status12
            end,
            Status14 = if
                NanoSecondsDayUpdate > 0 orelse
                NanoSecondsWeekUpdate > 0 orelse
                NanoSecondsMonthUpdate > 0 ->
                    [{interrupt_day_updating,
                      cloudi_core_i_status:
                      nanoseconds_to_string(NanoSecondsDayUpdate,
                                            ApproximateDayUpdate)} |
                     Status13];
                true ->
                    Status13
            end,
            Status15 = if
                TimeStart =< TimeMonthStart,
                NanoSecondsYearRestart > 0 ->
                    [{downtime_year_restarting,
                      cloudi_core_i_status:
                      nanoseconds_to_string(NanoSecondsYearRestart,
                                            ApproximateYearRestart)} |
                     Status14];
                true ->
                    Status14
            end,
            Status16 = if
                TimeStart =< TimeWeekStart,
                NanoSecondsMonthRestart > 0 orelse
                NanoSecondsYearRestart > 0 ->
                    [{downtime_month_restarting,
                      cloudi_core_i_status:
                      nanoseconds_to_string(NanoSecondsMonthRestart,
                                            ApproximateMonthRestart)} |
                     Status15];
                true ->
                    Status15
            end,
            Status17 = if
                TimeStart =< TimeDayStart,
                NanoSecondsWeekRestart > 0 orelse
                NanoSecondsMonthRestart > 0 orelse
                NanoSecondsYearRestart > 0 ->
                    [{downtime_week_restarting,
                      cloudi_core_i_status:
                      nanoseconds_to_string(NanoSecondsWeekRestart,
                                            ApproximateWeekRestart)} |
                     Status16];
                true ->
                    Status16
            end,
            Status18 = if
                NanoSecondsDayRestart > 0 orelse
                NanoSecondsWeekRestart > 0 orelse
                NanoSecondsMonthRestart > 0 ->
                    [{downtime_day_restarting,
                      cloudi_core_i_status:
                      nanoseconds_to_string(NanoSecondsDayRestart,
                                            ApproximateDayRestart)} |
                     Status17];
                true ->
                    Status17
            end,
            Status19 = [{uptime_total, UptimeTotal},
                        {uptime_running, UptimeRunning},
                        {uptime_restarts,
                         erlang:integer_to_list(Restarts)} | Status18],
            StatusN = if
                StartType =:= start_internal ->
                    [{count_process, CountProcess} | Status19];
                StartType =:= start_external ->
                    [{count_process, CountProcess},
                     {count_thread, CountThread} | Status19]
            end,
            {ok, StatusN};
        error ->
            {error, {service_not_found, ServiceId}}
    end.

update_start(PidList, UpdatePlan) ->
    Self = self(),
    [Pid ! {'cloudi_service_update', Self, UpdatePlan} || Pid <- PidList],
    update_start_recv(PidList, [], []).

update_start_recv([], PidListNew, UpdateResults) ->
    {UpdateResults, lists:reverse(PidListNew)};
update_start_recv([Pid | PidList], PidListNew, UpdateResults)
    when is_pid(Pid) ->
    receive
        {'DOWN', _, 'process', Pid, _} = DOWN ->
            self() ! DOWN,
            update_start_recv(PidList, [undefined | PidListNew],
                              [{error, pid_died} | UpdateResults]);
        {'cloudi_service_update', Pid} ->
            update_start_recv(PidList, [Pid | PidListNew],
                              UpdateResults);
        {'cloudi_service_update', Pid, {error, _} = UpdateResult} ->
            update_start_recv(PidList, [undefined | PidListNew],
                              [UpdateResult | UpdateResults])
    end.

update_now(PidList, UpdateResults, UpdateStart) ->
    Self = self(),
    lists:foreach(fun(Pid) ->
        if
            Pid =:= undefined ->
                ok;
            is_pid(Pid) ->
                Pid ! {'cloudi_service_update_now', Self, UpdateStart}
        end
    end, PidList),
    update_now_recv(PidList, UpdateResults).

update_now_recv([], UpdateResults) ->
    lists:reverse(UpdateResults);
update_now_recv([Pid | PidList], UpdateResults) ->
    if
        Pid =:= undefined ->
            update_now_recv(PidList, UpdateResults);
        is_pid(Pid) ->
            UpdateResult = receive
                {'DOWN', _, 'process', Pid, _} = DOWN ->
                    self() ! DOWN,
                    {error, pid_died};
                {'cloudi_service_update_now', Pid, Result} ->
                    Result
            end,
            update_now_recv(PidList, [UpdateResult | UpdateResults])
    end.

update_results(Results) ->
    update_results(Results, [], []).

update_results([], ResultsSuccess, ResultsError) ->
    {lists:reverse(ResultsSuccess), lists:usort(ResultsError)};
update_results([ok | Results], ResultsSuccess, ResultsError) ->
    update_results(Results, ResultsSuccess, ResultsError);
update_results([{ok, Result} | Results], ResultsSuccess, ResultsError) ->
    update_results(Results, [Result | ResultsSuccess], ResultsError);
update_results([{error, Reason} | Results], ResultsSuccess, ResultsError) ->
    update_results(Results, ResultsSuccess, [Reason | ResultsError]).

update_load_module([]) ->
    ok;
update_load_module([Module | ModulesLoad]) ->
    case reltool_util:module_reload(Module) of
        ok ->
            update_load_module(ModulesLoad);
        {error, _} = Error ->
            Error
    end.

update_load_module([], ModulesLoad) ->
    update_load_module(ModulesLoad);
update_load_module([CodePathAdd | CodePathsAdd], ModulesLoad) ->
    case code:add_patha(CodePathAdd) of
        true ->
            update_load_module(CodePathsAdd, ModulesLoad);
        {error, _} = Error ->
            Error
    end.

update_reload_stop(#config_service_update{
                       type = internal,
                       module = Module,
                       reload_stop = ReloadStop}) ->
    if
        ReloadStop =:= true ->
            ok = cloudi_core_i_services_internal_reload:
                 service_remove(Module);
        ReloadStop =:= false ->
            ok
    end;
update_reload_stop(#config_service_update{
                       type = external}) ->
    ok.

update_reload_start(#config_service_update{
                        type = internal,
                        module = Module,
                        options_keys = OptionsKeys,
                        options = #config_service_options{
                            reload = ReloadStart},
                        reload_stop = ReloadStop}) ->
    Reload = case lists:member(reload, OptionsKeys) of
        true ->
            ReloadStart;
        false ->
            ReloadStop
    end,
    if
        Reload =:= true ->
            ok = cloudi_core_i_services_internal_reload:
                 service_add(Module);
        Reload =:= false ->
            ok
    end;
update_reload_start(#config_service_update{
                        type = external}) ->
    ok.

update_before(#config_service_update{
                  modules_load = ModulesLoad,
                  code_paths_add = CodePathsAdd} = UpdatePlan) ->
    ok = update_reload_stop(UpdatePlan),
    UpdateModuleResult = update_load_module(CodePathsAdd, ModulesLoad),
    [UpdateModuleResult].

update_unload_module([]) ->
    ok;
update_unload_module([CodePathRemove | CodePathsRemove]) ->
    code:del_path(CodePathRemove),
    update_load_module(CodePathsRemove).

update_unload_module([], CodePathsRemove) ->
    update_unload_module(CodePathsRemove);
update_unload_module([Module | ModulesUnload], CodePathsRemove) ->
    reltool_util:module_unload(Module),
    update_unload_module(ModulesUnload, CodePathsRemove).

update_service(_, _,
               #config_service_update{
                   type = internal,
                   dest_refresh = DestRefresh,
                   timeout_init = TimeoutInit,
                   timeout_async = TimeoutAsync,
                   timeout_sync = TimeoutSync,
                   dest_list_deny = DestListDeny,
                   dest_list_allow = DestListAllow,
                   options_keys = OptionsKeys,
                   options = Options,
                   uuids = ServiceIds}, Services0) ->
    ServicesN = lists:foldl(fun(ServiceId, Services1) ->
        key2value:update1(ServiceId, fun(OldService) ->
            #service{service_m = Module,
                     service_a = Arguments} = OldService,
            cloudi_core_i_spawn = Module,
            ArgumentsNew = Module:update_internal_f(DestRefresh,
                                                    TimeoutInit,
                                                    TimeoutAsync,
                                                    TimeoutSync,
                                                    DestListDeny,
                                                    DestListAllow,
                                                    OptionsKeys,
                                                    Options,
                                                    Arguments),
            OldService#service{service_a = ArgumentsNew}
        end, Services1)
    end, Services0, ServiceIds),
    ServicesN;
update_service(Pids, Ports,
               #config_service_update{
                   type = external,
                   file_path = FilePath,
                   args = Args,
                   env = Env,
                   dest_refresh = DestRefresh,
                   timeout_init = TimeoutInit,
                   timeout_async = TimeoutAsync,
                   timeout_sync = TimeoutSync,
                   dest_list_deny = DestListDeny,
                   dest_list_allow = DestListAllow,
                   options_keys = OptionsKeys,
                   options = Options,
                   uuids = [ServiceId]}, Services0) ->
    ServicesN = key2value:update1(ServiceId, fun(OldService) ->
        #service{service_m = Module,
                 service_a = Arguments} = OldService,
        cloudi_core_i_spawn = Module,
        ArgumentsNext = Module:update_external_f(FilePath,
                                                 Args,
                                                 Env,
                                                 DestRefresh,
                                                 TimeoutInit,
                                                 TimeoutAsync,
                                                 TimeoutSync,
                                                 DestListDeny,
                                                 DestListAllow,
                                                 OptionsKeys,
                                                 Options,
                                                 Arguments),
        OldService#service{service_a = ArgumentsNext}
    end, Services0),
    if
        Ports == [] ->
            ok;
        length(Pids) == length(Ports) ->
            {_, ServiceNew} = key2value:fetch1(ServiceId,
                                                        ServicesN),
            #service{service_a = ArgumentsNew,
                     count_process = CountProcess,
                     count_thread = CountThread} = ServiceNew,
            Result = case cloudi_core_i_configurator:
                          service_update_external(Pids, Ports, ArgumentsNew,
                                                  CountThread, CountProcess) of
                ok ->
                    ok;
                {error, _} = Error ->
                    ?LOG_ERROR("failed ~p service update~n ~p",
                               [Error, service_id(ServiceId)]),
                    error
            end,
            [Pid ! {'cloudi_service_update_after', Result} || Pid <- Pids]
    end,
    ServicesN.

update_after(UpdateSuccess, PidList, ResultsSuccess,
             #config_service_update{
                 modules_unload = ModulesUnload,
                 code_paths_remove = CodePathsRemove} = UpdatePlan, Services) ->
    ServicesNew = if
        UpdateSuccess =:= true ->
            update_service(PidList, ResultsSuccess, UpdatePlan, Services);
        UpdateSuccess =:= false ->
            Services
    end,
    update_unload_module(ModulesUnload, CodePathsRemove),
    ok = update_reload_start(UpdatePlan),
    ServicesNew.

service_id(ID) ->
    uuid:uuid_to_string(ID, list_nodash).

new_service_process(M, F, A, ProcessIndex, CountProcess, CountThread,
                    Scope, Pids, MonitorRef, TimeStart, TimeRestart, Restarts,
                    TimeoutTerm, RestartDelay, MaxR, MaxT) ->
    #service{service_m = M,
             service_f = F,
             service_a = A,
             process_index = ProcessIndex,
             count_process = CountProcess,
             count_thread = CountThread,
             scope = Scope,
             pids = Pids,
             monitor = MonitorRef,
             time_start = TimeStart,
             time_restart = TimeRestart,
             restart_count_total = Restarts,
             timeout_term = TimeoutTerm,
             restart_delay = RestartDelay,
             max_r = MaxR,
             max_t = MaxT}.

