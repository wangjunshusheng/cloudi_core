%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI Internal Service Supervisor==
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

-module(cloudi_core_i_services_internal_sup).
-author('mjtruog at protonmail dot com').

-behaviour(supervisor).

%% external interface
-export([start_link/0,
         process_start/18,
         process_started/3]).

%% supervisor callbacks
-export([init/1]).

-record(cloudi_service_process_start,
    {
        dispatcher :: cloudi_service:dispatcher(),
        service :: cloudi_service:source()
    }).

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

%%-------------------------------------------------------------------------
%% @doc
%% @end
%%-------------------------------------------------------------------------

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%-------------------------------------------------------------------------
%% @doc
%% @end
%%-------------------------------------------------------------------------

process_start(ProcessIndex, ProcessCount,
              TimeStart, TimeRestart, Restarts,
              GroupLeader, Module, Args, Timeout, Prefix,
              TimeoutSync, TimeoutAsync, TimeoutTerm,
              DestRefresh, DestDeny, DestAllow,
              ConfigOptions, ID)
    when is_integer(ProcessIndex), is_integer(ProcessCount),
         is_integer(TimeStart), is_integer(Restarts),
         is_atom(Module), is_list(Args), is_integer(Timeout), is_list(Prefix),
         is_integer(TimeoutSync), is_integer(TimeoutAsync),
         is_integer(TimeoutTerm) ->
    true = (DestRefresh == immediate_closest) orelse
           (DestRefresh == lazy_closest) orelse
           (DestRefresh == immediate_furthest) orelse
           (DestRefresh == lazy_furthest) orelse
           (DestRefresh == immediate_random) orelse
           (DestRefresh == lazy_random) orelse
           (DestRefresh == immediate_local) orelse
           (DestRefresh == lazy_local) orelse
           (DestRefresh == immediate_remote) orelse
           (DestRefresh == lazy_remote) orelse
           (DestRefresh == immediate_newest) orelse
           (DestRefresh == lazy_newest) orelse
           (DestRefresh == immediate_oldest) orelse
           (DestRefresh == lazy_oldest) orelse
           (DestRefresh == none),
    case supervisor:start_child(?MODULE, [ProcessIndex, ProcessCount,
                                          TimeStart, TimeRestart, Restarts,
                                          GroupLeader, Module, Args,
                                          Timeout, Prefix,
                                          TimeoutSync, TimeoutAsync,
                                          TimeoutTerm,
                                          DestRefresh, DestDeny, DestAllow,
                                          ConfigOptions, ID, self()]) of
        {ok, Dispatcher} ->
            result(Dispatcher);
        {ok, Dispatcher, _} ->
            result(Dispatcher);
        {error, _} = Error ->
            Error
    end.

%%-------------------------------------------------------------------------
%% @doc
%% @end
%%-------------------------------------------------------------------------

process_started(Parent, Dispatcher, ReceiverPid)
    when is_pid(Parent), is_pid(Dispatcher), is_pid(ReceiverPid) ->
    Parent ! #cloudi_service_process_start{dispatcher = Dispatcher,
                                           service = ReceiverPid},
    ok.

%%%------------------------------------------------------------------------
%%% Callback functions from supervisor
%%%------------------------------------------------------------------------

init([]) ->
    MaxRestarts = 0,
    MaxTime = 1,
    Shutdown = infinity, % cloudi_core_i_services_monitor handles shutdown
    {ok, {{simple_one_for_one, MaxRestarts, MaxTime}, 
          [{undefined,
            {cloudi_core_i_services_internal, start_link, []},
            temporary, Shutdown, worker, [cloudi_core_i_services_internal]}]}}.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

result(Dispatcher) ->
    MonitorRef = erlang:monitor(process, Dispatcher),
    receive
        #cloudi_service_process_start{dispatcher = Dispatcher,
                                      service = Service} ->
            % sent before cloudi_service_init/4 via process_started/3
            % after the Erlang process is ready for cloudi_service_init_begin
            % from cloudi_core_i_services_monitor:process_init_begin/1
            erlang:demonitor(MonitorRef, [flush]),
            {ok, Service};
        {'DOWN', MonitorRef, process, Dispatcher, Info} ->
            {error, Info}
    end.

