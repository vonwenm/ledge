use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2);

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/../lua-resty-redis-connector/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/../lua-resty-cookie/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua "
        local use_resty_core = $ENV{TEST_USE_RESTY_CORE}
        if use_resty_core then
            require 'resty.core'
        end
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('redis_qless_database', $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE})
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
        redis_socket = '$ENV{TEST_LEDGE_REDIS_SOCKET}'
    ";
    init_worker_by_lua "
        ledge:run_workers()
    ";
};

no_long_string();
run_tests();

__DATA__
=== TEST 1: Header case insensitivity
--- http_config eval: $::HttpConfig
--- config
location /response_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("origin_fetched", function(res)
            if res.header["X_tesT"] == "1" then
                res.header["x-TESt"] = "2"
            end

            if res.header["X-TEST"] == "2" then
                res.header["x_test"] = "3"
            end
        end)
        ledge:run()
    ';
}
location /response_1 {
    content_by_lua '
        ngx.header["X-Test"] = "1"
        ngx.say("OK")
    ';
}
--- request
GET /response_1_prx
--- response_headers
X-Test: 3


=== TEST 2: TTL from s-maxage (overrides max-age / Expires)
--- http_config eval: $::HttpConfig
--- config
	location /response_2_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:bind("response_ready", function(res)
                res.header["X-TTL"] = res:ttl()
            end)
            ledge:run()
        ';
    }
    location /response_2 {
        content_by_lua '
            ngx.header["Expires"] = ngx.http_time(ngx.time() + 300)
            ngx.header["Cache-Control"] = "max-age=600, s-maxage=1200"
            ngx.say("OK")
        ';
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /response_2_prx
--- response_headers
X-TTL: 1200


=== TEST 3: TTL from max-age (overrides Expires)
--- http_config eval: $::HttpConfig
--- config
	location /response_3_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:bind("response_ready", function(res)
                res.header["X-TTL"] = res:ttl()
            end)
            ledge:run()
        ';
    }
    location /response_3 {
        content_by_lua '
            ngx.header["Expires"] = ngx.http_time(ngx.time() + 300)
            ngx.header["Cache-Control"] = "max-age=600"
            ngx.say("OK")
        ';
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /response_3_prx
--- response_headers
X-TTL: 600


=== TEST 4: TTL from Expires
--- http_config eval: $::HttpConfig
--- config
	location /response_4_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:bind("response_ready", function(res)
                res.header["X-TTL"] = res:ttl()
            end)
            ledge:run()
        ';
    }
    location /response_4 {
        content_by_lua '
            ngx.header["Expires"] = ngx.http_time(ngx.time() + 300)
            ngx.say("OK")
        ';
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /response_4_prx
--- response_headers
X-TTL: 300
