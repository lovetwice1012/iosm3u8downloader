@rem Minimal pinned Gradle wrapper launcher for Windows.
@echo off
setlocal

set "APP_HOME=%~dp0"
if defined JAVA_HOME (
    set "JAVACMD=%JAVA_HOME%\bin\java.exe"
) else (
    set "JAVACMD=java.exe"
)

"%JAVACMD%" -Dorg.gradle.appname=gradlew -classpath "%APP_HOME%gradle\wrapper\gradle-wrapper.jar" org.gradle.wrapper.GradleWrapperMain %*
if errorlevel 1 exit /b %errorlevel%

endlocal
