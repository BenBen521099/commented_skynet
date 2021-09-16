#ifndef poll_socket_epoll_h
#define poll_socket_epoll_h

#include <netdb.h>
#include <unistd.h>
#include <sys/epoll.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>

static bool 
sp_invalid(int efd) {
	return efd == -1;
}

static int
sp_create() {
	return epoll_create(1024);
}

static void
sp_release(int efd) {
	close(efd);
}

static int 
sp_add(int efd, int sock, void *ud) {
	struct epoll_event ev;
	ev.events = EPOLLIN;//居然使用效率更低的水平触发模式
	ev.data.ptr = ud;
	if (epoll_ctl(efd, EPOLL_CTL_ADD, sock, &ev) == -1) {
		return 1;
	}
	return 0;
}

static void 
sp_del(int efd, int sock) {
	epoll_ctl(efd, EPOLL_CTL_DEL, sock , NULL);
}

static int
sp_enable(int efd, int sock, void *ud, bool read_enable, bool write_enable) {
	struct epoll_event ev;
	ev.events = (read_enable ? EPOLLIN : 0) | (write_enable ? EPOLLOUT : 0);
	ev.data.ptr = ud;
	if (epoll_ctl(efd, EPOLL_CTL_MOD, sock, &ev) == -1) {
		return 1;
	}
	return 0;
}

static int 
sp_wait(int efd, struct event *e, int max) {
	struct epoll_event ev[max];
	int n = epoll_wait(efd , ev, max, -1);
	int i;
	for (i=0;i<n;i++) {
		e[i].s = ev[i].data.ptr;
		unsigned flag = ev[i].events;
		e[i].write = (flag & EPOLLOUT) != 0;
		e[i].read = (flag & EPOLLIN) != 0;
		e[i].error = (flag & EPOLLERR) != 0;
		e[i].eof = (flag & EPOLLHUP) != 0;
	}

	return n;
}

static void
sp_nonblocking(int fd) {
	int flag = fcntl(fd, F_GETFL, 0);
	if ( -1 == flag ) {
		return;
	}
    //在读操作时，如果读不到数据，O_NDELAY会使I/O函数马上返回0，但这又衍生出一个问题，因为读取到文件末尾(EOF)时返回的也是0，这样无法区分是哪种情况。因此，O_NONBLOCK就产生出来，它在读取不到数据时会回传-1，并且设置errno为EAGAIN。
	//在发送的时候O_NDELAY会使得tcp协议栈不要凑大包，马上把目前数据发送出去
	fcntl(fd, F_SETFL, flag | O_NONBLOCK);
}

#endif
