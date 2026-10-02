#define _GNU_SOURCE
#include <jni.h>
#include <dlfcn.h>
#include <errno.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "log.h"

#include "utils.h"

typedef int (*Main_Function_t)(int, char**);
typedef void (*android_update_LD_LIBRARY_PATH_t)(char*);

static char cpu_affinity_diagnostics[384] = "not configured";

static int count_affinity_cpus(const cpu_set_t *set) {
    int count = 0;
    for (int cpu = 0; cpu < CPU_SETSIZE; cpu++) {
        if (CPU_ISSET(cpu, set)) count++;
    }
    return count;
}

static unsigned long long affinity_mask64(const cpu_set_t *set) {
    unsigned long long mask = 0;
    for (int cpu = 0; cpu < 64 && cpu < CPU_SETSIZE; cpu++) {
        if (CPU_ISSET(cpu, set)) mask |= 1ULL << cpu;
    }
    return mask;
}

char** convert_to_char_array(JNIEnv *env, jobjectArray jstringArray) {
	int num_rows = (*env)->GetArrayLength(env, jstringArray);
	char **cArray = (char **) malloc(num_rows * sizeof(char*));
	jstring row;
	
	for (int i = 0; i < num_rows; i++) {
		row = (jstring) (*env)->GetObjectArrayElement(env, jstringArray, i);
		cArray[i] = (char*)(*env)->GetStringUTFChars(env, row, 0);
    }
	
    return cArray;
}

void free_char_array(JNIEnv *env, jobjectArray jstringArray, const char **charArray) {
	int num_rows = (*env)->GetArrayLength(env, jstringArray);
	jstring row;
	
	for (int i = 0; i < num_rows; i++) {
		row = (jstring) (*env)->GetObjectArrayElement(env, jstringArray, i);
		(*env)->ReleaseStringUTFChars(env, row, charArray[i]);
	}
}

jstring convertStringJVM(JNIEnv* srcEnv, JNIEnv* dstEnv, jstring srcStr) {
	if (srcStr == NULL) {
		return NULL;
	}

	const char* srcStrC = (*srcEnv)->GetStringUTFChars(srcEnv, srcStr, 0);
	jstring dstStr = (*dstEnv)->NewStringUTF(dstEnv, srcStrC);
	(*srcEnv)->ReleaseStringUTFChars(srcEnv, srcStr, srcStrC);
	return dstStr;
}

JNIEXPORT jint JNICALL Java_android_os_OpenJDKNativeRegister_nativeRegisterNatives(JNIEnv *env, jclass clazz, jstring registerSymbol) {
	const char *register_symbol_c = (*env)->GetStringUTFChars(env, registerSymbol, 0);
	void *symbol = dlsym(RTLD_DEFAULT, register_symbol_c);
	if (symbol == NULL) {
		printf("dlsym %s failed: %s\n", register_symbol_c, dlerror());
		return -1;
	}
	
	int (*registerNativesForClass)(JNIEnv*) = symbol;
	int result = registerNativesForClass(env);
	(*env)->ReleaseStringUTFChars(env, registerSymbol, register_symbol_c);
	
	return (jint) result;
}

JNIEXPORT void JNICALL Java_pojlib_util_JREUtils_setLdLibraryPath(JNIEnv *env, jclass clazz, jstring ldLibraryPath) {
	android_update_LD_LIBRARY_PATH_t android_update_LD_LIBRARY_PATH;
	
	void *libdl_handle = dlopen("libdl.so", RTLD_LAZY);
	void *updateLdLibPath = dlsym(libdl_handle, "android_update_LD_LIBRARY_PATH");
	if (updateLdLibPath == NULL) {
		updateLdLibPath = dlsym(libdl_handle, "__loader_android_update_LD_LIBRARY_PATH");
		if (updateLdLibPath == NULL) {
			char *dl_error_c = dlerror();
			LOGE("Error getting symbol android_update_LD_LIBRARY_PATH: %s", dl_error_c);
		}
	}
	
	android_update_LD_LIBRARY_PATH = (android_update_LD_LIBRARY_PATH_t) updateLdLibPath;
	const char* ldLibPathUtf = (*env)->GetStringUTFChars(env, ldLibraryPath, 0);
	android_update_LD_LIBRARY_PATH(ldLibPathUtf);
	(*env)->ReleaseStringUTFChars(env, ldLibraryPath, ldLibPathUtf);
}

JNIEXPORT jboolean JNICALL Java_pojlib_util_JREUtils_dlopen(JNIEnv *env, jclass clazz, jstring name) {
	const char *nameUtf = (*env)->GetStringUTFChars(env, name, 0);
	void* handle = dlopen(nameUtf, RTLD_GLOBAL | RTLD_LAZY);
	if (!handle) {
		LOGE("dlopen %s failed: %s", nameUtf, dlerror());
	} else {
		LOGD("dlopen %s success", nameUtf);
	}
	(*env)->ReleaseStringUTFChars(env, name, nameUtf);
	return handle != NULL;
}

JNIEXPORT jstring JNICALL Java_pojlib_util_JREUtils_dlerror(JNIEnv *env, jclass clazz) {
    char* err = dlerror();
    if(err == NULL) {
        return NULL;
    }
    jstring dstStr = (*env)->NewStringUTF(env, err);

	return dstStr;
}

JNIEXPORT jint JNICALL Java_pojlib_util_JREUtils_chdir(JNIEnv *env, jclass clazz, jstring nameStr) {
	const char *name = (*env)->GetStringUTFChars(env, nameStr, NULL);
	int retval = chdir(name);
	(*env)->ReleaseStringUTFChars(env, nameStr, name);
	return retval;
}

JNIEXPORT jint JNICALL Java_pojlib_util_JREUtils_configureCpuAffinity(JNIEnv *env, jclass clazz) {
    cpu_set_t before;
    cpu_set_t requested;
    cpu_set_t after;
    CPU_ZERO(&before);
    CPU_ZERO(&requested);
    CPU_ZERO(&after);

    int beforeResult = sched_getaffinity(0, sizeof(before), &before);
    int beforeCount = beforeResult == 0 ? count_affinity_cpus(&before) : 0;
    long configured = sysconf(_SC_NPROCESSORS_CONF);
    long online = sysconf(_SC_NPROCESSORS_ONLN);

    // Do not size this request from sysconf(). Android may make sysconf cpuset-aware,
    // which is exactly the three-core view we are trying to escape before HotSpot
    // starts. Linux safely intersects this full mask with physically present CPUs
    // and the process' permitted cpuset.
    for (int cpu = 0; cpu < CPU_SETSIZE; cpu++) CPU_SET(cpu, &requested);

    errno = 0;
    int setResult = sched_setaffinity(0, sizeof(requested), &requested);
    int setError = errno;
    int afterResult = sched_getaffinity(0, sizeof(after), &after);
    int afterCount = afterResult == 0 ? count_affinity_cpus(&after) : beforeCount;
    if (afterCount < 1) afterCount = 1;

    snprintf(cpu_affinity_diagnostics, sizeof(cpu_affinity_diagnostics),
            "sysconfConfigured=%ld sysconfOnline=%ld before=%d mask=0x%llx "
            "requested=all setResult=%d errno=%d(%s) after=%d mask=0x%llx",
            configured, online, beforeCount, affinity_mask64(&before), setResult, setError,
            setError == 0 ? "none" : strerror(setError), afterCount, affinity_mask64(&after));
    __android_log_print(ANDROID_LOG_INFO, "QuestCraft", "JVM CPU affinity: %s",
            cpu_affinity_diagnostics);
    return (jint) afterCount;
}

JNIEXPORT jstring JNICALL Java_pojlib_util_JREUtils_getCpuAffinityDiagnostics(JNIEnv *env, jclass clazz) {
    return (*env)->NewStringUTF(env, cpu_affinity_diagnostics);
}

JNIEXPORT jint JNICALL Java_pojlib_util_JREUtils_executeBinary(JNIEnv *env, jclass clazz, jobjectArray cmdArgs) {
	jclass exception_cls = (*env)->FindClass(env, "java/lang/UnsatisfiedLinkError");
	jstring execFile = (*env)->GetObjectArrayElement(env, cmdArgs, 0);
	
	char *exec_file_c = (char*) (*env)->GetStringUTFChars(env, execFile, 0);
	void *exec_binary_handle = dlopen(exec_file_c, RTLD_LAZY);
	
	(*env)->ReleaseStringUTFChars(env, execFile, exec_file_c);
	
	char *exec_error_c = dlerror();
	if (exec_error_c != NULL) {
		LOGE("Error: %s", exec_error_c);
		(*env)->ThrowNew(env, exception_cls, exec_error_c);
		return -1;
	}
	
	Main_Function_t Main_Function;
	Main_Function = (Main_Function_t) dlsym(exec_binary_handle, "main");
	
	exec_error_c = dlerror();
	if (exec_error_c != NULL) {
		LOGE("Error: %s", exec_error_c);
		(*env)->ThrowNew(env, exception_cls, exec_error_c);
		return -1;
	}
	
	int cmd_argv = (*env)->GetArrayLength(env, cmdArgs);
	char **cmd_args_c = convert_to_char_array(env, cmdArgs);
	int result = Main_Function(cmd_argv, cmd_args_c);
	free_char_array(env, cmdArgs, cmd_args_c);
	return result;
}

