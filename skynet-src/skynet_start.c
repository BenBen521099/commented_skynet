#include "skynet.h"
#include "skynet_server.h"
#include "skynet_imp.h"
#include "skynet_mq.h"
#include "skynet_handle.h"
#include "skynet_module.h"
#include "skynet_timer.h"
#include "skynet_monitor.h"
#include "skynet_socket.h"
#include "skynet_daemon.h"
#include "skynet_harbor.h"

#include <pthread.h>
#include <unistd.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

//监控线程的结构
struct monitor {
	int count;//工作线程数量
	struct skynet_monitor ** m;//每个工作线程对应一个skynet_monitor结构体存放工作线程的监控状态
	pthread_cond_t cond;//条件变量
	pthread_mutex_t mutex;//互斥锁
	int sleep;//睡眠的工作线程数量
	int quit;//是否退出工作线程，1退出，0继续工作
};

struct worker_parm {
	struct monitor *m;//监控的数据结构
	int id;//工作线程ID
	int weight;//处理消息的权重
};
//volatile修饰符的意思是，每次用到SIG这个值都要重新从内存读，这个值是随时在变化的
static volatile int SIG = 0;

static void
handle_hup(int signal) {
	if (signal == SIGHUP) {
		SIG = 1;
	}
}
//检查当前节点actor数量
#define CHECK_ABORT if (skynet_context_total()==0) break;

static void
create_thread(pthread_t *thread, void *(*start_routine) (void *), void *arg) {
	if (pthread_create(thread,NULL, start_routine, arg)) {
		fprintf(stderr, "Create thread failed");
		exit(1);
	}
}
//唤醒睡眠的工作线程
static void
wakeup(struct monitor *m, int busy) {
	if (m->sleep >= m->count - busy) {
		// signal sleep worker, "spurious wakeup" is harmless
		pthread_cond_signal(&m->cond);
	}
}

static void *
thread_socket(void *p) {
	struct monitor * m = p;
	skynet_initthread(THREAD_SOCKET);//设置线程类型标识
	for (;;) {
		int r = skynet_socket_poll();//处理所有的管道事件，一次处理一个epoll事件，也有可能epoll_wait时候阻塞在里面
		if (r==0)
			break;
		if (r<0) {
			//actor数量为0就退出线程
			CHECK_ABORT
			continue;
		}
		wakeup(m,0);//经过上面的操作，唤醒睡眠的线程干活了
	}
	return NULL;
}

static void
free_monitor(struct monitor *m) {
	int i;
	int n = m->count;
	for (i=0;i<n;i++) {
		skynet_monitor_delete(m->m[i]);
	}
	pthread_mutex_destroy(&m->mutex);
	pthread_cond_destroy(&m->cond);
	skynet_free(m->m);
	skynet_free(m);
}

static void *
thread_monitor(void *p) {
	struct monitor * m = p;
	int i;
	int n = m->count;
	skynet_initthread(THREAD_MONITOR);//设置线程私有数据
	for (;;) {
		CHECK_ABORT
		for (i=0;i<n;i++) {
			skynet_monitor_check(m->m[i]);//检查actor是否陷入了死循环
		}
		for (i=0;i<5;i++) {
			//actor数量为0就退出线程
			CHECK_ABORT
			sleep(1);
		}
	}

	return NULL;
}

static void
signal_hup() {
	// make log file reopen

	struct skynet_message smsg;
	smsg.source = 0;
	smsg.session = 0;
	smsg.data = NULL;
	smsg.sz = (size_t)PTYPE_SYSTEM << MESSAGE_TYPE_SHIFT;
	uint32_t logger = skynet_handle_findname("logger");
	if (logger) {
		skynet_context_push(logger, &smsg);
	}
}

static void *
thread_timer(void *p) {
	struct monitor * m = p;
	skynet_initthread(THREAD_TIMER);
	for (;;) {
		skynet_updatetime();//遍历定时器容器执行到期的定时器
		skynet_socket_updatetime();//没做啥就是复制当前时间到socket_server的time属性
		//actor数量为0就退出线程
		CHECK_ABORT
		wakeup(m,m->count-1);//经过上面的操作，唤醒睡眠的工作线程，开始工作
		usleep(2500);
		if (SIG) {//如果终端关了，打开日志文件
			signal_hup();
			SIG = 0;
		}
	}
	//如果定时器线程退出了，唤醒socket线程和工作线程让他们自己根据quit标识，自己退出
	// wakeup socket thread
	skynet_socket_exit();
	// wakeup all worker thread
	pthread_mutex_lock(&m->mutex);
	m->quit = 1;
	pthread_cond_broadcast(&m->cond);
	pthread_mutex_unlock(&m->mutex);
	return NULL;
}
//工作线程，主要负责从全局有消息的actor列表中获取actor，从列表中移除，然后按权重来处理这个接口里面的消息
//处理一部分消息之后如果还有剩余消息再把actor加入全局列表，保证同一时间，这个actor只有一个线程再运行他的处理函数，避免了多线程加锁问题
static void *
thread_worker(void *p) {
	struct worker_parm *wp = p;
	int id = wp->id;
	int weight = wp->weight;
	struct monitor *m = wp->m;
	struct skynet_monitor *sm = m->m[id];//获取对应的监控结构
	skynet_initthread(THREAD_WORKER);//设置线程标识
	struct message_queue * q = NULL;
	while (!m->quit) {//死循环直到退出指令 
		q = skynet_context_message_dispatch(sm, q, weight);//核心函数分发处理消息
		if (q == NULL) {
			if (pthread_mutex_lock(&m->mutex) == 0) {
				++ m->sleep;
				// "spurious wakeup" is harmless,
				// because skynet_context_message_dispatch() can be call at any time.
				if (!m->quit)
					pthread_cond_wait(&m->cond, &m->mutex);
				-- m->sleep;
				if (pthread_mutex_unlock(&m->mutex)) {
					fprintf(stderr, "unlock mutex error");
					exit(1);
				}
			}
		}
	}
	return NULL;
}

static void
start(int thread) {
	pthread_t pid[thread+3];//除了工作线程，还有监控，定时器，网络三个线程

	struct monitor *m = skynet_malloc(sizeof(*m));
	memset(m, 0, sizeof(*m));
	m->count = thread;
	m->sleep = 0;

	m->m = skynet_malloc(thread * sizeof(struct skynet_monitor *));
	int i;
	for (i=0;i<thread;i++) {
		m->m[i] = skynet_monitor_new();
	}
	if (pthread_mutex_init(&m->mutex, NULL)) {
		fprintf(stderr, "Init mutex error");
		exit(1);
	}
	if (pthread_cond_init(&m->cond, NULL)) {
		fprintf(stderr, "Init cond error");
		exit(1);
	}

	create_thread(&pid[0], thread_monitor, m);//创建监控线程
	create_thread(&pid[1], thread_timer, m); //创建定时器线程
	create_thread(&pid[2], thread_socket, m);//创建网络线程
    //工作线程一次处理消息数量的权重
	static int weight[] = { 
		-1, -1, -1, -1, 0, 0, 0, 0,
		1, 1, 1, 1, 1, 1, 1, 1, 
		2, 2, 2, 2, 2, 2, 2, 2, 
		3, 3, 3, 3, 3, 3, 3, 3, };
	struct worker_parm wp[thread];
	for (i=0;i<thread;i++) {
		wp[i].m = m;
		wp[i].id = i;
		if (i < sizeof(weight)/sizeof(weight[0])) {
			wp[i].weight= weight[i];
		} else {
			wp[i].weight = 0;
		}
		create_thread(&pid[i+3], thread_worker, &wp[i]);
	}
    //主线程会阻塞到这里直到所有线程都返回，如果这么看的话这个架构线程数量是没有办法动态的增加和减少的
	for (i=0;i<thread+3;i++) {
		pthread_join(pid[i], NULL); 
	}

	free_monitor(m);
}

static void
bootstrap(struct skynet_context * logger, const char * cmdline) {
	int sz = strlen(cmdline);
	char name[sz+1];
	char args[sz+1];
	int arg_pos;
	sscanf(cmdline, "%s", name);  
	arg_pos = strlen(name);
	if (arg_pos < sz) {
		while(cmdline[arg_pos] == ' ') {
			arg_pos++;
		}
		strncpy(args, cmdline + arg_pos, sz);
	} else {
		args[0] = '\0';
	}
	//在创建一个actor
	struct skynet_context *ctx = skynet_context_new(name, args);
	if (ctx == NULL) {
		skynet_error(NULL, "Bootstrap error : %s\n", cmdline);
		skynet_context_dispatchall(logger);
		exit(1);
	}
}

void 
skynet_start(struct skynet_config * config) {
	// register SIGHUP for log file reopen
	// 接管SIGHUP信号处理，这个信号量的意思是就是如果终端关闭了就向终端关联的进程发这个信号
	// 我们接到这个信号就在定时器线程打开日志文件把日志定向到日志文件
	struct sigaction sa;
	sa.sa_handler = &handle_hup;
	sa.sa_flags = SA_RESTART;
	sigfillset(&sa.sa_mask);
	sigaction(SIGHUP, &sa, NULL);

    //如果配置了守护进程，就在这里fork一个新的进程，然后老的进程退出，新的进程就是终端shell进程完全脱离了关系成为了孤儿进程
	if (config->daemon) {
		if (daemon_init(config->daemon)) {
			exit(1);
		}
	}
	//利用harbor初始化全局节点编号
	skynet_harbor_init(config->harbor);
	//初始化handle_storage，這裡存放以後所有的actor對象
	skynet_handle_init(config->harbor);
	//初始化全局有消息的actor的列表
	skynet_mq_init();
	//初始化動態庫管理容器，並把路徑地址記錄下來，但是並沒有加載這些動態庫
	skynet_module_init(config->module_path);
	//初始化全局定時器容器，並沒有啟動線程
	skynet_timer_init();
	//初始化全局的socket管理對象，包括創建epoll句柄，管道句柄，初始化每個socket管理結構
	skynet_socket_init();
	//設置是否開啟性能监控
	skynet_profile_enable(config->profile);
    //创建一个actor，这个很重要我们第一次接触如何创建一个skynet的核心数据结构
	struct skynet_context *ctx = skynet_context_new(config->logservice, config->logger);
	if (ctx == NULL) {
		fprintf(stderr, "Can't launch %s service\n", config->logservice);
		exit(1);
	}
    //把名字和handle存入全局容器
	skynet_handle_namehandle(skynet_context_handle(ctx), "logger");
    //根据bootstrap参数再创建一个actor
	bootstrap(ctx, config->bootstrap);
    //开启监控，日志，定时器和工作线程
	start(config->thread);

	// harbor_exit may call socket send, so it should exit before socket_free
	skynet_harbor_exit();
	skynet_socket_free();
	if (config->daemon) {
		daemon_exit(config->daemon);
	}
}
