-- Copyright (C) by Jiang Yang (jiangyang-pd@360.cn)

local _M = { _VERSION = "0.0.3" }

_M.CONF = {
    initted = false,
    app = "default",
    idc = "",
    monitor_switch = {
        METRIC_COUNTER_RESPONSES = {},
        METRIC_COUNTER_SENT_BYTES = {},
        METRIC_COUNTER_REVD_BYTES = {},
        METRIC_HISTOGRAM_LATENCY = {},
        METRIC_GAUGE_CONNECTS = {}
    },
    log_method = {},
    buckets = {},
    merge_path = false
}

local function inTable(needle, table_name)
    if type(needle) ~= "string" or type(table_name) ~= "table" then
        return false
    end
    for _, v in ipairs(table_name) do
        if v == needle then
            return true
        end
    end
    return false
end

local function empty(var)
    if type(var) == "table" then
        return next(var) == nil
    end
    return var == nil or var == '' or not var
end

function _M:init(user_config)
    for k, v in pairs(user_config) do
        if k == "app" then
            if type(v) ~= "string" then
                return nil, '"app" must be a string'
            end
            self.CONF.app = v
        elseif k == "idc" then
            if type(v) ~= "string" then
                return nil, '"idc" must be a string'
            end
            self.CONF.idc = v
        elseif k == "log_method" then
            if type(v) ~= "table" then
                return nil, '"log_method" must be a table'
            end
            self.CONF.log_method = v
        elseif k == "buckets" then
            if type(v) ~= "table" then
                return nil, '"buckets" must be a table'
            end
            self.CONF.buckets = v
        elseif k == "monitor_switch" then
            if type(v) ~= "table" then
                return nil, '"monitor_switch" must be a table'
            end
            for i, j in pairs(v) do
                if type(self.CONF.monitor_switch[i]) == "table" then
                    self.CONF.monitor_switch[i] = j
                end
            end
        elseif k == "merge_path" then
            if type(v) ~= "string" then
                return nil, '"merge_path" must be a string'
            end
            self.CONF.merge_path = v
        end
    end

    local config = ngx.shared.prometheus_metrics
    config:flush_all()

    local prometheus = require("prometheus.prometheus").init("prometheus_metrics")

    -- QPS
    if not empty(self.CONF.monitor_switch.METRIC_COUNTER_RESPONSES) then
        self.metric_requests = prometheus:counter(
            "module_responses",
            "[" .. self.CONF.idc .. "] number of /path",
            {"app", "api", "module", "method", "code"}
        )
    end

    -- 流量 out
    if not empty(self.CONF.monitor_switch.METRIC_COUNTER_SENT_BYTES) then
        self.metric_traffic_out = prometheus:counter(
            "module_sent_bytes",
            "[" .. self.CONF.idc .. "] traffic out of /path",
            {"app", "api", "module", "method", "code"}
        )
    end

    -- 流量 in
    if not empty(self.CONF.monitor_switch.METRIC_COUNTER_REVD_BYTES) then
        self.metric_traffic_in = prometheus:counter(
            "module_revd_bytes",
            "[" .. self.CONF.idc .. "] traffic in of /path",
            {"app", "api", "module", "method", "code"}
        )
    end

    -- 延迟
    if not empty(self.CONF.monitor_switch.METRIC_HISTOGRAM_LATENCY) then
        self.metric_latency = prometheus:histogram(
            "response_duration_milliseconds",
            "[" .. self.CONF.idc .. "] http request latency",
            {"app", "api", "module", "method"},
            self.CONF.buckets
        )
    end

    -- 状态
    if not empty(self.CONF.monitor_switch.METRIC_GAUGE_CONNECTS) then
        self.metric_connections = prometheus:gauge(
            "module_connections",
            "[" .. self.CONF.idc .. "] number of http connections",
            {"app", "state"}
        )
    end

    if true then
        self.CONF.initted = true
        self.prometheus = prometheus
    end

    return self.CONF.initted
end

function _M:log()
    if not self.CONF.initted then
        return nil, "init first.."
    end

    local path = ""
    local method = ngx.var.request_method or ""
    local request_uri = ngx.var.request_uri or ""
    local status = ngx.var.status or ""

    if not request_uri or not method then
        return nil, "empty request_uri|method"
    end

    local st, _ = string.find(request_uri, "?")
    if st == nil then
        path = request_uri
    else
        path = string.sub(request_uri, 1, st-1)
    end

    path = string.lower(path)

    if inTable(method, self.CONF.log_method) then
        if self.metric_requests and inTable(path, self.CONF.monitor_switch.METRIC_COUNTER_RESPONSES) then
            self.metric_requests:inc(1, {self.CONF.app, path, "self", method, status})
        end

        if self.metric_traffic_out and inTable(path, self.CONF.monitor_switch.METRIC_COUNTER_SENT_BYTES) then
            self.metric_traffic_out:inc(tonumber(ngx.var.bytes_sent), {self.CONF.app, path, "self", method, status})
        end

        if self.metric_traffic_in and inTable(path, self.CONF.monitor_switch.METRIC_COUNTER_REVD_BYTES) then
            self.metric_traffic_in:inc(tonumber(ngx.var.request_length), {self.CONF.app, path, "self", method, status})
        end

        if self.metric_latency and inTable(path, self.CONF.monitor_switch.METRIC_HISTOGRAM_LATENCY) then
            local tm = (ngx.now() - ngx.req.start_time()) * 1000
            self.metric_latency:observe(tm, {self.CONF.app, path, "self", method})
        end
    end

    return true
end

function _M:latencyLog(time, module_name, api, method)
    if not self.metric_latency or not self.CONF.initted then
        return false
    end
    method = method or "GET"
    self.metric_latency:observe(time, {self.CONF.app, api, module_name, method})
    return true
end

function _M:counterLog(counter_ins, value, module_name, api, method, code)
    if not counter_ins or not self.CONF.initted then
        return false
    end
    counter_ins:inc(tonumber(value), {self.CONF.app, module_name, api, method, code})
    return true
end

function _M:qpsCounterLog(times, module_name, api, method, code)
    method = method or "GET"
    code = code or 200
    return self:counterLog(self.metric_requests, times, module_name, api, method, code)
end

function _M:sendBytesCounterLog(bytes, module_name, api, method, code)
    method = method or "GET"
    code = code or 200
    return self:counterLog(self.metric_traffic_out, bytes, module_name, api, method, code)
end

function _M:receiveBytesCounterLog(bytes, module_name, api, method, code)
    method = method or "GET"
    code = code or 200
    return self:counterLog(self.metric_traffic_in, bytes, module_name, api, method, code)
end

function _M:gaugeLog(value, state)
    if not self.metric_connections or not self.CONF.initted then
        return false
    end
    self.metric_connections:set(value, {self.CONF.app, state})
    return true
end

function _M:getPrometheus()
    if not self.CONF.initted then
        return nil, "init first.."
    end
    return self.prometheus
end

function _M:metrics()
    local ip = ngx.var.remote_addr or ""
    local st, _ = string.find(ip, ".", 1, true)
    local sub_ip = ip
    if st == nil then
        sub_ip = ip
    else
        sub_ip = string.sub(ip, 1, st-1)
    end

    if sub_ip ~= '10' and sub_ip ~= '172' then
        ngx.exit(ngx.HTTP_FORBIDDEN)
    end

    if not self.CONF.initted then
        ngx.say("init first..")
        ngx.exit(ngx.HTTP_OK)
    end

    if self.metric_connections and ngx.var.connections_reading and ngx.var.connections_waiting and ngx.var.connections_writing then
        self.metric_connections:set(ngx.var.connections_reading, {self.CONF.app, "reading"})
        self.metric_connections:set(ngx.var.connections_waiting, {self.CONF.app, "waiting"})
        self.metric_connections:set(ngx.var.connections_writing, {self.CONF.app, "writing"})
    end

    self.prometheus:collect()

    -- 合并下游自定义统计项, merge_path 需跟 metrics 在同一个server下
    if self.CONF.merge_path and type(self.CONF.merge_path) == "string" then
        local res = ngx.location.capture(self.CONF.merge_path)
        if res and res.status == 200 and type(res.body) == "string" and res.body then
            local newstr, _, err = ngx.re.gsub(res.body, "# (HELP|TYPE).*\n", "", "i")
            if newstr then
                ngx.say(newstr)
            else
                ngx.log(ngx.ERR, "error: ", err)
            end
        end
    end
end

return _M
