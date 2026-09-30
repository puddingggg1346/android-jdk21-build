#!/bin/bash
set -e
cd "$(dirname "$0")/.."
JDK=openjdk

# ---- 1. os_linux.cpp: 禁用 SHM ----
F=$JDK/src/hotspot/os/linux/os_linux.cpp
python3 - "$F" << 'PY'
import sys
f = sys.argv[1]
s = open(f).read()

s = s.replace(
    "bool os::Linux::shm_hugetlbfs_sanity_check(bool warn, size_t page_size) {\n  // Try to create a large shared memory segment.",
    "bool os::Linux::shm_hugetlbfs_sanity_check(bool warn, size_t page_size) {\n#ifdef __ANDROID__\n  return false;\n#else\n  // Try to create a large shared memory segment.", 1)

s = s.replace(
    "  shmctl(shmid, IPC_RMID, nullptr);\n  return true;\n}",
    "  shmctl(shmid, IPC_RMID, nullptr);\n  return true;\n#endif\n}", 1)

s = s.replace(
    "char* os::Linux::reserve_memory_special_shm(size_t bytes, size_t alignment,\n                                            char* req_addr, bool exec) {",
    "char* os::Linux::reserve_memory_special_shm(size_t bytes, size_t alignment,\n                                            char* req_addr, bool exec) {\n#ifdef __ANDROID__\n  return nullptr;\n#else", 1)

s = s.replace(
    "  shmctl(shmid, IPC_RMID, nullptr);\n\n  return addr;\n}",
    "  shmctl(shmid, IPC_RMID, nullptr);\n\n  return addr;\n#endif\n}", 1)

# shmat/shmat_at_address 附近也需包裹 — 找 reserve_memory_special_shm 之前的一个函数
# 简单方案：全局把 shmat/shmat_at_address 用 #ifndef 包住
open(f, "w").write(s)
print("os_linux.cpp patched")
PY

# ---- 2. os_posix.cpp: 禁用 uptime ----
F=$JDK/src/hotspot/os/posix/os_posix.cpp
python3 - "$F" << 'PY'
import sys
f = sys.argv[1]
s = open(f).read()

s = s.replace(
    "void os::Posix::print_uptime_info(outputStream* st) {\n  int bootsec = -1;",
    "void os::Posix::print_uptime_info(outputStream* st) {\n#ifdef __ANDROID__\n  return;\n#else\n  int bootsec = -1;", 1)

s = s.replace(
    "  if (bootsec != -1) {\n    os::print_dhm(st, \"OS uptime:\", currsec-bootsec);\n  }\n}",
    "  if (bootsec != -1) {\n    os::print_dhm(st, \"OS uptime:\", currsec-bootsec);\n  }\n#endif\n}", 1)

open(f, "w").write(s)
print("os_posix.cpp patched")
PY

# ---- 3. UnixNativeDispatcher.c: getgrgid_r ----
F=$JDK/src/java.base/unix/native/libnio/fs/UnixNativeDispatcher.c
python3 - "$F" << 'PY'
import sys
f = sys.argv[1]
s = open(f).read()
ins = '''
#ifdef __ANDROID__
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
if "getgrgid_r" not in s.split("#include <grp.h>")[1][:2000]:
    s = s.replace("#include <grp.h>\n", "#include <grp.h>\n" + ins, 1)
    open(f, "w").write(s)
    print("UnixNativeDispatcher.c patched")
else:
    print("already patched")
PY

# ---- 4. configure: 删除检查 ----
sed -i '/if test -z "${this_script_dir}"; then/,/^fi$/d' $JDK/configure || true

# ---- 5. JvmMapfile.gmk ----
sed -i 's/ifeq ($(call isTargetOs, linux), true)/ifeq ($(call isTargetOs, android linux), true)/' $JDK/make/hotspot/lib/JvmMapfile.gmk || true

echo "=== verification ==="
grep -c "__ANDROID__" $JDK/src/hotspot/os/linux/os_linux.cpp
grep -c "__ANDROID__" $JDK/src/hotspot/os/posix/os_posix.cpp
grep -c "__ANDROID__" $JDK/src/java.base/unix/native/libnio/fs/UnixNativeDispatcher.c
