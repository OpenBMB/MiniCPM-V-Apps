// JNI surface for the NPU vision tower. Kept in its own file so the OCR path
// can be switched on/off without touching llama_jni.cpp's runtime plumbing.

#include "qnn_vit.h"

#include <android/log.h>
#include <jni.h>

#define TAG "QnnVitJni"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

extern "C" JNIEXPORT jint JNICALL
Java_com_example_minicpm_1v_1demo_QnnVit_nativeInit(JNIEnv * env, jclass, jstring jSkelDir,
                                                    jstring jBinPath, jint jArch) {
    const char * skel = env->GetStringUTFChars(jSkelDir, nullptr);
    const char * bin = env->GetStringUTFChars(jBinPath, nullptr);
    const int rc = qnnvit::init(skel, bin, (int) jArch);
    env->ReleaseStringUTFChars(jSkelDir, skel);
    env->ReleaseStringUTFChars(jBinPath, bin);
    return rc;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_minicpm_1v_1demo_QnnVit_nativeRuntimeAvailable(JNIEnv *, jclass) {
    return qnnvit::runtime_available() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_minicpm_1v_1demo_QnnVit_nativeReady(JNIEnv *, jclass) {
    return qnnvit::ready() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_minicpm_1v_1demo_QnnVit_nativeShutdown(JNIEnv *, jclass) {
    qnnvit::shutdown();
}

// `rgba` is (posW*14) x (posH*14) pixels, 4 bytes each, row major.
extern "C" JNIEXPORT jint JNICALL
Java_com_example_minicpm_1v_1demo_QnnVit_nativeEncode(JNIEnv * env, jclass, jbyteArray jRgba,
                                                      jint posW, jint posH) {
    if (posW <= 0 || posH <= 0) {
        LOGE("encode: bad grid %dx%d", posW, posH);
        return -1;
    }
    const jsize size = env->GetArrayLength(jRgba);
    const jsize want = posW * qnnvit::kPatch * posH * qnnvit::kPatch * 4;
    if (size != want) {
        LOGE("encode: got %d bytes, want %d for a %dx%d grid", size, want, posW, posH);
        return -1;
    }
    jbyte * data = env->GetByteArrayElements(jRgba, nullptr);
    if (!data) {
        return -1;
    }
    const int rc = qnnvit::encode_rgba(reinterpret_cast<const uint8_t *>(data), posW, posH);
    env->ReleaseByteArrayElements(jRgba, data, JNI_ABORT);
    return rc;
}
