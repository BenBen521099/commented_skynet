local args = {}--存放传进来的参数
for word in string.gmatch(..., "%S+") do--拆分参数放入table中
	table.insert(args, word)
	print(word)
end

SERVICE_NAME = args[1]--默认第一个参数是服务名

local main, pattern

local err = {}
for pat in string.gmatch(LUA_SERVICE, "([^;]+);*") do--拆分服务名，服务名也是有规则的不然拆不出来文件名
	local filename = string.gsub(pat, "?", SERVICE_NAME)
	print("filename="..filename)
	local f, msg = loadfile(filename)
	if not f then
		table.insert(err, msg)
	else
		pattern = pat
		main = f--服务的启动函数名
		break
	end
end

if not main then
	error(table.concat(err, "\n"))
end

LUA_SERVICE = nil
package.path , LUA_PATH = LUA_PATH--lua的文件路径
package.cpath , LUA_CPATH = LUA_CPATH--c动态库的文件路径

local service_path = string.match(pattern, "(.*/)[^/?]+$")

if service_path then
	service_path = string.gsub(service_path, "?", args[1])
	package.path = service_path .. "?.lua;" .. package.path
	SERVICE_PATH = service_path
else
	local p = string.match(pattern, "(.*/).+$")
	SERVICE_PATH = p
end

if LUA_PRELOAD then
	local f = assert(loadfile(LUA_PRELOAD))
	f(table.unpack(args))
	LUA_PRELOAD = nil
end

_G.require = (require "skynet.require").require

main(select(2, table.unpack(args)))--调用真的处理函数
