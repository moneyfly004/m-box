; MBox Windows 安装包（Inno Setup 6）
; 用法: ISCC.exe /DVERSION=1.0.0 /DBUILD_DIR=C:\...\Release scripts\windows_installer.iss
; 产物: ..\dist\MBox-setup-<VERSION>.exe（相对脚本所在目录）

#ifndef VERSION
  #define VERSION "1.0.0"
#endif
#ifndef BUILD_DIR
  #define BUILD_DIR "..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{B0C9E8F7-4D2A-4C5E-9F1B-6A3D2E7C8B1A}
AppName=MBox
AppVersion={#VERSION}
AppPublisher=top.moneyfly
AppPublisherURL=https://dy.moneyfly.top
; 默认安装目录：**C 盘**用户级目录 %LOCALAPPDATA%\Programs\MBox。
; 为什么不用 {autopf}：PrivilegesRequired=lowest 时它等于 {userpf}（同一个位置），
; 但这个脚本要**显式钉在 C 盘**（用户要求「安装时默认装到 C 盘」），并且必须同时满足：
;   - 免管理员：应用内「重启即更新」是静默安装（/SILENT），需要 UAC 的目录会让
;     每次自动更新都弹权限框、甚至装不上（PrivilegesRequired 保持 lowest）；
;   - 用户配置目录被重定向到别的盘时（企业环境常见），退回系统盘下的目录，
;     保证"默认装在 C 盘"依然成立。
DefaultDirName={code:GetDefaultDir}
; **不再沿用上一次安装目录**：Inno 默认 UsePreviousAppDir=yes，曾经把程序装在
; D 盘/E 盘的用户会一直默认装回那个盘（用户反馈"要默认装到 C 盘"的真实原因之一）。
; 旧目录里的程序仍会被旧版卸载程序正常卸载（按 AppId 识别，与目录无关）。
UsePreviousAppDir=no
DefaultGroupName=MBox
; 便携解压为 zip 版；安装版默认不强制管理员（v1 系统代理模式无需提权，
; 后续 TUN 模式需要时改为 requireAdministrator）
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=MBox-setup-{#VERSION}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\mbox.exe
; 支持 Windows 10 及以上（Flutter 引擎最低要求，见 README「系统要求」）
MinVersion=10.0

[Languages]
Name: "chinesesimp"; MessagesFile: "languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#BUILD_DIR}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\MBox"; Filename: "{app}\mbox.exe"
Name: "{group}\{cm:UninstallProgram,MBox}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\MBox"; Filename: "{app}\mbox.exe"; Tasks: desktopicon

[Run]
; 注意：**不能加 skipifsilent**。应用内「重启即更新」用的是 /SILENT 静默安装，
; 加了 skipifsilent 装完就不会拉起 App —— 用户看到的就是「升级装完了但程序没回来」
; （旧版本还停在后台/或窗口消失）。nowait 让安装器立刻返回，不阻塞收尾。
Filename: "{app}\mbox.exe"; Description: "{cm:LaunchProgram,MBox}"; Flags: nowait postinstall

; ===== 卸载清理 =====
; ⚠️ 这里**只能删纯缓存**，绝不能删应用数据目录：
; path_provider 在 Windows 上把 install_id（安装实例标记，客户端据此派生
; X-MF-Device-Id / device_hash）写在 %APPDATA%\top.moneyfly\MoneyFly 下。
; Inno 升级时会**先静默运行旧版卸载程序**，旧版在这里删掉了整个
; %APPDATA%\top.moneyfly\MoneyFly ⇒ install_id 丢失 ⇒ 同一台电脑在后台被
; 登记成新设备。生产实证：老站用户 susanzhang1230 只有 iPhone + 一台 Windows
; 两台设备，后台却显示 3 台（MoneyFly 2.2.25 与 2.2.28 是同一台 PC）。
; 应用数据的清理改到 [Code] 的 CurUninstallStepChanged，且**只在用户真正
; 手动卸载（非静默）时**执行；升级/应用内「重启即更新」都走静默卸载，数据保留。
[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\Temp\moneyfly_core"

[Code]
// 默认安装目录（见 [Setup] DefaultDirName={code:GetDefaultDir}）：
// 常规机器 = C:\Users\<用户>\AppData\Local\Programs\MBox；
// 用户配置目录不在系统盘时 = <系统盘>:\MoneyFly（同样是免管理员的用户级位置）。
function GetDefaultDir(Param: String): String;
var
  AppDataDir, SysDrive: String;
begin
  AppDataDir := ExpandConstant('{localappdata}');
  SysDrive := ExpandConstant('{sd}');
  if (Length(AppDataDir) >= 2) and (Length(SysDrive) >= 2) and
     (CompareText(Copy(AppDataDir, 1, 2), Copy(SysDrive, 1, 2)) <> 0) then
    Result := SysDrive + '\MoneyFly'
  else
    Result := AppDataDir + '\Programs\MoneyFly';
end;

// 升级安装时先结束正在运行的旧版本：/CLOSEAPPLICATIONS 靠 Restart Manager，
// 个别环境下拿不到句柄就替换失败，这里兜一层 taskkill（没在跑时它返回非零，无害）。
//
// ⚠️ 位置很重要：**绝不能放在 InitializeSetup 里**。Inno 的 {app} 等常量在
// 向导初始化阶段还没赋值，那里展开会直接抛
//   "An attempt was made to expand the "app" constant before it was initialized"
// 并中断安装（2.2.14 的真实事故：所有 Windows 用户装到 1:56 就报这个错）。
// PrepareToInstall 是「安装目录已确定、文件还没开始复制」的时机，
// 普通安装与 /SILENT 静默安装都会走到这里。
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Exec('taskkill.exe', '/f /im mbox.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := '';
end;

// ===== 真正的「卸载彻底」：只在用户手动卸载时清应用数据 =====
// 升级安装与应用内「重启即更新」都会**静默**运行旧版卸载程序（/SILENT），
// 那种情况下必须保留 %APPDATA%\top.moneyfly\MoneyFly —— 里面有 install_id，
// 删了同一台电脑就会被后台当成新设备（幽灵设备、白占设备名额）。
// 用户从控制面板/开始菜单真正卸载（交互式，无 /SILENT）时才清理，
// 保证「卸载后重装 = 全新状态（重新登录 + 重新拉订阅）」的原意不变。
function IsSilentRun: Boolean;
var
  Cmd: String;
begin
  Cmd := Uppercase(GetCmdTail);
  Result := (Pos('/SILENT', Cmd) > 0) or (Pos('/VERYSILENT', Cmd) > 0);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    if not IsSilentRun then
    begin
      DelTree(ExpandConstant('{userappdata}\top.moneyfly\MoneyFly'), True, True, True);
      DelTree(ExpandConstant('{localappdata}\top.moneyfly\MoneyFly'), True, True, True);
      DelTree(ExpandConstant('{localappdata}\Temp\moneyfly_core'), True, True, True);
    end;
  end;
end;
