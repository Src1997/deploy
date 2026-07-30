#requires -version 5.1
<#
.SYNOPSIS
    Pack financial-api (thin wrapper → pack-generic.ps1)

.DESCRIPTION
    保留旧命令入口，实际打包逻辑由 pack-generic.ps1 从 projects.json 读取配置。

.EXAMPLE
    .\scripts\pack-financial-api.ps1
#>

$ErrorActionPreference = "Stop"
$ScriptsDir = $PSScriptRoot

# 调用通用打包器，传入 projects.json 中的 financial-api 配置
& (Join-Path $ScriptsDir 'pack-generic.ps1') -ProjectId 'financial-api'
