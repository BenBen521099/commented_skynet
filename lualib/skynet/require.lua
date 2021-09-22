-- skynet module two-step initialize . When you require a skynet module :
-- 1. Run module main function as official lua module behavior.
-- 2. Run the functions register by skynet.init() during the step 1,
--      unless calling `require` in main thread .
-- If you call `require` in main thread ( service main function ), the functions
-- registered by skynet.init() do not execute immediately, they will be executed
-- by skynet.start() before start function.

local M = {}

local mainthread, ismain = coroutine.running()--返回当前运行的携程id，和是否是主携程
assert(ismain, "skynet.require must initialize in main thread")--如果不是主携程则报错

local context = {
	[mainthread] = {},
}

do
	local require = _G.require--在loader.lua调用了这个文件替换系统的require函数
	local loaded = package.loaded--用于记录那些模块已经被加载了
	local loading = {}

	function M.require(name)--以后所有的require都是走这个函数而不是标准的lua系统
		local m = loaded[name]--查看模块是否已经加载过了
		if m ~= nil then
			return m
		end

		local co, main = coroutine.running()
		if main then--如果在主携程中，利用系统的require函数加载模块
			return require(name)
		end
        --在配置的路径中寻找模块，如果找不到调用系统的require函数
		local filename = package.searchpath(name, package.path)
		if not filename then
			return require(name)
		end
        --加载文件，如果加载失败调用系统的require
		local modfunc = loadfile(filename)
		if not modfunc then
			return require(name)
		end
        --判断一个模块是否被多个携程同时加载，如果是的话就等待其他携程执行完
		local loading_queue = loading[name]
		if loading_queue then
			assert(loading_queue.co ~= co, "circular dependency")
			-- Module is in the init process (require the same mod at the same time in different coroutines) , waiting.
			local skynet = require "skynet"
			loading_queue[#loading_queue+1] = co
			skynet.wait(co)
			local m = loaded[name]--如果等待完，这个某块没有加载成功的话就退出
			if m == nil then
				error(string.format("require %s failed", name))
			end
			return m
		end

		loading_queue = {co = co}
		loading[name] = loading_queue

		local old_init_list = context[co]
		local init_list = {}
		context[co] = init_list

		-- We should call modfunc in lua, because modfunc may yield by calling M.require recursive.
		local function execute_module()
			local m = modfunc(name, filename)

			for _, f in ipairs(init_list) do
				f()
			end

			if m == nil then
				m = true
			end

			loaded[name] = m
		end

		local ok, err = xpcall(execute_module, debug.traceback)

		context[co] = old_init_list

		local waiting = #loading_queue
		if waiting > 0 then
			local skynet = require "skynet"
			for i = 1, waiting do
				skynet.wakeup(loading_queue[i])
			end
		end
		loading[name] = nil

		if ok then
			return loaded[name]
		else
			error(err)
		end
	end
end

function M.init_all()
	for _, f in ipairs(context[mainthread]) do
		f()
	end
	context[mainthread] = nil
end

function M.init(f)
	assert(type(f) == "function")
	local co = coroutine.running()
	table.insert(context[co], f)
end

return M