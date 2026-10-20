@echo off
if "%DEVECO_HOME%"=="" (
  echo Set DEVECO_HOME to your DevEco Studio installation
  exit /b 1
)
"%DEVECO_HOME%\sdk\default\openharmony\native\llvm\bin\clang.exe" --target=aarch64-linux-ohos --sysroot="%DEVECO_HOME%\sdk\default\openharmony\native\sysroot" %*
