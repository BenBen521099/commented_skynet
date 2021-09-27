local skynet = require "skynet"
require "skynet.manager"
local socket = require "skynet.socket"
local crypt = require "skynet.crypt"
local table = table
local string = string
local assert = assert

--[[

Protocol:

	line (\n) based text protocol

	1. Server->Client : base64(8bytes random challenge)
	2. Client->Server : base64(8bytes handshake client key)
	3. Server: Gen a 8bytes handshake server key
	4. Server->Client : base64(DH-Exchange(server key))
	5. Server/Client secret := DH-Secret(client key/server key)
	6. Client->Server : base64(HMAC(challenge, secret))
	7. Client->Server : DES(secret, base64(token))
	8. Server : call auth_handler(token) -> server, uid (A user defined method)
	9. Server : call login_handler(server, uid, secret) ->subid (A user defined method)
	10. Server->Client : 200 base64(subid)

Error Code:
	401 Unauthorized . unauthorized by auth_handler
	403 Forbidden . login_handler failed
	406 Not Acceptable . already in login (disallow multi login)

Success:
	200 base64(subid)
]]

local socket_error = {}
local function assert_socket(service, v, fd)
	if v then
		return v
	else
		skynet.error(string.format("%s failed: socket (fd = %d) closed", service, fd))
		error(socket_error)
	end
end

local function write(service, fd, text)
	assert_socket(service, socket.write(fd, text), fd)
end

local function launch_slave(auth_handler)
	print("launch_slave")
	--鉴权验证
	local function auth(fd, addr)
		-- set socket buffer limit (8K)
		-- If the attacker send large package, close the socket
		socket.limit(fd, 8192)--lua层面设置fd的包大小

		local challenge = crypt.randomkey()--生成一个随机数
		write("auth", fd, crypt.base64encode(challenge).."\n")--把这个随机数base64发给客户端

		local handshake = assert_socket("auth", socket.readline(fd), fd)--从fd读取握手数据
		local clientkey = crypt.base64decode(handshake)
		if #clientkey ~= 8 then
			error "Invalid client key"
		end
		local serverkey = crypt.randomkey()
		write("auth", fd, crypt.base64encode(crypt.dhexchange(serverkey)).."\n")

		local secret = crypt.dhsecret(clientkey, serverkey)

		local response = assert_socket("auth", socket.readline(fd), fd)
		local hmac = crypt.hmac64(challenge, secret)

		if hmac ~= crypt.base64decode(response) then
			error "challenge failed"
		end

		local etoken = assert_socket("auth", socket.readline(fd),fd)

		local token = crypt.desdecode(secret, crypt.base64decode(etoken))

		local ok, server, uid =  pcall(auth_handler,token)--生成了token调用server.auth_handler(token)（logind）

		return ok, server, uid, secret
	end
    --返回一个包
	local function ret_pack(ok, err, ...)
		if ok then
			return skynet.pack(err, ...)
		else
			if err == socket_error then
				return skynet.pack(nil, "socket error")
			else
				return skynet.pack(false, err)
			end
		end
	end
    --对fd进行鉴权
	local function auth_fd(fd, addr)
		skynet.error(string.format("connect from %s (fd = %d)", addr, fd))
		socket.start(fd)	-- may raise error here，调用epoll增加read事件从这开始才能读取数据
		local msg, len = ret_pack(pcall(auth, fd, addr))
		socket.abandon(fd)	-- never raise error here
		return msg, len
	end

	skynet.dispatch("lua", function(_,_,...)
		local ok, msg, len = pcall(auth_fd, ...)
		if ok then
			skynet.ret(msg,len)
		else
			skynet.ret(skynet.pack(false, msg))
		end
	end)
end

local user_login = {}
--conf logind.lua中相应的对象，s slave login，fd socket句柄 addr对方的地址
local function accept(conf, s, fd, addr)
	-- call slave auth
	local ok, server, uid, secret = skynet.call(s, "lua",  fd, addr)--调用slave的处理函数
	-- slave will accept(start) fd, so we can write to fd later

	if not ok then
		if ok ~= nil then
			write("response 401", fd, "401 Unauthorized\n")
		end
		error(server)
	end
    --判断重复登录
	if not conf.multilogin then
		if user_login[uid] then
			write("response 406", fd, "406 Not Acceptable\n")
			error(string.format("User %s is already login", uid))
		end

		user_login[uid] = true
	end
    --调用logind.lua 中的login_handler
	local ok, err = pcall(conf.login_handler, server, uid, secret)
	-- unlock login
	user_login[uid] = nil
    --返回一个登录回应
	if ok then
		err = err or ""
		write("response 200",fd,  "200 "..crypt.base64encode(err).."\n")
	else
		write("response 403",fd,  "403 Forbidden\n")
		error(err)
	end
end
--启动login的主服务
local function launch_master(conf)
	print("launch_master")
	local instance = conf.instance or 8--如果没有设置就启动8个slave
	assert(instance > 0)
	local host = conf.host or "0.0.0.0"--得到地址
	local port = assert(tonumber(conf.port))--得到端口
	local slave = {}
	local balance = 1--是否负载均衡
    --收到的消息直接使用command_handler进行处理然后打包返回
	skynet.dispatch("lua", function(_,source,command, ...)
		skynet.ret(skynet.pack(conf.command_handler(command, ...)))
	end)

	for i=1,instance do
		print("SERVICE_NAME"..SERVICE_NAME)
		table.insert(slave, skynet.newservice(SERVICE_NAME))--生成8个logind,因为这次是master剩余的8个就是slave调用launch_slave
	end

	skynet.error(string.format("login server listen at : %s %d", host, port))--127.0.0.1 8001
	local id = socket.listen(host, port)--生成一个socketid绑定对应的IP和端口
	socket.start(id , function(fd, addr)--必须调用这个接口才能开始接受消息
		local s = slave[balance]--一个简单地负载均衡
		balance = balance + 1
		if balance > #slave then
			balance = 1
		end
		local ok, err = pcall(accept, conf, s, fd, addr)--调用接受socket连接
		if not ok then
			if err ~= socket_error then
				skynet.error(string.format("invalid client (fd = %d) error = %s", fd, err))
			end
		end
		socket.close_fd(fd)	-- We haven't call socket.start, so use socket.close_fd rather than socket.close.
	end)
end
--conf logind.lua 相应的处理句柄，这个函数logind调过来的
local function login(conf)
	local name = "." .. (conf.name or "login")
	skynet.start(function()
		local loginmaster = skynet.localname(name)--先用服务名字查服务句柄
		if loginmaster then
			local auth_handler = assert(conf.auth_handler)--logind负责解析client传过来的token
			launch_master = nil
			conf = nil
			launch_slave(auth_handler)
		else--如果这个服务还没有
			launch_slave = nil
			conf.auth_handler = nil
			assert(conf.login_handler)
			assert(conf.command_handler)
			skynet.register(name)--注册自己，和这个名字建立联系.login_master
			launch_master(conf)--启动login的主服务
		end
	end)
end

return login
