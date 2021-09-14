#ifndef SKYNET_MODULE_H
#define SKYNET_MODULE_H

struct skynet_context;

typedef void * (*skynet_dl_create)(void);
typedef int (*skynet_dl_init)(void * inst, struct skynet_context *, const char * parm);
typedef void (*skynet_dl_release)(void * inst);
typedef void (*skynet_dl_signal)(void * inst, int signal);
//動態庫結構
struct skynet_module {
	const char * name;//動態庫名字
	void * module;//動態庫load之後的句柄
	//動態庫實現的函數
	skynet_dl_create create;
	skynet_dl_init init;
	skynet_dl_release release;
	skynet_dl_signal signal;
};
 //動態庫的函數指針類型
 //把动态库结构加入管理容器，这个函数没有被调用过
void skynet_module_insert(struct skynet_module *mod);
//创建actor时候根据名字查找这个模块
struct skynet_module * skynet_module_query(const char * name);
//创建actor时候实例化一个module对象
void * skynet_module_instance_create(struct skynet_module *);
//创建actor时候初始化一个module对象
int skynet_module_instance_init(struct skynet_module *, void * inst, struct skynet_context *ctx, const char * parm);
//释放一个module对象
void skynet_module_instance_release(struct skynet_module *, void *inst);
void skynet_module_instance_signal(struct skynet_module *, void *inst, int signal);

void skynet_module_init(const char *path);

#endif
