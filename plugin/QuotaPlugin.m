#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <fcntl.h>
#import <errno.h>
#import <pthread.h>
#import <spawn.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <poll.h>
#import <time.h>
#import <stdatomic.h>
#import <sys/wait.h>
#import <unistd.h>
#import <signal.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include "QuotaPayload.h"

#ifndef QUOTA_VERSION
#error QUOTA_VERSION must identify the packaged helper version
#endif
#ifndef QUOTA_APP_TREE_SHA256
#error QUOTA_APP_TREE_SHA256 must pin the extracted application bundle
#endif
#define PLUGIN_VERSION QUOTA_VERSION
#define READY_TIMEOUT_MS 5000
#define MAX_REQUEST_BYTES (1024 * 1024)

typedef struct { void *ptr; size_t len; } cliproxy_buffer;
typedef struct {
    uint32_t abi_version;
    void *host_ctx;
    int (*call)(void *, const char *, const uint8_t *, size_t, cliproxy_buffer *);
    void (*free_buffer)(void *, size_t);
} cliproxy_host_api;
typedef struct {
    uint32_t abi_version;
    int (*call)(char *, uint8_t *, size_t, cliproxy_buffer *);
    void (*free_buffer)(void *, size_t);
    void (*shutdown)(void);
} cliproxy_plugin_api;

extern char **environ;
static pthread_mutex_t lifecycleLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t lifecycleChanged = PTHREAD_COND_INITIALIZER;
static pthread_t reconnectThread;
static BOOL reconnectStarted = NO, stopping = NO, suspended = NO;
static int eventSocket = -1;
static pid_t helperPID = -1;
static atomic_int pendingUsage = 0;
static NSString *dataDirectory = nil, *cpaHome = nil, *authDirectory = nil;
static NSInteger managementPort = 0;
static NSString *lastError = nil;

static NSString *failure(NSString *message) { lastError = message ?: @"Plugin operation failed"; return nil; }
static NSString *expandAbsolutePath(NSString *input, NSString *fallback) {
    NSString *value = input.length ? input : fallback;
    if (!value.length) return nil;
    value = [value stringByExpandingTildeInPath];
    if (![value isAbsolutePath] || [value containsString:@"\0"]) return nil;
    for (NSString *component in [value componentsSeparatedByString:@"/"]) {
        if ([component isEqualToString:@"."] || [component isEqualToString:@".."]) return nil;
    }
    return value;
}

static BOOL secureDirectory(NSString *path, BOOL create) {
    if (!path.length || ![path isAbsolutePath]) { lastError = @"Directory path is not absolute"; return NO; }
    NSArray<NSString *> *parts = [path pathComponents];
    NSString *walk = @"/";
    for (NSUInteger i = 1; i < parts.count; i++) {
        walk = [walk stringByAppendingPathComponent:parts[i]];
        struct stat st;
        if (lstat(walk.fileSystemRepresentation, &st) != 0) {
            if (errno != ENOENT || !create || mkdir(walk.fileSystemRepresentation, 0700) != 0) { lastError = [NSString stringWithFormat:@"Cannot create directory component %@ (%d)", walk, errno]; return NO; }
            if (lstat(walk.fileSystemRepresentation, &st) != 0) { lastError = @"Cannot inspect new directory"; return NO; }
        }
        if (S_ISLNK(st.st_mode) || !S_ISDIR(st.st_mode)) { lastError = [NSString stringWithFormat:@"Directory component is a link or non-directory: %@", walk]; return NO; }
        if (i == parts.count - 1 && st.st_uid != getuid()) { lastError = [NSString stringWithFormat:@"Directory is not user-owned: %@", walk]; return NO; }
    }
    struct stat finalStat;
    if (lstat(path.fileSystemRepresentation, &finalStat) != 0 || S_ISLNK(finalStat.st_mode) ||
        !S_ISDIR(finalStat.st_mode) || finalStat.st_uid != getuid()) { lastError = [NSString stringWithFormat:@"Final directory is unsafe: %@", path]; return NO; }
    if (chmod(path.fileSystemRepresentation, 0700) != 0) { lastError = [NSString stringWithFormat:@"Cannot secure directory %@ (%d)", path, errno]; return NO; }
    return YES;
}

static BOOL safeOwnedFile(NSString *path, struct stat *out) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0 || S_ISLNK(st.st_mode) ||
        !S_ISREG(st.st_mode) || st.st_uid != getuid()) return NO;
    if (out) *out = st;
    return YES;
}

static NSString *sha256Data(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *value = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [value appendFormat:@"%02x", digest[i]];
    return value;
}

static void appendU32LE(NSMutableData *data, uint32_t value) {
    uint8_t bytes[4]; for (NSUInteger i = 0; i < 4; i++) bytes[i] = (uint8_t)(value >> (i * 8));
    [data appendBytes:bytes length:sizeof(bytes)];
}
static void appendU64LE(NSMutableData *data, uint64_t value) {
    uint8_t bytes[8]; for (NSUInteger i = 0; i < 8; i++) bytes[i] = (uint8_t)(value >> (i * 8));
    [data appendBytes:bytes length:sizeof(bytes)];
}

static BOOL appendAppTree(NSString *root, NSString *relative, NSMutableData *digestInput) {
    NSString *directory = relative.length ? [root stringByAppendingPathComponent:relative] : root;
    DIR *stream = opendir(directory.fileSystemRepresentation);
    if (!stream) return NO;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    struct dirent *entry;
    while ((entry = readdir(stream)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSString stringWithUTF8String:entry->d_name]; if (name) [names addObject:name];
    }
    closedir(stream);
    [names sortUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        return [left compare:right options:NSLiteralSearch];
    }];
    BOOL ok = YES;
    for (NSString *name in names) {
        if (!ok) break;
        NSString *childRelative = relative.length ? [relative stringByAppendingPathComponent:name] : name;
        NSString *child = [root stringByAppendingPathComponent:childRelative];
        struct stat st;
        if (lstat(child.fileSystemRepresentation, &st) != 0 || S_ISSOCK(st.st_mode)) { ok = NO; break; }
        NSData *pathData = [childRelative dataUsingEncoding:NSUTF8StringEncoding];
        uint64_t nameLength = pathData.length; uint32_t mode = (uint32_t)(st.st_mode & 07777);
        appendU64LE(digestInput, nameLength); [digestInput appendData:pathData]; appendU32LE(digestInput, mode);
        if (S_ISDIR(st.st_mode)) {
            uint8_t kind = 'd'; [digestInput appendBytes:&kind length:1];
            ok = appendAppTree(root, childRelative, digestInput);
        } else if (S_ISREG(st.st_mode)) {
            uint8_t kind = 'f'; [digestInput appendBytes:&kind length:1];
            NSData *contents = [NSData dataWithContentsOfFile:child options:NSDataReadingMappedIfSafe error:nil];
            if (!contents) { ok = NO; break; }
            uint64_t size = contents.length; appendU64LE(digestInput, size); [digestInput appendData:contents];
        } else if (S_ISLNK(st.st_mode)) {
            uint8_t kind = 'l'; [digestInput appendBytes:&kind length:1];
            char target[PATH_MAX + 1]; ssize_t count = readlink(child.fileSystemRepresentation, target, PATH_MAX);
            if (count < 0) { ok = NO; break; }
            uint64_t size = (uint64_t)count; appendU64LE(digestInput, size); [digestInput appendBytes:target length:(NSUInteger)count];
        } else ok = NO;
    }
    return ok;
}

static NSString *appTreeSHA256(NSString *appPath) {
    NSMutableData *tree = [NSMutableData data];
    return appendAppTree(appPath, @"", tree) ? sha256Data(tree) : nil;
}

static BOOL runTool(NSString *tool, NSArray<NSString *> *arguments) {
    NSMutableArray *args = [NSMutableArray arrayWithObject:tool]; [args addObjectsFromArray:arguments];
    char **argv = calloc(args.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < args.count; i++) argv[i] = (char *)[args[i] fileSystemRepresentation];
    posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    pid_t pid = -1; int rc = posix_spawn(&pid, tool.fileSystemRepresentation, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions); free(argv);
    if (rc != 0) return NO;
    int status = 0; while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static BOOL validSignedApp(NSString *appPath) {
    struct stat st;
    if (lstat(appPath.fileSystemRepresentation, &st) != 0 || S_ISLNK(st.st_mode) || !S_ISDIR(st.st_mode) || st.st_uid != getuid()) return NO;
    NSString *exe = [appPath stringByAppendingPathComponent:@"Contents/MacOS/QuotaMenubar"];
    if (!safeOwnedFile(exe, NULL) || access(exe.fileSystemRepresentation, X_OK) != 0) return NO;
    if (!runTool(@"/usr/bin/codesign", @[@"--verify", @"--deep", @"--strict", appPath])) return NO;
    NSString *treeHash = appTreeSHA256(appPath);
    return treeHash && [treeHash isEqualToString:@QUOTA_APP_TREE_SHA256];
}

static NSString *deployPayload(void) {
    NSData *zip = [NSData dataWithBytes:quota_payload_bytes length:quota_payload_size];
    NSString *actual = sha256Data(zip);
    if (![actual isEqualToString:@QUOTA_PAYLOAD_SHA256]) return failure(@"Embedded payload SHA-256 does not match QUOTA_PAYLOAD_SHA256");
#if defined(__arm64__)
    if (strcmp(QUOTA_PAYLOAD_ARCH, "arm64") != 0) return failure(@"Embedded payload architecture does not match this host");
#elif defined(__x86_64__)
    if (strcmp(QUOTA_PAYLOAD_ARCH, "amd64") != 0) return failure(@"Embedded payload architecture does not match this host");
#else
    return failure(@"Unsupported host architecture");
#endif
    if (!secureDirectory(dataDirectory, YES)) return failure(@"dataDir must be an absolute, user-owned directory without symlinks");
    NSString *versions = [dataDirectory stringByAppendingPathComponent:@"payloads"];
    if (!secureDirectory(versions, YES)) return failure(@"Cannot create a safe payload directory");
    NSString *identity = [NSString stringWithFormat:@"%@-%@", @PLUGIN_VERSION, actual];
    NSString *destination = [versions stringByAppendingPathComponent:identity];
    NSString *app = [destination stringByAppendingPathComponent:@"Codex Quota Menubar.app"];
    NSString *manifest = [destination stringByAppendingPathComponent:@"payload.sha256"];
    struct stat dst;
    if (lstat(destination.fileSystemRepresentation, &dst) == 0) {
        if (S_ISLNK(dst.st_mode) || !S_ISDIR(dst.st_mode) || dst.st_uid != getuid()) return failure(@"Unsafe existing payload directory");
        NSData *stored = safeOwnedFile(manifest, NULL) ? [NSData dataWithContentsOfFile:manifest] : nil;
        NSString *manifestText = stored ? [[NSString alloc] initWithData:stored encoding:NSUTF8StringEncoding] : nil;
        NSArray<NSString *> *manifestParts = [manifestText componentsSeparatedByString:@"\n"];
        NSString *installedTreeHash = validSignedApp(app) ? appTreeSHA256(app) : nil;
        if (manifestParts.count == 3 && [manifestParts[0] isEqualToString:actual] && installedTreeHash &&
            [manifestParts[1] isEqualToString:installedTreeHash] && manifestParts[2].length == 0) return app;
        return failure(@"Installed payload failed its manifest or code-signature check; refusing to replace it");
    }
    NSString *staging = [versions stringByAppendingPathComponent:[NSString stringWithFormat:@".stage-%d-%@", getpid(), NSUUID.UUID.UUIDString]];
    if (mkdir(staging.fileSystemRepresentation, 0700) != 0) return failure(@"Cannot create payload staging directory");
    NSString *archive = [staging stringByAppendingPathComponent:@"payload.zip"];
    NSString *stageApp = [staging stringByAppendingPathComponent:@"Codex Quota Menubar.app"];
    NSString *stageManifest = [staging stringByAppendingPathComponent:@"payload.sha256"];
    BOOL ok = [zip writeToFile:archive options:NSDataWritingAtomic error:nil] && chmod(archive.fileSystemRepresentation, 0600) == 0 &&
        runTool(@"/usr/bin/ditto", @[@"-x", @"-k", archive, staging]) && unlink(archive.fileSystemRepresentation) == 0 && validSignedApp(stageApp);
    NSString *treeHash = ok ? appTreeSHA256(stageApp) : nil;
    NSString *manifestContents = treeHash ? [NSString stringWithFormat:@"%@\n%@\n", actual, treeHash] : nil;
    ok = ok && manifestContents && [manifestContents writeToFile:stageManifest atomically:YES encoding:NSUTF8StringEncoding error:nil] && chmod(stageManifest.fileSystemRepresentation, 0600) == 0;
    if (ok) ok = rename(staging.fileSystemRepresentation, destination.fileSystemRepresentation) == 0;
    if (!ok) { runTool(@"/bin/rm", @[@"-rf", staging]); return failure(@"Payload extraction, signature validation, or atomic install failed"); }
    return app;
}

static NSString *socketPath(void) {
    NSData *data = [dataDirectory dataUsingEncoding:NSUTF8StringEncoding];
    NSString *digest = sha256Data(data);
    NSString *base = [NSString stringWithFormat:@"/tmp/cqm-%d-%@", getuid(), [digest substringToIndex:12]];
    NSString *physicalBase = [NSString stringWithFormat:@"/private/tmp/cqm-%d-%@", getuid(), [digest substringToIndex:12]];
    if (!secureDirectory(physicalBase, YES)) { lastError = [NSString stringWithFormat:@"Cannot create a safe helper socket directory: %@", lastError ?: base]; return nil; }
    NSString *path = [base stringByAppendingPathComponent:@"events-v2.sock"];
    if (path.length >= sizeof(((struct sockaddr_un *)0)->sun_path)) return nil;
    return path;
}

static BOOL readLineWithTimeout(int fd, char *buffer, size_t cap, int timeoutMS) {
    size_t used = 0;
    while (used + 1 < cap) {
        struct pollfd p = {.fd = fd, .events = POLLIN};
        int ready; do { ready = poll(&p, 1, timeoutMS); } while (ready < 0 && errno == EINTR);
        if (ready <= 0) return NO;
        ssize_t n = recv(fd, buffer + used, 1, 0);
        if (n <= 0) return NO;
        if (buffer[used++] == '\n') { buffer[used] = 0; return YES; }
    }
    return NO;
}

static int connectSocketPath(NSString *path) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0 || S_ISLNK(st.st_mode) || !S_ISSOCK(st.st_mode) || st.st_uid != getuid()) return -1;
    struct sockaddr_un address = {0}; address.sun_family = AF_UNIX; address.sun_len = sizeof(address);
    strlcpy(address.sun_path, path.fileSystemRepresentation, sizeof(address.sun_path));
    int fd = socket(AF_UNIX, SOCK_STREAM, 0); if (fd < 0) return -1;
    int flags = fcntl(fd, F_GETFL, 0); fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    int rc = connect(fd, (struct sockaddr *)&address, sizeof(address));
    if (rc != 0 && errno != EINPROGRESS) { close(fd); return -1; }
    struct pollfd p = {.fd = fd, .events = POLLOUT};
    if (poll(&p, 1, 500) <= 0) { close(fd); return -1; }
    int err = 0; socklen_t len = sizeof(err); getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
    if (err) { close(fd); return -1; }
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    if (send(fd, "Q2", 2, 0) != 2) { close(fd); return -1; }
    char reply[128]; if (!readLineWithTimeout(fd, reply, sizeof(reply), 1000)) { close(fd); return -1; }
    NSString *line = [NSString stringWithUTF8String:reply];
    NSString *expected = [NSString stringWithFormat:@"Q2M:%@\n", @PLUGIN_VERSION];
    NSString *compatible = [NSString stringWithFormat:@"Q2I:%@\n", @PLUGIN_VERSION];
    if ([line hasPrefix:@"Q2E:"]) { lastError = [line stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]; close(fd); return -2; }
    if (![line isEqualToString:expected] && ![line isEqualToString:compatible]) {
        lastError = [NSString stringWithFormat:@"Incompatible helper socket protocol reply: %@", line ?: @"(invalid)"];
        close(fd); return -2;
    }
    return fd;
}

static BOOL waitReady(int fd, pid_t pid) {
    char reply[128]; size_t used = 0;
    while (used + 1 < sizeof(reply)) {
        struct pollfd p = {.fd = fd, .events = POLLIN};
        int elapsed = 0, ready = 0;
        while (elapsed < READY_TIMEOUT_MS && ready == 0) {
            ready = poll(&p, 1, 100);
            if (ready < 0 && errno == EINTR) ready = 0;
            if (ready == 0) { elapsed += 100; if (waitpid(pid, NULL, WNOHANG) == pid) return NO; }
        }
        if (ready <= 0) return NO;
        ssize_t n = recv(fd, reply + used, 1, 0); if (n <= 0) return NO;
        if (reply[used++] == '\n') {
            reply[used] = 0;
            char expected[64]; snprintf(expected, sizeof(expected), "Q2M:%s\n", PLUGIN_VERSION);
            if (strcmp(reply, expected) == 0) return YES;
            lastError = [NSString stringWithFormat:@"Helper ready protocol mismatch: %s", reply]; return NO;
        }
    }
    return NO;
}

static BOOL connectExisting(void) {
    lastError = nil;
    NSString *path = socketPath(); if (!path) { if (!lastError) lastError = @"Cannot create a safe helper socket directory"; return NO; }
    int fd = connectSocketPath(path);
    if (fd == -2) return NO;
    if (fd < 0) return NO;
    eventSocket = fd; helperPID = -1; return YES;
}

static BOOL spawnHelper(void) {
    NSString *app = deployPayload(); if (!app) return NO;
    NSString *path = socketPath(); if (!path) { if (!lastError) lastError = @"Cannot create a safe helper socket directory"; return NO; }
    /* Another plugin instance may have finished installing and starting while
       this registration was validating its copy. Reuse that owner's listener. */
    if (connectExisting()) return YES;
    if (lastError && ([lastError hasPrefix:@"Q2E:"] || [lastError hasPrefix:@"Incompatible helper socket protocol reply:"])) return NO;
    int pair[2]; if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) { lastError = @"Cannot create helper ownership channel"; return NO; }
    for (int i = 0; i < 2; i++) {
        if (pair[i] == 198) {
            int moved = fcntl(pair[i], F_DUPFD_CLOEXEC, 199);
            if (moved < 0) { close(pair[0]); close(pair[1]); lastError = @"Cannot reserve helper ownership descriptor"; return NO; }
            close(pair[i]); pair[i] = moved;
        }
    }
    int yes = 1; setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)); setsockopt(pair[1], SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    fcntl(pair[0], F_SETFD, FD_CLOEXEC); fcntl(pair[1], F_SETFD, FD_CLOEXEC);
    posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pair[0], 198);
    if (pair[0] != 198) posix_spawn_file_actions_addclose(&actions, pair[0]);
    if (pair[1] != 198) posix_spawn_file_actions_addclose(&actions, pair[1]);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawnattr_t attrs; posix_spawnattr_init(&attrs); posix_spawnattr_setflags(&attrs, POSIX_SPAWN_CLOEXEC_DEFAULT);
    NSString *exe = [app stringByAppendingPathComponent:@"Contents/MacOS/QuotaMenubar"];
    char *argv[] = {(char *)exe.fileSystemRepresentation, "--home", (char *)dataDirectory.fileSystemRepresentation,
        "--socket-path", (char *)path.fileSystemRepresentation, "--event-fd", "198", NULL};
    pid_t pid = -1; int rc = posix_spawn(&pid, exe.fileSystemRepresentation, &actions, &attrs, argv, environ);
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attrs); close(pair[0]);
    if (rc != 0) { close(pair[1]); lastError = [NSString stringWithFormat:@"Cannot launch helper (%d)", rc]; return NO; }
    if (!waitReady(pair[1], pid)) {
        kill(pid, SIGTERM); for (int i = 0; i < 100 && waitpid(pid, NULL, WNOHANG) == 0; i++) usleep(10000);
        if (waitpid(pid, NULL, WNOHANG) == 0) { kill(pid, SIGKILL); waitpid(pid, NULL, 0); }
        close(pair[1]);
        if (lastError && [lastError hasPrefix:@"Helper ready protocol mismatch:"]) return NO;
        lastError = nil;
        if (connectExisting()) return YES;
        if (!lastError) lastError = @"Helper did not create its menu status item within five seconds"; return NO;
    }
    int flags = fcntl(pair[1], F_GETFL, 0); if (flags >= 0) fcntl(pair[1], F_SETFL, flags | O_NONBLOCK);
    eventSocket = pair[1]; helperPID = pid; return YES;
}

static BOOL startHelper(void) {
    if (helperPID > 0) {
        int status; pid_t result = waitpid(helperPID, &status, WNOHANG);
        if (result == helperPID || (result < 0 && errno == ECHILD)) { helperPID = -1; if (eventSocket >= 0) close(eventSocket); eventSocket = -1; }
    }
    if (eventSocket >= 0) {
        char c; ssize_t n = recv(eventSocket, &c, 1, MSG_DONTWAIT | MSG_PEEK);
        if (n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
            close(eventSocket); eventSocket = -1;
            if (helperPID > 0) {
                int status; pid_t child = waitpid(helperPID, &status, WNOHANG);
                if (child == helperPID || (child < 0 && errno == ECHILD)) helperPID = -1;
                else return NO;
            }
        }
        else return YES;
    }
    if (helperPID > 0) return NO;
    if (connectExisting()) return YES;
    if (lastError && ([lastError hasPrefix:@"Q2E:"] || [lastError hasPrefix:@"Incompatible helper socket protocol reply:"])) return NO;
    return spawnHelper();
}

static void *reconnectHelper(void *unused) {
    pthread_mutex_lock(&lifecycleLock);
    while (!stopping) {
        if (eventSocket >= 0) {
            char message; ssize_t count = recv(eventSocket, &message, 1, MSG_DONTWAIT);
            if (count > 0 && message == 'D') { suspended = YES; }
            else if (count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
                close(eventSocket); eventSocket = -1;
            }
        }
        if (!suspended && eventSocket < 0) startHelper();
        if (helperPID > 0) {
            pid_t result = waitpid(helperPID, NULL, WNOHANG);
            if (result == helperPID || (result < 0 && errno == ECHILD)) { helperPID = -1; if (eventSocket >= 0) { close(eventSocket); eventSocket = -1; } }
        }
        if (!suspended && eventSocket >= 0 && atomic_exchange(&pendingUsage, 0)) {
            if (send(eventSocket, "U", 1, 0) < 0) atomic_store(&pendingUsage, 1);
        }
        struct timespec deadline; clock_gettime(CLOCK_REALTIME, &deadline); deadline.tv_sec += 1;
        pthread_cond_timedwait(&lifecycleChanged, &lifecycleLock, &deadline);
    }
    pthread_mutex_unlock(&lifecycleLock); return NULL;
}

static void stopOwnedHelper(BOOL terminateOwned) {
    if (eventSocket >= 0) { shutdown(eventSocket, SHUT_RDWR); close(eventSocket); eventSocket = -1; }
    if (terminateOwned && helperPID > 0) {
        int status;
        for (int i = 0; i < 500; i++) { pid_t r = waitpid(helperPID, &status, WNOHANG); if (r == helperPID || (r < 0 && errno == ECHILD)) { helperPID = -1; return; } usleep(10000); }
        kill(helperPID, SIGTERM);
        for (int i = 0; i < 100; i++) { pid_t r = waitpid(helperPID, &status, WNOHANG); if (r == helperPID || (r < 0 && errno == ECHILD)) { helperPID = -1; return; } usleep(10000); }
        kill(helperPID, SIGKILL); waitpid(helperPID, NULL, 0); helperPID = -1;
    } else helperPID = -1;
}

static void stopThreadAndHelper(BOOL terminateOwned) {
    pthread_mutex_lock(&lifecycleLock); stopping = YES; pthread_cond_broadcast(&lifecycleChanged);
    BOOL join = reconnectStarted; pthread_t thread = reconnectThread; reconnectStarted = NO;
    pthread_mutex_unlock(&lifecycleLock);
    if (join && !pthread_equal(pthread_self(), thread)) pthread_join(thread, NULL);
    pthread_mutex_lock(&lifecycleLock); stopOwnedHelper(terminateOwned); pthread_mutex_unlock(&lifecycleLock);
}

static BOOL parseYAMLConfig(NSData *yaml, NSDictionary **out) {
    NSMutableDictionary *config = [NSMutableDictionary dictionary];
    if (!yaml.length) { *out = config; return YES; }
    if (yaml.length > 65536) { lastError = @"Plugin config exceeds 64 KiB"; return NO; }
    NSString *text = [[NSString alloc] initWithData:yaml encoding:NSUTF8StringEncoding];
    if (!text) { lastError = @"Plugin config is not UTF-8 YAML"; return NO; }
    NSSet *allowed = [NSSet setWithArray:@[@"dataDir", @"cpaHome", @"authDir", @"managementPort"]];
    BOOL skipStoreSubtree = NO;
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSUInteger indent = 0;
        while (indent < raw.length && [raw characterAtIndex:indent] == ' ') indent++;
        if (indent < raw.length && [raw characterAtIndex:indent] == '\t') { lastError = @"Tabs are not accepted for YAML indentation"; return NO; }
        NSString *line = [[raw substringFromIndex:indent] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!line.length || [line hasPrefix:@"#"]) continue;
        if (indent > 0 && skipStoreSubtree) continue;
        if (indent > 0) { lastError = @"Nested YAML is only accepted inside the host-owned store manifest"; return NO; }
        skipStoreSubtree = NO;
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) { lastError = @"Plugin config supports scalar key: value entries only"; return NO; }
        NSString *key = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([key isEqualToString:@"enabled"] || [key isEqualToString:@"priority"]) continue;
        if ([key isEqualToString:@"store"]) { skipStoreSubtree = value.length == 0; continue; }
        if (![allowed containsObject:key]) { lastError = [NSString stringWithFormat:@"Unknown plugin config field: %@", key]; return NO; }
        if (config[key]) { lastError = [NSString stringWithFormat:@"Duplicate plugin config field: %@", key]; return NO; }
        if ([value hasPrefix:@"\""]) {
            if (value.length < 2 || ![value hasSuffix:@"\""]) { lastError = @"Invalid quoted plugin config scalar"; return NO; }
            value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
            if ([value containsString:@"\\"] || [value containsString:@"\""]) { lastError = @"Escapes are not accepted in plugin config paths"; return NO; }
        } else if ([value hasPrefix:@"'"]) {
            if (value.length < 2 || ![value hasSuffix:@"'"]) { lastError = @"Invalid quoted plugin config scalar"; return NO; }
            value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
            if ([value containsString:@"'"]) { lastError = @"Escaped YAML scalars are not accepted"; return NO; }
        } else {
            NSRange comment = [value rangeOfString:@" #"]; if (comment.location != NSNotFound) value = [[value substringToIndex:comment.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
        if ([key isEqualToString:@"managementPort"]) {
            NSScanner *scanner = [NSScanner scannerWithString:value]; NSInteger port = 0;
            if (![scanner scanInteger:&port] || !scanner.isAtEnd || port < 1 || port > 65535) { lastError = @"managementPort must be an integer between 1 and 65535"; return NO; }
            config[key] = @(port);
        } else {
            if (!value.length || [@[@"null", @"~", @"true", @"false", @"yes", @"no"] containsObject:value.lowercaseString]) { lastError = [NSString stringWithFormat:@"%@ must be a non-empty string path", key]; return NO; }
            config[key] = value;
        }
    }
    *out = config; return YES;
}

static BOOL persistSettings(NSDictionary *config) {
    NSString *settingsDir = [dataDirectory stringByAppendingPathComponent:@"cpa-plugin"];
    if (!secureDirectory(settingsDir, YES)) { lastError = @"Cannot create a safe cpa-plugin settings directory"; return NO; }
    NSString *path = [settingsDir stringByAppendingPathComponent:@"settings.json"];
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) == 0) {
        if (!safeOwnedFile(path, &st) || st.st_size > 1024 * 1024) { lastError = @"Unsafe or oversized existing settings.json"; return NO; }
        NSData *old = [NSData dataWithContentsOfFile:path]; id decoded = old ? [NSJSONSerialization JSONObjectWithData:old options:NSJSONReadingMutableContainers error:nil] : nil;
        if (![decoded isKindOfClass:[NSDictionary class]]) { lastError = @"Existing settings.json is not a JSON object"; return NO; }
        [settings addEntriesFromDictionary:decoded];
    } else if (errno != ENOENT) { lastError = @"Cannot inspect settings.json"; return NO; }
    if (settings[@"selectedAuthIndex"] && ![settings[@"selectedAuthIndex"] isKindOfClass:[NSString class]]) { lastError = @"Existing selectedAuthIndex has an invalid type"; return NO; }
    settings[@"cpaHome"] = cpaHome;
    settings[@"authDir"] = authDirectory ?: [NSNull null];
    settings[@"managementPort"] = @(managementPort);
    NSData *json = [NSJSONSerialization dataWithJSONObject:settings options:NSJSONWritingPrettyPrinted error:nil];
    if (!json) { lastError = @"Could not serialize plugin settings"; return NO; }
    NSString *temp = [settingsDir stringByAppendingPathComponent:[NSString stringWithFormat:@".settings-%@.tmp", NSUUID.UUID.UUIDString]];
    int fd = open(temp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) { lastError = @"Cannot create temporary settings file"; return NO; }
    const uint8_t *cursor = json.bytes; size_t left = json.length; BOOL ok = YES;
    while (left) { ssize_t n = write(fd, cursor, left); if (n < 0 && errno == EINTR) continue; if (n <= 0) { ok = NO; break; } cursor += n; left -= (size_t)n; }
    if (fsync(fd) != 0) ok = NO; close(fd);
    if (ok && rename(temp.fileSystemRepresentation, path.fileSystemRepresentation) != 0) ok = NO;
    if (!ok) { unlink(temp.fileSystemRepresentation); lastError = @"Could not atomically save plugin settings"; return NO; }
    chmod(path.fileSystemRepresentation, 0600); return YES;
}

static BOOL applyConfiguration(uint8_t *request, size_t length) {
    if (!request || length == 0 || length > MAX_REQUEST_BYTES) { lastError = @"Invalid lifecycle request"; return NO; }
    NSData *bytes = [NSData dataWithBytes:request length:length]; NSDictionary *body = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    if (![body isKindOfClass:[NSDictionary class]]) { lastError = @"Lifecycle request must be a JSON object"; return NO; }
    if (body[@"schema_version"]) {
        NSInteger schemaVersion = [body[@"schema_version"] integerValue];
        if (schemaVersion < 1 || schemaVersion > 6) { lastError = @"Unsupported lifecycle schema_version (supported versions: 1 through 6)"; return NO; }
    }
    NSData *yaml = nil; id encoded = body[@"config_yaml"];
    if (encoded && ![encoded isKindOfClass:[NSString class]]) { lastError = @"config_yaml must be base64 text"; return NO; }
    if ([encoded isKindOfClass:[NSString class]] && [encoded length]) { yaml = [[NSData alloc] initWithBase64EncodedString:encoded options:0]; if (!yaml) { lastError = @"config_yaml is invalid base64"; return NO; } }
    NSDictionary *config; if (!parseYAMLConfig(yaml, &config)) return NO;
    NSString *newData = expandAbsolutePath(config[@"dataDir"], @"~/Library/Application Support/CodexQuotaMenubar");
    NSString *newCPA = expandAbsolutePath(config[@"cpaHome"], @"~/Library/Application Support/com.cpa.gui");
    NSString *newAuth = config[@"authDir"] ? expandAbsolutePath(config[@"authDir"], nil) : nil;
    if (!newData || !newCPA || (config[@"authDir"] && !newAuth)) { lastError = @"dataDir, cpaHome and authDir must resolve to absolute paths"; return NO; }
    NSInteger port = config[@"managementPort"] ? [config[@"managementPort"] integerValue] : 8317;
    if ((config[@"managementPort"] && (port < 1 || port > 65535))) { lastError = @"Invalid managementPort"; return NO; }
    BOOL changed = ![dataDirectory isEqualToString:newData] || ![cpaHome isEqualToString:newCPA] || !((authDirectory == newAuth) || [authDirectory isEqualToString:newAuth]) || managementPort != port;
    if (changed && reconnectStarted) stopThreadAndHelper(YES);
    dataDirectory = newData; cpaHome = newCPA; authDirectory = newAuth; managementPort = port;
    if (!secureDirectory(dataDirectory, YES)) { if (!lastError) lastError = @"dataDir is unsafe, contains a symlink, or is not user-owned"; return NO; }
    if (!persistSettings(config)) return NO;
    pthread_mutex_lock(&lifecycleLock); stopping = NO; lastError = nil;
    BOOL ready = YES;
    if (!reconnectStarted) {
        suspended = NO;
        ready = startHelper();
        if (ready) { if (pthread_create(&reconnectThread, NULL, reconnectHelper, NULL) != 0) { ready = NO; lastError = @"Could not start helper reconnect thread"; } else reconnectStarted = YES; }
    }
    pthread_cond_broadcast(&lifecycleChanged); pthread_mutex_unlock(&lifecycleLock);
    return ready;
}

static void quiescePlugin(void) { stopThreadAndHelper(YES); }
static void shutdownPlugin(void) { quiescePlugin(); }
static void freeResponse(void *pointer, size_t length) { free(pointer); }

static int callPlugin(char *method, uint8_t *request, size_t requestLength, cliproxy_buffer *response) {
    @autoreleasepool {
        if (!response) return 1; response->ptr = NULL; response->len = 0;
        NSString *name = method ? [NSString stringWithUTF8String:method] : nil; BOOL accepted = YES; NSDictionary *result = @{};
        if ([name isEqualToString:@"plugin.register"] || [name isEqualToString:@"plugin.reconfigure"]) {
            accepted = applyConfiguration(request, requestLength);
            result = @{@"schema_version": @1,
                @"metadata": @{@"Name": @"codex-quota-menubar", @"Version": @PLUGIN_VERSION,
                    @"Author": @"RoyalXC", @"GitHubRepository": @"https://github.com/RoyalXC/cpa-plugin-codex-quota-menubar",
                    @"ConfigFields": @[
                        @{@"Name": @"dataDir", @"Type": @"string", @"Description": @"Absolute plugin data directory"},
                        @{@"Name": @"cpaHome", @"Type": @"string", @"Description": @"Absolute CPA home directory"},
                        @{@"Name": @"authDir", @"Type": @"string", @"Description": @"Optional absolute auth directory"},
                        @{@"Name": @"managementPort", @"Type": @"integer", @"Description": @"CPA management port"} ]},
                @"capabilities": @{@"usage_plugin": @YES}};
        } else if ([name isEqualToString:@"plugin.quiesce"]) {
            quiescePlugin();
        } else if ([name isEqualToString:@"plugin.shutdown"]) {
            shutdownPlugin();
        } else if ([name isEqualToString:@"usage.handle"]) {
            BOOL generated = YES;
            if (request && requestLength && requestLength <= MAX_REQUEST_BYTES) {
                id body = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:request length:requestLength] options:0 error:nil];
                if ([body isKindOfClass:[NSDictionary class]]) {
                    id record = body[@"record"] ?: body[@"Record"] ?: body;
                    if ([record isKindOfClass:[NSDictionary class]]) {
                        id flag = record[@"generate"] ?: record[@"Generate"];
                        if ([flag isKindOfClass:[NSNumber class]]) generated = [flag boolValue];
                    }
                }
            }
            if (generated) atomic_store(&pendingUsage, 1);
            if (pthread_mutex_trylock(&lifecycleLock) == 0) { pthread_cond_signal(&lifecycleChanged); pthread_mutex_unlock(&lifecycleLock); }
        } else { accepted = NO; lastError = [NSString stringWithFormat:@"Unsupported plugin method: %@", name ?: @"(null)"]; }
        NSDictionary *envelope = accepted ? @{@"ok": @YES, @"result": result} :
            @{@"ok": @NO, @"error": @{@"code": @"plugin_error", @"message": lastError ?: @"Plugin lifecycle command failed"}};
        NSData *data = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
        response->ptr = malloc(data.length); if (!response->ptr) return 1;
        memcpy(response->ptr, data.bytes, data.length); response->len = data.length; return accepted ? 0 : 1;
    }
}

__attribute__((visibility("default")))
int cliproxy_plugin_init(const cliproxy_host_api *host, cliproxy_plugin_api *plugin) {
    if (!host || host->abi_version != 1 || !plugin) return 1;
    plugin->abi_version = 1; plugin->call = callPlugin; plugin->free_buffer = freeResponse; plugin->shutdown = shutdownPlugin; return 0;
}
