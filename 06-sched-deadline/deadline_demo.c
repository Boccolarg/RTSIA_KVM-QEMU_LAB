/*
 * deadline_demo.c — Demonstrate SCHED_DEADLINE on Linux.
 *
 * Runs a CPU-bound task under SCHED_DEADLINE with a configurable budget,
 * and reports how the kernel enforces that budget.
 *
 * Usage:
 *   deadline_demo <runtime_ms> <deadline_ms> <period_ms> <total_seconds>
 *
 * Example:
 *   sudo ./deadline_demo 10 100 100 5
 *      -> 10 ms of CPU work guaranteed per 100 ms window, for 5 s of wall time.
 *
 * To demonstrate admission control rejection, request an unreasonable budget:
 *   sudo ./deadline_demo 99 100 100 1
 *      -> requests 99% of one CPU; admission control will reject with EBUSY,
 *         because the default kernel.sched_rt_runtime_us is 950000 of 1000000
 *         (95% RT budget) and SCHED_DEADLINE shares that pool.
 *
 * Build:
 *   gcc -O2 -o deadline_demo deadline_demo.c
 *
 * Notes:
 *   - Requires CAP_SYS_NICE (i.e. root, or a process with that capability).
 *   - SCHED_DEADLINE constraint: runtime <= deadline <= period (all > 0).
 *   - The kernel will throttle this task as soon as it has used 'runtime' ns
 *     of CPU within the current period, then wake it again at the next period.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sched.h>
#include <sys/syscall.h>
#include <linux/types.h>

#ifndef SCHED_DEADLINE
#define SCHED_DEADLINE 6
#endif

#ifndef __NR_sched_setattr
#  if defined(__x86_64__)
#    define __NR_sched_setattr 314
#  elif defined(__aarch64__)
#    define __NR_sched_setattr 274
#  else
#    error "Define __NR_sched_setattr for your architecture"
#  endif
#endif

struct sched_attr {
    __u32 size;
    __u32 sched_policy;
    __u64 sched_flags;
    __s32 sched_nice;
    __u32 sched_priority;
    __u64 sched_runtime;
    __u64 sched_deadline;
    __u64 sched_period;
};

static int sched_setattr(pid_t pid, struct sched_attr *attr, unsigned int flags) {
    return syscall(__NR_sched_setattr, pid, attr, flags);
}

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

int main(int argc, char *argv[]) {
    if (argc != 5) {
        fprintf(stderr,
                "Usage: %s <runtime_ms> <deadline_ms> <period_ms> <total_seconds>\n"
                "Example: sudo %s 10 100 100 5\n",
                argv[0], argv[0]);
        return 1;
    }

    uint64_t runtime_ms  = strtoull(argv[1], NULL, 10);
    uint64_t deadline_ms = strtoull(argv[2], NULL, 10);
    uint64_t period_ms   = strtoull(argv[3], NULL, 10);
    uint64_t total_s     = strtoull(argv[4], NULL, 10);

    if (!(runtime_ms <= deadline_ms && deadline_ms <= period_ms) || period_ms == 0) {
        fprintf(stderr,
                "Invalid: must have 0 < runtime <= deadline <= period (got %lu/%lu/%lu)\n",
                runtime_ms, deadline_ms, period_ms);
        return 1;
    }

    struct sched_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.size           = sizeof(attr);
    attr.sched_policy   = SCHED_DEADLINE;
    attr.sched_runtime  = runtime_ms  * 1000000ULL;  /* ms -> ns */
    attr.sched_deadline = deadline_ms * 1000000ULL;
    attr.sched_period   = period_ms   * 1000000ULL;

    fprintf(stderr,
            "Requesting SCHED_DEADLINE: runtime=%lu ms, deadline=%lu ms, period=%lu ms\n",
            runtime_ms, deadline_ms, period_ms);

    if (sched_setattr(0, &attr, 0) < 0) {
        if (errno == EBUSY) {
            fprintf(stderr,
                    "sched_setattr: EBUSY -- admission control rejected.\n"
                    "  The kernel refuses this allocation because the total deadline\n"
                    "  bandwidth (sum of runtime/period for all SCHED_DEADLINE tasks)\n"
                    "  would exceed the system limit. Default is 95%% of one CPU.\n");
        } else if (errno == EPERM) {
            fprintf(stderr,
                    "sched_setattr: EPERM -- not allowed.\n"
                    "  Need CAP_SYS_NICE; try running with sudo.\n");
        } else if (errno == EINVAL) {
            fprintf(stderr,
                    "sched_setattr: EINVAL -- invalid parameters.\n"
                    "  Check runtime <= deadline <= period.\n");
        } else {
            perror("sched_setattr");
        }
        return 2;
    }

    fprintf(stderr, "Granted. Running for ~%lu s of wall time...\n", total_s);

    /*
     * Busy-loop body. The loop *intentionally* requests more CPU than 'runtime'
     * provides per period -- so we can observe the kernel throttling us:
     * after we burn 'runtime' ns within a period, the kernel deschedules us
     * and reschedules us only at the next period boundary.
     *
     * Each "iteration" below is a chunk of busy work plus an elapsed-time
     * measurement. We print one summary line per second of wall time.
     */
    uint64_t t_start = now_ns();
    uint64_t t_deadline = t_start + total_s * 1000000000ULL;
    uint64_t period_count = 0;
    uint64_t max_iter_ns = 0;
    uint64_t total_iters = 0;
    uint64_t last_print = t_start;

    while (now_ns() < t_deadline) {
        uint64_t t0 = now_ns();
        /* Tight integer busy loop to consume CPU. */
        volatile uint64_t x = 0;
        for (uint64_t j = 0; j < 50000000ULL; j++) x += j;
        uint64_t t1 = now_ns();
        uint64_t iter_ns = t1 - t0;
        if (iter_ns > max_iter_ns) max_iter_ns = iter_ns;
        total_iters++;

        /* Yielding here triggers throttling more cleanly. The kernel
         * runs us again at the next period boundary. */
        sched_yield();
        period_count++;

        /* Print one line per ~1 s of wall time. */
        if (now_ns() - last_print >= 1000000000ULL) {
            last_print = now_ns();
            fprintf(stderr,
                    "[%4.1fs] iterations=%lu, max iter elapsed=%lu us\n",
                    (last_print - t_start) / 1e9,
                    total_iters,
                    max_iter_ns / 1000);
        }
    }

    fprintf(stderr,
            "Done. %lu iterations completed in %.1f s. Max iteration duration: %lu us.\n",
            total_iters,
            (now_ns() - t_start) / 1e9,
            max_iter_ns / 1000);

    return 0;
}
