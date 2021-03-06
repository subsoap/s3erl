-module(s3_test).
-include_lib("eunit/include/eunit.hrl").

integration_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [
      ?_test(get_put()),
      ?_test(concurrency_limit()),
      ?_test(timeout_retry()),
      ?_test(slow_endpoint()),
      ?_test(permission_denied()),
      ?_test(list_objects())
     ]}.

setup() ->
    application:start(crypto),
    application:start(public_key),
    application:start(ssl),
    application:start(lhttpc),
    {ok, Pid} = s3_server:start_link(default_config()),
    [Pid].

teardown(Pids) ->
    [begin unlink(P), exit(P, kill) end || P <- Pids].




get_put() ->
    delete_if_existing(bucket(), <<"foo">>),

    ?assertEqual({ok, not_found}, s3:get(bucket(), <<"foo">>)),
    ?assertEqual({ok, not_found}, s3:get(bucket(), "foo")),

    ?assertMatch({ok, _}, s3:put(bucket(), <<"foo">>, <<"bazbar">>, "text/plain")),
    ?assertEqual({ok, <<"bazbar">>}, s3:get(bucket(), <<"foo">>)),

    ?assertMatch({ok, _}, s3:put(bucket(), <<"foo-copy">>, <<>>, "text/plain",
                                 5000, [{"x-amz-copy-source", bucket() ++ "/foo"}])).

permission_denied() ->
    ?assertEqual({error, {"AccessDenied", "Access Denied"}},
                 s3:put("foobar", <<"foo">>, <<"bazbar">>, "text/plain")).

concurrency_limit() ->
    Parent = self(),
    MaxConcurrencyCB = fun (N) -> Parent ! {max_concurrency, N} end,

    s3_server:stop(),
    s3_server:start_link([{max_concurrency_callback, MaxConcurrencyCB},
                          {max_concurrency, 3}] ++ default_config()),

    meck:new(s3_lib),
    GetF = fun (_, _, _) -> timer:sleep(50), {ok, <<"bazbar">>} end,
    meck:expect(s3_lib, get, GetF),
    meck:expect(s3_lib, get, GetF),
    meck:expect(s3_lib, get, GetF),


    P1 = spawn(fun() -> Parent ! {self(), s3:get(bucket(), <<"foo">>)} end),
    P2 = spawn(fun() -> Parent ! {self(), s3:get(bucket(), <<"foo">>)} end),
    P3 = spawn(fun() -> Parent ! {self(), s3:get(bucket(), <<"foo">>)} end),
    P4 = spawn(fun() -> Parent ! {self(), s3:get(bucket(), <<"foo">>)} end),

    receive M0 -> ?assertEqual({max_concurrency, 3}, M0) end,
    receive {P1, M1} -> ?assertEqual({ok, <<"bazbar">>}, M1) end,
    receive {P2, M2} -> ?assertEqual({ok, <<"bazbar">>}, M2) end,
    receive {P3, M3} -> ?assertEqual({ok, <<"bazbar">>}, M3) end,
    receive {P4, M4} -> ?assertEqual({error, max_concurrency}, M4) end,

    ?assertEqual({ok, <<"bazbar">>}, s3:get(bucket(), <<"foo">>)),
    ?assertEqual({ok, [{puts, 0}, {gets, 4}, {deletes, 0}, {num_workers, 0}]},
                 s3_server:get_stats()),

    meck:validate(s3_lib),
    meck:unload(s3_lib).

timeout_retry() ->
    Parent = self(),
    RetryCb = fun (Reason, Attempt) ->
                      Parent ! {Reason, Attempt}
              end,
    s3_server:stop(),
    s3_server:start_link([{timeout, 10},
                          {retry_callback, RetryCb},
                          {retry_delay, 10}] ++ default_config()),

    meck:new(lhttpc),
    TimeoutF = fun (_, _, _, _, _) ->
                       timer:sleep(50),
                       {error, timeout}
               end,
    meck:expect(lhttpc, request, TimeoutF),
    %% meck:expect(lhttpc, request, TimeoutF),
    %% meck:expect(lhttpc, request, TimeoutF),

    ?assertEqual({error, timeout}, s3:get(bucket(), <<"foo">>)),

    receive M1 -> ?assertEqual({timeout, 0}, M1) end,
    receive M2 -> ?assertEqual({timeout, 1}, M2) end,
    receive M3 -> ?assertEqual({timeout, 2}, M3) end,
    receive _  -> ?assert(false) after 1 -> ok end,

    ?assert(meck:validate(lhttpc)),
    meck:unload(lhttpc).

slow_endpoint() ->
    Port = webserver:start(gen_tcp, [fun very_slow_response/5]),

    s3_server:stop(),
    s3_server:start_link([{timeout, 10},
                          {endpoint, "localhost:" ++ integer_to_list(Port)},
                          {retry_delay, 10}] ++ default_config()),

    ?assertEqual({error, timeout}, s3:get(bucket(), <<"foo">>, 100)).

list_objects() ->
    {ok, _} = s3:put(bucket(), "1/1", "foo", "text/plain"),
    {ok, _} = s3:put(bucket(), "1/2", "foo", "text/plain"),
    {ok, _} = s3:put(bucket(), "1/3", "foo", "text/plain"),
    {ok, _} = s3:put(bucket(), "2/1", "foo", "text/plain"),


    ?assertEqual({ok, [<<"1/">>, <<"1/1">>, <<"1/2">>, <<"1/3">>]},
                 s3:list(bucket(), "1/", 10, "")),

    ?assertEqual({ok, [<<"1/3">>]},
                 s3:list(bucket(), "1/", 3, "1/2")),

    %% List all, includes keys from other tests.
    ?assertEqual({ok, [<<"1/">>, <<"1/1">>, <<"1/2">>, <<"1/3">>, <<"2/1">>,
                       <<"foo">>, <<"foo-copy">>]},
                 s3:list(bucket(), "", 10, "")).


%%
%% HELPERS
%%

very_slow_response(Module, Socket, _, _, _) ->
    timer:sleep(100),
    Module:send(
      Socket,
      "HTTP/1.1 200 OK\r\n"
      "Content-type: text/plain\r\nContent-length: 14\r\n\r\n"
      "Great success!"
    ).

delete_if_existing(Bucket, Key) ->
    case s3:get(Bucket, Key) of
        {ok, not_found} ->
            ok;
        {ok, _Doc} ->
            {ok, _} = s3:delete(Bucket, Key)
    end.

default_config() ->
    credentials().

credentials() ->
    File = filename:join([code:priv_dir(s3erl), "s3_credentials.term"]),
    {ok, Cred} = file:consult(File),
    Cred.

bucket() ->
    File = filename:join([code:priv_dir(s3erl), "bucket.term"]),
    {ok, Config} = file:consult(File),
    proplists:get_value(bucket, Config).
