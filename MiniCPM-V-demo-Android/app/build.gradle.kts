plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "com.example.minicpm_v_demo"
    compileSdk {
        version = release(36) {
            minorApiLevel = 1
        }
    }
    ndkVersion = "27.0.12077973"

    defaultConfig {
        // `namespace` stays as the Kotlin package (it only names the generated R
        // class). `applicationId` is the real app identity seen by the device and
        // Play Store, so it must not be the `com.example.*` scaffold default.
        applicationId = "com.tianchi.minicpmv"
        // minSdk = 24 (Android 7.0) covers ~99% of in-use devices.
        // The native code only requires arm64-v8a (Android 5.0+), and the
        // app itself uses no Android 13+ APIs. The adaptive icon XML is
        // placed under mipmap-anydpi-v26/ so pre-Oreo devices fall back
        // to the WebP icons in mipmap-{m,h,xh,xxh,xxxh}dpi/.
        minSdk = 24
        targetSdk = 36
        versionCode = 18
        versionName = "2.6"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        ndk {
            abiFilters.add("arm64-v8a")
        }

        externalNativeBuild {
            cmake {
                arguments += "-DCMAKE_BUILD_TYPE=Release"
                arguments += "-DBUILD_SHARED_LIBS=ON"
                arguments += "-DLLAMA_BUILD_COMMON=ON"
                arguments += "-DLLAMA_BUILD_TOOLS=ON"
                arguments += "-DLLAMA_OPENSSL=OFF"

                arguments += "-DGGML_NATIVE=OFF"
                arguments += "-DGGML_LLAMAFILE=ON"
                arguments += "-DLLAMA_CURL=OFF"
                // 16 KB page size. NDK r27 still defaults to 4 KB LOAD alignment.
                arguments += "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON"
            }
        }
    }

    // Release signing config. Credentials live in ~/.gradle/gradle.properties
    // (outside any git repo, only readable by your local mac account).
    // If those properties aren't set the release build still works but produces
    // an unsigned apk - useful e.g. on CI without secrets.
    signingConfigs {
        create("release") {
            val keystorePath = providers.gradleProperty("MINICPMV_KEYSTORE").orNull
            if (!keystorePath.isNullOrBlank()) {
                storeFile = file(keystorePath)
                storePassword = providers.gradleProperty("MINICPMV_KEYSTORE_PASSWORD").orNull
                keyAlias = providers.gradleProperty("MINICPMV_KEY_ALIAS").orNull
                keyPassword = providers.gradleProperty("MINICPMV_KEY_PASSWORD").orNull
            }
            // AGP leaves v3 off by default, which makes `apksigner verify`
            // report it missing; Play and most OEM installers want it.
            enableV3Signing = true
        }
    }

    buildTypes {
        release {
            // Keep ProGuard/R8 disabled: the app calls native JNI symbols and
            // shrinking the Kotlin side has no measurable benefit here, while
            // an over-aggressive shrinker is the most common cause of crashes
            // in apps with lots of JNI bindings.
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // Only attach the signing config when the keystore actually exists,
            // so contributors without the secret can still run :assembleRelease
            // (it'll produce an unsigned apk in that case).
            val signingCfg = signingConfigs.getByName("release")
            if (signingCfg.storeFile?.exists() == true) {
                signingConfig = signingCfg
            }
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "4.1.2"
        }
    }
    buildFeatures {
        viewBinding = true
    }

    androidResources {
        noCompress.add("gguf")
        noCompress.add("bin")
        noCompress.add("onnx")
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.appcompat)
    implementation(libs.material)
    implementation(libs.androidx.constraintlayout)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.ktx)
    implementation(libs.androidx.activity.ktx)
    implementation("androidx.coordinatorlayout:coordinatorlayout:1.2.0")
    implementation("androidx.recyclerview:recyclerview:1.3.2")

    // Markdown rendering for AI streaming responses (headings, bold, lists, code, etc.)
    implementation("io.noties.markwon:core:4.6.2")
    // Renders $$...$$ math in OCR output. Pulls in ru.noties:jlatexmath-android,
    // whose fonts are latin-only -- CJK inside \text{} cannot be shown and is
    // stripped before rendering (see OcrLatexMarkdown).
    implementation("io.noties.markwon:ext-latex:4.6.2")
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.22.0")
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
}

// ---------------------------------------------------------------------------
// Dynamic CPU dispatch: build an additional libggml-cpu.so optimised for
// ARMv8.6-a (i8mm + bf16) and package it alongside the baseline build.
// At runtime the Kotlin CpuFeatures helper detects hardware capabilities
// and pre-loads the best variant before the rest of the native chain.
// ---------------------------------------------------------------------------

fun runCmd(vararg args: String) {
    val proc = ProcessBuilder(*args).inheritIO().start()
    val rc = proc.waitFor()
    if (rc != 0) error("Command failed (rc=$rc): ${args.joinToString(" ")}")
}

val sdkRoot: String = System.getenv("ANDROID_HOME")
    ?: file("../local.properties").takeIf { it.exists() }?.readLines()
        ?.firstOrNull { it.startsWith("sdk.dir=") }?.substringAfter("=")
    ?: error("Cannot locate Android SDK — set ANDROID_HOME or local.properties")

tasks.register("buildGgmlCpu_v86") {
    group = "native"
    description = "Build libggml-cpu optimised for armv8.6-a+i8mm+bf16"

    val destSo = file("src/main/jniLibs/arm64-v8a/libggml-cpu-v86.so")
    outputs.file(destSo)

    doLast {
        val cmake = "$sdkRoot/cmake/4.1.2/bin/cmake"
        val toolchain = "$sdkRoot/ndk/27.0.12077973/build/cmake/android.toolchain.cmake"
        val bd = File(project.layout.buildDirectory.asFile.get(), "v86-cmake/arm64-v8a")
        bd.mkdirs()

        runCmd(
            cmake,
            "-DCMAKE_TOOLCHAIN_FILE=$toolchain",
            "-DANDROID_ABI=arm64-v8a",
            "-DANDROID_PLATFORM=android-24",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=ON",
            "-DLLAMA_BUILD_COMMON=ON",
            "-DLLAMA_OPENSSL=OFF",
            "-DLLAMA_CURL=OFF",
            "-DLLAMA_BUILD_TOOLS=ON",
            "-DGGML_NATIVE=OFF",
            "-DGGML_LLAMAFILE=ON",
            "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON",
            "-DGGML_CPU_ARM_ARCH=armv8.6-a+dotprod+i8mm+fp16+bf16",
            "-S", file("src/main/cpp").absolutePath,
            "-B", bd.absolutePath,
        )

        runCmd(
            cmake,
            "--build", bd.absolutePath,
            "--target", "ggml-cpu",
            "-j", Runtime.getRuntime().availableProcessors().toString(),
        )

        val builtSo = fileTree(bd).matching { include("**/libggml-cpu.so") }.singleFile
        destSo.parentFile.mkdirs()
        builtSo.copyTo(destSo, overwrite = true)
        logger.lifecycle("Copied v86 ggml-cpu -> ${destSo.absolutePath} (${destSo.length() / 1024}K)")
    }
}

afterEvaluate {
    listOf("Debug", "Release").forEach { buildType ->
        tasks.findByName("merge${buildType}JniLibFolders")?.dependsOn("buildGgmlCpu_v86")
    }
}
