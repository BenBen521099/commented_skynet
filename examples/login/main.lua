local skynet = require "skynet"

skynet.start(function()
	--启动loginserver其中包含一个login_master，8个login_slave
	local loginserver = skynet.newservice("logind")
	--把login_master的句柄传给gate服务，主要是为了让gate服务网login服务去注册自己
	local gate = skynet.newservice("gated", loginserver)

	skynet.call(gate, "lua", "open" , {
		port = 8888,
		maxclient = 64,
		servername = "sample",
	})
end)
