local msgserver = require "snax.msgserver"
local crypt = require "skynet.crypt"
local skynet = require "skynet"

local loginservice = tonumber(...)

local server = {}
local users = {}
local username_map = {}
local internal_id = 0

-- login server disallow multi login, so login_handler never be reentry
-- call by login server
-- 这个是loginserver调过来的？逻辑方面的事情不应该让gateserver来处理吧
-- secret loginserver传过来的加密码
-- uid loginserver传过来的角色ID
function server.login_handler(uid, secret)
	if users[uid] then
		error(string.format("%s is already login", uid))
	end

	internal_id = internal_id + 1--递增的ID？
	local id = internal_id	-- don't use internal_id directly
	local username = msgserver.username(uid, id, servername)--做一个字符串的拼接，拼出一个唯一的username

	-- you can use a pool to alloc new agent
	-- 创建一个新的服务msgagent
	local agent = skynet.newservice "msgagent"
	local u = {
		username = username,--拼接的唯一角色名
		agent = agent,--消息代理
		uid = uid,--loginserver传过来的唯一ID
		subid = id,--递增ID
	}

	-- trash subid (no used)
	skynet.call(agent, "lua", "login", uid, id, secret)

	users[uid] = u--保存uid和u的映射
	username_map[username] = u--保存username和u的映射

	msgserver.login(username, secret)--调用msgservre的登录函数？我靠为啥一个登录功能切分的如此支离破碎

	-- you should return unique subid
	return id
end

-- call by agent
-- agent调用登出？
function server.logout_handler(uid, subid)
	local u = users[uid]
	if u then
		local username = msgserver.username(uid, subid, servername)
		assert(u.username == username)
		msgserver.logout(u.username)
		users[uid] = nil
		username_map[u.username] = nil
		skynet.call(loginservice, "lua", "logout",uid, subid)--调用loginserver处理登出
	end
end

-- call by login server
-- loginserver调过来的负责踢出玩家
function server.kick_handler(uid, subid)
	local u = users[uid]
	if u then
		local username = msgserver.username(uid, subid, servername)
		assert(u.username == username)
		-- NOTICE: logout may call skynet.exit, so you should use pcall.
		pcall(skynet.call, u.agent, "lua", "logout")
	end
end

-- call by self (when socket disconnect)
-- socket关闭
function server.disconnect_handler(username)
	local u = username_map[username]
	if u then
		skynet.call(u.agent, "lua", "afk")
	end
end

-- call by self (when recv a request from client)
function server.request_handler(username, msg)
	local u = username_map[username]
	return skynet.tostring(skynet.rawcall(u.agent, "client", msg))
end

-- call by self (when gate open)
-- gate open 消息调用loginserver注册自己
function server.register_handler(name)
	servername = name
	skynet.call(loginservice, "lua", "register_gate", servername, skynet.self())
end

msgserver.start(server)

