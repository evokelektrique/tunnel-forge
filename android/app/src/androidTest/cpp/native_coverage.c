#include <jni.h>
#include <stddef.h>

void __llvm_profile_set_filename(const char *name);
int __llvm_profile_write_file(void);

JNIEXPORT jint JNICALL Java_io_github_evokelektrique_tunnelforge_NativeCoverage_writeProfile(JNIEnv *env, jclass type,
                                                                                            jstring file) {
  (void)type;
  const char *path = (*env)->GetStringUTFChars(env, file, NULL);
  if (path == NULL)
    return -1;
  __llvm_profile_set_filename(path);
  int result = __llvm_profile_write_file();
  (*env)->ReleaseStringUTFChars(env, file, path);
  return result;
}
