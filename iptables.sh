export tun_IF=tun0  && export WAN_IF=eth0  #设置物理网卡和虚拟网卡的接口
#其中的 tun0 在不同的机器中不一样，你可以在路由器ssh环境中用 ip addr
iptables -I FORWARD -i $WAN_IF -j ACCEPT
iptables -I FORWARD -o  $WAN_IF -j ACCEPT
iptables -t nat -I POSTROUTING -o  $WAN_IF -j MASQUERADE
iptables -I FORWARD -i $tun_IF -j ACCEPT
iptables -I FORWARD -o $tun_IF -j ACCEPT
iptables -t nat -I POSTROUTING -o $tun_IF -j MASQUERADE
apt-get install iptables-persistent -y #保存规则，重启后能生效
netfilter-persistent save
