@echo off
rem ===================================================================
rem  Campus DNS fix - launcher (ASCII only, so no codepage problems)
rem  This file must stay ASCII-only. All Chinese UI text lives in
rem  menu.ps1 (UTF-8 with BOM) which Windows PowerShell reads correctly.
rem ===================================================================
chcp 65001 >nul
title Campus DNS Fix

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0menu.ps1"
