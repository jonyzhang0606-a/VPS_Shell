#!/usr/bin/env bash

# 遇到错误、未定义变量或管道中的失败时立即停止，避免留下半成品配置。
set -Eeuo pipefail

# 使用稳定的字段分隔符，减少路径中空格导致的意外拆分。
IFS=$'\n\t'

# 固定博客中采用的主题和两个第三方插件地址。
readonly ZSH_THEME_NAME="xiong-chiamiov-plus"
readonly AUTOSUGGESTIONS_REPO="https://github.com/zsh-users/zsh-autosuggestions.git"
readonly HIGHLIGHTING_REPO="https://github.com/zsh-users/zsh-syntax-highlighting.git"
readonly OMZ_INSTALL_URL="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"

# 输出带时间的普通日志，便于定位执行阶段。
log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

# 输出错误信息并终止脚本。
die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

# 检查当前系统是否提供指定命令。
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# 防止通过 sudo 启动整个脚本后把配置错误地写进 root 的家目录。
if [[ ${EUID} -eq 0 && -n ${SUDO_USER:-} && ${SUDO_USER} != "root" ]]; then
  die "请直接以普通用户运行本脚本，不要使用 sudo；脚本会在需要时自行调用 sudo。"
fi

# 记录真正需要配置 Zsh 的当前用户及其家目录。
readonly TARGET_USER="$(id -un)"
readonly TARGET_HOME="${HOME}"
readonly ZSH_DIR="${TARGET_HOME}/.oh-my-zsh"
readonly ZSHRC_FILE="${TARGET_HOME}/.zshrc"
readonly CUSTOM_PLUGIN_DIR="${ZSH_DIR}/custom/plugins"

# 仅支持原博客对应的 Debian/Ubuntu apt 系发行版。
command_exists apt-get || die "未找到 apt-get；本脚本仅适用于 Debian、Ubuntu 及其衍生系统。"

# 普通用户通过 sudo 安装系统包；root 用户则直接执行命令。
if [[ ${EUID} -eq 0 ]]; then
  APT_PREFIX=()
else
  command_exists sudo || die "当前不是 root，且系统未安装 sudo。"
  log "正在获取 sudo 权限；这里可能需要输入一次当前用户密码。"
  sudo -v
  APT_PREFIX=(sudo)
fi

# 更新软件索引；DEBIAN_FRONTEND 避免包管理器弹出交互界面。
log "更新 apt 软件索引……"
"${APT_PREFIX[@]}" env DEBIAN_FRONTEND=noninteractive apt-get update

# 使用 -y 自动确认 apt 的 y/n 提示，并在配置文件冲突时保留本机已有版本。
log "安装 zsh、git、curl 和证书组件……"
"${APT_PREFIX[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  -o Dpkg::Options::="--force-confold" \
  zsh git curl ca-certificates

# 确认后续步骤依赖的命令确实已经安装成功。
command_exists zsh || die "zsh 安装失败。"
command_exists git || die "git 安装失败。"
command_exists curl || die "curl 安装失败。"

# 创建临时安装器，并确保脚本无论成功失败都会清理它。
OMZ_INSTALLER="$(mktemp "${TMPDIR:-/tmp}/oh-my-zsh-install.XXXXXX")"
cleanup() {
  rm -f -- "${OMZ_INSTALLER}"
}
trap cleanup EXIT

# 已安装时跳过 Oh My Zsh，保证脚本可以安全地重复执行。
if [[ -d ${ZSH_DIR}/.git ]]; then
  log "Oh My Zsh 已安装，跳过重复安装。"
else
  # 先保存官方安装器，再以无人值守参数执行，避免输入 y 或自动进入 zsh。
  log "下载并安装 Oh My Zsh……"
  curl -fsSL "${OMZ_INSTALL_URL}" -o "${OMZ_INSTALLER}"
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh "${OMZ_INSTALLER}" --unattended --keep-zshrc
fi

# 确保自定义插件目录存在。
mkdir -p -- "${CUSTOM_PLUGIN_DIR}"

# 仅在插件尚未安装时克隆自动建议插件，避免覆盖用户的本地修改。
if [[ -d ${CUSTOM_PLUGIN_DIR}/zsh-autosuggestions/.git ]]; then
  log "zsh-autosuggestions 已存在，跳过。"
else
  log "安装 zsh-autosuggestions……"
  git clone --depth=1 "${AUTOSUGGESTIONS_REPO}" "${CUSTOM_PLUGIN_DIR}/zsh-autosuggestions"
fi

# 仅在插件尚未安装时克隆语法高亮插件。
if [[ -d ${CUSTOM_PLUGIN_DIR}/zsh-syntax-highlighting/.git ]]; then
  log "zsh-syntax-highlighting 已存在，跳过。"
else
  log "安装 zsh-syntax-highlighting……"
  git clone --depth=1 "${HIGHLIGHTING_REPO}" "${CUSTOM_PLUGIN_DIR}/zsh-syntax-highlighting"
fi

# 如果安装器因保留旧配置而没有创建文件，则先建立最小配置文件。
if [[ ! -f ${ZSHRC_FILE} ]]; then
  {
    # 写入 Oh My Zsh 的安装目录。
    printf '%s\n' 'export ZSH="$HOME/.oh-my-zsh"'
    # 写入博客采用的主题。
    printf 'ZSH_THEME="%s"\n' "${ZSH_THEME_NAME}"
    # 写入博客采用的内置 git 插件。
    printf '%s\n' 'plugins=(git)'
    # 加载 Oh My Zsh 主配置。
    printf '%s\n' 'source "$ZSH/oh-my-zsh.sh"'
  } > "${ZSHRC_FILE}"
fi

# 每次修改前备份当前配置，时间戳可避免覆盖以前的备份。
readonly ZSHRC_BACKUP="${ZSHRC_FILE}.bak.$(date '+%Y%m%d%H%M%S')"
cp -p -- "${ZSHRC_FILE}" "${ZSHRC_BACKUP}"
log "已备份现有配置到 ${ZSHRC_BACKUP}"

# 有主题设置时原位替换；没有时把主题设置放到文件开头。
if grep -Eq '^[[:space:]]*ZSH_THEME=' "${ZSHRC_FILE}"; then
  sed -i "s|^[[:space:]]*ZSH_THEME=.*|ZSH_THEME=\"${ZSH_THEME_NAME}\"|" "${ZSHRC_FILE}"
else
  THEME_TEMP="$(mktemp "${TMPDIR:-/tmp}/zshrc-theme.XXXXXX")"
  printf 'ZSH_THEME="%s"\n' "${ZSH_THEME_NAME}" > "${THEME_TEMP}"
  printf '\n' >> "${THEME_TEMP}"
  sed -n '1,$p' "${ZSHRC_FILE}" >> "${THEME_TEMP}"
  mv -- "${THEME_TEMP}" "${ZSHRC_FILE}"
fi

# 用受控标记块配置插件，便于重复执行时先删除旧块再重新插入。
readonly PLUGIN_BLOCK_START="# BEGIN one-click-zsh managed plugins"
readonly PLUGIN_BLOCK_END="# END one-click-zsh managed plugins"
PLUGIN_TEMP="$(mktemp "${TMPDIR:-/tmp}/zshrc-plugins.XXXXXX")"

# 删除本脚本上一次写入的插件块，保留用户的其他配置。
awk -v start="${PLUGIN_BLOCK_START}" -v end="${PLUGIN_BLOCK_END}" '
  # 遇到起始标记后暂停输出。
  $0 == start { skipping = 1; next }
  # 遇到结束标记后恢复输出。
  $0 == end { skipping = 0; next }
  # 仅输出不在受控块中的原始内容。
  !skipping { print }
' "${ZSHRC_FILE}" > "${PLUGIN_TEMP}"

# 在加载 Oh My Zsh 之前追加插件；若找不到加载行，则在文件末尾补齐初始化。
awk -v start="${PLUGIN_BLOCK_START}" -v end="${PLUGIN_BLOCK_END}" '
  # 输出由脚本管理的插件配置块。
  function print_plugin_block() {
    print start
    print "plugins+=(zsh-autosuggestions zsh-syntax-highlighting)"
    print end
  }
  # 在首次加载 Oh My Zsh 前插入插件配置。
  !inserted && $0 ~ /^[[:space:]]*source[[:space:]].*oh-my-zsh\.sh/ {
    print_plugin_block()
    inserted = 1
  }
  # 保留原文件的每一行。
  { print }
  # 缺少加载语句时，在末尾补上完整初始化。
  END {
    if (!inserted) {
      print ""
      print "export ZSH=\"$HOME/.oh-my-zsh\""
      print_plugin_block()
      print "source \"$ZSH/oh-my-zsh.sh\""
    }
  }
' "${PLUGIN_TEMP}" > "${ZSHRC_FILE}"
rm -f -- "${PLUGIN_TEMP}"

# 使用管理员权限直接设置登录 Shell，避免 chsh 再询问 y/n；认证密码仍由系统安全处理。
readonly ZSH_BIN="$(command -v zsh)"
readonly CURRENT_LOGIN_SHELL="$(getent passwd "${TARGET_USER}" | cut -d: -f7)"
if [[ ${CURRENT_LOGIN_SHELL} == "${ZSH_BIN}" ]]; then
  log "默认 Shell 已经是 ${ZSH_BIN}。"
elif [[ ${EUID} -eq 0 ]]; then
  chsh -s "${ZSH_BIN}" "${TARGET_USER}"
else
  sudo chsh -s "${ZSH_BIN}" "${TARGET_USER}"
fi

# 给出明确的生效方式；脚本本身不强制替换当前父终端进程。
log "安装完成。重新登录后默认使用 Zsh；现在可执行：exec zsh"
