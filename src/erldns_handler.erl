-module(erldns_handler).
-behavior(gen_server).

-include("dns.hrl").
-include("erldns.hrl").

-export([start_link/0, register_handler/2, get_handlers/0, handle/2]).

% Gen server hooks
-export([init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3
       ]).

% Internal API
-export([handle_message/2]).

-record(state, {handlers}).

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register_handler(RecordTypes, Module) ->
  gen_server:call(?MODULE, {register_handler, RecordTypes, Module}).

get_handlers() ->
  gen_server:call(?MODULE, {get_handlers}).

init([]) ->
  %lager:info("Initialized the handler_registry"),
  {ok, #state{handlers=[]}}.

handle_call({register_handler, RecordTypes, Module}, _, State) ->
  %lager:info("Registered handler ~p for types ~p", [Module, RecordTypes]),
  {reply, ok, State#state{handlers = State#state.handlers ++ [{Module, RecordTypes}]}};
handle_call({get_handlers}, _, State) ->
  {reply, State#state.handlers, State}.

handle_cast(_, State) ->
  {noreply, State}.
handle_info(_, State) ->
  {noreply, State}.
terminate(_, _) ->
  ets:delete(handler_registry),
  ok.
code_change(_PreviousVersion, State, _Extra) ->
  {ok, State}.

%% If the message has trailing garbage just throw the garbage away and continue
%% trying to process the message.
handle({trailing_garbage, Message, _}, Host) ->
  handle(Message, Host);
%% Handle the message, checking to see if it is throttled.
handle(Message, Host) when is_record(Message, dns_message) ->
  handle(Message, Host, erldns_query_throttle:throttle(Message, Host));
%% The message was bad so just return it.
%% TODO: consider just throwing away the message
handle(BadMessage, Host) ->
  lager:error("Received a bad message: ~p from ~p", [BadMessage, Host]),
  BadMessage.

%% We throttle ANY queries to discourage use of our authoritative name servers
%% for reflection attacks.
handle(Message, Host, {throttled, Host, _ReqCount}) ->
  %lager:debug("Throttled ANY query for ~p. (req count: ~p)", [Host, ReqCount]),
  Message#dns_message{rc = ?DNS_RCODE_REFUSED};
%% Message was not throttled, so handle it, then do EDNS handling, optionally
%% append the SOA record if it is a zone transfer and complete the response
%% by filling out count-related header fields.
handle(Message, Host, _) ->
  %lager:debug("Questions: ~p", [Message#dns_message.questions]),
  NewMessage = handle_message(Message, Host),
  complete_response(erldns_axfr:optionally_append_soa(erldns_edns:handle(NewMessage))).

%% Handle the message by hitting the packet cache and either
%% using the cached packet or continuing with the lookup process.
handle_message(Message, Host) ->
  case erldns_packet_cache:get(Message#dns_message.questions, Host) of
    {ok, CachedResponse} -> CachedResponse#dns_message{id=Message#dns_message.id};
    {error, _} -> handle_packet_cache_miss(Message, get_authority(Message), Host) % SOA lookup
  end.

%% If the packet is not in the cache and we are not authoritative, then answer
%% immediately with the root delegation hints.
handle_packet_cache_miss(Message, [], _Host) ->
  {Authority, Additional} = erldns_records:root_hints(),
  Message#dns_message{aa = false, rc = ?DNS_RCODE_NOERROR, authority = Authority, additional = Additional};

%% The packet is not in the cache yet we are authoritative, so try to resolve
%% the request.
handle_packet_cache_miss(Message, AuthorityRecords, Host) ->
  handle_packet_cache_miss(Message#dns_message{ra = false}, AuthorityRecords, Host, Message#dns_message.aa).

handle_packet_cache_miss(Message, AuthorityRecords, Host, Authoritative) ->
  case application:get_env(erldns, catch_exceptions) of
    {ok, false} -> maybe_cache_packet(erldns_resolver:resolve(Message, AuthorityRecords, Host), Authoritative);
    _ ->
      try erldns_resolver:resolve(Message, AuthorityRecords, Host) of
        Response -> maybe_cache_packet(Response, Authoritative)
      catch
        Exception:Reason ->
          lager:error("Error answering request: ~p (~p)", [Exception, Reason]),
          Message#dns_message{aa = false, rc = ?DNS_RCODE_SERVFAIL}
      end
  end.

%% We are authoritative so cache the packet and return the message.
maybe_cache_packet(Message, true) ->
  erldns_packet_cache:put(Message#dns_message.questions, Message),
  Message;

%% We are not authoritative so just return the message.
maybe_cache_packet(Message, false) ->
  Message.

%% Get the SOA authority for the current query.
get_authority(MessageOrName) ->
  case erldns_zone_cache:get_authority(MessageOrName) of
    {ok, Authority} -> [Authority];
    {error, _} -> []
  end.

%% Update the message counts and set the QR flag to true.
complete_response(Message) ->
   Message#dns_message{
    anc = length(Message#dns_message.answers),
    auc = length(Message#dns_message.authority),
    adc = length(Message#dns_message.additional),
    qr = true
  }.
