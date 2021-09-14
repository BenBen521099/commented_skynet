#ifndef SKYNET_IMP_H
#define SKYNET_IMP_H

struct skynet_config {
	int thread;//几个线程
	int harbor;//可以是 1-255 间的任意整数。一个 skynet 网络最多支持 255 个节点。每个节点有必须有一个唯一的编号如果 harbor 为 0 ，skynet 工作在单节点模式下。此时 master 和 address 以及 standalone 都不必设置
	int profile; //是否开启性能监控
	const char * daemon;//配置 daemon = "./skynet.pid" 可以以后台模式启动 skynet 。注意，同时请配置 logger 项输出 log
	const char * module_path;//模块的路径
	const char * bootstrap;//bootstrap 是启动的2个服务, 默认的 bootstrap 配置项为 "snlua bootstrap" ，这意味着，skynet 会启动 snlua 这个服务，并将 bootstrap 作为参数传给它。snlua 是 lua 沙盒服务，bootstrap 会根据配置的 luaservice 匹配到最终的 lua 脚本。如果按默认配置，这个脚本应该是 service/bootstrap.lua ,bootstrap最后一行会从config读取start配置项， 这个才是用户定义的启动脚本。作为用户定义的服务启动入口脚本运行。成功后，把自己退出
	const char * logger;//它决定了 skynet 内建的 skynet_error 这个 C API 将信息输出到什么文件中。如果 logger 配置为 nil ，将输出到标准输出，你可以指定一个路径和文件名，这样 “终端”输出的内容就写到日志中文件了
	const char * logservice;//日志服务
};
//线程的类型,这个要写进线程的私有数据中
#define THREAD_WORKER 0 //工作线程
#define THREAD_MAIN 1 //主线程
#define THREAD_SOCKET 2 //网络线程
#define THREAD_TIMER 3 //定时器线程
#define THREAD_MONITOR 4 //监控线程

void skynet_start(struct skynet_config * config);

#endif
