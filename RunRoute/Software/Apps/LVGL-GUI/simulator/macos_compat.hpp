/**
 * Force-included into the simulator's C++ sources on macOS (see CMakeLists.txt).
 *
 * macOS declares POSIX unnamed semaphores but sem_init() always fails, and it has
 * no sem_timedwait(), both of which the SDK's simulator OS layer relies on. This
 * swaps them for a mutex and condition variable. It never reaches the watch build.
 */

#ifndef MACOS_COMPAT_HPP
#define MACOS_COMPAT_HPP

#include <new>  // std::align_val_t, used by the simulator without including it

#include <cerrno>
#include <ctime>
#include <pthread.h>
#include <semaphore.h>

struct MacSem {
    pthread_mutex_t mutex;
    pthread_cond_t  cond;
    unsigned        count;
};

inline int macSemInit(MacSem* sem, int /*shared*/, unsigned value)
{
    pthread_mutex_init(&sem->mutex, nullptr);
    pthread_cond_init(&sem->cond, nullptr);
    sem->count = value;
    return 0;
}

inline int macSemDestroy(MacSem* sem)
{
    pthread_cond_destroy(&sem->cond);
    pthread_mutex_destroy(&sem->mutex);
    return 0;
}

inline int macSemPost(MacSem* sem)
{
    pthread_mutex_lock(&sem->mutex);
    ++sem->count;
    pthread_cond_signal(&sem->cond);
    pthread_mutex_unlock(&sem->mutex);
    return 0;
}

inline int macSemWait(MacSem* sem)
{
    pthread_mutex_lock(&sem->mutex);
    while (sem->count == 0) {
        pthread_cond_wait(&sem->cond, &sem->mutex);
    }
    --sem->count;
    pthread_mutex_unlock(&sem->mutex);
    return 0;
}

inline int macSemTimedWait(MacSem* sem, const timespec* deadline)
{
    int result = 0;
    pthread_mutex_lock(&sem->mutex);
    while (sem->count == 0 && result == 0) {
        result = pthread_cond_timedwait(&sem->cond, &sem->mutex, deadline);
    }
    if (sem->count > 0) {
        --sem->count;
        result = 0;
    }
    pthread_mutex_unlock(&sem->mutex);
    if (result != 0) {
        errno = result;
        return -1;
    }
    return 0;
}

#define sem_t         MacSem
#define sem_init      macSemInit
#define sem_destroy   macSemDestroy
#define sem_post      macSemPost
#define sem_wait      macSemWait
#define sem_timedwait macSemTimedWait

#endif // MACOS_COMPAT_HPP
