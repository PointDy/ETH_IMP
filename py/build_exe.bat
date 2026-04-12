@echo off
setlocal

cd /d "%~dp0"

if not exist dist mkdir dist

python -m PyInstaller ^
  --noconfirm ^
  --clean ^
  --onefile ^
  --windowed ^
  --name BISHE_Image_Receiver ^
  pc_receiver.py

echo.
echo Build finished. Output: dist\BISHE_Image_Receiver.exe
pause
