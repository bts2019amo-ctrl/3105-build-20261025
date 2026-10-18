//
//  AntiDetection.m
//  3105
//
//  Hardened runtime protection layer.
//  - Blocks common jailbreak detection via fork()
//  - Denies ptrace attach / debugger attachment
//  - Detects Frida, Substrate, Cycript, common injectors
//  - Provides C API used by Swift integrity checks
//

#import <unistd.h>
#import <errno.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <sys/types.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>
#import <fcntl.h>
#import <dirent.h>
#import <objc/runtime.h>

// ---------------------------------------------------------------------------
// fork() override — defeats classic JB detection that checks if fork works
// ---------------------------------------------------------------------------
pid_t fork(void) {
    errno = EAGAIN;
    return -1;
}

// ---------------------------------------------------------------------------
// ptrace deny — prevent external debugger from attaching
// ---------------------------------------------------------------------------
typedef int (*ptrace_ptr_t)(int _request, pid_t _pid, caddr_t _addr, int _data);
#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif

static void deny_debugger_attach(void) {
    void *handle = dlopen(NULL, RTLD_NOW);
    if (!handle) return;
    ptrace_ptr_t ptrace_ptr = (ptrace_ptr_t)dlsym(handle, "ptrace");
    if (ptrace_ptr) {
        ptrace_ptr(PT_DENY_ATTACH, 0, 0, 0);
    }
}

// ---------------------------------------------------------------------------
// sysctl P_TRACED check
// ---------------------------------------------------------------------------
static int is_debugger_present_sysctl(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc info;
    size_t size = sizeof(info);
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return 0;
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

// ---------------------------------------------------------------------------
// Parent process name check (common debugger parents)
// ---------------------------------------------------------------------------
static int parent_is_suspicious(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getppid()};
    struct kinfo_proc info;
    size_t size = sizeof(info);
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return 0;
    const char *name = info.kp_proc.p_comm;
    if (!name) return 0;
    if (strstr(name, "debugserver") || strstr(name, "lldb") ||
        strstr(name, "gdb") || strstr(name, "frida") ||
        strstr(name, "cycript") || strstr(name, "injector")) {
        return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Dyld image enumeration — look for known injection frameworks
// ---------------------------------------------------------------------------
static int has_suspicious_dyld_image(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (strstr(name, "FridaGadget") ||
            strstr(name, "frida") ||
            strstr(name, "cycript") ||
            strstr(name, "libcycript") ||
            strstr(name, "Substrate") ||
            strstr(name, "libsubstrate") ||
            strstr(name, "MobileSubstrate") ||
            strstr(name, "CydiaSubstrate") ||
            strstr(name, "libhooker") ||
            strstr(name, "substitute") ||
            strstr(name, "TweakInject") ||
            strstr(name, "SSLKillSwitch") ||
            strstr(name, "Flex.dylib") ||
            strstr(name, "RevealServer") ||
            strstr(name, "libInjector") ||
            strstr(name, "Frida") ||
            strstr(name, "gadget")) {
            return 1;
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// File system probes for common JB / inject paths
// ---------------------------------------------------------------------------
static int has_suspicious_paths(void) {
    const char *paths[] = {
        "/Applications/Cydia.app",
        "/Library/MobileSubstrate/MobileSubstrate.dylib",
        "/bin/bash",
        "/usr/sbin/sshd",
        "/etc/apt",
        "/private/var/lib/apt",
        "/private/var/lib/cydia",
        "/private/var/mobile/Library/SBSettings/Themes",
        "/Library/MobileSubstrate/DynamicLibraries",
        "/usr/lib/libhooker.dylib",
        "/usr/lib/TweakInject",
        "/var/jb",
        "/var/containers/Bundle/iosbinpack64",
        "/usr/bin/frida-server",
        "/usr/sbin/frida-server",
        "/Library/LaunchDaemons/re.frida.server.plist",
        NULL
    };
    for (int i = 0; paths[i]; i++) {
        if (access(paths[i], F_OK) == 0) return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Environment variable checks (Frida / injectors often set these)
// ---------------------------------------------------------------------------
static int has_suspicious_env(void) {
    const char *keys[] = {
        "DYLD_INSERT_LIBRARIES",
        "_MSSafeMode",
        "FRIDA_SERVER",
        "CYCRIPT",
        NULL
    };
    for (int i = 0; keys[i]; i++) {
        if (getenv(keys[i]) != NULL) return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Public C API called from Swift
// ---------------------------------------------------------------------------

/// Returns 1 if any strong indicator of debugger / injector / tamper is found.
int AD_isTampered(void) {
    if (is_debugger_present_sysctl()) return 1;
    if (parent_is_suspicious()) return 1;
    if (has_suspicious_dyld_image()) return 1;
    if (has_suspicious_env()) return 1;
    // Path checks are softer (many legitimate paths can exist on some devices)
    // so we only count them when combined with another signal would be better,
    // but for now keep them as additional signal.
    if (has_suspicious_paths()) return 1;
    return 0;
}

/// Call as early as possible (init / +load style).
void AD_applyEarlyProtections(void) {
    deny_debugger_attach();
}

// Constructor — runs before main
__attribute__((constructor)) static void AD_constructor(void) {
    deny_debugger_attach();
}
