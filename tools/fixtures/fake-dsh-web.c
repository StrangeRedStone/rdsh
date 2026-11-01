// fake-dsh-web.c —— 冒烟专用：造一个"长得像 dsh web"的长命进程
// 为什么需要：端口归属的判据（is_dsh_web_pid）读 /proc/<pid>/cmdline 必须含 "bin.ts web"。
// /proc/<pid>/cmdline 是按 argv 逐项用 NUL 连接，所以必须**改整个 argv 数组**，
// 不能只改 argv[0] 的字符串（那样会把后面的参数全并入 argv[0]，形如 "bin.ts<空格>20655 20656 300"）。
// 用法：fake-dsh-web <port-main> <port-side> <秒数>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/prctl.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

static int listen_on(int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = htons((unsigned short)port);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0) { close(fd); return -1; }
  if (listen(fd, 8) != 0) { close(fd); return -1; }
  return fd;
}

int main(int argc, char **argv) {
  if (argc < 4) { fprintf(stderr, "usage: %s <port-main> <port-side> <seconds>\n", argv[0]); return 2; }
  int pm = atoi(argv[1]), ps = atoi(argv[2]), secs = atoi(argv[3]);
  // 改整个 argv 数组（**先把端口参数读出来**，再覆盖 argv 指针）。
  // 关键：/proc/pid/cmdline 读的是 argv[i] **指向的内存**，不是指针数组本身；若把 argv[i]
  // 指到字符串字面量，内核仍读原来的 arg 内存块 → 显示还是旧命令。所以必须往原内存里写。
  // 原块够长（"fake-dsh-web\0" + 数字 + …），按 NUL 切好写进去即可。
  static const char *names[] = { "bin.ts", "web", "fake-dsh-web" };
  size_t off = 0;
  char *base = argv[0];
  for (int i = 0; i < 3; i++) {
    size_t n = strlen(names[i]) + 1;
    memcpy(base + off, names[i], n);
    argv[i] = base + off;
    off += n;
  }
  argv[3] = NULL;
  prctl(PR_SET_NAME, "bin.ts", 0, 0, 0);
  int a = listen_on(pm), b = listen_on(ps);
  if (a < 0 || b < 0) { if (a >= 0) close(a); if (b >= 0) close(b); return 3; }
  sleep(secs);
  close(a); close(b);
  return 0;
}
