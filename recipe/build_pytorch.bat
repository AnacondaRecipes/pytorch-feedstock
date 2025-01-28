@echo On
setlocal enabledelayedexpansion

call %RECIPE_DIR%\bld.bat
if errorlevel 1 exit /b 1