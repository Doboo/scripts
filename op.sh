#!/bin/sh
# OpenWrt 无线配置脚本
# 警告：密码已从脚本中移除，请在运行前设置环境变量 WIFI_KEY
# 用法示例: WIFI_KEY='你的密码' sh op.sh

# 检查密码是否已设置
if [ -z "$WIFI_KEY" ]; then
    printf "错误：请通过环境变量 WIFI_KEY 设置 WiFi 密码\n"
    printf "用法示例: WIFI_KEY='你的密码' sh %s\n" "$0"
    exit 1
fi

# 2.4G 配置信息
uci set wireless.radio0.htmode='HE40'
uci set wireless.radio0.channel='auto'
uci set wireless.radio0.country='CN'
uci set wireless.radio0.cell_density='0'
uci set wireless.default_radio0.encryption='psk-mixed'
uci set wireless.default_radio0.key="$WIFI_KEY"

# 5G 配置信息
uci set wireless.radio1.channel='auto'
uci set wireless.radio1.country='CN'
uci set wireless.radio1.cell_density='0'
uci set wireless.default_radio1.ssid='OpenWrt-5G'
uci set wireless.default_radio1.encryption='psk-mixed'
uci set wireless.default_radio1.key="$WIFI_KEY"

# 应用配置
uci commit wireless
wifi reload

printf "无线配置已应用完成。\n"
