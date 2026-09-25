// fakepci.c —— 只做一件事: 让 /proc/bus/pci/devices 可读。
//
// 背景(2026-09-24 实测): Chromium/Electron 的 GPU 子进程 stderr 只有
//     pcilib: Cannot open /proc/bus/pci/devices
//   随后 exit 1(主进程报 exit_code=256), 连一行 EGL/Mesa 调试都没有
//   → 它死在【GPU 信息收集】阶段, 根本没走到 EGL 初始化。
//   本机 /proc/bus/pci 目录存在, 但 devices 文件被 SELinux 拦(EACCES, 不是 ENOENT)。
//
// 做法: 拦 fopen/fopen64/open/open64, 把对 /proc/bus/pci/devices 的访问重定向到
//   环境变量 FAKE_PCI_FILE 指向的普通文件(内容是内核 drivers/pci/proc.c 的 show_device 格式)。
//   其余路径一律原样透传。只在被 LD_PRELOAD 时生效, 对系统零影响。
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>

static const char *TARGET = "/proc/bus/pci/devices";

static const char *redirect(const char *path) {
    if (path && strcmp(path, TARGET) == 0) {
        const char *f = getenv("FAKE_PCI_FILE");
        if (f && *f) return f;
    }
    return path;
}

FILE *fopen(const char *path, const char *mode) {
    static FILE *(*real)(const char *, const char *);
    if (!real) real = dlsym(RTLD_NEXT, "fopen");
    return real(redirect(path), mode);
}

FILE *fopen64(const char *path, const char *mode) {
    static FILE *(*real)(const char *, const char *);
    if (!real) real = dlsym(RTLD_NEXT, "fopen64");
    if (!real) return fopen(path, mode);
    return real(redirect(path), mode);
}

int open(const char *path, int flags, ...) {
    static int (*real)(const char *, int, ...);
    mode_t m = 0;
    if (!real) real = dlsym(RTLD_NEXT, "open");
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); m = va_arg(ap, mode_t); va_end(ap); }
    return real(redirect(path), flags, m);
}

int open64(const char *path, int flags, ...) {
    static int (*real)(const char *, int, ...);
    mode_t m = 0;
    if (!real) real = dlsym(RTLD_NEXT, "open64");
    if (!real) return open(path, flags);
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); m = va_arg(ap, mode_t); va_end(ap); }
    return real(redirect(path), flags, m);
}
