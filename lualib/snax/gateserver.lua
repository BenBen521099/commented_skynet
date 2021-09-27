local skynet = require "skynet"
local netpack = require "skynet.netpack"
local socketdriver = require "skynet.socketdriver"

local gateserver = {}

local socket	-- listen socket
local queue		-- message queue
local maxclient	-- max client
local client_number = 0
local CMD = setmetatable({}, { __gc = function() netpack.clear(queue) end })
local nodelay = false

local connection = {}
-- true : connected
-- nil : closed
-- false : close read
-- 打开句柄可以接收数据
function gateserver.openclient(fd)
	if connection[fd] then
		socketdriver.start(fd)
	end
end
--关闭句柄释放
function gateserver.closeclient(fd)
	local c = connection[fd]
	if c ~= nil then
		connection[fd] = nil
		socketdriver.close(fd)
	end
end

function gateserver.start(handler)
	assert(handler.message)
	assert(handler.connect)
    --管道的控制指令open
	--skynet.call(gate, "lua", "open" , {
	--	port = 8888,
	--	maxclient = 64,
	--	servername = "sample",
	--})
	function CMD.open( source, conf )
		assert(not socket)
		local address = conf.address or "0.0.0.0"
		local port = assert(conf.port)
		maxclient = conf.maxclient or 1024
		nodelay = conf.nodelay
		skynet.error(string.format("Listen on %s:%d", address, port))
		socket = socketdriver.listen(address, port)
		socketdriver.start(socket)
		if handler.open then
			return handler.open(source, conf)
		end
	end
    --关闭的指令
	function CMD.close()
		assert(socket)
		socketdriver.close(socket)
	end

	local MSG = {}
    --消息分发
	local function dispatch_msg(fd, msg, sz)
		if connection[fd] then
			handler.message(fd, msg, sz)--高层传进来的处理回调
		else
			skynet.error(string.format("Drop message from fd (%d) : %s", fd, netpack.tostring(msg,sz)))
		end
	end

	MSG.data = dispatch_msg

	local function dispatch_queue()
		local fd, msg, sz = netpack.pop(queue)
		if fd then
			-- may dispatch even the handler.message blocked
			-- If the handler.message never block, the queue should be empty, so only fork once and then exit.
			skynet.fork(dispatch_queue)
			dispatch_msg(fd, msg, sz)--循环处理消息

			for fd, msg, sz in netpack.pop, queue do
				dispatch_msg(fd, msg, sz)
			end
		end
	end

	MSG.more = dispatch_queue
    --有一个新的连接
	function MSG.open(fd, msg)
		if client_number >= maxclient then
			socketdriver.shutdown(fd)
			return
		end
		if nodelay then
			socketdriver.nodelay(fd)
		end
		connection[fd] = true
		client_number = client_number + 1
		handler.connect(fd, msg)--调用高层回调处理
	end
    --一个连接断掉
	function MSG.close(fd)
		if fd ~= socket then
			client_number = client_number - 1
			if connection[fd] then
				connection[fd] = false	-- close read
			end
			if handler.disconnect then
				handler.disconnect(fd)--调用高层回调处理
			end
		else
			socket = nil
		end
	end
    --一个连接返回错误
	function MSG.error(fd, msg)
		if fd == socket then
			skynet.error("gateserver accept error:",msg)
		else
			socketdriver.shutdown(fd)--关闭socket句柄
			if handler.error then
				handler.error(fd, msg)--调用上层处理
			end
		end
	end

	function MSG.warning(fd, size)
		if handler.warning then
			handler.warning(fd, size)--调用上层处理
		end
	end
    --注册socket消息类型，注册消息的分发函数MSG
	skynet.register_protocol {
		name = "socket",
		id = skynet.PTYPE_SOCKET,	-- PTYPE_SOCKET = 6
		unpack = function ( msg, sz )
			return netpack.filter( queue, msg, sz)
		end,
		dispatch = function (_, _, q, type, ...)
			queue = q
			if type then
				MSG[type](...)
			end
		end
	}

	local function init()
		--注册lua消息类型和相应的处理函数CMD,如果能处理自己处理，不能处理传到上层处理
		skynet.dispatch("lua", function (_, address, cmd, ...)
			local f = CMD[cmd]
			if f then
				skynet.ret(skynet.pack(f(address, ...)))
			else
				skynet.ret(skynet.pack(handler.command(cmd, address, ...)))
			end
		end)
	end

	if handler.embed then
		init()
	else
		skynet.start(init)
	end
end

return gateserver
