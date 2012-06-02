module("ledge.ledge", package.seeall)

_VERSION = '0.01'

-- Load modules and config only on the first run
local event = require("ledge.event")
local resty_redis = require("resty.redis")

-- Cache states 
local cache_states= {
    SUBZERO = 1, -- We don't know anything about this URI. Either first hit or not cacheable.
    COLD    = 2, -- Previosuly cacheable, expired and beyond stale. Revalidate.
    WARM    = 3, -- Previously cacheable, cached but stale. Serve and bg refresh.
    HOT     = 4, -- Cached. Serve.
}

-- Proxy actions
local proxy_actions = {
    FETCHED     = 1, -- Went to the origin.
    COLLAPSED   = 2, -- Waited on a similar request to the origin, and shared the reponse.
}

local options = {}

-- Resty rack interface
function call(o)
    options = o

    return function(req, res)
        ngx.ctx.redis = resty_redis:new()
        if not options.redis then options.redis = {} end -- In case nothing has been set.

        -- Connect to Redis. The connection is kept alive later.
        ngx.ctx.redis:set_timeout(options.redis.timeout or 1000) -- Default to 1 sec

        local ok, err = ngx.ctx.redis:connect(
            -- Try redis_host or redis_socket, fallback to localhost:6379 (Redis default).
            options.redis.host or options.redis.socket or "127.0.0.1", 
            options.redis.port or 6379
        )

        -- Read from cache. 
        if read(req, res) then
            res.state = cache_states.HOT
            set_headers(req, res)
        else
            -- Nothing in cache or the client can't accept a cached response. 
            -- TODO: Check for prior knowledge to determine probably cacheability?

            if not fetch(req, res) then
                -- Keep the Redis connection
                ngx.ctx.redis:set_keepalive(
                    options.redis.keepalive.max_idle_timeout or 0, 
                    options.redis.keepalive.pool_size or 100
                )
                return res.status, res.header, res.body -- Pass the proxied error back.
            else
                res.state = cache_states.SUBZERO
                set_headers(req, res)
            end
        end

        event.emit("response_ready", req, res)

        -- Keep the Redis connection
        ngx.ctx.redis:set_keepalive(
            options.redis.keepalive.max_idle_timeout or 0, 
            options.redis.keepalive.pool_size or 100
        )

        -- Currently rack expets these. Seems a little verbose, but it's rack-like.
        return res.status, res.header, res.body 
    end
end


-- Reads an item from cache
--
-- @param	table   req
-- @param   table   res
-- @return	number  ttl
function read(req, res)
    if not request_accepts_cache(req) then return nil end

    -- Fetch from Redis, pipeline to reduce overhead
    ngx.ctx.redis:init_pipeline()
    local cache_parts = ngx.ctx.redis:hgetall(ngx.var.cache_key)
    local ttl = ngx.ctx.redis:ttl(ngx.var.cache_key)
    local replies, err = ngx.ctx.redis:commit_pipeline()
    if not replies then
        error("Failed to query ngx.ctx.redis: " .. err)
    end

    -- A positive TTL tells us if there's anything valid
    local ttl = assert(tonumber(replies[2]), "Bad TTL found for " .. ngx.var.cache_key)
    if ttl < 0 then
        return nil -- Cache miss cache_states.SUBZERO  -- Cache miss
    end

    -- We should get a table of cache entry values
    assert(type(replies[1]) == 'table', 
        "Failed to collect cache data from Redis")

    local cache_parts = replies[1]
    -- The Redis replies is a sequence of messages, so we iterate over pairs
    -- to get hash key/values.
    for i = 1, #cache_parts, 2 do
        if cache_parts[i] == 'body' then
            res.body = cache_parts[i+1]
        elseif cache_parts[i] == 'status' then
            res.status = cache_parts[i+1]
        else
            -- Everything else will be a header, with a h: prefix.
            local _, _, header = cache_parts[i]:find('h:(.*)')
            if header then
                res.header[header] = cache_parts[i+1]
            end
        end
    end

    event.emit("cache_accessed", req, res)
    return ttl
end


-- Stores an item in cache
--
-- @param	table       The HTTP response object to store
-- @return	boolean|nil, status     Saved state or nil, ngx.capture status on error.
function save(req, res)
    if not response_is_cacheable(res) then
        return 0 -- Not cacheable, but no error
    end

    ngx.ctx.redis:init_pipeline()

    -- Turn the headers into a flat list of pairs
    local h = {}
    for header,header_value in pairs(res.header) do
        table.insert(h, 'h:'..header)
        table.insert(h, header_value)
    end

    ngx.ctx.redis:hmset(ngx.var.cache_key, 
        'body', res.body, 
        'status', res.status,
        'uri', req.uri_full,
        unpack(h))

    -- Set the expiry (this might include an additional stale period)
    local ttl, expiry = calculate_expiry(res)
    ngx.ctx.redis:expire(ngx.var.cache_key, ttl)

    -- Add this to the uris_by_expiry sorted set, for cache priming and analysis
    ngx.ctx.redis:zadd('ledge:uris_by_expiry', expiry, req.uri_full)

    local replies, err = ngx.ctx.redis:commit_pipeline()
    if not replies then
        error("Failed to query Redis: " .. err)
    end
    return assert(replies[1] == "OK" and replies[2] == 1 and type(replies[3]) == 'number')
end


-- Fetches a resource from the origin server.
--
-- @param	string	The nginx location to proxy using
-- @return	table	Response
function fetch(req, res)
    event.emit("origin_required", req, res)

    local origin = ngx.location.capture(options.proxy_location..req.uri_relative, {
        method = ngx['HTTP_' .. req.method], -- Method as ngx.HTTP_x constant.
        body = req.body,
    })

    res.status = origin.status
    -- Merge headers in rather than wipe out the res.headers table)
    for k,v in pairs(origin.header) do
        res.header[k] = v
    end
    res.body = origin.body

    -- Could not proxy for some reason
    if res.status >= 500 then
        return nil
    else 
        -- A nice opportunity for post-fetch / pre-save work.
        event.emit("origin_fetched", req, res)

        -- Save
        assert(save(req, res), "Could not save fetched object")
        return true
    end
end


-- Publish that an item needs fetching in the background.
-- Returns immediately.
function fetch_background(req, res)
    ngx.ctx.redis:publish('revalidate', req.uri_full)
end


function set_headers(req, res)
    -- Get the cache state as human string for response headers
    local cache_state_human = ''
    for k,v in pairs(cache_states) do
        if v == res.state then
            cache_state_human = tostring(k)
            break
        end
    end

    -- Via header
    local via = '1.1 ' .. req.host
    if  (res.header['Via'] ~= nil) then
        res.header['Via'] = via .. ', ' .. res.header['Via']
    else
        res.header['Via'] = via
    end

    -- X-Cache header
    if res.state >= cache_states.WARM then
        res.header['X-Cache'] = 'HIT' 
    else
        res.header['X-Cache'] = 'MISS'
    end

    res.header['X-Cache-State'] = cache_state_human
end


-- @return  boolean
function request_accepts_cache(req) 
    -- Only cache GET. I guess this should be configurable.
    if ngx['HTTP_'..req.method] ~= ngx.HTTP_GET then return false end
    if req.header['cache-control'] == 'no-cache' or req.header['Pragma'] == 'no-cache' then
        return false
    end
    return true
end


-- Determines if the response can be stored, based on RFC 2616.
-- This is probably not complete.
function response_is_cacheable(res)
    local cacheable = true

    local nocache_headers = {}
    nocache_headers['Pragma'] = { 'no-cache' }
    nocache_headers['Cache-Control'] = { 
        'no-cache', 
        'must-revalidate', 
        'no-store', 
        'private' 
    }

    for k,v in pairs(nocache_headers) do
        for i,header in ipairs(v) do
            if (res.header[k] and res.header[k] == header) then
                cacheable = false
                break
            end
        end
    end

    return cacheable
end


-- Work out the valid expiry from the Expires header.
function calculate_expiry(res)
    local ttl = 0
    if (response_is_cacheable(res)) then
        local ex = res.header['Expires']
        if ex then
            --local serve_when_stale = ngx.ctx.config.serve_when_stale or 0
            local serve_when_stale = 0
            expires = ngx.parse_http_time(ex)
            ttl =  (expires - ngx.time()) + serve_when_stale
        end
    end

    return ttl, expires
end


-- Metatable
--
-- To avoid race conditions, we specify a shared metatable and detect any 
-- attempt to accidentally declare a field in this module from outside.
setmetatable(ledge, {})
getmetatable(ledge).__newindex = function(table, key, val) 
    error('Attempt to write to undeclared variable "'..key..'": '..debug.traceback()) 
end
