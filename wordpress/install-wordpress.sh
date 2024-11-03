#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 临时目录
TEMP_DIR=""

# 错误处理函数
error_exit() {
    echo -e "${RED}错误: $1${NC}" >&2
    exit 1
}

# 创建临时目录
create_temp_dir() {
    TEMP_DIR=$(mktemp -d)
    if [[ ! "$TEMP_DIR" || ! -d "$TEMP_DIR" ]]; then
        error_exit "无法创建临时目录"
    fi
    # 确保脚本退出时清理临时目录
    trap 'cleanup' EXIT
}

# 检查必要工具
check_requirements() {
    command -v curl >/dev/null 2>&1 || error_exit "需要curl但未安装"
    command -v sha1sum >/dev/null 2>&1 || error_exit "需要sha1sum但未安装"
    command -v id >/dev/null 2>&1 || error_exit "需要id命令但未安装"
}

# 验证用户/组是否存在
validate_user_group() {
    local user=$1
    local group=$2
    
    id "$user" >/dev/null 2>&1 || error_exit "用户 $user 不存在"
    getent group "$group" >/dev/null 2>&1 || error_exit "用户组 $group 不存在"
}

# 获取用户输入
get_user_input() {
    # 获取目标文件夹名
    while true; do
        read -p "请输入目标文件夹名称: " INSTALL_PATH
        if [[ ! -z "$INSTALL_PATH" ]]; then
            if [[ -d "$INSTALL_PATH" ]]; then
                echo -e "${YELLOW}警告: 文件夹已存在${NC}"
                read -p "是否继续？[y/N] " response
                if [[ "$response" =~ ^[Yy]$ ]]; then
                    break
                fi
            else
                break
            fi
        else
            echo -e "${RED}文件夹名称不能为空${NC}"
        fi
    done

    # 获取所属主和所属组
    read -p "请输入所属主 [www-data]: " WP_OWNER
    WP_OWNER=${WP_OWNER:-www-data}
    read -p "请输入所属组 [www-data]: " WP_GROUP
    WP_GROUP=${WP_GROUP:-www-data}

    # 验证用户和组是否存在
    validate_user_group "$WP_OWNER" "$WP_GROUP"

    # 获取数据库信息
    read -p "请输入数据库名称: " DB_NAME
    read -p "请输入数据库用户名: " DB_USER
    read -s -p "请输入数据库密码: " DB_PASSWORD
    echo
    read -p "请输入数据库主机地址 [localhost]: " DB_HOST
    DB_HOST=${DB_HOST:-localhost}


    # 数据库前缀配置
    while true; do
        read -p "请输入数据库表前缀 [wp_]: " DB_PREFIX
        DB_PREFIX=${DB_PREFIX:-wp_}
        
        # 验证前缀格式
        if [[ "$DB_PREFIX" =~ ^[a-zA-Z0-9_]+$ ]]; then
            # 确保前缀以下划线结尾
            if [[ "$DB_PREFIX" != *_ ]]; then
                DB_PREFIX="${DB_PREFIX}_"
                echo -e "${YELLOW}已自动在前缀末尾添加下划线: ${DB_PREFIX}${NC}"
            fi
            break
        else
            echo -e "${RED}错误: 前缀只能包含字母、数字和下划线${NC}"
        fi
    done

    # 显示配置确认
    echo -e "\n${GREEN}配置信息确认:${NC}"
    echo -e "安装目录: ${YELLOW}$INSTALL_PATH${NC}"
    echo -e "所属主: ${YELLOW}$WP_OWNER${NC}"
    echo -e "所属组: ${YELLOW}$WP_GROUP${NC}"
    echo -e "数据库主机: ${YELLOW}$DB_HOST${NC}"
    echo -e "数据库名称: ${YELLOW}$DB_NAME${NC}"
    echo -e "数据库用户: ${YELLOW}$DB_USER${NC}"
    echo -e "数据库前缀: ${YELLOW}$DB_PREFIX${NC}"

    read -p $'\n确认以上配置信息？[y/N] ' response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        error_exit "用户取消安装"
    fi
}

# 下载和验证WordPress
download_wordpress() {
    echo -e "\n${GREEN}正在获取WordPress版本...${NC}"
    WP_VERSION=$(curl -s https://api.wordpress.org/core/version-check/1.7/ | grep -o '"current":"[^"]*"' | head -n 1 | sed -E 's/"current":"([^"]*)"/\1/')

    echo -e "\n${GREEN}正在下载WordPress ${WP_VERSION}...${NC}"
    
    # 下载WordPress
    cd "$TEMP_DIR" || error_exit "无法进入临时目录"
    WP_URL="https://wordpress.org/wordpress-${WP_VERSION}.tar.gz"
    CHECKSUM_URL="https://wordpress.org/wordpress-${WP_VERSION}.tar.gz.sha1"
    
    curl -# -o "wordpress.tar.gz" $WP_URL || error_exit "下载WordPress失败"
    curl -s -o "wordpress.tar.gz.sha1" $CHECKSUM_URL || error_exit "下载校验和失败"
    
    # 验证校验和
    echo -e "${GREEN}正在验证下载完整性...${NC}"
    CHECKSUM=$(cat wordpress.tar.gz.sha1)
    echo "$CHECKSUM wordpress.tar.gz" | sha1sum -c --status
    if [ $? -ne 0 ]; then
        rm wordpress.tar.gz wordpress.tar.gz.sha1
        error_exit "WordPress包验证失败！可能被篡改或下载不完整"
    fi
}

# 解压和配置WordPress
setup_wordpress() {
    echo -e "${GREEN}正在解压文件...${NC}"
    tar xzf wordpress.tar.gz || error_exit "解压失败"
    
    # 重命名wordpress文件夹
    if [ "$INSTALL_PATH" != "wordpress" ]; then
        mv wordpress "$INSTALL_PATH" || error_exit "重命名文件夹失败"
    fi
    
    echo -e "${GREEN}正在配置wp-config.php...${NC}"
    cd "$INSTALL_PATH" || error_exit "无法进入目标目录"
    
    # 复制配置文件
    cp wp-config-sample.php wp-config.php || error_exit "创建配置文件失败"
    
    
    # 修改配置文件
    sed -i "s/database_name_here/$DB_NAME/" wp-config.php
    sed -i "s/username_here/$DB_USER/" wp-config.php
    sed -i "s/password_here/$DB_PASSWORD/" wp-config.php
    sed -i "s/localhost/$DB_HOST/" wp-config.php
    
    # 修改数据库表前缀
    echo -e "${GREEN}正在设置数据库表前缀...${NC}"
    sed -i "s/\$table_prefix = 'wp_';/\$table_prefix = '$DB_PREFIX';/" wp-config.php

    # 获取安全密钥
    echo -e "${GREEN}正在获取安全密钥...${NC}"
    SALT=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
    if [ -z "$SALT" ]; then
        error_exit "获取安全密钥失败"
    fi


    # 替换安全密钥
    echo -e "${GREEN}正在配置安全密钥...${NC}"
    # FORMAT_SALT=$(echo "$SALT" | sed 's/^define/\ndefine/g')
    # sed -i.tmp '
    # /define.*\(AUTH\|SECURE_AUTH\|LOGGED_IN\|NONCE\)_\(KEY\|SALT\)/{
    #     r /dev/stdin
    #     d
    # }' wp-config.php <<< "$FORMAT_SALT" && mv wp-config.php.tmp wp-config.php

    # 创建一个临时文件来保存新的配置
    TEMP_CONFIG=$(mktemp)
    
    # 在配置文件中定位并替换密钥部分
    START_LINE=$(grep -n "define( 'AUTH_KEY'" wp-config.php | cut -d: -f1)
    END_LINE=$(grep -n "define( 'NONCE_SALT'" wp-config.php | cut -d: -f1)
    
    if [ ! -z "$START_LINE" ] && [ ! -z "$END_LINE" ]; then
        # 写入密钥之前的部分
        head -n $((START_LINE - 1)) wp-config.php > "$TEMP_CONFIG"
        
        # 写入新的密钥
        echo "$SALT" >> "$TEMP_CONFIG"
        
        # 写入密钥之后的部分
        tail -n +$((END_LINE + 1)) wp-config.php >> "$TEMP_CONFIG"
        
        # 检查临时文件是否创建成功
        if [ -s "$TEMP_CONFIG" ]; then
            mv "$TEMP_CONFIG" wp-config.php
        else
            rm -f "$TEMP_CONFIG"
            error_exit "替换安全密钥失败"
        fi
    else
        rm -f "$TEMP_CONFIG"
        error_exit "无法在配置文件中找到密钥部分"
    fi


    # 设置文件权限和所属关系
    echo -e "${GREEN}正在设置文件权限和所属关系...${NC}"
    chown -R "$WP_OWNER:$WP_GROUP" . || error_exit "更改所属关系失败"
    chmod 644 wp-config.php
    find . -type d -exec chmod 755 {} \;
    find . -type f -exec chmod 644 {} \;
}

# 清理临时文件
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        echo -e "${GREEN}清理临时文件${NC}"
        rm -rf "$TEMP_DIR"
    fi
}

# 主程序
main() {
    echo -e "${GREEN}WordPress 安装脚本启动${NC}"
    
    # 检查必要工具
    check_requirements
    
    # 创建临时目录
    create_temp_dir

    # 获取用户输入
    get_user_input
    
    # 下载和验证
    download_wordpress
    
    # 安装和配置
    setup_wordpress
    
    echo -e "\n${GREEN}WordPress ${WP_VERSION}安装完成！${NC}"
    echo -e "安装目录: ${YELLOW}$INSTALL_PATH${NC}"
    echo -e "所属主: ${YELLOW}$WP_OWNER${NC}"
    echo -e "所属组: ${YELLOW}$WP_GROUP${NC}"
    echo -e "\n${YELLOW}请确保您的数据库已经创建并且配置正确。${NC}"
    echo -e "${YELLOW}下一步：${NC}"
    echo "1. 配置Web服务器指向 $INSTALL_PATH 目录"
    echo "2. 访问您的网站完成WordPress安装"
}

# 运行主程序
main
