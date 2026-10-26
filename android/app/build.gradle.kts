import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---- 发布签名（CI / GitHub Actions） ----
// 环境变量：KEYSTORE_BASE64（keystore 文件 base64）、KEYSTORE_PASSWORD、
// KEY_ALIAS、KEY_PASSWORD。任一缺失**或为空**则回退 debug 签名（仅限本地开发）。
//
// 为什么必须判空而不是判 null：GitHub Actions 里未配置的 secret 注入进来是
// **空字符串**，`System.getenv(...) != null` 依然成立 → 以前会把空 base64 解成
// 0 字节写成 release.keystore → 内核签 APK 时报
// 「Failed to read key from store: Tag number over 30 is not supported」，
// 整个 assembleRelease / bundleRelease 直接失败。
fun envOrNull(name: String): String? =
    System.getenv(name)?.trim()?.takeIf { it.isNotEmpty() }

val keystoreDir = file("keystore")
val keystoreFile = file("keystore/release.keystore")
val releaseKeystoreBytes: ByteArray? = envOrNull("KEYSTORE_BASE64")?.let { b64 ->
    try {
        Base64.getDecoder().decode(b64)
    } catch (e: IllegalArgumentException) {
        println("KEYSTORE_BASE64 不是合法 base64（${e.message}），忽略发布签名")
        null
    }
}
val hasReleaseSigning = (releaseKeystoreBytes?.size ?: 0) > 1024 &&
    envOrNull("KEYSTORE_PASSWORD") != null &&
    envOrNull("KEY_ALIAS") != null &&
    envOrNull("KEY_PASSWORD") != null
if (hasReleaseSigning) {
    if (!keystoreFile.exists()) {
        keystoreDir.mkdirs()
        keystoreFile.writeBytes(releaseKeystoreBytes!!)
    }
} else {
    println(
        "⚠️ 未提供有效的发布签名密钥（KEYSTORE_BASE64/KEYSTORE_PASSWORD/" +
            "KEY_ALIAS/KEY_PASSWORD），本次构建回退 debug 签名 —— " +
            "能装能测，但不能用于正式分发（用户无法覆盖升级）。"
    )
}

android {
    namespace = "top.mbox.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 等依赖 java.time 新 API，
        // 低版本 Android 需 core library desugaring（见下方 dependencies）
        isCoreLibraryDesugaringEnabled = true
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    defaultConfig {
        applicationId = "top.mbox.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = keystoreFile
                storePassword = envOrNull("KEYSTORE_PASSWORD")
                keyAlias = envOrNull("KEY_ALIAS")
                keyPassword = envOrNull("KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // 有发布密钥用正式签名；否则回退 debug（本地开发跑 --release 用）
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // 体积优化：R8 代码裁剪 + 资源收缩（依赖均为官方插件，自带 consumer rules）
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // libmbox.aar（sing-box 内核库，Java 包名 top.moneyfly.libbox）由 CI
    // 从 moneyfly004/sing-box-lib 预编译 release 下载
    // （.github/workflows/release.yml）；本地调试用
    // tool/build_singbox_aar.sh。缺失时构建出的 APK 无内核，属残次包，
    // 直接报错给出清晰指引。
    val coreAar = file("libs/libmbox.aar")
    if (!coreAar.exists()) {
        throw GradleException(
            "缺少 android/app/libs/libmbox.aar（sing-box 内核库）。\n" +
                "CI 构建会自动下载预编译 aar；本地调试请先运行: bash tool/build_singbox_aar.sh"
        )
    }
    implementation(files(coreAar))
    // flutter_local_notifications（java.time）要求的 core library desugaring
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
