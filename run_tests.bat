@echo off
chcp 65001 >nul
rem %~dp0 = このバッチファイルのあるディレクトリ
rem 絶対パスを直書きするとプロジェクトを移動・改名した際に壊れるため
cd /d "%~dp0"
rake test
