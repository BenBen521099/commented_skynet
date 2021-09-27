local login = require "snax.loginserver"
local crypt = require "skynet.crypt"
local skynet = require "skynet"

local server = {
	host = "127.0.0.1",
	port = 8001,
	multilogin = false,	-- disallow multilogin
	name = "login_master",
}

local server_list = {}
local user_online = {}
local user_login = {}
--解析token返回server和user
function server.auth_handler(token)
	-- the token is base64(user)@base64(server):base64(password)
	local user, server, password = token:match("([^@]+)@([^:]+):(.+)")
	user = crypt.base64decode(user)
	server = crypt.base64decode(server)
	password = crypt.base64decode(password)
	assert(password == "password", "Invalid password")
	return server, user
end
--玩家登录操作
function server.login_handler(server, uid, secret)
	print(string.format("%s@%s is login, secret is %s", uid, server, crypt.hexencode(secret)))
	local gameserver = assert(server_list[server], "Unknown server")
	-- only one can login, because disallow multilogin
	--只有一个可以登陆，如果发现玩家已经登陆了就踢掉之前的
	local last = user_online[uid]
	if last then
		skynet.call(last.address, "lua", "kick", uid, last.subid)
	end
	if user_online[uid] then
		error(string.format("user %s is already online", uid))
	end
    --调用gameserver完成登录
	local subid = tostring(skynet.call(gameserver, "lua", "login", uid, secret))
	--记录下来登录信息
	user_online[uid] = { address = gameserver, subid = subid , server = server}
	return subid
end

local CMD = {}
--gateserver调过来的，注册gateserver
function CMD.register_gate(server, address)
	server_list[server] = address--server_list到底存的gameserver还是gateserver？这么混乱是云风写的代码么？
end
--玩家登出
function CMD.logout(uid, subid)
	local u = user_online[uid]
	if u then
		print(string.format("%s@%s is logout", uid, u.server))
		user_online[uid] = nil
	end
end

function server.command_handler(command, ...)
	local f = assert(CMD[command])
	return f(...)
end

login(server)
