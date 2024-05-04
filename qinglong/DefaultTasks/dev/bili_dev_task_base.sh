#!/usr/bin/env bash
# new Env("bili_dev_task_base")
# cron 0 0 1 1 * bili_dev_task_base.sh

# Stop script on NZEC
set -e
# Stop script if unbound variable found (use ${var:-} if intentional)
set -u
# By default cmd1 | cmd2 returns exit code of cmd2 regardless of cmd1 success
# This is causing it to fail
set -o pipefail

# Use in the the functions: eval $invocation
invocation='say_verbose "Calling: ${yellow:-}${FUNCNAME[0]} ${green:-}$*${normal:-}"'

# standard output may be used as a return value in the functions
# we need a way to write text on the screen in the functions so that
# it won't interfere with the return value.
# Exposing stream 3 as a pipe to standard output of the script itself
exec 3>&1

# Setup some colors to use. These need to work in fairly limited shells, like the Ubuntu Docker container where there are only 8 colors.
# See if stdout is a terminal
if [ -t 1 ] && command -v tput >/dev/null; then
    # see if it supports colors
    ncolors=$(tput colors || echo 0)
    if [ -n "$ncolors" ] && [ $ncolors -ge 8 ]; then
        bold="$(tput bold || echo)"
        normal="$(tput sgr0 || echo)"
        black="$(tput setaf 0 || echo)"
        red="$(tput setaf 1 || echo)"
        green="$(tput setaf 2 || echo)"
        yellow="$(tput setaf 3 || echo)"
        blue="$(tput setaf 4 || echo)"
        magenta="$(tput setaf 5 || echo)"
        cyan="$(tput setaf 6 || echo)"
        white="$(tput setaf 7 || echo)"
    fi
fi

say_warning() {
    printf "%b\n" "${yellow:-}bilitool: Warning: $1${normal:-}" >&3
}

say_err() {
    printf "%b\n" "${red:-}bilitool: Error: $1${normal:-}" >&2
}

say() {
    # using stream 3 (defined in the beginning) to not interfere with stdout of functions
    # which may be used as return value
    printf "%b\n" "${cyan:-}bilitool:${normal:-} $1" >&3
}

say_verbose() {
    if [ "$verbose" = true ]; then
        say "$1"
    fi
}

QL_DIR=${QL_DIR:-"/ql"}
QL_BRANCH=${QL_BRANCH:-"develop"}
DefaultCronRule=${DefaultCronRule:-""}
CpuWarn=${CpuWarn:-""}
MemoryWarn=${MemoryWarn:-""}
DiskWarn=${DiskWarn:-""}

verbose=false
dir_shell=$QL_DIR/shell
. $dir_shell/env.sh
. $dir_shell/share.sh ""
touch /root/.bashrc
. /root/.bashrc

# 目录
say "青龙repo目录: $dir_repo"
bili_repo="raywangqvq/bilibilitoolpro_develop"
qinglong_bili_repo=$(echo "$bili_repo" | sed 's/\//_/g')
qinglong_bili_repo_dir="$(find $dir_repo -type d -iname $qinglong_bili_repo | head -1)"
say "bili仓库目录: $qinglong_bili_repo_dir"

prefer_mode=${BILI_MODE:-"dotnet"} # 或bilitool
current_linux_os="debian"  # 或alpine
current_os="linux"         # 或linux-musl
machine_architecture="x64" # 或arm、arm64
dotnet_installed=false
bilitool_installed=false
bilitool_installed_version=0

# 以下操作仅在bilitool仓库的根bin文件下执行
cd $qinglong_bili_repo_dir
mkdir -p bin
cd bin

# 读参数
while [ $# -ne 0 ]; do
    name="$1"
    case "$name" in
    --verbose | -[Vv]erbose)
        verbose=true
        ;;
    *)
        say_err "Unknown argument \`$name\`"
        exit 1
        ;;
    esac

    shift
done

# 判断是否存在某指令
machine_has() {
    eval $invocation

    command -v "$1" >/dev/null 2>&1
    return $?
}

# 判断系统架构
# 输出：arm、arm64、x64
get_machine_architecture() {
    eval $invocation

    if command -v uname >/dev/null; then
        CPUName=$(uname -m)
        case $CPUName in
        armv*l)
            echo "arm"
            return 0
            ;;
        aarch64 | arm64)
            echo "arm64"
            return 0
            ;;
        esac
    fi

    # Always default to 'x64'
    echo "x64"
    return 0
}

# 获取linux系统名称
# 输出：debian.10、debian.11、debian.12、ubuntu.20.04、ubuntu.22.04、alpine.3.4.3...
get_linux_platform_name() {
    eval $invocation

    if [ -e /etc/os-release ]; then
        . /etc/os-release
        echo "$ID${VERSION_ID:+.${VERSION_ID}}"
        return 0
    elif [ -e /etc/redhat-release ]; then
        local redhatRelease=$(</etc/redhat-release)
        if [[ $redhatRelease == "CentOS release 6."* || $redhatRelease == "Red Hat Enterprise Linux "*" release 6."* ]]; then
            echo "rhel.6"
            return 1
        fi
    fi

    echo "Linux specific platform name and version could not be detected: UName = $uname"
    return 1
}

# 判断是否为musl（一般指alpine）
is_musl_based_distro() {
    eval $invocation

    (ldd --version 2>&1 || true) | grep -q musl
}

# 获取当前系统名称
# 输出：linux、linux-musl、osx、freebsd
get_current_os_name() {
    eval $invocation

    local uname=$(uname)
    if [ "$uname" = "Darwin" ]; then
        say_warning "当前系统：osx"
        echo "osx"
        return 1
    elif [ "$uname" = "FreeBSD" ]; then
        say_warning "当前系统：freebsd"
        echo "freebsd"
        return 1
    elif [ "$uname" = "Linux" ]; then
        local linux_platform_name=""
        linux_platform_name="$(get_linux_platform_name)" || true
        say "当前系统发行版本：$linux_platform_name"

        if [ "$linux_platform_name" = "rhel.6" ]; then
            echo $linux_platform_name
            return 1
        elif is_musl_based_distro; then
            echo "linux-musl"
            return 0
        elif [ "$linux_platform_name" = "linux-musl" ]; then
            echo "linux-musl"
            return 0
        else
            echo "linux"
            return 0
        fi
    fi

    say_err "OS name could not be detected: UName = $uname"
    return 1
}

check_os() {
    eval $invocation

    # 获取系统信息
    current_os="$(get_current_os_name)"
    say "当前系统：$current_os"
    machine_architecture="$(get_machine_architecture)"
    say "当前架构：$machine_architecture"

    if [ "$current_os" = "linux" ]; then
        current_linux_os="debian" # 当前青龙只有debian和aplpine两种
        if ! machine_has curl; then
            say "curl未安装，开始安装依赖..."
            apt-get update
            apt-get install -y curl
        fi
    else
        current_linux_os="alpine"
        if ! machine_has curl; then
            say "curl未安装，开始安装依赖..."
            apk update
            apk add -y curl
        fi
    fi

    if [ -f "./Ray.BiliBiliTool.Console" ]; then
        prefer_mode="bilitool"
    fi
    say "当前选择的运行方式：$prefer_mode"
}

check_jq() {
    if [ "$current_linux_os" = "debian" ]; then
        if ! machine_has jq; then
            say "jq未安装，开始安装依赖..."
            apt-get update
            apt-get install -y jq
        fi
    else
        if ! machine_has jq; then
            say "jq未安装，开始安装依赖..."
            apk update
            apk add -y jq
        fi
    fi
}

check_unzip() {
    if [ "$current_linux_os" = "debian" ]; then
        if ! machine_has unzip; then
            say "unzip未安装，开始安装依赖..."
            apt-get update
            apt-get install -y unzip
        fi
    else
        if ! machine_has unzip; then
            say "jq未安装，开始安装依赖..."
            apk update
            apk add -y unzip
        fi
    fi
}

# 检查dotnet
check_dotnet() {
    eval $invocation

    dotnetVersion=$(dotnet --version)
    if [[ $dotnetVersion == 6.* ]]; then
        say "已安装dotnet，当前版本：$dotnetVersion"
        say "which dotnet: $(which dotnet)"
        return 0
    else
        say "未安装"
        return 1
    fi
}

# 检查bilitool
check_bilitool() {
    eval $invocation

    TAG_FILE="./tag.txt"
    touch $TAG_FILE
    local STORED_TAG=$(cat $TAG_FILE 2>/dev/null)

    #如果STORED_TAG为空，则返回1
    if [[ -z $STORED_TAG ]]; then
        say "tag.txt为空，未安装过"
        return 1
    fi

    say "tag.txt记录的版本：$STORED_TAG"

    # 查找当前目录下是否有叫Ray.BiliBiliTool.Console的文件
    if [ -f "./Ray.BiliBiliTool.Console" ]; then
        say "bilitool已安装"
        bilitool_installed_version=$STORED_TAG
        return 0
    else
        say "bilitool未安装"
        return 1
    fi
}

# 检查环境
check() {
    eval $invocation

    if [ "$prefer_mode" == "dotnet" ]; then
        if check_dotnet; then
            dotnet_installed=true
            return 0
        else
            dotnet_installed=true
            return 1
        fi
    fi

    if [ "$prefer_mode" == "bilitool" ]; then
        if check_bilitool; then
            bilitool_installed=true
            return 0
        else
            bilitool_installed=false
            return 1
        fi
    fi

    return 1
}

# 安装dotnet环境
install_dotnet() {
    eval $invocation

    say "开始安装dotnet"
    if [[ $current_linux_os == "linux" ]]; then
        say "当前系统：debian"
        . /etc/os-release
        wget https://packages.microsoft.com/config/debian/$VERSION_ID/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
        dpkg -i packages-microsoft-prod.deb
        rm packages-microsoft-prod.deb
        apt-get update && apt-get install -y dotnet-sdk-6.0
    else
        say "当前系统：alpine"
        apk add dotnet6-sdk
    fi
    dotnet --version && say "which dotnet: $(which dotnet)" && say "安装成功"
    return $?
}

# 从github获取bilitool下载地址
get_download_url() {
    eval $invocation

    tag=$1
    url="https://github.com/RayWangQvQ/BiliBiliToolPro/releases/download/$tag/bilibili-tool-pro-v$tag-$current_os-$machine_architecture.zip"
    echo $url
    return 0
}

# 安装bilitool
install_bilitool() {
    eval $invocation

    say "开始安装bilitool"
    # 获取最新的release信息
    LATEST_RELEASE=$(curl -s https://api.github.com/repos/$bili_repo/releases/latest)

    # 解析最新的tag名称
    check_jq
    LATEST_TAG=$(echo $LATEST_RELEASE | jq -r '.tag_name')
    say "最新版本：$LATEST_TAG"

    # 读取之前存储的tag并比较
    if [ "$LATEST_TAG" != "$bilitool_installed_version" ]; then
        # 如果不一样，则需要更新安装
        ASSET_URL=$(get_download_url $LATEST_TAG)

        # 使用curl下载文件到当前目录下的test.zip文件
        local zip_file_name="bilitool-$LATEST_TAG.zip"
        curl -L -o "$zip_file_name" $ASSET_URL

        # 解压
        check_unzip
        unzip -jo "$zip_file_name" -d ./ \
            && rm "$zip_file_name" \
            && rm -f appsettings.*

        # 更新tag.txt文件
        echo $LATEST_TAG >./tag.txt
    else
        say "已经是最新版本，无需下载。"
    fi
}

## 安装dotnet（如果未安装过）
install() {
    eval $invocation

    # 调用check方法，如果通过则返回0，否则返回1
    if check; then
        say "环境正常，本次无需安装"
        return 0
    else
        say "开始安装环境"
        # 先尝试使用install_dotnet安装，如果失败，就再尝试使用install_bilitool安装
        if [ "$prefer_mode" == "dotnet" ]; then
            install_dotnet || {
                echo "安装失败，请根据文档自行在青龙容器中安装dotnet：https://learn.microsoft.com/zh-cn/dotnet/core/install/linux-$current_linux_os"
                exit 1
            }
        fi

        if [ "$prefer_mode" == "bilitool" ]; then
            install_bilitool || {
                echo "安装失败，请检查日志并重试"
                exit 1
            }
        fi
        return $?
    fi
}

check_os
install

export Ray_PlateformType=QingLong
export DOTNET_ENVIRONMENT=Production
