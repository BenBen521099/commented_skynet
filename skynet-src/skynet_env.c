#include "skynet.h"
#include "skynet_env.h"
#include "spinlock.h"

#include <lua.h>
#include <lauxlib.h>

#include <stdlib.h>
#include <assert.h>

struct skynet_env {
	struct spinlock lock;//自旋锁
	lua_State *L;//lua虚拟机地址
};

static struct skynet_env *E = NULL; //全局的环境变量指针，写c和c++很不同的是c大量的用了这种全局的静态变量，c++的代码风格很少这么写。取而代之的是工厂模式，单例模式
                                    //这种封装层次更高的写法

const char * 
skynet_getenv(const char *key) {
	SPIN_LOCK(E)

	lua_State *L = E->L;
	
	lua_getglobal(L, key);
	const char * result = lua_tostring(L, -1);
	lua_pop(L, 1);

	SPIN_UNLOCK(E)

	return result;
}

void 
skynet_setenv(const char *key, const char *value) {
	SPIN_LOCK(E)
	
	lua_State *L = E->L;
	lua_getglobal(L, key);
	assert(lua_isnil(L, -1));
	lua_pop(L,1);
	lua_pushstring(L,value);
	lua_setglobal(L,key);

	SPIN_UNLOCK(E)
}

void
skynet_env_init() {
	E = skynet_malloc(sizeof(*E));//分配一个环境变量的结构
	SPIN_INIT(E)//初始化自旋锁
	E->L = luaL_newstate();//生成一个lua虚拟机，这个是不是初始化的有点早？
}
