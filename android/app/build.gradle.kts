import java.io.File
import java.io.FileOutputStream
import java.net.URI
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val ffmpegKitUrl =
    "https://github.com/akashskypatel/ffmpeg-kit-builders/releases/download/" +
        "v0.10.5-android/bundle-base-shared-small-lgpl-release.aar"
val ffmpegKitSha256 =
    "4edd40f4d6e5504c9bc8f523af01392ac2921e9901e621afaead6f694e2b286b"

fun sha256(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().buffered().use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
    }
    return digest.digest().joinToString("") { "%02x".format(it) }
}

val ffmpegKitAar = layout.projectDirectory.file("libs/ffmpegkit.aar")

val downloadFfmpegKit by tasks.registering {
    group = "build setup"
    description = "Downloads and verifies the pinned LGPL FFmpegKit Android AAR"
    inputs.property("sourceUrl", ffmpegKitUrl)
    inputs.property("sha256", ffmpegKitSha256)
    outputs.file(ffmpegKitAar)

    doLast {
        val target = ffmpegKitAar.asFile
        target.parentFile.mkdirs()

        if (target.exists()) {
            val actual = sha256(target)
            if (actual != ffmpegKitSha256) {
                throw GradleException(
                    "Existing ${target.name} failed SHA-256 verification: $actual. " +
                        "Delete it and retry."
                )
            }
            logger.lifecycle("Verified cached FFmpegKit AAR: $actual")
            return@doLast
        }

        val temporary = File(target.parentFile, "${target.name}.part")
        val connection = URI(ffmpegKitUrl).toURL().openConnection().apply {
            connectTimeout = 30_000
            readTimeout = 180_000
            setRequestProperty("User-Agent", "HLSDownloader-Android-Gradle")
        }

        try {
            connection.getInputStream().buffered().use { input ->
                FileOutputStream(temporary, false).buffered().use(input::copyTo)
            }
            val actual = sha256(temporary)
            if (actual != ffmpegKitSha256) {
                Files.deleteIfExists(temporary.toPath())
                throw GradleException(
                    "Downloaded FFmpegKit AAR failed SHA-256 verification: $actual"
                )
            }

            try {
                Files.move(
                    temporary.toPath(),
                    target.toPath(),
                    StandardCopyOption.ATOMIC_MOVE
                )
            } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
                Files.move(
                    temporary.toPath(),
                    target.toPath(),
                    StandardCopyOption.REPLACE_EXISTING
                )
            }
            logger.lifecycle("Downloaded and verified FFmpegKit AAR: $actual")
        } finally {
            Files.deleteIfExists(temporary.toPath())
        }
    }
}

android {
    namespace = "com.example.hlsdownloader"
    compileSdk = 35
    ndkVersion = "27.2.12479018"

    defaultConfig {
        applicationId = "com.example.hlsdownloader"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables.useSupportLibrary = true

        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }

        externalNativeBuild {
            cmake {
                cppFlags += listOf("-std=c++17")
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            isDebuggable = false
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // Intentionally no signingConfig: assembleRelease emits app-release-unsigned.apk.
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
        freeCompilerArgs += listOf("-Xjvm-default=all")
    }

    packaging {
        resources.excludes += setOf(
            "/META-INF/{AL2.0,LGPL2.1}",
            "META-INF/DEPENDENCIES",
            "META-INF/LICENSE.md",
            "META-INF/NOTICE.md"
        )
    }

    testOptions {
        animationsDisabled = true
        unitTests.isIncludeAndroidResources = true
    }
}

tasks.named("preBuild") {
    dependsOn(downloadFfmpegKit)
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.04.01")

    implementation(files(ffmpegKitAar.asFile))

    implementation("androidx.core:core-ktx:1.16.0")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.9.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.9.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.0")
    implementation("androidx.webkit:webkit:1.16.0")

    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")
    implementation("org.jsoup:jsoup:1.20.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("io.coil-kt:coil-compose:2.7.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("androidx.test:core:1.6.1")
    testImplementation("org.robolectric:robolectric:4.14.1")

    androidTestImplementation(composeBom)
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.6.1")
    androidTestImplementation("androidx.test:runner:1.6.2")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
