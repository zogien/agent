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
#define cond_wake(c) WakeConditionVariable(c)
#define cond_destroy(c) ((void)(c))
#define THREAD_RESULT unsigned __stdcall
#define THREAD_DONE 0
static int spawn_thread(unsigned (__stdcall *fn)(void *), void *arg) {
    uintptr_t handle = _beginthreadex(NULL, 8 * 1024 * 1024, fn, arg, STACK_SIZE_PARAM_IS_A_RESERVATION, NULL);
    if (!handle) return -1;
    CloseHandle((HANDLE)handle);
    return 0;
}
static void *open_library(const char *path) {
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (count <= 0) return NULL;
    wchar_t *wide = calloc((size_t)count, sizeof(*wide));
    if (!wide) return NULL;
    HMODULE library = NULL;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, count))
        library = LoadLibraryExW(wide, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    free(wide);
    return library;
}
#define library_symbol(l,n) GetProcAddress(l,n)
#define close_library(l) FreeLibrary(l)
#define library_error() "could not load AgentCore DLL or its dependencies"
#else
#include <dlfcn.h>
#include <pthread.h>
typedef pthread_mutex_t mutex_t;
typedef pthread_cond_t cond_t;
#define MUTEX_INITIALIZER PTHREAD_MUTEX_INITIALIZER
#define mutex_init(m) pthread_mutex_init(m,NULL)
#define mutex_lock(m) pthread_mutex_lock(m)
#define mutex_unlock(m) pthread_mutex_unlock(m)
#define mutex_destroy(m) pthread_mutex_destroy(m)
#define cond_init(c) pthread_cond_init(c,NULL)
#define cond_wait(c,m) pthread_cond_wait(c,m)
#define cond_wake(c) pthread_cond_signal(c)
#define cond_destroy(c) pthread_cond_destroy(c)
#define THREAD_RESULT void *
#define THREAD_DONE NULL
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
#endif
