@echo On
@REM Workaround for SIR-3276 (post-Taskcluster 95.x AMI rebuild on win-64).
@REM Without this per-output script entry conda-build inlines bld.bat into a
@REM generated IF-block wrapper where %blas_impl% (and other CBC variant vars)
@REM evaluate as empty strings — see meta.yaml libtorch output comment.
setlocal enabledelayedexpansion

call %RECIPE_DIR%\bld.bat
if errorlevel 1 exit /b 1
