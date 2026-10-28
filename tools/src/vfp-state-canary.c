#define _GNU_SOURCE
#include <inttypes.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/wait.h>
#include <sys/timerfd.h>
#include <errno.h>
#include <unistd.h>

extern int vfp_raw_sleep(const uint64_t *, uint64_t *, uint64_t *, const struct timespec *);
static int seconds = 3600;
static int crypto_failures;
static uint64_t now(int id) {
    struct timespec t;
    if (clock_gettime(id, &t)) abort();
    return (uint64_t)t.tv_sec * 1000000000ULL + t.tv_nsec;
}
static void *worker(void *arg) {
    int cpu = (int)(intptr_t)arg, bad = 0, affinity = -1;
    uint64_t expected[33], before[33], after[33], iterations = 0, suspends = 0;
    uint64_t start = now(CLOCK_BOOTTIME), end = start + (uint64_t)seconds * 1000000000ULL;
    struct timespec request = {0, 100000000};
    cpu_set_t mask;
    CPU_ZERO(&mask); CPU_SET(cpu, &mask);
    while (now(CLOCK_BOOTTIME) < end && bad < 8) {
        // Hotplug can relax a task's affinity mask; reapply it when the core returns.
        affinity = sched_setaffinity(0, sizeof(mask), &mask);
        for (int i = 0; i < 32; ++i)
            expected[i] = (iterations & 1) ? 0 :
                0x1122334455667788ULL ^ (0x9e3779b97f4a7c15ULL * (i + 1)) ^ ((uint64_t)cpu << 56);
        expected[32] = 0x03000000;
        memset(before, 0, sizeof before); memset(after, 0, sizeof after);
        uint64_t b0 = now(CLOCK_BOOTTIME), m0 = now(CLOCK_MONOTONIC);
        int rc = vfp_raw_sleep(expected, before, after, &request);
        uint64_t m1 = now(CLOCK_MONOTONIC), b1 = now(CLOCK_BOOTTIME);
        int before_bad = memcmp(expected, before, sizeof expected) != 0;
        int after_bad = memcmp(expected, after, sizeof expected) != 0;
        int64_t suspend_ns = (int64_t)(b1 - b0) - (int64_t)(m1 - m0);
        if (suspend_ns > 20000000) {
            suspends++;
            printf("SUSPEND cpu=%d actual=%d seq=%" PRIu64 " suspended_ms=%" PRId64
                   " boot_ms=%" PRIu64 " before_bad=%d after_bad=%d\n",
                   cpu, sched_getcpu(), iterations, suspend_ns / 1000000, b1 / 1000000,
                   before_bad, after_bad);
            if (cpu == 0) {
                // A fresh dynamically linked process exercises libcrypto's real
                // startup integrity/KAT path; any diagnostic reaches this log.
                pid_t child = fork();
                if (child == 0) { execl("/system/bin/toybox", "toybox", "true", NULL); _exit(127); }
                int status = -1;
                if (child > 0 && waitpid(child, &status, 0) == child) {
                    printf("CRYPTO_AFTER_RESUME wait_status=%d boot_ms=%" PRIu64 "\n", status, b1 / 1000000);
                    if(status) __sync_fetch_and_add(&crypto_failures,1);
                } else {
                    printf("CRYPTO_AFTER_RESUME fork_or_wait_failed\n");
                    __sync_fetch_and_add(&crypto_failures,1);
                }
            }
        }
        if (before_bad || after_bad) {
            bad++;
            printf("CORRUPT cpu=%d actual=%d affinity_rc=%d seq=%" PRIu64
                   " boot_ms=%" PRIu64 " syscall_rc=%d before_bad=%d after_bad=%d\n",
                   cpu, sched_getcpu(), affinity, iterations, b1 / 1000000, rc, before_bad, after_bad);
            for (int i = 0; i < 33; ++i)
                if (before[i] != expected[i] || after[i] != expected[i])
                    printf(" %s%d expected=%016" PRIx64 " before=%016" PRIx64 " after=%016" PRIx64 "\n",
                           i == 32 ? "fpscr" : "d", i, expected[i], before[i], after[i]);
        }
        iterations++;
        if (iterations == 1 || iterations % 600 == 0)
            printf("PROGRESS cpu=%d actual=%d affinity_rc=%d iterations=%" PRIu64
                   " suspends=%" PRIu64 " corruptions=%d boot_ms=%" PRIu64 "\n",
                   cpu, sched_getcpu(), affinity, iterations, suspends, bad, b1 / 1000000);
    }
    printf("DONE cpu=%d iterations=%" PRIu64 " suspends=%" PRIu64 " corruptions=%d\n",
           cpu, iterations, suspends, bad);
    return (void *)(intptr_t)bad;
}
int main(int argc, char **argv) {
    if (argc > 1) seconds = atoi(argv[1]);
    if (seconds < 1 || seconds > 86400) return 2;
    int alarm_seconds = argc > 2 ? atoi(argv[2]) : 0;
    if (alarm_seconds < 0 || alarm_seconds > 3600) return 2;
    setvbuf(stdout, NULL, _IOLBF, 0);
    int alarm_fd = -1;
    int alarm_failure = 0;
    uint64_t alarm_end = now(CLOCK_BOOTTIME) + (uint64_t)seconds * 1000000000ULL;
    if (alarm_seconds) {
        alarm_fd = timerfd_create(CLOCK_BOOTTIME_ALARM, TFD_CLOEXEC);
        uint64_t next=now(CLOCK_BOOTTIME)+(uint64_t)alarm_seconds*1000000000ULL;
        if(next>alarm_end) next=alarm_end;
        struct itimerspec its = {{0,0},{next/1000000000ULL,next%1000000000ULL}};
        if (alarm_fd < 0 || timerfd_settime(alarm_fd,TFD_TIMER_ABSTIME,&its,NULL)) {perror("alarm timer");return 5;}
        printf("BOUNDED_ALARM period_s=%d duration_s=%d\n",alarm_seconds,seconds);
    }
    int n = (int)sysconf(_SC_NPROCESSORS_CONF);
    if (n < 1 || n > 8) return 2;
    pthread_t threads[8]; int count = 0;
    printf("START duration_s=%d cpus=%d raw_syscall=nanosleep all_d0_d31_and_fpscr\n", seconds, n);
    for (int i = 0; i < n; ++i) {
        if (pthread_create(&threads[i], NULL, worker, (void *)(intptr_t)i)) return 3;
        count++;
    }
    while (alarm_fd >= 0 && now(CLOCK_BOOTTIME) < alarm_end) {
        uint64_t expirations;
        ssize_t nread = read(alarm_fd,&expirations,sizeof expirations);
        if (nread < 0 && errno == EINTR) continue;
        if (nread != sizeof expirations) {perror("alarm read");alarm_failure=1;break;}
        printf("ALARM count=%" PRIu64 " boot_ms=%" PRIu64 "\n",expirations,now(CLOCK_BOOTTIME)/1000000);
        // One-shot alarms: a stuck/killed monitor cannot leave a periodic wake
        // source behind. Never rearm beyond the absolute test deadline.
        uint64_t current=now(CLOCK_BOOTTIME);
        if(current>=alarm_end) break;
        uint64_t next=current+(uint64_t)alarm_seconds*1000000000ULL;
        if(next>alarm_end) next=alarm_end;
        struct itimerspec its={{0,0},{next/1000000000ULL,next%1000000000ULL}};
        if(timerfd_settime(alarm_fd,TFD_TIMER_ABSTIME,&its,NULL)) {perror("alarm rearm");alarm_failure=1;break;}
    }
    if(alarm_fd >= 0) close(alarm_fd);
    intptr_t total = 0;
    for (int i = 0; i < count; ++i) {
        void *result; if (pthread_join(threads[i], &result)) return 4;
        total += (intptr_t)result;
    }
    printf("TOTAL corruptions=%" PRIdPTR " crypto_failures=%d alarm_failures=%d\n", total,crypto_failures,alarm_failure);
    return total || crypto_failures || alarm_failure ? 1 : 0;
}
