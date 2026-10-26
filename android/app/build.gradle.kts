import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---- 发布签名（CI / GitHub Actions） ----
// 环境变量：KEYSTORE_BASE64（keystore 文件 base64）、KEYSTORE_PASSWORD、
// KEY_ALIAS、KEY_PASSWORD。任一缺失则回退 debug 签名（仅限本地开发）。
val keystoreDir = file("keystore")
val keystoreFile = file("keystore/release.keystore")
val hasReleaseSigning = System.getenv("KEYSTORE_BASE64") != null &&
    System.getenv("KEYSTORE_PASSWORD") != null &&
    System.getenv("KEY_ALIAS") != null &&
    System.getenv("KEY_PASSWORD") != null
if (hasReleaseSigning) {
    if (!keystoreFile.exists()) {
        keystoreDir.mkdirs()
        keystoreFile.writeBytes(Base64.getDecoder().decode(System.getenv("KEYSTORE_BASE64")))
    }
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
                storePassword = System.getenv("KEYSTORE_PASSWORD")
                keyAlias = System.getenv("KEY_ALIAS")
                keyPassword = System.getenv("KEY_PASSWORD")
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
