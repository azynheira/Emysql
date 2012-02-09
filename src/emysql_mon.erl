-module(emysql_mon).
-include_lib("eunit/include/eunit.hrl").
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-record(state,
			{queue_size=0,			% Current Queue size
			high_watermark=10,		% High watermark
			onoff=false,			% Is monitor active ?
			curr_state=false,		% Current state of defect (raise=true, clear=false)
			next_state=false,	    % Next state of defect (raise=true, clear=false)
		   	f1filter=1000,			% f1 filter configuration (both for clear and raise)
			filterpid=false,		% Pid of the filter process
			last_trap=false			% Last trap sent
			}).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0,monitor/1,set_enable/1,set_watermark/1,get_state/0,set_f1filter/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([test/0]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% Exposed emysql_monitor API Function
%% ------------------------------------------------------------------
get_state() ->
	{state,QueueSize,Watermark,OnOff,CurrRaiseClear,NextRaiseClear,F1Filter,FilterPid,Last} = gen_server:call(?MODULE,get_state),
 	gen_server:call(?MODULE,get_state),
 	io:format("Queue size:~p~n",[QueueSize]),
	io:format("Watermark: ~p~n",[Watermark]),
	io:format("Enabled:   ~p~n",[OnOff]),
	io:format("Current St:~p~n",[CurrRaiseClear]),
	io:format("Next State:~p~n",[NextRaiseClear]),
    io:format("Filter(s): ~p~n",[F1Filter]),
    io:format("FilterPid: ~p~n",[FilterPid]),
    io:format("Last:	  ~p~n",[Last]).

monitor(QueueS) ->
	gen_server:call(?MODULE,{monitor, QueueS}).

set_watermark(QueueS) ->
	gen_server:call(?MODULE,{set_watermark, QueueS}).

set_enable(OnOff) ->
	gen_server:call(?MODULE,{set_enable, OnOff}).

set_f1filter(F1Filter) ->
	gen_server:call(?MODULE,{set_filter, F1Filter}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% -----------------------------------------------------------------

init([]) ->
	{ok, #state {queue_size=0, high_watermark=101, onoff=false, curr_state=false, next_state=false, f1filter=1000,
			filterpid=false, last_trap=false}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Request, State) ->
	{noreply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({set_enable, OnOff}, _From, State) ->
	?debugFmt("Just received set_enable[~p]~n",[OnOff]),
    if State#state.onoff =/= OnOff ->
			NewState=defect_processing(State#state{onoff=OnOff}),
    		{reply, ok, NewState};
    	true ->
			{reply, ok, State}
	end;

handle_call({set_watermark, QueueS}, _From, State) ->
	?debugFmt("Just received set_watermark[~p]~n",[QueueS]),
    if State#state.high_watermark =/= QueueS ->
			NewState=defect_processing(State#state{high_watermark=QueueS}),
    		{reply, ok, NewState};
    	true ->
			{reply, ok, State}
	end;

handle_call({set_filter, Miliseconds}, _From, State) ->
	?debugFmt("Just received set_filter[~p]~n",[Miliseconds]),
    if State#state.f1filter =/= Miliseconds ->
			NewState=(State#state{f1filter=Miliseconds}),
    		{reply, ok, NewState};
    	true ->
			{reply, ok, State}
	end;

handle_call({monitor, QueueS}, From, State) ->
	?debugFmt("Just received monitor[~p,~p,~p]~n",[QueueS, From,State]),
	if State#state.onoff == true ->
			NewState=defect_processing(State#state{queue_size=QueueS}),
			{reply, ok, NewState};
		true ->
			{reply, ok, State#state{queue_size=QueueS}}
	end;

handle_call(get_state, _From, State) ->
	{reply,State,State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling of defect. Processes the defect, by spwaning a new process
%% to integrate into a real alarm.
%% The FSM state change is done here!
%%
%% @spec defect_processing(State) -> NewState
%% @end
%%--------------------------------------------------------------------
defect_processing(State) ->
	?debugFmt("Current state:~p~n",[State]),
	% 1. State transition: (No alarm -> Alarm)
	% -> Start integrating defect in order to send rasing alarm
	if State#state.onoff == true andalso
       State#state.high_watermark < State#state.queue_size andalso
       State#state.curr_state == false ->
			?debugFmt("State transition C->R~n",[]),
			start_filter(State#state{next_state=true});
	% State transition: (Raised being integrated -> Cleared)
    % -> Start integrating defect in order to send clear alarm
       State#state.onoff == true andalso
	   State#state.high_watermark >= State#state.queue_size andalso
       State#state.curr_state == true ->
			?debugFmt("State transition R->C~n",[]),
			start_filter(State#state{next_state=false});
	% State transition: (Disabled and Alarm is Raised)
	% -> Clear alarm at once
       State#state.onoff == false andalso
       State#state.curr_state == true ->
			?debugFmt("State transition with defect being raised (disabled)~n",[]),
			start_filter(State#state{next_state=false});
	   true ->
			?debugFmt("Did not process state: ~p~n",[State]),
			State
	end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({emysql_monitor_trap, TrapState}, State) ->
	?debugFmt("Just received trap:~p|~p~n",[TrapState,State]),
	NewState=State#state{last_trap=TrapState},
    {noreply, NewState}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    	{ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

start_filter(State) ->

	% Cancel any active filter process from still active integration
	% eg. Trap was being integrated for raise and then now was involked
	% to be integrated for clear
	if State#state.filterpid =/= false ->
			%io:format("Pid~p ~n",[State]),
			State#state.filterpid ! {self(), abort_integration},
			catch exit(State#state.filterpid);
		true -> ok
	end,

	NextState=State#state{curr_state=State#state.next_state},

	%io:format("start_filter state ~p@~p~n",[State,NextState]),
	if (State#state.next_state == State#state.last_trap) ->
		%io:format("States are the same"),
		NextState;
	   State#state.onoff == true ->
		Pid = spawn(fun() -> filter_process(0) end),
		%io:format("FilterPid:~p~n",[Pid]),
		% Start the integration inside the spwaned process
		_Result = Pid ! {self(), {start_integration, State}}, State#state{filterpid=Pid},
		NextState#state{filterpid=Pid};
	% Just disable the monitoring.
	   State#state.onoff == false andalso
	   State#state.next_state == false andalso
	   State#state.curr_state == true ->
		self() !  {emysql_monitor_trap, NextState#state.next_state},
		NextState;
	true -> NextState
	end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling of filter integration.
%% This is spawned to a filter process and will wait for the integration
%% time to elapse, and if nobody has killed it then it will issue a trap
%% (true or false).
%%
%% @spec filter_loop(State) -> void
%% @end
%%--------------------------------------------------------------------
filter_process(PState) ->
	receive
		{_From, {start_integration, State}} ->
		    ?debugFmt("Starting integration of defect timer: ~p ~n",[State]),
			{ok, TRef} = timer:send_after(State#state.f1filter, {_From, {send_trap, State#state.next_state}}),
			%io:format("Ret:~p~n",[TRef]),
			filter_process(TRef);
		{_From, abort_integration} ->
		    ?debugFmt("Canceling integration of defect~n",[]),
		    timer:cancel(PState),
		    catch exit(aborted);
		{_From, {send_trap, TrapState}} ->
		    ?debugFmt("Sending trap to server ~n",[]),
			_From ! {emysql_monitor_trap, TrapState},
			catch exit(ok);
		Other ->
			?debugFmt("Just an unkown message in filter_process:~p ~n",[Other]),
			filter_process(PState)
	end.

-ifdef(TEST).
%% Utils

%%--------------------------------------------------------------------
%% @doc
%% To perform some kind of validation on the module by
%% running all test steps with assertions so that any result
%% not matching fails the test.
%%
%% @sdd-define(TEST,1). %%% Uncomment or define in rebar.config
%% @spec test() -> ok | error
%% @end
%%--------------------------------------------------------------------
test() ->
	?debugFmt("Running eunit tests~n for module ~s~n",[?MODULE]),
	% 0. Init
	init([]),
    % 0. Get state
	emysql_mon:get_state(),
    % 1. Enable monitoring and set watermark
	emysql_mon:set_enable(true),
	emysql_mon:set_watermark(10),
    % 2. Set queue size to 20 -> Trap TRUE sent
	emysql_mon:monitor(20),
	emysql_mon:get_state(),
	timer:sleep(5000),
    % 3. Set queue size to 9 -> Trap FALSE sent
	emysql_mon:monitor(9),
	emysql_mon:get_state(),
	timer:sleep(5000),
    % 4. Disable monitoring
	emysql_mon:get_state(),
	emysql_mon:set_enable(false),
    % 5. Set queue size to 20 -> Nothing happens
	emysql_mon:monitor(20),
    % 6. Enable monitoring -> Trap TRUE sent
	emysql_mon:set_enable(true),
    % 7. Disable monitoring -> Nothing happens
	emysql_mon:set_enable(false),
    % 8. Get state
	emysql_mon:get_state().

-endif.
