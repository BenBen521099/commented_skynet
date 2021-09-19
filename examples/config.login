--开8个工作线程
thread = 8
--不需要指定日志文件，直接输出到终端
logger = nil
--不需要开启主从模式
harbor = 0
--
start = "main"
bootstrap = "snlua bootstrap"	-- The service for bootstrap
luaservice = "./service/?.lua;./examples/login/?.lua"
lualoader = "lualib/loader.lua"--前期加载lua文件
cpath = "./cservice/?.so"
