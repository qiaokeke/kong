local declarative = require("kong.db.declarative")
local concurrency = require("kong.concurrency")
local reports = require("kong.reports")
local errors = require("kong.db.errors")


local kong = kong
local ngx = ngx
local dc = declarative.new_config(kong.configuration)
local table = table
local tostring = tostring


-- Do not accept Lua configurations from the Admin API
-- because it is Turing-complete.
local accept = {
  yaml = true,
  json = true,
}

local _reports = {
  decl_fmt_version = false,
}


local function reports_timer(premature)
  if premature then
    return
  end

  reports.send("dbless-reconfigure", _reports)
end


return {
  ["/config"] = {
    GET = function(self, db)
      if kong.db.strategy ~= "off" then
        return kong.response.exit(400, {
          message = "this endpoint is only available when Kong is " ..
                    "configured to not use a database"
        })
      end

      local file = {
        buffer = {},
        write = function(self, str)
          self.buffer[#self.buffer + 1] = str
        end,
      }

      local ok, err = declarative.export_from_db(file)
      if not ok then
        kong.log.err("failed exporting config from cache: ", err)
        return kong.response.exit(500, { message = "An unexpected error occurred" })
      end

      return kong.response.exit(200, { config = table.concat(file.buffer) })
    end,
    POST = function(self, db)
      if kong.db.strategy ~= "off" then
        return kong.response.exit(400, {
          message = "this endpoint is only available when Kong is " ..
                    "configured to not use a database"
        })
      end

      local check_hash, old_hash
      if tostring(self.params.check_hash) == "1" then
        check_hash = true
        old_hash = declarative.get_current_hash()
      end
      self.params.check_hash = nil

      local dc_table, new_hash, err_t
      if self.params._format_version then
        dc_table, new_hash, err_t =
          dc:parse_table(self.params)
      else
        local config = self.params.config
        if not config then
          return kong.response.exit(400, {
            message = "expected a declarative configuration"
          })
        end
        dc_table, new_hash, err_t =
          dc:parse_string(config, nil, accept, old_hash)
      end

      if not dc_table then
        if check_hash and err_t and err_t.error == "configuration is identical" then
          return kong.response.exit(304)
        end
        return kong.response.exit(400, errors:declarative_config(err_t))
      end

      local ok, err = concurrency.with_worker_mutex({ name = "dbless-worker" }, function()
        return declarative.load_into_cache_with_events(dc_table, new_hash)
      end)

      if err == "no memory" then
        kong.log.err("not enough cache space for declarative config")
        return kong.response.exit(413, {
          message = "Configuration does not fit in Kong cache"
        })
      end

      if not ok then
        kong.log.err("failed loading declarative config into cache: ", err)
        return kong.response.exit(500, { message = "An unexpected error occurred" })
      end

      _reports.decl_fmt_version = dc_table._format_version
      _reports.decl_trans_en    = dc_table._transformations_enabled

      ngx.timer.at(0, reports_timer)

      local entities = {}
      for k, v in pairs(dc_table) do
        if k:sub(1,1) ~= "_" then
          entities[k] = v
        end
      end

      return kong.response.exit(201, entities)
    end,
  },
}
