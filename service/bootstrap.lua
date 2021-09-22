local skynet = require "skynet"
local harbor = require "skynet.harbor"
local service = require "skynet.service"
require "skynet.manager"	-- import skynet.launch, ...

--skynet.start 这个函数的作用是设置了一个定时器延迟触发匿名函数
--并且设置这个actor的回调函数为lua函数，把消息的分发处理权力从c转移到了lua
skynet.start(function()
	local standalone = skynet.getenv "standalone"

	local launcher = assert(skynet.launch("snlua","launcher"))--启动launcher服务，以后其他的服务都由这个服务启动,这个是阻塞调用，直接拉起launcher
	skynet.name(".launcher", launcher)--cslave服务中，注册名字和句柄

	local harbor_id = tonumber(skynet.getenv "harbor" or 0)
	if harbor_id == 0 then--如果是非集群方式
		assert(standalone ==  nil)
		standalone = true
		skynet.setenv("standalone", "true")--服務器啓動時候有个全局的lua虚拟机来记录全局的环境变量这个就是设置全局的环境变量

		local ok, slave = pcall(skynet.newservice, "cdummy")--给launcher发一个消息啟動一個cdummy的服務这个就是异步得了，但是在携程中，会等到对方执行完返回消息才会继续往下走
		if not ok then
			skynet.abort()
		end
		skynet.name(".cslave", slave)

	else
		if standalone then
			if not pcall(skynet.newservice,"cmaster") then--如果是集群方式就再启动一个cmaster服务
				skynet.abort()
			end
		end

		local ok, slave = pcall(skynet.newservice, "cslave")--启动slave服务
		if not ok then
			skynet.abort()
		end
		skynet.name(".cslave", slave)
	end

	if standalone then
		local datacenter = skynet.newservice "datacenterd"--启动datacenterd服务
		skynet.name("DATACENTER", datacenter)
	end
	skynet.newservice "service_mgr"--启动service_mgr服务

	local enablessl = skynet.getenv "enablessl"--https的设置
	if enablessl then
		service.new("ltls_holder", function ()
			local c = require "ltls.init.c"
			c.constructor()
		end)
	end

	pcall(skynet.newservice,skynet.getenv "start" or "main")--如果设置start参数就运行参数指定的lua文件，不然就运行默认的example中的main.lua
	skynet.exit()
end)
