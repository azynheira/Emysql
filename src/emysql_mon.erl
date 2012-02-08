-module(emysql_mon).
-include_lib("eunit/include/eunit.hrl").
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-record(state, {queue_size=0,			% Current Queue size
				high_watermark=10,		% High watermark
				onoff=false,			% Is monitor active ?
				trap_sent=false,		% Was high-watermark trap sent ?
		   		f1filter=10				% f1 filter configuration (both for clear and raise)
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
	{state,QueueSize,Watermark,OnOff,TrapSent,F1Filter} = gen_server:call(?MODULE,get_state),
 	gen_server:call(?MODULE,get_state),
 	io:format("Queue size:~p~n",[QueueSize]),
	io:format("Watermark: ~p~n",[Watermark]),
	io:format("Enabled:   ~p~n",[OnOff]),
	io:format("Trap sent: ~p~n",[TrapSent]),
    io:format("F1 filter: ~p~n",[F1Filter]).

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
	{ok, #state {queue_size=0, high_watermark=10, onoff=false, trap_sent=false, f1filter=10}}.

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
handle_call({set_enable, OnOff}, From, State) ->
	io:format("Just received set_enable[~p]~n",[OnOff]),
    if State#state.onoff =/= OnOff ->
    		NewState=State#state{onoff=OnOff},
			io:format("[~p]~n",[NewState]),
			trap_processing(NewState#state.queue_size, From, NewState),
    		{reply, ok, NewState};
    	true ->
			{reply, ok, State}
	end;

handle_call({set_watermark, QueueS}, From, State) ->
	io:format("Just received set_watermark[~p]~n",[QueueS]),
    if State#state.high_watermark =/= QueueS ->
    		NewState=State#state{high_watermark=QueueS},
			trap_processing(NewState#state.queue_size, From, NewState),
    		{reply, ok, NewState};
    	true ->
			{reply, ok, State}
	end;

handle_call({monitor, QueueS}, From, State) ->
	io:format("Just reveived monitor[~p,~p,~p]~n",[QueueS, From,State]),
	if State#state.onoff == true ->
			NewState = trap_processing(QueueS, From, State),
			{reply, ok, NewState#state{queue_size=QueueS}};
		true ->
			{reply, ok, State#state{queue_size=QueueS}}
	end;

handle_call(get_state, _From, State) ->
	{reply,State,State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling of traps. Processes traps, sends them if required and sends
%%					  the new state when the trap state updated.
%%
%% @spec trap_processing(QueueS, _From, State) -> NewState
%% @end
%%--------------------------------------------------------------------
trap_processing(QueueS, _From, State) ->
	% Trap was not sent and the watermark was just overtrown
	% -> Sent rasing alarm
	if State#state.onoff == true andalso
       State#state.high_watermark < QueueS andalso
       State#state.trap_sent == false ->
			NewState=State#state{trap_sent=true},
			self() ! {emysql_monitor_trap, true},
			NewState;
	% Trap was already sent and the watermark was just undertrown
	% -> Sent lowering alarm
	   State#state.onoff == true andalso
	   State#state.high_watermark >= QueueS andalso
	   State#state.trap_sent == true ->
			NewState=State#state{trap_sent=false},
			self() ! {emysql_monitor_trap, false},
			NewState;
    	true ->
			State
	end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling of filter integration
%%
%% @spec filter_processing(State) -> NewState
%% @end
%%--------------------------------------------------------------------
filter_processing(_State) ->
	ok.

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
handle_info({emysql_monitor_trap, TrapValue}, State) ->
	io:format("Just received trap:~p~p~n",[TrapValue,State]),
    {noreply, State}.

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
    % 1. Enable monitoring and set watermark
	emysql_mon:set_enable(true),
	emysql_mon:set_watermark(10),
    % 2. Set queue size to 20 -> Trap TRUE sent
	emysql_mon:monitor(20),
    % 3. Set queue size to 9 -> Trap FALSE sent
	emysql_mon:monitor(9),
    % 4. Disable monitoring
	emysql_mon:set_enable(false),
    % 5. Set queue size to 20 -> Nothing happens
	emysql_mon:monitor(20),
    % 6. Enable monitoring -> Trap TRUE sent
	emysql_mon:set_enable(true),
    % 7. Disable monitoring -> Nothing happens
	emysql_mon:set_enable(false),
    % 8. Get state
	emysql_mon:get_state().

%%% Tests

-endif.
