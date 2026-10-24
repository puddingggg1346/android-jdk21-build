#!/bin/bash
set -e
cd "$(dirname "$0")/.."
JDK=openjdk

# ---- 1. os_linux.cpp: stub SysV SHM ----
F=$JDK/src/hotspot/os/linux/os_linux.cpp
python3 - "$F" << 'PY'
import sys, re
f = sys.argv[1]
s = open(f).read()
if 'Bionic has no SysV SHM' in s:
    print("os_linux: already")
else:
    stubs = '''
#if defined(__ANDROID__) || defined(ANDROID)
/* Bionic has no SysV SHM */
#define shmget(k,s,f) (-1)
#define shmctl(i,c,b) (-1)
#define shmat(i,a,f) ((void*)-1)
#define shmdt(a) (-1)
#define IPC_PRIVATE 0
#define IPC_CREAT 01000
#define IPC_RMID 0
#define SHM_R 0400
#define SHM_W 0200
#define SHM_HUGETLB 04000
#endif
'''
    ms = list(re.finditer(r'^#include .*$', s, re.MULTILINE))
    last = ms[-1]
    s = s[:last.end()] + stubs + s[last.end():]
    open(f, "w").write(s)
    print("os_linux: stubs inserted")
PY

# ---- 2. os_posix.cpp: guard print_uptime_info ----
F=$JDK/src/hotspot/os/posix/os_posix.cpp
python3 - "$F" << 'PY'
import sys
f = sys.argv[1]
s = open(f).read()
if '__ANDROID_DISABLE_UPTIME__' in s:
    print("os_posix: already")
else:
    sig = "void os::Posix::print_uptime_info(outputStream* st)"
    idx = s.find(sig)
    if idx < 0:
        print("os_posix: NOT FOUND"); sys.exit(1)
    brace = s.find('{', idx)
    depth = 1
    i = brace + 1
    while i < len(s) and depth > 0:
        c = s[i]
        if c == '{': depth += 1
        elif c == '}': depth -= 1
        i += 1
    new_s = (s[:brace+1]
             + "\n#if defined(__ANDROID__) || defined(ANDROID)\n  /* __ANDROID_DISABLE_UPTIME__ */\n  return;\n#else\n"
             + s[brace+1:i-1]
             + "\n#endif\n"
             + s[i-1:])
    open(f, "w").write(new_s)
    print("os_posix: guarded")
PY

# ---- 3. UnixNativeDispatcher.c ----
F=$JDK/src/java.base/unix/native/libnio/fs/UnixNativeDispatcher.c
python3 - "$F" << 'PY'
import sys
f = sys.argv[1]
s = open(f).read()
if '__ANDROID_GETGR__' in s or 'int getgrgid_r' in s:
    print("dispatch: upstream patch already provides getgrgid_r, skip")
else:
    ins = '''
// __ANDROID_GETGR__
#if defined(__ANDROID__) || defined(ANDROID)
int getgrgid_r(gid_t gid, struct group* grp, char* buf, size_t buflen, struct group** result) {
  *result = NULL; errno = 0;
  struct group* g = getgrgid(gid);
  if (g == NULL) return errno;
  *result = g; return 0;
}
int getgrnam_r(const char* name, struct group* grp, char* buf, size_t buflen, struct group** result) {
  *result = NULL; errno = 0;
  struct group* g = getgrnam(name);
  if (g == NULL) return errno;
  *result = g; return 0;
}
#endif
'''
    s = s.replace("#include <grp.h>\n", "#include <grp.h>\n" + ins, 1)
    open(f, "w").write(s)
    print("dispatch: patched")
PY

# ---- 3b. libnet: bionic needs <netinet/in.h> for sockaddr_in ----
# 关键：原 Android patch 在文件开头加了 forward declaration 'struct sockaddr_in;'
# 我们的 include 必须插到 header guard 之后、所有内容之前
for F2 in $JDK/src/java.base/unix/native/libnet/net_util_md.h \
          $JDK/src/java.base/unix/native/libnet/net_util_md.c; do
  python3 - "$F2" << 'PY2'
import sys, re
f = sys.argv[1]
s = open(f).read()
if '__ANDROID_NETINET__' in s:
    print(f + ": already")
    sys.exit(0)

ins = """
#if defined(__ANDROID__) || defined(ANDROID)
/* __ANDROID_NETINET__ */
#include <sys/socket.h>
#include <netinet/in.h>
#endif
"""

# 定位 header guard 之后（#ifndef ... \n#define ... \n）
m = re.search(r'#ifndef[^\n]*\n#define[^\n]*\n', s)
if m:
    pos = m.end()
else:
    pos = 0

# 跳过多余空行
while pos < len(s) and s[pos] in ' \t\r\n':
    pos += 1

s = s[:pos] + ins + s[pos:]
open(f, 'w').write(s)
print(f + ": netinet inserted at pos %d" % pos)
print("=== first 15 lines ===")
for i, line in enumerate(s.split('\n')[:15], 1):
    print("%3d %s" % (i, line))
PY2
done

# ---- 4. configure ----
sed -i '/if test -z "${this_script_dir}"; then/,/^fi$/d' $JDK/configure || true

# ---- 5. JvmMapfile.gmk ----
sed -i 's/ifeq ($(call isTargetOs, linux), true)/ifeq ($(call isTargetOs, android linux), true)/' $JDK/make/hotspot/lib/JvmMapfile.gmk || true

echo "=== verify ==="
grep -c "Bionic has no SysV SHM" $JDK/src/hotspot/os/linux/os_linux.cpp
grep -c "__ANDROID_DISABLE_UPTIME__" $JDK/src/hotspot/os/posix/os_posix.cpp
grep -c "__ANDROID_GETGR__" $JDK/src/java.base/unix/native/libnio/fs/UnixNativeDispatcher.c || true
