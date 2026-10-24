#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <sys/select.h>

static int (*real_connect)(int, const struct sockaddr*, socklen_t);
static uint16_t g_port = 48416;
static char g_host[64] = "127.0.0.1";
static const char* g_log = "/var/log/tuxler/socks5shim.log";
#define HS_TIMEOUT 15   /* seconds, handshake only */

static void logline(const char* fmt, ...) {
    char buf[512];
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n <= 0) return;
    if (n > (int)sizeof buf) n = sizeof buf;
    int fd = open(g_log, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) { write(fd, buf, (size_t)n); close(fd); }
}

__attribute__((constructor))
static void init_shim(void) {
    real_connect = dlsym(RTLD_NEXT, "connect");
    const char* p = getenv("SHIM_SOCKS_PORT");
    if (p && atoi(p) > 0) g_port = (uint16_t)atoi(p);
    const char* h = getenv("SHIM_SOCKS_HOST");
    if (h && strlen(h) < sizeof g_host) strcpy(g_host, h);
    const char* l = getenv("SHIM_LOG");
    if (l && strlen(l) > 0) g_log = l;
    logline("init pid=%d socks=%s:%d\n", getpid(), g_host, g_port);
}

static int v4_bypass(uint32_t ip_be) {
    uint32_t ip = ntohl(ip_be);
    uint8_t a = (uint8_t)(ip >> 24), b = (uint8_t)(ip >> 16);
    if (a == 127 || a == 0) return 1;
    if (a == 10) return 1;
    if (a == 172 && b >= 16 && b <= 31) return 1;
    if (a == 192 && b == 168) return 1;
    if (a == 169 && b == 254) return 1;
    if (a == 100 && b >= 64 && b <= 127) return 1;
    return 0;
}

static int should_bypass(const struct sockaddr* a) {
    if (a->sa_family == AF_INET)
        return v4_bypass(((const struct sockaddr_in*)a)->sin_addr.s_addr);
    if (a->sa_family == AF_INET6) {
        const unsigned char* p = (const unsigned char*)&((const struct sockaddr_in6*)a)->sin6_addr;
        static const unsigned char loop[16] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1};
        if (memcmp(p, loop, 16) == 0) return 1;
        if (p[0] == 0xfe && (p[1] & 0xc0) == 0x80) return 1;
        if (p[0] == 0xfc || p[0] == 0xfd) return 1;
        if (memcmp(p, "\0\0\0\0\0\0\0\0\0\0\0\xff\xff", 12) == 0)
            return v4_bypass(*(const uint32_t*)(p + 12));
        return 1; /* other IPv6: no tunnel, don't leak either */
    }
    /* AF_UNIX (wineserver IPC), AF_NETLINK, etc: NEVER proxy. */
    return 1;
}

static int waitfd(int fd, int for_write, int sec) {
    fd_set s; struct timeval tv;
    FD_ZERO(&s); FD_SET(fd, &s);
    tv.tv_sec = sec; tv.tv_usec = 0;
    int r = select(fd + 1, for_write ? NULL : &s, for_write ? &s : NULL, NULL, &tv);
    return r > 0 ? 0 : -1;
}

static ssize_t send_all(int fd, const void* buf, size_t n) {
    size_t sent = 0;
    while (sent < n) {
        ssize_t r = send(fd, (const char*)buf + sent, n - sent, MSG_NOSIGNAL);
        if (r > 0) { sent += (size_t)r; continue; }
        if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (waitfd(fd, 1, HS_TIMEOUT) == 0) continue;
        }
        return -1;
    }
    return (ssize_t)sent;
}

static ssize_t recv_all(int fd, void* buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = recv(fd, (char*)buf + got, n - got, 0);
        if (r > 0) { got += (size_t)r; continue; }
        if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (waitfd(fd, 0, HS_TIMEOUT) == 0) continue;
        }
        if (r == 0) errno = ECONNRESET;
        return -1;
    }
    return (ssize_t)got;
}

static int socks5_connect(int fd, const struct sockaddr* tgt) {
    struct sockaddr_in sin;
    memset(&sin, 0, sizeof sin);
    sin.sin_family = AF_INET;
    sin.sin_port = htons(g_port);
    if (inet_pton(AF_INET, g_host, &sin.sin_addr) != 1) {
        errno = EINVAL; return -1;
    }

    /* keepalive: keeps carrier NAT from dropping long-lived relays */
    int optval = 1;
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &optval, sizeof optval);
#ifdef TCP_KEEPIDLE
    int idle = 30, intvl = 10, cnt = 4;
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof idle);
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof intvl);
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof cnt);
#endif

    /* handshake on a non-blocking socket with select timeouts;
       original flags restored before handing the fd back to the app */
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);

    int rc = -1;
    unsigned char b[512];
    if (real_connect(fd, (struct sockaddr*)&sin, sizeof sin) != 0 &&
        errno != EINPROGRESS) goto out;

    if (waitfd(fd, 1, HS_TIMEOUT) != 0) { errno = ETIMEDOUT; goto out; }
    int soerr = 0; socklen_t sl = sizeof soerr;
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl) != 0 || soerr != 0) {
        errno = soerr ? soerr : ECONNREFUSED; goto out;
    }

    unsigned char hello[3] = {5, 1, 0};
    if (send_all(fd, hello, 3) != 3) goto out;
    if (recv_all(fd, b, 2) != 2 || b[0] != 5 || b[1] != 0) {
        if (errno != ETIMEDOUT && errno != ECONNRESET) errno = ECONNREFUSED;
        goto out;
    }

    unsigned char req[22];
    int rlen = 0;
    req[0] = 5; req[1] = 1; req[2] = 0;
    if (tgt->sa_family == AF_INET) {
        const struct sockaddr_in* t = (const void*)tgt;
        req[3] = 1;
        memcpy(req + 4, &t->sin_addr.s_addr, 4);
        memcpy(req + 8, &t->sin_port, 2);
        rlen = 10;
    } else if (tgt->sa_family == AF_INET6) {
        const struct sockaddr_in6* t = (const void*)tgt;
        req[3] = 4;
        memcpy(req + 4, &t->sin6_addr, 16);
        memcpy(req + 20, &t->sin_port, 2);
        rlen = 22;
    } else { errno = EAFNOSUPPORT; goto out; }

    if (send_all(fd, req, (size_t)rlen) != rlen) goto out;
    if (recv_all(fd, b, 4) != 4 || b[1] != 0) {
        if (errno != ETIMEDOUT && errno != ECONNRESET) errno = ECONNREFUSED;
        goto out;
    }
    if (b[3] == 1) { if (recv_all(fd, b, 6) != 6) goto out; }
    else if (b[3] == 4) { if (recv_all(fd, b, 18) != 18) goto out; }
    else if (b[3] == 3) {
        unsigned char dl;
        if (recv_all(fd, &dl, 1) != 1) goto out;
        if (recv_all(fd, b, dl + 2) != (ssize_t)dl + 2) goto out;
    } else { errno = ECONNREFUSED; goto out; }

    rc = 0;
out:
    if (fl >= 0) fcntl(fd, F_SETFL, fl);  /* restore app's original mode */
    return rc;
}

int connect(int fd, const struct sockaddr* addr, socklen_t len) {
    if (!real_connect) real_connect = dlsym(RTLD_NEXT, "connect");
    if (!addr) { errno = EINVAL; return -1; }
    if (should_bypass(addr)) return real_connect(fd, addr, len);

    int rc = socks5_connect(fd, addr);
    if (rc == 0) {
        char tgt[80];
        if (addr->sa_family == AF_INET) {
            const struct sockaddr_in* s = (const void*)addr;
            char ip[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &s->sin_addr, ip, sizeof ip);
            snprintf(tgt, sizeof tgt, "%s:%d", ip, ntohs(s->sin_port));
        } else {
            strcpy(tgt, "IPv6");
        }
        logline("PROXIED fd=%d %s pid=%d\n", fd, tgt, getpid());
    } else {
        logline("FAILED fd=%d fam=%d errno=%d pid=%d\n",
                fd, addr->sa_family, errno, getpid());
    }
    return rc;
}