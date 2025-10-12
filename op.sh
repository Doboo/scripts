#!/bin/sh
# 2.4G配置信息
uci set wireless.radio0.htmode='HE40'
uci set wireless.radio0.channel='auto'
uci set wireless.radio0.country='CN'
uci set wireless.radio0.cell_density='0'
uci set wireless.default_radio0.encryption='psk-mixed'
uci set wireless.default_radio0.key='38196962'
# 5G配置信息
uci set wireless.radio1.channel='auto'
uci set wireless.radio1.country='CN'
uci set wireless.radio1.cell_density='0'
uci set wireless.default_radio1.ssid='OpenWrt-5G'
uci set wireless.default_radio1.encryption='psk-mixed'
uci set wireless.default_radio1.key='38196962'
