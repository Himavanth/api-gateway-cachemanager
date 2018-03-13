--[[
  Copyright 2016 Adobe Systems Incorporated. All rights reserved.

  This file is licensed to you under the Apache License, Version 2.0 (the
  "License"); you may not use this file except in compliance with the License.  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR RESPRESENTATIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and limitations under the License.
  ]]


--
-- Base class for Redis Cache Store
--
--  Init options:
--   1. ttl  - time to live of the key, in seconds. it could be a function, a static value or nil
--
-- User: ddascal
-- Date: 31/01/16
--

local redis = require "resty.redis"
local RedisStatus = require "api-gateway.cache.status.remoteCacheStatus"

---
-- Shared dictionary used by RedisHealthCheck
local SHARED_DICT_NAME = "cachedkeys"

local REDIS_RO_UPSTREAM =  "api-gateway-redis-replica"
local REDIS_RW_UPSTREAM = "api-gateway-redis"

local redisStatus = RedisStatus:new({
    shared_dict = SHARED_DICT_NAME
})


local cache_store_cls = require "api-gateway.cache.store"

local _M = cache_store_cls:new()

---
--- DefaultRedisConnectionProvider - a default redis connection provider to be used
---
local DefaultRedisConnectionProvider = {
    max_idle_timeout = 30000,
    pool_size = 100,
    default_redis_timeout = 5000,
    -- Read Only Redis upstream name
    redis_ro_upstream_connection_data = nil,

    ---
    -- Read write Redis upstream name
    redis_rw_upstream_connection_data = nil
}

---
--- @params upstream_name
--- This method retrieves an upstream connection
--- @return host, port
function DefaultRedisConnectionProvider:getRedisUpstream(upstream_name)
    local n = upstream_name or REDIS_RW_UPSTREAM
    local upstream, host, port = redisStatus:getHealthyServer(n)
    ngx.log(ngx.DEBUG, "Obtained Redis Host:" .. tostring(host) .. ":" .. tostring(port), " from upstream:", n)
    if (nil ~= host and nil ~= port) then
        return host, port
    end

    ngx.log(ngx.ERR, "Could not find a Redis upstream.")
    return nil, nil
end

---
--- @params upstream
--- @return success, redis_instance
--- Method that gets a redis object after connection - it tries to authenticate based on an environment variable - REDIS_PASS or
--- REDIS_PASSWORD
function DefaultRedisConnectionProvider:getConnection(upstream)
    local redis_host, redis_port = self:getRedisUpstream(upstream)
    local redisPassword = os.getenv("REDIS_PASS") or os.getenv("REDIS_PASSWORD") or ''
    return self:connectToRedis(redis_host, redis_port, redisPassword)
end

---
--- @params host
--- @params port
--- @params password
--- @return success, redis
--- Method that connects to redis host port with password if any
function DefaultRedisConnectionProvider:connectToRedis(host, port, password)
    local redis_instance = redis:new()
    local redis_timeout = ngx.var.redis_timeout or self.default_redis_timeout
    redis_instance:set_timeout(redis_timeout)

    local ok, err = redis_instance:connect(host, port)

    if not ok then
        ngx.log(ngx.ERR, "Failed to connect to Redis instance: " .. host .. ", port: " .. port .. ". Error: ", err)
        return false, nil
    end

    if password ~= nil and password ~= '' then
        -- Authenticate
        local ok, err = redis_instance:auth(password)
        if not ok then
            ngx.log(ngx.ERR, "Redis authentication failed for server: " .. host .. ":" .. port .. ". Error: ", err)
            return false, nil
        end
        ngx.log(ngx.DEBUG, "Redis authentication successful")
        return ok, redis_instance
    else
        ngx.log(ngx.DEBUG, "No password authentication for Redis")
        return true, redis_instance
    end
end

---
--- @params redis_instance
--- Closes a connections and puts the connection back into the pool
function DefaultRedisConnectionProvider:closeConnection(redis_instance)
    redis_instance:set_keepalive(self.max_idle_timeout, self.pool_size)
end


_M.redis_connection_provider = DefaultRedisConnectionProvider


---
-- Returns the name of this cache store.
function _M:getName()
    error("getName method must be overwritten from redisHashCache or redisSetCache")
end

---
-- Returns the name of the field where the cached information is stored.
function _M:getField()
    return self.field
end

--- The Redis command to execute in order to save an elements in the cache
-- @param redis the instance to the redis client
-- @param key Cache Key
-- @param value Cache Value
--
function _M:addPutCommand(redis, key, value)
    error("addPutCommand method must be overwritten from redisHashCache or redisSetCache")
end

--- The Redis command to execute in order to get an element from the cache
-- @param redis the instance of the redis client
-- @param key Cache Key
--
function _M:addGetCommand(redis, key)
    error("addGetCommand method must be overwritten from redisHashCache or redisSetCache")
end

--- The Redis command to execute in order to delete an element from the cache
-- @param redis the instance of the redis client
-- @param key Cache Key
--
function _M:addDeleteCommand(redis, key)
    error("addDeleteCommand method must be overwritten from redisHashCache or redisSetCache")
end

---
-- @Override
-- @param key The name of the cached key
--
function _M:get(key)

    local upstreamConfig = self.redis_connection_provider.redis_ro_upstream_connection_data or REDIS_RO_UPSTREAM
    if self.redis_connection_provider.redis_ro_upstream_connection_data and
            type(self.redis_connection_provider.redis_ro_upstream_connection_data) == 'table' then
        upstreamConfig = {
            upstream = self.redis_connection_provider.redis_ro_upstream_connection_data.upstream,
            password = os.getenv(self.redis_connection_provider.redis_ro_upstream_connection_data.password)
        }
    end

    local ok, redis_r = self.redis_connection_provider:getConnection(upstreamConfig)
    if ok then
        local redis_response, err = self:addGetCommand(redis_r, key)
        self.redis_connection_provider:closeConnection(redis_r)
        if (err) then
            ngx.log(ngx.WARN, "Could not return a value for key=[", tostring(key), "].", err)
            return nil
        end
        if (redis_response == ngx.null) then
            ngx.log(ngx.DEBUG, "key=[", tostring(key), "] not found in ", tostring(self:getName()))
            return nil
        end
        ngx.log(ngx.WARN, "key=[", tostring(key), "] returned a value of type=", type(redis_response), " from ", tostring(self:getName()))
        return redis_response
    end
    return nil
end

---
-- @Override
-- @param key
-- @param value
--
function _M:put(key, value)
    local keyexpires = self:getTTL(key, value)
--    ngx.log(ngx.DEBUG, "Storing in Redis the key [", tostring(key), "], expires in=", tostring(keyexpires), " s, value=", tostring(value))
    ngx.log(ngx.DEBUG, "Storing in Redis the key [", tostring(key), "], expires in=", tostring(keyexpires), " s" )

    local upstreamConfig = self.redis_connection_provider.redis_rw_upstream_connection_data or REDIS_RW_UPSTREAM
    if self.redis_connection_provider.redis_rw_upstream_connection_data and
            type(self.redis_connection_provider.redis_rw_upstream_connection_data) == 'table' then
        upstreamConfig = {
            upstream = self.redis_connection_provider.redis_rw_upstream_connection_data.upstream,
            password = os.getenv(self.redis_connection_provider.redis_rw_upstream_connection_data.password)
        }
    end

    local ok, redis_rw = self.redis_connection_provider:getConnection(upstreamConfig)
    if ok then
        --ngx.log(ngx.DEBUG, "WRITING IN REDIS JSON OBJ key=" .. key .. "=" .. value .. ",expiring in:" .. (keyexpires - (os.time() * 1000)) )
        redis_rw:init_pipeline()
        self:addPutCommand(redis_rw, key, value)
        if keyexpires ~= nil then
            redis_rw:expire(key, keyexpires)
        end
        local commit_res, commit_err = redis_rw:commit_pipeline()
        self.redis_connection_provider:closeConnection(redis_rw)
        --ngx.log(ngx.WARN, "SAVE RESULT:" .. cjson.encode(commit_res) )
        if (commit_err == nil) then
            return true
        end
        ngx.log(ngx.WARN, "Failed to write the key [", key, "] in Redis. Error:", commit_err)
        return false
    end
    return false
end

---
-- @Override
-- @param key
-- @param value
--
function _M:evict(key)
    ngx.log(ngx.DEBUG, "Delete key from Redis [", tostring(key), "]")
    if (key == nil or #key == 0) then
        ngx.log(ngx.WARN, "Could not evict an empty key")
        return
    end

    local upstreamConfig = self.redis_connection_provider.redis_rw_upstream_connection_data or REDIS_RW_UPSTREAM
    if self.redis_connection_provider.redis_rw_upstream_connection_data and
            type(self.redis_connection_provider.redis_rw_upstream_connection_data) == 'table' then
        upstreamConfig = {
            upstream = self.redis_connection_provider.redis_rw_upstream_connection_data.upstream,
            password = os.getenv(self.redis_connection_provider.redis_rw_upstream_connection_data.password)
        }
    end

    local ok, redis_rw = self.redis_connection_provider:getConnection(upstreamConfig)
    if ok then
        redis_rw:init_pipeline()
        self:addDeleteCommand(redis_rw, key)
        local commit_res, commit_err = redis_rw:commit_pipeline()
        self.redis_connection_provider:closeConnection(redis_rw)
        if (commit_err == nil) then
            return true
        end
        ngx.log(ngx.WARN, "Failed to delete key [", key, "] in Redis. Error:", commit_err)
        return false
    end
    return false
end

return _M