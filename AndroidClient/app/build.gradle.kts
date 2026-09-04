plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val appVersion = rootProject.file("../VERSION").readText().trim()
val releaseKeystore = providers.environmentVariable("SIDESCREEN_RELEASE_KEYSTORE").orNull
val releaseStorePassword = providers.environmentVariable("SIDESCREEN_RELEASE_STORE_PASSWORD").orNull
val releaseKeyAlias = providers.environmentVariable("SIDESCREEN_RELEASE_KEY_ALIAS").orNull
val releaseKeyPassword = providers.environmentVariable("SIDESCREEN_RELEASE_KEY_PASSWORD").orNull
val releaseSigningConfigured = listOf(
    releaseKeystore,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }

if (releaseSigningConfigured && !file(releaseKeystore!!).isFile) {
    error("SIDESCREEN_RELEASE_KEYSTORE does not point to a file: $releaseKeystore")
}
val versionParts = appVersion.split(".")
val computedVersionCode = versionParts[0].toInt() * 10000 + versionParts[1].toInt() * 100 + versionParts[2].toInt()

android {
    namespace = "com.sidescreen.app"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.sidescreen.app"
        minSdk = 26
        targetSdk = 34
        versionCode = computedVersionCode
        versionName = appVersion
    }

    signingConfigs {
        if (releaseSigningConfigured) {
            create("release") {
                storeFile = file(releaseKeystore!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (releaseSigningConfigured) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = "11"
    }

    buildFeatures {
        viewBinding = true
        buildConfig = true
    }
}

val verifyReleaseSigning by tasks.registering {
    doLast {
        if (!releaseSigningConfigured) {
            error(
                "Release signing is not configured. Set SIDESCREEN_RELEASE_KEYSTORE, " +
                    "SIDESCREEN_RELEASE_STORE_PASSWORD, SIDESCREEN_RELEASE_KEY_ALIAS, " +
                    "and SIDESCREEN_RELEASE_KEY_PASSWORD before assembling a release APK.",
            )
        }
    }
}

tasks.matching { it.name == "assembleRelease" }.configureEach {
    dependsOn(verifyReleaseSigning)
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.11.0")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")

    // Wireless mode (0.8.0)
    implementation("androidx.camera:camera-core:1.3.1")
    implementation("androidx.camera:camera-camera2:1.3.1")
    implementation("androidx.camera:camera-lifecycle:1.3.1")
    implementation("androidx.camera:camera-view:1.3.1")
    implementation("com.google.mlkit:barcode-scanning:17.2.0")

    testImplementation("junit:junit:4.13.2")
}
