allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Force every Android subproject (app + plugin modules) to compile against
// API 36. A transitive plugin dependency (flutter_plugin_android_lifecycle,
// pulled in by file_picker / share_plus) requires its consumers to compile
// against 36+, and this Flutter version does not propagate the app's
// compileSdk down to plugin modules — so each plugin (which otherwise defaults
// to flutter.compileSdkVersion = 34) is overridden here.
subprojects {
    // `:app` is force-evaluated by the evaluationDependsOn(":app") block above,
    // so calling afterEvaluate on it here would throw ("already evaluated").
    // Skip already-evaluated projects — `:app` already sets compileSdk = 36 in
    // its own build.gradle.kts; the plugin modules (not yet evaluated) get the
    // override below.
    if (!state.executed) {
        afterEvaluate {
            val androidExtension = extensions.findByName("android") as? com.android.build.gradle.BaseExtension
            androidExtension?.compileSdkVersion(36)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
