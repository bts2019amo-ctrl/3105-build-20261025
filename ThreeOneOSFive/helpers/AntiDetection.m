//
//  AntiDetection.m
//  3105
//
//  Hardened runtime protection layer.
//

#import <unistd.h>
#import <errno.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <sys/types.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>
#import <fcntl.h>
#import <signal.h>
#import <CommonCrypto/CommonDigest.h>

pid_t fork(void) {
    errno = EAGAIN;
    return -1;
}

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

static int is_debugger_present_sysctl(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc info;
    size_t size = sizeof(info);
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return 0;
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

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

static int has_suspicious_dyld_image(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (strstr(name, "FridaGadget") || strstr(name, "frida") ||
            strstr(name, "cycript") || strstr(name, "libcycript") ||
            strstr(name, "Substrate") || strstr(name, "libsubstrate") ||
            strstr(name, "MobileSubstrate") || strstr(name, "CydiaSubstrate") ||
            strstr(name, "libhooker") || strstr(name, "substitute") ||
            strstr(name, "TweakInject") || strstr(name, "SSLKillSwitch") ||
            strstr(name, "Flex.dylib") || strstr(name, "RevealServer") ||
            strstr(name, "libInjector") || strstr(name, "gadget")) {
            return 1;
        }
    }
    return 0;
}

static int has_suspicious_paths(void) {
    const char *paths[] = {
        "/Applications/Cydia.app",
        "/Library/MobileSubstrate/MobileSubstrate.dylib",
        "/bin/bash",
        "/usr/sbin/sshd",
        "/etc/apt",
        "/private/var/lib/apt",
        "/private/var/lib/cydia",
        "/Library/MobileSubstrate/DynamicLibraries",
        "/usr/lib/libhooker.dylib",
        "/usr/lib/TweakInject",
        "/var/jb",
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

static unsigned char g_text_hash[CC_SHA256_DIGEST_LENGTH];
static int g_text_hash_ready = 0;

static int compute_text_hash(unsigned char out[CC_SHA256_DIGEST_LENGTH]) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!mh || mh->magic != MH_MAGIC_64) return -1;

    size_t header_size = sizeof(struct mach_header_64) + mh->sizeofcmds;
    if (header_size > 8192) header_size = 8192;

    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    CC_SHA256_Update(&ctx, mh, (CC_LONG)header_size);

    const uint8_t *base = (const uint8_t *)mh;
    const struct load_command *lc = (const struct load_command *)(base + sizeof(struct mach_header_64));
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, "__TEXT", 16) == 0 && seg->filesize > 0) {
                size_t slice = seg->filesize > 16384 ? 16384 : (size_t)seg->filesize;
                CC_SHA256_Update(&ctx, base + seg->fileoff, (CC_LONG)slice);
                break;
            }
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }

    CC_SHA256_Final(out, &ctx);
    return 0;
}

static void init_text_hash(void) {
    if (g_text_hash_ready) return;
    if (compute_text_hash(g_text_hash) == 0) {
        g_text_hash_ready = 1;
    }
}

static int text_hash_changed(void) {
    if (!g_text_hash_ready) return 0;
    unsigned char current[CC_SHA256_DIGEST_LENGTH];
    if (compute_text_hash(current) != 0) return 0;
    return memcmp(g_text_hash, current, CC_SHA256_DIGEST_LENGTH) != 0;
}

int AD_isTampered(void) {
    if (is_debugger_present_sysctl()) return 1;
    if (parent_is_suspicious()) return 1;
    if (has_suspicious_dyld_image()) return 1;
    if (has_suspicious_env()) return 1;
    if (has_suspicious_paths()) return 1;
    if (text_hash_changed()) return 1;
    return 0;
}

void AD_applyEarlyProtections(void) {
    deny_debugger_attach();
    init_text_hash();
}

void AD_killProcess(void) {
    kill(getpid(), SIGKILL);
    _exit(1);
    abort();
}

__attribute__((constructor)) static void AD_constructor(void) {
    deny_debugger_attach();
    init_text_hash();
}
