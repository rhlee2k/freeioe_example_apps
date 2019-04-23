local ioe = require 'ioe'
local cjson = require 'cjson.safe'
local app_mqtt = require 'app.mqtt'

--- 创建应用（名称，最小API版本)
local app = app_mqtt("_TELIT_CLOUD_MQTT", 4)

function app:app_initialize(name, sys, conf)
	self._log:debug("Telit app intialize!!!")

	--- difference mqtt_initalize
	self._mqtt_id = conf.application_id or 'APPLICATION_ID'
	self._mqtt_username = sys:id()
	self._mqtt_password = conf.application_token or "APPLICATION_TOKEN"
	self._mqtt_host = conf.server or "device1-api.10646.cn"
	self._mqtt_port = conf.port or "1883"

	self._def_keys = conf.def_keys or {}
	self._def_key_default = string.lower(conf.def_key_default or 'ThingsLinkSimDevice')
	self._key_created = {}
	
end

function app:app_start()
	self._log:debug("Telit app start!!!")
	return true
end

function app:app_close(reason)
	self._log:debug("Telit app closed!!!")
	return true
end

function app:app_run(tms)
	self._log:debug("Telit run")

	return 10 * 1000 -- 10 seconds
end

function app:pack_devices(devices)
	for sn, props in pairs(devices) do
		self:on_add_device('__fake_name', sn, props)
	end
end

function app:on_add_device(src_app, sn, props)
	self._log:debug("Telit on_add_device")

	if not self:connected() then
		return
	end

	--[[
	if self._key_created[sn] then
		return
	end
	]]--

	local sysid = self._sys:id()
	if sn ~= sysid then
		local def_key = self._def_keys[sn]
		if not def_key and sysid == string.sub(sn, 1, string.len(sysid)) then
			local ssn = string.sub(sn, string.len(sysid) + 1)
			if ssn[1] == '.' then
				ssn = string.sub(ssn, 2)
			end
			def_key = self._def_keys[ssn]
		end
		def_key = def_key or self._def_key_default
		--[[
		{
  "cmd": {
    "command": "thing.create",
    "params": {
      "name": "My New Thing Name",
      "key": "12e692ba0f62g167",
      "defKey": "thingdefinitionkey",
      "desc": "Description of my new thing",
      "iccid": "123456789",
      "esn": "123456789",
      "tunnelActualHost": "192.168.4.241",
      "tunnelVirtualHost": "127.10.10.10",
      "tunnelLatencies": {
        "router01": 110,
        "router02": 340
      },
      "tags": ["tag1", "tag2"],
      "secTags": ["secTag1", "secTag2"],
      "attrs": {
        "attribute1key": {
          "value": "25",
          "ts": "2014-04-05T02:03:04.322Z"
        },
        "attribute2key": {
          "value": "Orange",
          "ts": "2014-04-05T02:03:04.322Z"
        }
      },
      "locEnabled": false
    }
  }
}
		--]]--
		local tags = {}
		local tag_map = {}
		for _, input in ipairs(props.inputs) do
			tag_map[input.name] = true
			tags[#tags + 1] = input.name
		end
		for _, output in ipairs(props.outputs or {}) do
			if not tag_map[output.name] then
				tag_map[input.name] = true
				tags[#tags + 1] = output.name
			end
		end
		local params = {
			name = props.meta.name or 'UNKNOWN',
			key = key_escape(sn),
			defKey = def_key,
			desc = props.meta.description or 'UNKNOWN',
			--tags = tags, -- disable tags for now
		}
		local cmd = {
			command = "thing.create",
			params = params,
		}
		local val, err = cjson.encode({cmd=cmd})
		if not val then
			self._log:warning('cjson encode failure. error: ', err)
			return true -- skip this data
		end

		self._log:trace(val)
		self._key_created[sn] = true
		return self:mqtt_publish("api", val, 1, false)
	end
	return true
end

function app:on_del_device(src_app, sn)
	self._log:debug("Telit on_del_device")
	return true
end

function app:on_mod_device(src_app, sn, props)
	self._log:debug("Telit on_mod_device")
	return true
end

function app:format_timestamp(timestamp)
	return string.format("%s.%03dZ", os.date('!%FT%T', timestamp//1), ((timestamp * 1000) % 1000))
end

local key_escape_entities = {
	['.'] = '__',
	['/'] = '___',
	['\\'] = '____',
}

function key_escape(text)
	text = text or ""
	return (text:gsub([=[[./\]]=], key_escape_entities))
end


function app:pack_key(src_app, sn, input)
	return key_escape(sn)..'.'..key_escape(input)
end

function app:publish_data(key, value, timestamp, quality)
	if not self:connected() then
		return nil, "MQTT connection lost!"
	end

	local sn, input = string.match(key, '^([^%.]+)%.(.+)$')
	assert(key and sn)
    local cmd = {
		command = "property.publish",
		params = {
			thingKey = sn,
			key = input,
			value = value,
			ts = self:format_timestamp(timestamp),
			--corrId = self._mqtt_username,
		}
	}
	local val, err = cjson.encode({cmd=cmd})
	if not val then
		self._log:warning('cjson encode failure. error: ', err)
		return true -- skip this data
	end

	self._log:trace(val)
	return self:mqtt_publish("api", val, 1, false)
end



--- The implementation for publish data in list (zip compressing required)
function app:publish_data_list(val_list)
	assert(val_list)

	local val_count = #val_list
	self._log:trace('publish_data_list begin',  #val_list)

	if val_count == 0 then
		return true
	end

	if not self:connected() then
		return nil, "MQTT connection lost!"
	end

--[[
{
  "cmd": {
    "command": "property.batch",
    "params": {
      "thingKey": "mything",
      "key": "myp",
      "ts" : "2018-04-05T02:03:04.322Z",
      "corrId": "mycorrid",
      "aggregate":true,
      "data": [
        {
          "key": "myprop",
          "value": 123.44,
          "ts": "2018-04-05T02:03:04.322Z",
          "corrId": "mycorrid"
        },
        {
          "key": "myprop2",
          "value": 42.12,
          "ts": "2018-04-05T02:03:04.322Z",
          "corrId": "mycorrid"
        }
      ]
    }
  }
}
]]--
	local data_list = {}
	local attr_list = {}
	for _, v in ipairs(val_list) do
		local sn, input = string.match(v[1], '^([^%.]+)%.(.+)$')

		if type(v[2]) ~= 'string' then
			if not data_list[sn] then
				data_list[sn] = {}
			end
			table.insert(data_list[sn], {
				key = input,
				value = v[2],
				ts = self:format_timestamp(v[3]),
				--corrId = self._mqtt_username,
			})
		else
			if not attr_list[sn] then
				attr_list[sn] = {}
			end
			table.insert(attr_list[sn], {
				key = input,
				value = v[2],
				ts = self:format_timestamp(v[3]),
			})
		end
	end

	for sn, data in pairs(data_list) do
		local cmd = {
			command = "property.batch",
			params = {
				thingKey = sn,
				--key = 'UNKNOW',
				--ts = self:format_timestamp(ioe.time()),
				data = data
			}
		}

		local val, err = cjson.encode({cmd=cmd})
		--print(val)
		if not val then
			self._log:warning('cjson encode failure. error: ', err)
			return true -- skip current datas
		end

		local deflated = self:compress(val)
		local r, err = self:mqtt_publish("apiz", deflated, 1, false)

		if not r then
			return nil, err
		end
	end

	for sn, data in pairs(attr_list) do
		local cmd = {
			command = "attribute.batch",
			params = {
				thingKey = sn,
				--key = 'UNKNOW',
				--ts = self:format_timestamp(ioe.time()),
				data = data
			}
		}

		local val, err = cjson.encode({cmd=cmd})
		--print(val)
		if not val then
			self._log:warning('cjson encode failure. error: ', err)
			return true -- skip current datas
		end

		local deflated = self:compress(val)
		local r, err = self:mqtt_publish("apiz", deflated, 1, false)

		if not r then
			return nil, err
		end
	end
	return true
end

-- no return
function app:on_connect_ok()
	self._log:debug("Telit on_connect_ok")
	self:subscribe('reply', 1)
	self:subscribe('replyz', 1)
end

function app:on_message(packet_id, topic, data, qos, retained)
	if topic == 'replyz' then
		local inflated, eof, bytes_in, bytes_out = self:decompress(data)
		data = inflated
	end
	self._log:trace('MQTT', topic, qos, retained, data)
end

--- 返回应用类对象
return app

