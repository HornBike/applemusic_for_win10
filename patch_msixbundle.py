from __future__ import annotations

import shutil
import subprocess
import sys
import re
from dataclasses import dataclass
from pathlib import Path

DEFAULT_PASSWORD = "12345"
DEFAULT_CERT_NAME = "AppleMusicWinLocalTest"
DEFAULT_TIMESTAMP_URL = "http://timestamp.digicert.com"


@dataclass(frozen=True)
class BundleSelection:
    index: int
    path: Path


def natural_sort_key(value: str) -> list[object]:
    parts = re.split(r"(\d+)", value)
    key: list[object] = []
    for part in parts:
        if part.isdigit():
            key.append(int(part))
        else:
            key.append(part.lower())
    return key


def find_bundles(root_dir: Path) -> list[Path]:
    bundles = [path for path in root_dir.glob("*.msixbundle") if path.is_file()]
    return sorted(bundles, key=lambda path: natural_sort_key(path.name))


def prompt_for_bundle(bundles: list[Path]) -> BundleSelection:
    if not bundles:
        raise FileNotFoundError("根目录下没有找到 .msixbundle 文件。")

    print("可选择的 msixbundle 包：")
    for index, bundle in enumerate(bundles, start=1):
        print(f"{index}. {bundle.name}")

    while True:
        user_input = input("请输入要修改的包序号，或输入 q 退出: ").strip()
        if user_input.lower() == "q":
            raise KeyboardInterrupt("用户取消操作。")
        if not user_input.isdigit():
            print("输入无效，请输入数字序号。")
            continue

        selected_index = int(user_input)
        if 1 <= selected_index <= len(bundles):
            return BundleSelection(index=selected_index, path=bundles[selected_index - 1])

        print("序号超出范围，请重新输入。")


def prompt_text(message: str, default: str) -> str:
    user_input = input(f"{message} [{default}]: ").strip()
    return user_input or default


def prompt_yes_no(message: str, default: bool = True) -> bool:
    suffix = "[Y/n]" if default else "[y/N]"
    while True:
        user_input = input(f"{message} {suffix}: ").strip().lower()
        if not user_input:
            return default
        if user_input in {"y", "yes"}:
            return True
        if user_input in {"n", "no"}:
            return False
        print("输入无效，请输入 y 或 n。")


def prompt_scope(default: str = "CurrentUser") -> str:
    while True:
        user_input = input(f"证书导入范围 [CurrentUser/LocalMachine] [{default}]: ").strip()
        if not user_input:
            return default
        if user_input in {"CurrentUser", "LocalMachine"}:
            return user_input
        print("输入无效，请输入 CurrentUser 或 LocalMachine。")


def get_powershell_executable() -> str:
    for candidate in ("powershell.exe", "powershell", "pwsh.exe", "pwsh"):
        executable = shutil.which(candidate)
        if executable:
            return executable
    raise FileNotFoundError("未找到 PowerShell 可执行文件。")


def run_command(command: list[str], failure_message: str) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if result.returncode != 0:
        details = "\n".join(part for part in (result.stdout.strip(), result.stderr.strip()) if part)
        if details:
            raise RuntimeError(f"{failure_message}\n{details}")
        raise RuntimeError(failure_message)
    return result


def run_pack_script(
    root_dir: Path,
    selection: BundleSelection,
    password: str,
    cert_name: str,
    timestamp_url: str,
    skip_timestamp: bool,
) -> subprocess.CompletedProcess[str]:
    powershell = get_powershell_executable()
    script_path = root_dir / "script" / "New-CertificateAndPack.ps1"
    if not script_path.is_file():
        raise FileNotFoundError(f"未找到打包脚本: {script_path}")

    command = [
        powershell,
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script_path),
        "-RootPath",
        str(root_dir),
        "-BundleIndex",
        str(selection.index),
        "-Password",
        password,
        "-CertName",
        cert_name,
    ]
    if timestamp_url:
        command.extend(["-TimestampUrl", timestamp_url])
    if skip_timestamp:
        command.append("-SkipTimestamp")

    return run_command(command, "PowerShell 打包脚本执行失败。")


def run_import_script(root_dir: Path, password: str, cert_name: str, scope: str) -> subprocess.CompletedProcess[str]:
    powershell = get_powershell_executable()
    script_path = root_dir / "script" / "Import-GeneratedCertificate.ps1"
    if not script_path.is_file():
        raise FileNotFoundError(f"未找到证书导入脚本: {script_path}")

    command = [
        powershell,
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script_path),
        "-RootPath",
        str(root_dir),
        "-Password",
        password,
        "-CertName",
        cert_name,
        "-Scope",
        scope,
    ]
    return run_command(command, "PowerShell 证书导入脚本执行失败。")


def main() -> int:
    root_dir = Path(__file__).resolve().parent

    try:
        bundles = find_bundles(root_dir)
        selection = prompt_for_bundle(bundles)
        print(f"已选择: {selection.path.name}")

        password = prompt_text("请输入证书密码，直接回车使用默认值", DEFAULT_PASSWORD)
        cert_name = prompt_text("请输入证书名称，直接回车使用默认值", DEFAULT_CERT_NAME)
        use_timestamp = prompt_yes_no("是否使用时间戳", default=True)
        timestamp_url = DEFAULT_TIMESTAMP_URL if use_timestamp else ""
        if use_timestamp:
            timestamp_url = prompt_text("请输入时间戳 URL，直接回车使用默认值", DEFAULT_TIMESTAMP_URL)

        pack_result = run_pack_script(
            root_dir=root_dir,
            selection=selection,
            password=password,
            cert_name=cert_name,
            timestamp_url=timestamp_url,
            skip_timestamp=not use_timestamp,
        )
        if pack_result.stdout.strip():
            print(pack_result.stdout.strip())

        scope = prompt_scope()
        import_result = run_import_script(
            root_dir=root_dir,
            password=password,
            cert_name=cert_name,
            scope=scope,
        )
        if import_result.stdout.strip():
            print(import_result.stdout.strip())
    except KeyboardInterrupt as exc:
        print(str(exc))
        return 1
    except Exception as exc:
        print(f"处理失败: {exc}")
        return 1

    print("Python 已完成 bundle 选择，并将所选序号传递给 PowerShell 脚本，同时已自动执行证书导入。输出扩展名可能根据打包目标自动调整。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
