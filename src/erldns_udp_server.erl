-module(erldns_udp_server).
-behavior(gen_server).

% API
-export([start_link/2]).

% Gen server hooks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
  ]).

% Internal API
-export([handle_request/5]).

-define(SERVER, ?MODULE).

-record(state, {port, socket, workers}).

%% Public API
start_link(Name, InetFamily) ->
  gen_server:start_link({local, Name}, ?MODULE, [InetFamily], []).

%% gen_server hooks
init([InetFamily]) ->
  Port = erldns_config:get_port(),
  {ok, Socket} = start(Port, InetFamily),
  {ok, #state{port = Port, socket = Socket, workers = make_workers(queue:new())}}.
handle_call(_Request, _From, State) ->
  {ok, State}.
handle_cast(_Message, State) ->
  {noreply, State}.
handle_info(timeout, State) ->
  %lager:info("UDP instance timed out"),
  {noreply, State};
handle_info({udp, Socket, Host, Port, Bin}, State) ->
  Response = handle_request(Socket, Host, Port, Bin, State),
  inet:setopts(State#state.socket, [{active, once}]),
  Response;
handle_info(_Message, State) ->
  {noreply, State}.
terminate(_Reason, _State) ->
  ok.
code_change(_PreviousVersion, State, _Extra) ->
  {ok, State}.

%% Internal functions
%% Start a UDP server.
start(Port, InetFamily) ->
  lager:info("Starting UDP server for ~p on port ~p", [InetFamily, Port]),
  case gen_udp:open(Port, [binary, {active, once}, {read_packets, 1000}, {ip, erldns_config:get_address(InetFamily)}, InetFamily]) of
    {ok, Socket} -> 
      lager:info("UDP server (~p) opened socket: ~p", [InetFamily, Socket]),
      {ok, Socket};
    {error, eacces} ->
      lager:error("Failed to open UDP socket. Need to run as sudo?"),
      {error, eacces}
  end.

handle_request(Socket, Host, Port, Bin, State) ->
  case queue:out(State#state.workers) of
    {{value, Worker}, Queue} ->
      gen_server:cast(Worker, {udp_query, Socket, Host, Port, Bin}),
      {noreply, State#state{workers = queue:in(Worker, Queue)}};
    {empty, _Queue} ->
      lager:info("Queue is empty, dropping packet"),
      {noreply, State}
  end.

make_workers(Queue) ->
  make_workers(Queue, erldns_config:get_num_workers()).
make_workers(Queue, NumWorkers) ->
  make_workers(Queue, NumWorkers, 1).
make_workers(Queue, NumWorkers, N) ->
  case N < NumWorkers of
    true ->
      {ok, WorkerPid} = erldns_worker:start_link([]),
      make_workers(queue:in(WorkerPid, Queue), NumWorkers, N + 1);
    false ->
      Queue
  end.
