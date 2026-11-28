#pragma once

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <process.h>
#include <stdlib.h>
#include "host_api.h"

typedef SRWLOCK mutex_t;
typedef CONDITION_VARIABLE cond_t;
#define MUTEX_INITIALIZER SRWLOCK_INIT
#define mutex_init(m) InitializeSRWLock(m)
#define mutex_lock(m) AcquireSRWLockExclusive(m)
#define mutex_unlock(m) ReleaseSRWLockExclusive(m)
#define mutex_destroy(m) ((void)(m))
#define cond_init(c) InitializeConditionVariable(c)
#define cond_wait(c,m) SleepConditionVariableSRW(c,m,INFINITE,0)
static uint64_t monotonic_ms(void) { return GetTickCount64(); }
static void cond_wait_ms(cond_t *c, mutex_t *m, unsigned ms) { SleepConditionVariableSRW(c, m, ms, 0); }
#define cond_wake(c) WakeConditionVariable(c)
#define cond_destroy(c) ((void)(c))
#define THREAD_RESULT unsigned __stdcall
#define THREAD_DONE 0
static int pin_addon(void *address) {
    HMODULE module;
    return GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                              (LPCWSTR)address, &module) != 0;
}
static int spawn_thread(unsigned (__stdcall *fn)(void *), void *arg) {
    uintptr_t handle = _beginthreadex(NULL, 8 * 1024 * 1024, fn, arg, STACK_SIZE_PARAM_IS_A_RESERVATION, NULL);
    if (!handle) return -1;
    CloseHandle((HANDLE)handle);
    return 0;
}
static wchar_t *wide_path(const char *path) {
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (count <= 0) return NULL;
    wchar_t *wide = calloc((size_t)count, sizeof(*wide));
    if (wide && !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, count)) {
        free(wide);
        wide = NULL;
    }
    return wide;
}
static void *open_library(const char *path) {
    wchar_t *wide = wide_path(path);
    if (!wide) return NULL;
    HMODULE library = LoadLibraryExW(wide, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    free(wide);
    return library;
}
typedef HANDLE path_lock_t;
static int lock_path(const char *path, path_lock_t *out, int *error) {
    wchar_t *wide = wide_path(path);
    if (!wide) {
        *error = (int)ERROR_INVALID_NAME;
        return -1;
    }
    HANDLE handle = CreateFileW(wide, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_ALWAYS,
                                FILE_ATTRIBUTE_NORMAL | FILE_FLAG_DELETE_ON_CLOSE, NULL);
    DWORD failure = GetLastError();
    free(wide);
    if (handle == INVALID_HANDLE_VALUE) {
        *error = (int)failure;
        return failure == ERROR_SHARING_VIOLATION ? 1 : -1;
    }
    *out = handle;
    return 0;
}
static void unlock_path(path_lock_t lock, const char *path) {
    (void)path;
    CloseHandle(lock);
}
#define library_symbol(l,n) GetProcAddress(l,n)
#define close_library(l) FreeLibrary(l)
#define library_error() "could not load AgentCore DLL or its dependencies"
#else
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <time.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
typedef pthread_mutex_t mutex_t;
typedef pthread_cond_t cond_t;
#define MUTEX_INITIALIZER PTHREAD_MUTEX_INITIALIZER
#define mutex_init(m) pthread_mutex_init(m,NULL)
#define mutex_lock(m) pthread_mutex_lock(m)
#define mutex_unlock(m) pthread_mutex_unlock(m)
#define mutex_destroy(m) pthread_mutex_destroy(m)
#define cond_init(c) pthread_cond_init(c,NULL)
#define cond_wait(c,m) pthread_cond_wait(c,m)
static uint64_t monotonic_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}
static void cond_wait_ms(cond_t *c, mutex_t *m, unsigned ms) {
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_nsec += (long)ms * 1000000;
    until.tv_sec += until.tv_nsec / 1000000000;
    until.tv_nsec %= 1000000000;
    pthread_cond_timedwait(c, m, &until);
}
#define cond_wake(c) pthread_cond_signal(c)
#define cond_destroy(c) pthread_cond_destroy(c)
#define THREAD_RESULT void *
#define THREAD_DONE NULL
static int pin_addon(void *address) {
    Dl_info info;
    return dladdr(address, &info) && dlopen(info.dli_fname, RTLD_NOW | RTLD_LOCAL) != NULL;
}
static int spawn_thread(void *(*fn)(void *), void *arg) {
    pthread_t thread;
    pthread_attr_t attr;
    if (pthread_attr_init(&attr)) return -1;
    int err = pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (!err) err = pthread_attr_setstacksize(&attr, 8 * 1024 * 1024);
    if (!err) err = pthread_create(&thread, &attr, fn, arg);
    pthread_attr_destroy(&attr);
    return err;
}
#define open_library(p) dlopen(p,RTLD_NOW | RTLD_LOCAL)
#define library_symbol(l,n) dlsym(l,n)
#define close_library(l) dlclose(l)
#define library_error() dlerror()
typedef int path_lock_t;
static int lock_path(const char *path, path_lock_t *out, int *error) {
    for (;;) {
        int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
        if (fd < 0) {
            if (errno == EINTR) continue;
            *error = errno;
            return -1;
        }
        int locked;
        do locked = flock(fd, LOCK_EX | LOCK_NB);
        while (locked && errno == EINTR);
        if (locked) {
            *error = errno;
            close(fd);
            return *error == EWOULDBLOCK ? 1 : -1;
        }
        struct stat held, named;
        if (fstat(fd, &held) == 0 && stat(path, &named) == 0) {
            if (held.st_dev == named.st_dev && held.st_ino == named.st_ino) {
                *out = fd;
                return 0;
            }
        } else if (errno != ENOENT) {
            *error = errno;
            close(fd);
            return -1;
        }
        close(fd);
    }
}
static void unlock_path(path_lock_t lock, const char *path) {
    unlink(path);
    close(lock);
}
#endif
