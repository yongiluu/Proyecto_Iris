@echo off
REM ============================================================================
REM  Entrenamiento de noche del lector de texto (OCR) de la placa.
REM  Doble clic y dejar el PC enchufado. Se puede cerrar cuando quieras: al volver
REM  a abrirlo sigue desde la ultima epoca terminada. El PC no se suspende mientras corre.
REM  Avance: ML_Training\logs\noche.log
REM ============================================================================
setlocal
cd /d "%~dp0ocr"
set PYTHONIOENCODING=utf-8
set PY=..\.venv\Scripts\python.exe
set LOG=..\logs\noche.log
if not exist ..\logs mkdir ..\logs

echo [%date% %time%] Inicio >> %LOG%

REM 1. Lector de lineas (12 epocas). Se salta si ya termino (existe el reporte).
if exist ..\models\ocr_report.txt goto detector
if exist ..\models\ocr_reader_respaldo (
    echo Lector: sigo desde el ultimo respaldo...
    %PY% train.py >> %LOG% 2>&1
) else if exist ..\models\ocr_reader.keras (
    echo Lector: sigo desde la epoca 2...
    %PY% train.py --desde-epoca 2 >> %LOG% 2>&1
) else (
    echo Lector: desde cero...
    %PY% train.py >> %LOG% 2>&1
)
if errorlevel 1 goto fallo

:detector
REM 2. Detector de donde hay texto (15 epocas).
if exist ..\models\ocr_detector_report.txt goto exportar
echo Detector...
%PY% detector.py train >> %LOG% 2>&1
if errorlevel 1 goto fallo

:exportar
REM 3. Modelos int8 para la placa + reporte de errores.
echo Exportando a la placa...
%PY% export_model.py >> %LOG% 2>&1
if errorlevel 1 goto fallo

echo [%date% %time%] LISTO >> %LOG%
echo.
echo LISTO. Avisale a Claude: hay que compilar y subir el firmware del lector.
pause
exit /b 0

:fallo
echo [%date% %time%] FALLO (ver noche.log) >> %LOG%
echo.
echo Algo fallo. Avisale a Claude (el detalle esta en ML_Training\logs\noche.log).
pause
exit /b 1
