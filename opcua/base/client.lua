--- 导入需求的模块
local opcua = require 'opcua'
local class = require 'middleclass'

local client = class("APP_OPCUA_CLIENT_BASE")

function client:initialize(app, conf)
	self._app = app
	self._log = app._log
	self._sys = app._sys

	self._conf = conf

	self._sub_map = {}
	self._co_tasks = {}
end

function client:connected()
	return self._client ~= nil
end

---
-- Get the objects node (ns=0, i=85)
--
function client:get_objects_node()
	if not self._client then
		return nil, "Not connected"
	end
	return self._client:getObjectsNode()
end

---
-- Get the namespace index (number) by specified namespace string
-- e.g. http://opcfoundation.org/UA/ which is 0
--
function client:get_namespace_index(namespace)
	if not self._client then
		return nil, "Not connected"
	end
	return self._client:getNamesapceIndex(namespace)
end

--- Get the specified child from node by child_name
--  The child_name is <namespace id>:<browse name>
--  and you cloud append more child_name for deep finding
function client:get_child(node, child_name, ...)
	if not self._client then
		return nil, "Not connected"
	end
	return node:getChild(child_name, ...)
end

function client:get_node(ns, i)
	local opc_client = self._client

	if not opc_client then
		self._log:warning('no opc client', ns, i)
		return nil
	end

	-- Make sure all other functions are working well
	self._sys:sleep(0)

	local id = opcua.NodeId.new(ns, i)
	local obj, err = opc_client:getNode(id)
	if not obj then
		self._log:warning("Cannot get OPCUA node", ns, i)
	end
	self._log:debug('got input node', obj, ns, i)
	return obj, err
end

function client:get_node_by_id(id)
	local obj, err = self._client:getNode(id)
	if not obj then
		self._log:warning("Cannot get OPCUA node", id.ns, id.index)
	end
	self._log:debug('got input node', obj, id.ns, id.index)
	return obj, err
end

function client:read_value(node, vt)
	self._log:debug('reading node', node, vt, node and node.id)
	if not node then
		return nil
	end
	self._sys:sleep(0)

	local dv = node.dataValue

	return self:parse_value(dv, vt)
end

function client:write_value(node, vt, val)
	self._log:debug('writing node', node, vt, node and node.id)
	local val = assert(val, "value is missing")
	if vt == 'int' then
		val = math.floor(tonumber(val))
	elseif vt == 'float' then
		val = tonumber(val)
	else
		val = tostring(val)
	end
	if not val then
		return nil, "Value incorrect!!"
	end
	--- Write the value to node
	node.dataValue = opcua.DataValue.new(opcua.Variant.new(val))

	return true
end

function client:parse_value(data_value, vt)
	local dv = data_value

	--- Latest opcua binding support asValue function
	if dv.value.asValue then
		local value, err = dv.value:asValue()
		if value then
			if vt == 'int' then
				value = tonumber(value)
				if value then
					return math.floor(value)
				end
			end
			if vt == 'string' then
				value = tostring(value)
				if value then
					return value
				end
			end
			value = tonumber(value)
			if value then
				return value
			end
		else
			--self._log:debug('asValue failed', err)
			return nil, err
		end
	end

	if vt == 'int' then
		local value = dv.value:isNumeric() and dv.value:asLong() or dv.value:asString() or dv.value:asDateTime()
		if not value then
			return nil, "Value type incorrect"
		end

		value = tonumber(value)
		if not value then
			return nil, "Cannot convert to number"
		end

		return math.floor(value), dv.sourceTimestamp, dv.serverTimestamp
	end

	if vt == 'string' then
		local value = dv.value:asString() or dv.value:asDateTime()
		return value, dv.sourceTimestamp, dv.serverTimestamp
	end

	local value = dv.value:isNumeric() and dv.value:asDouble() or dv.value:asString() or dv.value:asDateTime()
	if not value then
		return nil, "Value type incorrect"
	end

	value = tonumber(value)
	if not value then
		return nil, "Cannot convert to number"
	end

	return value, dv.sourceTimestamp, dv.serverTimestamp
end

function client:on_connected()
	self._log:debug("default on connected callback")
	return true
end

function client:on_disconnected()
	self._log:debug("default on disconnected callback")
end

---
-- 连接处理函数
function client:connect_proc()
	local client = self._client_obj
	local conf = self._conf
	local sys = self._sys
	local log = self._log

	log:notice("OPC Client start connection!")

	client:setStateCallback(function(cli, state)
		table.insert(self._co_tasks, function()
			self._log:trace("Client state changed to", state, cli)
			if self._client_obj ~= cli then
				return
			end
			if state == opcua.UA_ClientState.DISCONNECTED then
				return self:on_disconnected()
			end
			if state == opcua.UA_ClientState.CONNECTED then
				return self:on_connected()
			end
		end)
	end)

	local ep = conf.endpoint or "opc.tcp://127.0.0.1:4840"
	--local ep = conf.endpoint or "opc.tcp://172.30.0.187:55623"
	--local ep = conf.endpoint or "opc.tcp://192.168.0.100:4840"
	log:info("Client connect endpoint", ep)

	local connect_opc = function()
		local r, err
		if conf.auth then
			if not self._client then
				log:info("Client connect with username&password")
			end
			r, err = client:connect_username(ep, conf.auth.username, conf.auth.password)
		else
			if not self._client then
				log:info("Client connect without username&password")
			end
			r, err = client:connect(ep)
		end

		if r and r == 0 then
			if not self._client then
				log:notice("OPC Client connect successfully!")
				self._client = client

				return true
			else
				return true
			end
		else
			err = err or opcua.getStatusCodeName(r)
			if self._client then
				log:error("OPC Client connect failure!", err)
				self._client = nil
			end
			return false, err
		end
	end

	local connect_delay = 1000
	while self._closing == nil and client and self._client_obj do
		-- call connect is save when client connected according to open62541 example
		local r, err = connect_opc()
		if not r then
			--- Connection Failed
			log:error("OPC Client disconnected!", err)
			sys:sleep(connect_delay)
			connect_delay = connect_delay * 2
			if connect_delay > 64000 then
				connect_delay = 1000
			end
		else
			--- Connection OK
			sys:sleep(10)

			connect_delay = 1000
			--- Client object run
			self._client_obj:run_iterate(50)

			--- Trigger all coroutine tasks
			for _, v in ipairs(self._co_tasks) do
				v(self)
				sys:sleep(0)
			end
			self._co_tasks = {}
		end
	end

	client:disconnect()
	log:notice("OPCUA connection closed")

	if self._closing then
		sys:wakeup(self._closing)
	end
end

function client:load_encryption(conf)
	local securityMode = nil
	if (conf.encryption.mode) then
		local mode = conf.encryption.mode
		if mode == 'SignAndEncrypt' then
			securityMode = opcua.UA_MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT
		end
		if mode == 'Sign' then
			securityMode = opcua.UA_MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGN
		end
		if mode == 'None' then
			securityMode = opcua.UA_MessageSecurityMode.UA_MESSAGESECURITYMODE_NONE
		end
	end

	local sys = self._sys
	local cert_file = sys:app_dir()..(conf.encryption.cert or "certs/cert.der")
	local key_file = sys:app_dir()..(conf.encryption.key or "certs/key.der")

	return {
		cert = cert_file,
		key = key_file,
		mode = securityMode,
	}
end

--- 应用启动函数
function client:connect()
	local conf = self._conf
	--conf.modal = conf.modal or default_modal

	local client_obj = nil

	if conf.encryption then
		local cp = self:load_encryption(conf)
		self._log:info("Create client with encryption", cp.mode, cp.cert, cp.key)
		client_obj = opcua.Client.new(cp.mode, cp.cert, cp.key)
	else
		self._log:info("Create client without encryption.")
		client_obj = opcua.Client.new()
	end

	local config = client_obj.config
	config:setTimeout(5000)
	config:setSecureChannelLifeTime(10 * 60 * 1000)

	local client_uri = conf.client_uri or "urn:freeioe:opcuaclient"
	config:setApplicationURI(client_uri)

	self._client_obj = client_obj

	--- 发起OpcUa连接
	self._sys:fork(function() self:connect_proc() end)

	return true
end

function client:disconnect()
	self._closing = {}
	self._sys:wait(self._closing)
	self._closing = nil
	return true
end

function client:create_subscription(inputs, callback)
	if not self._client then
		return nil, "Client not connected"
	end
	local sub_id, err = self._client:createSubscription(function(mon_id, data_value, sub_id)
		local m = self._sub_map[sub_id]
		if not m then
			return
		end
		local input = m[mon_id]
		if input then
			--- TODO: Using better way to implement this co tasks
			table.insert(self._co_tasks, function()
				local r, err = xpcall(callback, debug.traceback, input, data_value)
				if not r then
					self._log:warning("Failed to call callback", err)
				end
			end)
		end
	end)

	if not sub_id then
		return nil, err
	end

	local sub_map = {}
	local failed = {}
	for _, v in ipairs(inputs) do
		self._sys:sleep(0)
		local id = opcua.NodeId.new(v.ns, v.i)
		local node = self:get_node_by_id(id)
		if node then
			local mon_id, err = self._client:subscribeNode(sub_id, id)
			if mon_id then
				sub_map[mon_id] = v
			else
				self._log:warning("Failed to subscribe node", v.ns, v.i, err)
				table.insert(failed, v)
			end

			local r, err = xpcall(callback, debug.traceback, v, node.dataValue)
			if not r then
				self._log:warning("Failed to call callback", err)
			end
		end
	end

	self._sub_map[sub_id] = sub_map
	return #failed == 0, failed
end

--- 返回应用对象
return client

