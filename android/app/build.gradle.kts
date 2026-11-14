import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    // B단계(FCM)에서 활성화 — google-services.json이 이미 있어 주석의 전제
    // 조건(파일 없음)이 더는 성립하지 않는다. FCM이 이 플러그인이 생성하는
    // 리소스에 의존하는 부분이 있어 여기서 켠다(handoff §5 함정 4).
    id("com.google.gms.google-services")
}

// 릴리스 서명 — android/key.properties(저장소에 넣지 않는다, .gitignore)에서 keystore를 읽는다.
// keystore 파일은 저장소 밖에 둔다. key.properties가 없으면 릴리스 서명 설정이 비어 release
// 빌드가 서명 단계에서 멈춘다(debug 키로 조용히 서명하지 않는다).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "com.fashionai.ai_fashion_assistant"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        // flutter_local_notifications(AAR)가 코어 라이브러리 디슈가링을 요구함.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.fashionai.ai_fashion_assistant"
        minSdk = flutter.minSdkVersion // Firebase + image_picker 최소 요구사항
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        
        // 라이브러리가 많아질 경우를 대비해 멀티덱스 활성화
        multiDexEnabled = true
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
            storeFile = keystoreProperties.getProperty("storeFile")?.let { project.file(it) }
            storePassword = keystoreProperties.getProperty("storePassword")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
