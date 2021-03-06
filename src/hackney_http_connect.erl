%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2012-2014 Benoît Chesneau <benoitc@e-engura.org>
%%%
%%%
-module(hackney_http_connect).

-include_lib("kernel/src/inet_dns.hrl").

-export([messages/1,
         connect/3, connect/4,
         recv/2, recv/3,
         send/2,
         setopts/2,
         controlling_process/2,
         peername/1,
         close/1,
         sockname/1]).

-define(TIMEOUT, infinity).

-type socks5_socket() :: {atom(), inet:socket()}.
-export_type([socks5_socket/0]).

%% @doc Atoms used to identify messages in {active, once | true} mode.
messages({hackney_ssl_transport, _}) ->
    {ssl, ssl_closed, ssl_error};
messages({_, _}) ->
    {tcp, tcp_closed, tcp_error}.


connect(Host, Port, Opts) ->
    connect(Host, Port, Opts, infinity).

connect(Host, Port, Opts, Timeout) when is_list(Host), is_integer(Port),
	(Timeout =:= infinity orelse is_integer(Timeout)) ->

    %% get the proxy host and port from the options
    ProxyHost = proplists:get_value(connect_host, Opts),
    ProxyPort = proplists:get_value(connect_port, Opts),
    Transport = proplists:get_value(connect_transport, Opts),

    case gen_tcp:connect(ProxyHost, ProxyPort, [binary, {packet, 0},
                                                {keepalive, true},
                                                {active, false}]) of
        {ok, Socket} ->
            case do_handshake(Socket, Host, Port, Opts) of
                ok ->
                    case Transport of
                        hackney_ssl_transport ->
                            SslOpts0 = proplists:get_value(ssl_options, Opts),
                            Insecure = proplists:get_value(insecure, Opts),

                            SslOpts = case {SslOpts0, Insecure} of
                                {undefined, true} ->
                                    [{verify, verify_none},
                                     {reuse_sessions, true}];
                                {undefined, _} ->
                                    [];
                                _ ->
                                    SslOpts0
                            end,
                            %% upgrade the tcp connection
                            case ssl:connect(Socket, SslOpts) of
                                {ok, SslSocket} ->
                                    {ok, {Transport, SslSocket}};
                                Error ->
                                    Error
                            end;
                        _ ->
                            {ok, {Transport, Socket}}
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

recv(Socket, Length) ->
    recv(Socket, Length, infinity).

%% @doc Receive a packet from a socket in passive mode.
%% @see gen_tcp:recv/3
-spec recv(socks5_socket(), non_neg_integer(), timeout())
	-> {ok, any()} | {error, closed | atom()}.
recv({Transport, Socket}, Length, Timeout) ->
	Transport:recv(Socket, Length, Timeout).


%% @doc Send a packet on a socket.
%% @see gen_tcp:send/2
-spec send(socks5_socket(), iolist()) -> ok | {error, atom()}.
send({Transport, Socket}, Packet) ->
	Transport:send(Socket, Packet).

%% @doc Set one or more options for a socket.
%% @see inet:setopts/2
-spec setopts(socks5_socket(), list()) -> ok | {error, atom()}.
setopts({Transport, Socket}, Opts) ->
	Transport:setopts(Socket, Opts).

%% @doc Assign a new controlling process <em>Pid</em> to <em>Socket</em>.
%% @see gen_tcp:controlling_process/2
-spec controlling_process(socks5_socket(), pid())
	-> ok | {error, closed | not_owner | atom()}.
controlling_process({Transport, Socket}, Pid) ->
	Transport:controlling_process(Socket, Pid).

%% @doc Return the address and port for the other end of a connection.
%% @see inet:peername/1
-spec peername(socks5_socket())
	-> {ok, {inet:ip_address(), inet:port_number()}} | {error, atom()}.
peername({Transport, Socket}) ->
	Transport:peername(Socket).

%% @doc Close a socks5 socket.
%% @see gen_tcp:close/1
-spec close(socks5_socket()) -> ok.
close({Transport, Socket}) ->
	Transport:close(Socket).

%% @doc Get the local address and port of a socket
%% @see inet:sockname/1
-spec sockname(socks5_socket())
	-> {ok, {inet:ip_address(), inet:port_number()}} | {error, atom()}.
sockname({Transport, Socket}) ->
	Transport:sockname(Socket).

%% private functions
do_handshake(Socket, Host, Port, Options) ->
    ProxyUser = proplists:get_value(connect_user, Options),
    ProxyPass = proplists:get_value(connect_pass, Options, <<>>),
    ProxyPort = proplists:get_value(connect_port, Options),

    %% set defaults headers
    HostHdr = case ProxyPort of
        80 ->
            list_to_binary(Host);
        _ ->
            iolist_to_binary([Host, ":", integer_to_list(Port)])
    end,
    UA =  hackney_request:default_ua(),
    Headers0 = [<<"Host", HostHdr/binary>>,
                <<"User-Agent: ", UA/binary >>],

    Headers = case ProxyUser of
        undefined ->
            Headers0;
        _ ->
            Credentials = base64:encode(<<ProxyUser/binary, ":",
                                          ProxyPass/binary>>),
            Headers0 ++ [<< "Proxy-Authorization: ", Credentials/binary >>]
    end,
    Path = iolist_to_binary([Host, ":", integer_to_list(Port)]),

    Payload = [<< "CONNECT ", Path/binary, " HTTP/1.1", "\r\n" >>,
               hackney_bstr:join(lists:reverse(Headers), <<"\r\n">>),
               <<"\r\n\r\n">>],
    case gen_tcp:send(Socket, Payload) of
        ok ->
           check_response(Socket);
       Error ->
           Error
    end.

check_response(Socket) ->
    case gen_tcp:recv(Socket, 0, ?TIMEOUT) of
        {ok, Data} ->
            check_status(Data);
        Error ->
            Error
    end.

check_status(<< "HTTP/1.1 200", _/bits >>) ->
    ok;
check_status(<< "HTTP/1.1 201", _/bits >>) ->
    ok;
check_status(<< "HTTP/1.0 200", _/bits >>) ->
    ok;
check_status(<< "HTTP/1.0 201", _/bits >>) ->
    ok;
check_status(Else) ->
    error_logger:error_msg("proxy error: ~w~n", [Else]),
    false.
