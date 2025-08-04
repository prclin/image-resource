#!/bin/sh

#获取集群节点列表
echo "请输入master节点列表:"
read masters

echo "请输入node节点列表(包含master节点):"
read nodes

echo "请输入etcd节点列表:"
read etcd_nodes

echo "masters are: $masters"
echo "nodes are: $nodes"
echo "etcd nodes are: $etcd_nodes"

k8s_lb=$(echo "$masters" | cut -d' ' -f1)
all_nodes="$nodes $etcd_nodes"
k8s_nodes="$nodes"

echo "开始配置免密登陆..."

echo "生成证书ssh密钥..."
KEY_PATH="$HOME/.ssh/id_rsa"

# 检查密钥是否已存在
if [ -f "$KEY_PATH" ]; then
  echo "SSH 密钥已存在：$KEY_PATH"
else
  echo "正在生成 SSH 密钥对..."
  yes y | ssh-keygen -t rsa -b 2048 -N "" -f "$KEY_PATH" >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    echo "✅ SSH 密钥生成成功：$KEY_PATH"
  else
    echo "❌ SSH 密钥生成失败"
    exit 1
  fi
fi

for i in $all_nodes;do 
    echo "请输入 root@$i 的登录密码："
    # 读取密码时隐藏输入
    stty -echo
    read pwd
    stty echo
    echo

    # 检查 sshpass 是否已安装
    if ! command -v sshpass >/dev/null 2>&1; then
      echo "错误：sshpass 未安装，请先安装 sshpass"
      exit 1
    fi
    sshpass -p "$pwd" ssh-copy-id -i ~/.ssh/id_rsa.pub -o StrictHostKeyChecking=no $i

    if [ $? -eq 0 ]; then
        echo "✅ 已成功将公钥复制到 $i"
    else
        echo "❌ 公钥复制失败，请检查用户名、密码或主机是否可达"
    fi
done

echo "免密登陆配置完成!"

all_nodes_ip_map=""
#获取主机对应的ip
for node in $all_nodes; do
    ip=$(getent hosts "$node" | awk '{print $1}')
    # 如果 getent 失败，也可以用 nslookup
    if [ -z "$ip" ]; then
      ip=$(nslookup "$node" | awk '/^Address: / { print $2 }' | tail -n1)
    fi
    all_nodes_ip_map="$all_nodes_ip_map $node:$ip"
done
echo $all_nodes_ip_map

echo "开始初始化节点环境"
for node in $k8s_nodes; do
    echo "域名解析设置..."
    ssh root@$node "ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf"
    echo "更新软件源..."
    ssh root@$node "apt update"
    echo "关闭防火墙..."
    ssh root@$node "systemctl disable firewalld"
    echo "配置iptables..."
    ssh root@$node "apt install -y iptables && systemctl enable --now iptables && iptables -L -n -v && iptables -F && mkdir /etc/iptables && touch /etc/iptables/rules.v4 && iptables-save > /etc/iptables/rules.v4 && touch /etc/iptables/rules.v6 && ip6tables-save > /etc/iptables/rules.v6"
    echo "设置selinux..."
    ssh root@$node <<EOF
apt install -y selinux-utils
if [ -f /etc/selinux/config ]; then
    sed -i 's#SELINUX=enforcing#SELINUX=disabled#g' /etc/selinux/config
else
    cat > /etc/selinux/config << INNER_EOF
    # This file controls the state of SELinux on the system.
    # SELINUX= can take one of these three values:
    #     enforcing - SELinux security policy is enforced.
    #     permissive - SELinux prints warnings instead of enforcing.
    #     disabled - No SELinux policy is loaded.
    SELINUX=disabled
    # SELINUXTYPE= can take one of three values:
    #     targeted - Targeted processes are protected,
    #     minimum - Modification of targeted policy. Only selected processes are protected. 
    #     mls - Multi Level Security protection.
    SELINUXTYPE=targeted
    INNER_EOF
fi
EOF
    echo "设置swap分区..."
    ssh root@$node "swapoff -a && sed -ri '/^[^#]*swap/s@^@#@' /etc/fstab"
    echo "时间设置..."
    echo root@$node <<EOF
timedatectl set-timezone Asia/Shanghai
apt install -y ntpdate
ntpdate time2.aliyun.com
crontab -l > mycron
echo "*/5 * * * * /usr/sbin/ntpdate time2.aliyun.com" >> mycron
crontab mycron
rm mycron
EOF
    echo "开启路由转发..."
    ssh root@$node "echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf && echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf && sysctl -p"

    echo "NetworkManager设置..."
    ssh root@$node <<EOF
cat > /etc/NetworkManager/conf.d/calico.conf << INNER_EOF
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:tunl*
INNER_EOF
systemctl restart NetworkManager
EOF
    echo "ulimit配置"
    ssh root@$node <<EOF
ulimit -SHn 65535 
cat > /etc/security/limits.conf << INNER_EOF
* soft nofile 655360
* hard nofile 131072
* soft nproc 655350
* hard nproc 655350
* soft memlock unlimited
* hard memlock unlimited
INNER_EOF
EOF
    echo "ipvs配置..."
    ssh root@$node <<EOF
apt install -y ipvsadm ipset sysstat conntrack
cat >/etc/modules-load.d/ipvs.conf <<INNER_EOF
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
ip_tables
ip_set
xt_set
ipt_set
ipt_rpfilter
ipt_REJECT
ipip
INNER_EOF
systemctl restart systemd-modules-load.service
lsmod | grep -e ip_vs -e nf_conntrack
EOF
    echo "配置k8s所需内核参数..."
    ssh root@$node <<EOF
cat <<INNER_EOF > /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
fs.may_detach_mounts = 1
vm.overcommit_memory=1
vm.panic_on_oom=0
fs.inotify.max_user_watches=89100
fs.file-max=52706963
fs.nr_open=52706963
net.netfilter.nf_conntrack_max=2310720
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl =15
net.ipv4.tcp_max_tw_buckets = 36000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_orphans = 327680
net.ipv4.tcp_orphan_retries = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.ip_conntrack_max = 65536
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_timestamps = 0
net.core.somaxconn = 16384
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.dsiable_ipv6 = 0
net.ipv6.conf.lo.dsiable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
INNER_EOF
sysctl --system
EOF
done


echo "开始生成证书..."
if command -v cfssl >/dev/null 2>&1; then
    :
else
    echo "cfssl不存在，开始下载..."
    wget "https://github.com/cloudflare/cfssl/releases/download/v1.6.5/cfssl_1.6.5_linux_amd64" -O /usr/local/bin/cfssl
    chmod +x /usr/local/bin/cfssl 
fi

if command -v cfssljson >/dev/null 2>&1; then
    :
else
    echo "cfssljson不存在，开始下载..."
    wget "https://github.com/cloudflare/cfssl/releases/download/v1.6.5/cfssljson_1.6.5_linux_amd64" -O /usr/local/bin/cfssljson
    chmod +x /usr/local/bin/cfssljson
fi

echo "下载物料..."
cd ~
rm -rf ~/k8s-ha-install
git clone https://github.com/dotbalo/k8s-ha-install.git
cd ~/k8s-ha-install
git checkout manual-installation-v1.30.x
cd pki

echo "生成etcd证书..."
mkdir -p /etc/etcd/ssl
#etcd CA证书生成
cfssl gencert -initca etcd-ca-csr.json | cfssljson -bare /etc/etcd/ssl/etcd-ca
#获取etcd节点的hostname和ip
etcd_hostnames="127.0.0.1"
for target in $etcd_nodes; do
    for item in $all_nodes_ip_map; do
        node=$(echo "$item" | cut -d: -f1)
        ip=$(echo "$item" | cut -d: -f2)

        if [ "$node" = "$target" ]; then
            etcd_hostnames="$etcd_hostnames,$node,$ip"
            break
        fi
    done
done
#颁发etcd客户端证书
cfssl gencert \
   -ca=/etc/etcd/ssl/etcd-ca.pem \
   -ca-key=/etc/etcd/ssl/etcd-ca-key.pem \
   -config=ca-config.json \
   -hostname=$etcd_hostnames \
   -profile=kubernetes \
   etcd-csr.json | cfssljson -bare /etc/etcd/ssl/etcd
#将证书发送到其它etcd结点
for node in $etcd_nodes; do
     ssh $node "mkdir -p /etc/etcd/ssl"
     for FILE in etcd-ca-key.pem  etcd-ca.pem  etcd-key.pem  etcd.pem; do
       scp /etc/etcd/ssl/$FILE $node:/etc/etcd/ssl/$FILE
     done
 done

echo "生成k8s证书..."

echo "请输入pod网段(例如172.16.0.0/16):"
read pod_net
echo "请输入service网段(例如10.96.0.0/16):"
read service_net

if command -v ipcalc >/dev/null 2>&1; then
    :
else
    echo "ipcalc不存在，开始安装..."
    apt install -y ipcalc
fi

#获取service网段第1和10个地址
service_first_ip=$(ipcalc "$service_net" | awk '/HostMin/ { print $2 }')
# 把IP转换为整数
ip_to_int() {
    old_ifs="$IFS"
    IFS=. 
    set -- $1
    a=$1
    b=$2
    c=$3
    d=$4
    IFS="$old_ifs"
    echo $((a * 256 * 256 * 256 + b * 256 * 256 + c * 256 + d))
}

# 把整数转换为IP
int_to_ip() {
    ip_int=$1
    a=$((ip_int / 256 / 256 / 256 % 256))
    b=$((ip_int / 256 / 256 % 256))
    c=$((ip_int / 256 % 256))
    d=$((ip_int % 256))
    echo "$a.$b.$c.$d"
}

first_ip_int=$(ip_to_int "$service_first_ip")
service_broad_ip=$(int_to_ip $((first_ip_int + 9)))
#获取lb ip
k8s_lb_ip=""
for item in $all_nodes_ip_map; do
    node=$(echo "$item" | cut -d: -f1)
    ip=$(echo "$item" | cut -d: -f2)
    if [ "$node" = "$k8s_lb" ]; then
        k8s_lb_ip="$ip"
        break
    fi
done

mkdir -p /etc/kubernetes/pki

#生成kubernetes CA证书
cfssl gencert -initca ca-csr.json | cfssljson -bare /etc/kubernetes/pki/ca
#获取k8s节点的hostname和ip
k8s_hostnames="127.0.0.1,kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster,kubernetes.default.svc.cluster.local,$service_first_ip,$k8s_lb_ip"
for target in $masters; do
    for item in $all_nodes_ip_map; do
        node=$(echo "$item" | cut -d: -f1)
        ip=$(echo "$item" | cut -d: -f2)

        if [ "$node" = "$target" ]; then
            k8s_hostnames="$k8s_hostnames,$ip"
            break
        fi
    done
done
echo "k8s-hosts: $k8s_hostnames"
sleep 5
#颁发api-server客户端证书
cfssl gencert \
    -ca=/etc/kubernetes/pki/ca.pem \
    -ca-key=/etc/kubernetes/pki/ca-key.pem \
    -config=ca-config.json \
    -hostname=$k8s_hostnames \
    -profile=kubernetes apiserver-csr.json | cfssljson -bare /etc/kubernetes/pki/apiserver
#生成api-server聚合ca证书
cfssl gencert -initca front-proxy-ca-csr.json | cfssljson -bare /etc/kubernetes/pki/front-proxy-ca
#颁发apiserver客户端聚合证书
cfssl gencert \
    -ca=/etc/kubernetes/pki/front-proxy-ca.pem \
    -ca-key=/etc/kubernetes/pki/front-proxy-ca-key.pem \
    -config=ca-config.json \
    -profile=kubernetes \
    front-proxy-client-csr.json | cfssljson -bare /etc/kubernetes/pki/front-proxy-client
#颁发controller-manager的证书
cfssl gencert \
   -ca=/etc/kubernetes/pki/ca.pem \
   -ca-key=/etc/kubernetes/pki/ca-key.pem \
   -config=ca-config.json \
   -profile=kubernetes \
   manager-csr.json | cfssljson -bare /etc/kubernetes/pki/controller-manager
#颁发scheduler证书
cfssl gencert \
   -ca=/etc/kubernetes/pki/ca.pem \
   -ca-key=/etc/kubernetes/pki/ca-key.pem \
   -config=ca-config.json \
   -profile=kubernetes \
   scheduler-csr.json | cfssljson -bare /etc/kubernetes/pki/scheduler
#颁发admin管理员
cfssl gencert \
   -ca=/etc/kubernetes/pki/ca.pem \
   -ca-key=/etc/kubernetes/pki/ca-key.pem \
   -config=ca-config.json \
   -profile=kubernetes \
   admin-csr.json | cfssljson -bare /etc/kubernetes/pki/admin
#颁发kube-proxy证书
cfssl gencert \
   -ca=/etc/kubernetes/pki/ca.pem \
   -ca-key=/etc/kubernetes/pki/ca-key.pem \
   -config=ca-config.json \
   -profile=kubernetes \
   kube-proxy-csr.json | cfssljson -bare /etc/kubernetes/pki/kube-proxy
#将证书发送到其它k8s master结点
for node in $masters; do
    ssh $node "mkdir -p /etc/kubernetes/pki"
    for FILE in $(ls /etc/kubernetes/pki | grep -v etcd); do 
        scp /etc/kubernetes/pki/$FILE $node:/etc/kubernetes/pki/$FILE
    done
done

echo "安装etcd..."
if [ ! -d "$HOME/etcd.d" ]; then
    mkdir ~/etcd.d
fi
cd ~/etcd.d

if [ -f $HOME/etcd.d/etcd-v3.5.15-linux-amd64.tar.gz ]; then
    :
else
    echo "下载etcd..."
    #todo 动态etcd版本安装
    wget https://github.com/etcd-io/etcd/releases/download/v3.5.15/etcd-v3.5.15-linux-amd64.tar.gz
fi

#获取etcd初始化集群节点的所有master地址
initial_cluster=""
etcd_listen_urls=""
for node in $etcd_nodes; do
    for item in $all_nodes_ip_map; do
        ip=$(echo "$item" | cut -d: -f2)
        initial_cluster="$initial_cluster,$node=https://$ip:2380"
        etcd_listen_urls="$etcd_listen_urls,$ip:2379"
        break
    done
done
initial_cluster=$(echo "$initial_cluster" | cut -c2-)
etcd_listen_urls=$(echo "$etcd_listen_urls" | cut -c2-)
#开始安装
for node in $etcd_nodes; do
    #发送etcd安装包
    ssh $node "mkdir ~/etcd.d"
    scp ~/etcd.d/etcd.tar.gz $node:~/etcd.d/etcd.tar.gz
    node_ip=""
    for item in $all_nodes_ip_map; do
        target=$(echo "$item" | cut -d: -f1)
        ip=$(echo "$item" | cut -d: -f2)

        if [ "$node" = "$target" ]; then
            node_ip="$ip"
            break
        fi
    done

    ssh $node <<OUTER_EOF
cd ~/etcd.d
tar -zxvf etcd-v3.5.15-linux-amd64.tar.gz --strip-components=1 -C /usr/local/bin etcd-v3.5.15-linux-amd64/etcd{,ctl}
mkdir  /etc/kubernetes/pki/etcd/
ln -s /etc/etcd/ssl/* /etc/kubernetes/pki/etcd/
cat <<EOF > /etc/etcd/etcd.config.yaml
name: '$node'
data-dir: /var/lib/etcd
wal-dir: /var/lib/etcd/wal
snapshot-count: 5000
heartbeat-interval: 100
election-timeout: 1000
quota-backend-bytes: 0
listen-peer-urls: 'https://$node_ip:2380'
listen-client-urls: 'https://$node_ip:2379,http://127.0.0.1:2379'
max-snapshots: 3
max-wals: 5
cors:
initial-advertise-peer-urls: 'https://$node_ip:2380'
advertise-client-urls: 'https://$node_ip:2379'
discovery:
discovery-fallback: 'proxy'
discovery-proxy:
discovery-srv:
initial-cluster: '$initial_cluster'
initial-cluster-token: 'etcd-k8s-cluster'
initial-cluster-state: 'new'
strict-reconfig-check: false
enable-v2: true
enable-pprof: true
proxy: 'off'
proxy-failure-wait: 5000
proxy-refresh-interval: 30000
proxy-dial-timeout: 1000
proxy-write-timeout: 5000
proxy-read-timeout: 0
client-transport-security:
  cert-file: '/etc/kubernetes/pki/etcd/etcd.pem'
  key-file: '/etc/kubernetes/pki/etcd/etcd-key.pem'
  client-cert-auth: true
  trusted-ca-file: '/etc/kubernetes/pki/etcd/etcd-ca.pem'
  auto-tls: true
peer-transport-security:
  cert-file: '/etc/kubernetes/pki/etcd/etcd.pem'
  key-file: '/etc/kubernetes/pki/etcd/etcd-key.pem'
  peer-client-cert-auth: true
  trusted-ca-file: '/etc/kubernetes/pki/etcd/etcd-ca.pem'
  auto-tls: true
debug: false
log-package-levels:
log-outputs: [default]
force-new-cluster: false
EOF

cat <<EOF > /usr/lib/systemd/system/etcd.service
[Unit]
Description=Etcd Service
Documentation=https://coreos.com/etcd/docs/latest/
After=network.target

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd --config-file=/etc/etcd/etcd.config.yaml
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
Alias=etcd3.service
EOF

systemctl daemon-reload
systemctl enable --now etcd
systemctl restart etcd
OUTER_EOF
done
#校验安装结果
tar -zxvf etcd-v3.5.15-linux-amd64.tar.gz --strip-components=1 -C /usr/local/bin etcd-v3.5.15-linux-amd64/etcdctl
#导出etcdctl api接口版本
export ETCDCTL_API=3

#查看etcd状态
sleep 10
echo $"$etcd_listen_urls"
etcdctl --endpoints="$etcd_listen_urls" \
  --cacert=/etc/kubernetes/pki/etcd/etcd-ca.pem \
  --cert=/etc/kubernetes/pki/etcd/etcd.pem \
  --key=/etc/kubernetes/pki/etcd/etcd-key.pem \
  endpoint status --write-out=table

if [ $? -eq 0 ]; then
    echo "✅etcd安装成功"
  else
    echo "❌etcd安装失败"
    exit 1
fi

echo "安装docker..."
if [ ! -d "$HOME/docker.d" ]; then
    mkdir ~/docker.d
    cd ~/docker.d
    echo "下载docker..."
    #todo 动态docker下载
    wget https://mirrors.aliyun.com/docker-ce/linux/ubuntu/dists/jammy/pool/stable/amd64/containerd.io_1.7.22-1_amd64.deb
    wget https://mirrors.aliyun.com/docker-ce/linux/ubuntu/dists/jammy/pool/stable/amd64/docker-ce-cli_27.3.1-1~ubuntu.22.04~jammy_amd64.deb
    wget https://mirrors.aliyun.com/docker-ce/linux/ubuntu/dists/jammy/pool/stable/amd64/docker-ce_27.3.1-1~ubuntu.22.04~jammy_amd64.deb
    wget https://github.com/Mirantis/cri-dockerd/releases/download/v0.3.15/cri-dockerd_0.3.15.3-0.ubuntu-jammy_amd64.deb
fi
cd ~/docker.d

#开始安装
for node in $nodes; do
    #发送k8s安装包
    ssh $node "mkdir ~/docker.d"
    scp -r ~/docker.d/* $node:~/docker.d/
    ssh $node <<OUTER_EOF
cd ~/docker.d
dpkg -i ./*.deb
mkdir -p /etc/docker
cat <<EOF >/etc/docker/daemon.json
{
  "registry-mirrors": [
    "https://4tuvcdxu.mirror.aliyuncs.com",
    "https://docker.mirrors.ustc.edu.cn",
    "https://dockerhub.icu",
    "https://docker.chenby.cn",
    "https://docker.1panel.live",
    "https://docker.awsl9527.cn",
    "https://docker.anyhub.us.kg",
    "https://dhub.kubesre.xyz"
  ],
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "data-root": "/var/lib/docker",
  "storage-driver": "overlay2",
  "live-restore": true,
  "max-concurrent-downloads": 10,
  "max-concurrent-uploads": 5
}
EOF
systemctl daemon-reload
systemctl enable --now docker
systemctl restart docker

#containerd配置
containerd config default > ~/config.toml
sed -i '/sandbox[-_]image/ c\    sandbox_image = "registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.10"' ~/config.toml
sed -i "s#SystemdCgroup = false#SystemdCgroup = true#g" ~/config.toml
rm -rf /etc/containerd/config.toml
cp ~/config.toml /etc/containerd/config.toml
rm -rf ~/config.toml
systemctl enable --now containerd
systemctl restart containerd
#cri-docker配置
sed -i 's|^ExecStart=.*|ExecStart=/usr/bin/cri-dockerd --network-plugin=cni --pod-infra-container-image=registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.10|' /etc/systemd/system/multi-user.target.wants/cri-docker.service
sed -i 's|^ExecStart=.*|ExecStart=/usr/bin/cri-dockerd --network-plugin=cni --pod-infra-container-image=registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.10|' /usr/lib/systemd/system/cri-docker.service
systemctl daemon-reload
systemctl enable --now cri-docker
systemctl restart cri-docker
OUTER_EOF
done

echo "安装k8s masters..."
if [ ! -d "$HOME/k8s" ]; then
    mkdir ~/k8s
fi
cd ~/k8s
if [ -f $HOME/k8s/kubernetes-server-linux-amd64.tar.gz ]; then
    :
else
    echo "下载k8s..."
    #todo 动态k8s下载
    wget https://dl.k8s.io/v1.31.2/kubernetes-server-linux-amd64.tar.gz
fi

#生成k8s相关配置
tar -xf kubernetes-server-linux-amd64.tar.gz  --strip-components=3 -C /usr/local/bin kubernetes/server/bin/kubectl
#配置controller-manager的kubeconfig文件
#设置一个集群项。注意，如果不是高可用集群，$k8s_lb_ip:8443改为k8s-1的地址，8443改为api-server的端口，默认是6443
kubectl config set-cluster kubernetes \
     --certificate-authority=/etc/kubernetes/pki/ca.pem \
     --embed-certs=true \
     --server=https://$k8s_lb_ip:6443 \
     --kubeconfig=/etc/kubernetes/controller-manager.kubeconfig
#设置一个用户项
kubectl config set-credentials system:kube-controller-manager \
     --client-certificate=/etc/kubernetes/pki/controller-manager.pem \
     --client-key=/etc/kubernetes/pki/controller-manager-key.pem \
     --embed-certs=true \
     --kubeconfig=/etc/kubernetes/controller-manager.kubeconfig
#设置一个环境项，也就是上下文
kubectl config set-context system:kube-controller-manager@kubernetes \
    --cluster=kubernetes \
    --user=system:kube-controller-manager \
    --kubeconfig=/etc/kubernetes/controller-manager.kubeconfig
#设置默认环境项
kubectl config use-context system:kube-controller-manager@kubernetes \
     --kubeconfig=/etc/kubernetes/controller-manager.kubeconfig

#配置scheduler的kubeconfig文件
#设置一个集群项。注意，如果不是高可用集群，$k8s_lb_ip:8443改为k8s-1的地址，8443改为api-server的端口，默认是6443
kubectl config set-cluster kubernetes \
     --certificate-authority=/etc/kubernetes/pki/ca.pem \
     --embed-certs=true \
     --server=https://$k8s_lb_ip:6443 \
     --kubeconfig=/etc/kubernetes/scheduler.kubeconfig
#设置一个用户项
kubectl config set-credentials system:kube-scheduler \
     --client-certificate=/etc/kubernetes/pki/scheduler.pem \
     --client-key=/etc/kubernetes/pki/scheduler-key.pem \
     --embed-certs=true \
     --kubeconfig=/etc/kubernetes/scheduler.kubeconfig
#设置一个环境项
kubectl config set-context system:kube-scheduler@kubernetes \
     --cluster=kubernetes \
     --user=system:kube-scheduler \
     --kubeconfig=/etc/kubernetes/scheduler.kubeconfig
#设置默认环境项
kubectl config use-context system:kube-scheduler@kubernetes \
     --kubeconfig=/etc/kubernetes/scheduler.kubeconfig

#配置admin的kubeconfig文件
#设置一个集群项。注意，如果不是高可用集群，$k8s_lb_ip:8443改为k8s-1的地址，8443改为api-server的端口，默认是6443
kubectl config set-cluster kubernetes \
    --certificate-authority=/etc/kubernetes/pki/ca.pem \
    --embed-certs=true \
    --server=https://$k8s_lb_ip:6443 \
    --kubeconfig=/etc/kubernetes/admin.kubeconfig
#设置一个用户项
kubectl config set-credentials kubernetes-admin \
    --client-certificate=/etc/kubernetes/pki/admin.pem \
    --client-key=/etc/kubernetes/pki/admin-key.pem \
    --embed-certs=true \
    --kubeconfig=/etc/kubernetes/admin.kubeconfig
#设置一个环境项
kubectl config set-context kubernetes-admin@kubernetes \
   --cluster=kubernetes \
   --user=kubernetes-admin \
   --kubeconfig=/etc/kubernetes/admin.kubeconfig
#设置默认环境项
kubectl config use-context kubernetes-admin@kubernetes \
  --kubeconfig=/etc/kubernetes/admin.kubeconfig

#配置kube-proxy的kubeconfig文件
#设置一个集群项。注意，如果不是高可用集群，$k8s_lb_ip:8443改为k8s-1的地址，8443改为api-server的端口，默认是6443
kubectl config set-cluster kubernetes \
    --certificate-authority=/etc/kubernetes/pki/ca.pem \
    --embed-certs=true \
    --server=https://$k8s_lb_ip:6443 \
    --kubeconfig=/etc/kubernetes/kube-proxy.kubeconfig
#设置一个用户项
kubectl config set-credentials kube-proxy \
    --client-certificate=/etc/kubernetes/pki/kube-proxy.pem \
    --client-key=/etc/kubernetes/pki/kube-proxy-key.pem \
    --embed-certs=true \
    --kubeconfig=/etc/kubernetes/kube-proxy.kubeconfig
#设置一个环境项
kubectl config set-context kube-proxy@kubernetes \
   --cluster=kubernetes \
   --user=kube-proxy \
   --kubeconfig=/etc/kubernetes/kube-proxy.kubeconfig
#设置默认环境项
kubectl config use-context kube-proxy@kubernetes \
  --kubeconfig=/etc/kubernetes/kube-proxy.kubeconfig

#创建ServiceAccount Key，也就是secret
openssl genrsa -out /etc/kubernetes/pki/sa.key 2048
openssl rsa -in /etc/kubernetes/pki/sa.key -pubout -out /etc/kubernetes/pki/sa.pub

#开始安装
for node in $masters; do
    #发送k8s安装包
    ssh $node "mkdir ~/k8s"
    scp ~/k8s/kubernetes-server-linux-amd64.tar.gz $node:~/k8s/kubernetes-server-linux-amd64.tar.gz
    #发送配置文件
    for file in pki/sa.key pki/sa.pub admin.kubeconfig controller-manager.kubeconfig scheduler.kubeconfig; do 
        scp /etc/kubernetes/$file $node:/etc/kubernetes/$file
    done

    ssh $node <<OUTER_EOF
cd ~/k8s
tar -xf kubernetes-server-linux-amd64.tar.gz  --strip-components=3 -C /usr/local/bin kubernetes/server/bin/kube{ctl,-apiserver,-controller-manager,-scheduler}
#所有节点创建k8s相关目录
mkdir -p /etc/kubernetes/manifests/ /etc/systemd/system/kubelet.service.d /var/lib/kubelet /var/log/kubernetes

#所有k8s master节点创建kube-apiserver service，配置不同
cat <<EOF > /usr/lib/systemd/system/kube-apiserver.service 
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes
After=network.target
 
[Service]
ExecStart=/usr/local/bin/kube-apiserver \
      --v=2  \
      --allow-privileged=true  \
      --bind-address=0.0.0.0  \
      --secure-port=6443  \
      --advertise-address=$k8s_lb_ip \
      --service-cluster-ip-range=$service_net  \
      --service-node-port-range=30000-32767  \
      --etcd-servers=$etcd_listen_urls \
      --etcd-cafile=/etc/etcd/ssl/etcd-ca.pem  \
      --etcd-certfile=/etc/etcd/ssl/etcd.pem  \
      --etcd-keyfile=/etc/etcd/ssl/etcd-key.pem  \
      --client-ca-file=/etc/kubernetes/pki/ca.pem  \
      --tls-cert-file=/etc/kubernetes/pki/apiserver.pem  \
      --tls-private-key-file=/etc/kubernetes/pki/apiserver-key.pem  \
      --kubelet-client-certificate=/etc/kubernetes/pki/apiserver.pem  \
      --kubelet-client-key=/etc/kubernetes/pki/apiserver-key.pem  \
      --service-account-key-file=/etc/kubernetes/pki/sa.pub  \
      --service-account-signing-key-file=/etc/kubernetes/pki/sa.key  \
      --service-account-issuer=https://kubernetes.default.svc.cluster.local \
      --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname  \
      --enable-admission-plugins=NamespaceLifecycle,LimitRanger,ServiceAccount,DefaultStorageClass,DefaultTolerationSeconds,NodeRestriction,ResourceQuota  \
      --authorization-mode=Node,RBAC  \
      --enable-bootstrap-token-auth=true  \
      --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.pem  \
      --proxy-client-cert-file=/etc/kubernetes/pki/front-proxy-client.pem  \
      --proxy-client-key-file=/etc/kubernetes/pki/front-proxy-client-key.pem  \
      --requestheader-allowed-names=aggregator  \
      --requestheader-group-headers=X-Remote-Group  \
      --requestheader-extra-headers-prefix=X-Remote-Extra-  \
      --requestheader-username-headers=X-Remote-User
      # --token-auth-file=/etc/kubernetes/token.csv
 
Restart=on-failure
RestartSec=10s
LimitNOFILE=65535
 
[Install]
WantedBy=multi-user.target
EOF
#启动apiserver
systemctl daemon-reload
systemctl enable --now kube-apiserver
systemctl restart kube-apiserver
#所有master节点配置kube-controller-manager service，配置相同
cat <<EOF > /usr/lib/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes
After=network.target
 
[Service]
ExecStart=/usr/local/bin/kube-controller-manager \
      --v=2 \
      --bind-address=0.0.0.0 \
      --root-ca-file=/etc/kubernetes/pki/ca.pem \
      --cluster-signing-cert-file=/etc/kubernetes/pki/ca.pem \
      --cluster-signing-key-file=/etc/kubernetes/pki/ca-key.pem \
      --service-account-private-key-file=/etc/kubernetes/pki/sa.key \
      --kubeconfig=/etc/kubernetes/controller-manager.kubeconfig \
      --leader-elect=true \
      --use-service-account-credentials=true \
      --node-monitor-grace-period=40s \
      --node-monitor-period=5s \
      --controllers=*,bootstrapsigner,tokencleaner \
      --allocate-node-cidrs=true \
      --service-cluster-ip-range=$service_net \
      --cluster-cidr=$pod_net \
      --node-cidr-mask-size=24 \
      --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.pem

Restart=always
RestartSec=10s
 
[Install]
WantedBy=multi-user.target
EOF
#所有master节点启动kube-controller-manager
systemctl daemon-reload
systemctl enable --now kube-controller-manager
systemctl restart kube-controller-manager
#所有master节点配置kube-scheduler service，配置相同
cat <<EOF > /usr/lib/systemd/system/kube-scheduler.service 
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes
After=network.target
 
[Service]
ExecStart=/usr/local/bin/kube-scheduler \
      --v=2 \
      --bind-address=0.0.0.0 \
      --leader-elect=true \
      --kubeconfig=/etc/kubernetes/scheduler.kubeconfig
 
Restart=always
RestartSec=10s
 
[Install]
WantedBy=multi-user.target
EOF
#所有master节点启动kube-scheduler 
systemctl daemon-reload 
systemctl enable --now kube-scheduler
systemctl restart kube-scheduler
OUTER_EOF
done

#配置tls bootstrap
cd ~/k8s-ha-install/bootstrap
#修改token
sed -i 's/name: bootstrap-token-c8ad9c/name: bootstrap-token-1e8cd1/g' bootstrap.secret.yaml
sed -i 's/token-id: c8ad9c/token-id: 1e8cd1/g' bootstrap.secret.yaml
sed -i 's/token-secret: 2e4d610cf3e7426e/token-secret: df64bc92c17f30f2/g' bootstrap.secret.yaml

kubectl config set-cluster kubernetes \
  --certificate-authority=/etc/kubernetes/pki/ca.pem \
  --embed-certs=true \
  --server=https://$k8s_lb_ip:6443\
  --kubeconfig=/etc/kubernetes/bootstrap-kubelet.kubeconfig

#token参数是，bootstrap.secret.yaml中Secret的token-id.token-secret
kubectl config set-credentials tls-bootstrap-token-user \
  --token=1e8cd1.df64bc92c17f30f2 \
  --kubeconfig=/etc/kubernetes/bootstrap-kubelet.kubeconfig
  
kubectl config set-context tls-bootstrap-token-user@kubernetes \
  --cluster=kubernetes \
  --user=tls-bootstrap-token-user \
  --kubeconfig=/etc/kubernetes/bootstrap-kubelet.kubeconfig
  
kubectl config use-context tls-bootstrap-token-user@kubernetes \
  --kubeconfig=/etc/kubernetes/bootstrap-kubelet.kubeconfig
  
#创建目录，并将admin.kubeconfig复制到此目录
mkdir -p /root/.kube
cp /etc/kubernetes/admin.kubeconfig /root/.kube/config

#创建bootstrap
kubectl create -f bootstrap.secret.yaml


echo "安装k8s nodes..."
cd ~/k8s
#开始安装
for node in $nodes; do
    #发送k8s安装包
    ssh $node "mkdir ~/k8s && mkdir ~/.kube"
    scp ~/k8s/kubernetes-server-linux-amd64.tar.gz $node:~/k8s/kubernetes-server-linux-amd64.tar.gz
    scp ~/.kube/config $node:~/.kube/config
    #发送配置文件
    ssh $node mkdir -p /etc/kubernetes/pki
    for file in pki/ca.pem pki/ca-key.pem pki/front-proxy-ca.pem bootstrap-kubelet.kubeconfig kube-proxy.kubeconfig; do
      scp /etc/kubernetes/$file $node:/etc/kubernetes/$file
    done

    ssh $node <<OUTER_EOF
cd ~/k8s
tar -xf kubernetes-server-linux-amd64.tar.gz  --strip-components=3 -C /usr/local/bin kubernetes/server/bin/kube{ctl,let,-proxy}
#所有节点配置kubelet，配置相同
mkdir -p /var/lib/kubelet /var/log/kubernetes /etc/systemd/system/kubelet.service.d /etc/kubernetes/manifests/

#配置kubelet service文件
#container-runtime-endpoint如果用的cri-docker则配置，否则可以删除
#pod-infra-container-image指定pause镜像的版本
cat <<EOF > /usr/lib/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/local/bin/kubelet \
  --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.kubeconfig \
  --kubeconfig=/etc/kubernetes/kubelet.kubeconfig \
  --config=/etc/kubernetes/kubelet-conf.yaml \
  --pod-infra-container-image=registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.10 \
  --container-runtime-endpoint=unix:///var/run/cri-dockerd.sock \
  --node-labels=node.kubernetes.io/node=

Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
#创建kubelet yaml配置文件，clusterDNS的值为service网段的第10个地址，也就是10.96.0.10
cat <<EOF > /etc/kubernetes/kubelet-conf.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
address: 0.0.0.0
port: 10250
readOnlyPort: 10255
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 2m0s
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.pem
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s
cgroupDriver: systemd
cgroupsPerQOS: true
clusterDNS:
- $service_broad_ip
clusterDomain: cluster.local
containerLogMaxFiles: 5
containerLogMaxSize: 10Mi
contentType: application/vnd.kubernetes.protobuf
cpuCFSQuota: true
cpuManagerPolicy: none
cpuManagerReconcilePeriod: 10s
enableControllerAttachDetach: true
enableDebuggingHandlers: true
enforceNodeAllocatable:
- pods
eventBurst: 10
eventRecordQPS: 5
evictionHard:
  imagefs.available: 15%
  memory.available: 100Mi
  nodefs.available: 10%
  nodefs.inodesFree: 5%
evictionPressureTransitionPeriod: 5m0s
failSwapOn: true
fileCheckFrequency: 20s
hairpinMode: promiscuous-bridge
healthzBindAddress: 127.0.0.1
healthzPort: 10248
httpCheckFrequency: 20s
imageGCHighThresholdPercent: 85
imageGCLowThresholdPercent: 80
imageMinimumGCAge: 2m0s
iptablesDropBit: 15
iptablesMasqueradeBit: 14
kubeAPIBurst: 10
kubeAPIQPS: 5
makeIPTablesUtilChains: true
maxOpenFiles: 1000000
maxPods: 110
nodeStatusUpdateFrequency: 10s
oomScoreAdj: -999
podPidsLimit: -1
registryBurst: 10
registryPullQPS: 5
resolvConf: /etc/resolv.conf
rotateCertificates: true
runtimeRequestTimeout: 2m0s
serializeImagePulls: true
staticPodPath: /etc/kubernetes/manifests
streamingConnectionIdleTimeout: 4h0m0s
syncFrequency: 1m0s
volumeStatsAggPeriod: 1m0s
EOF

#所有节点启动kubelet
systemctl daemon-reload
systemctl enable --now kubelet
systemctl restart kubelet

#kube-proxy service配置
cat > /usr/lib/systemd/system/kube-proxy.service << EOF
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=network.service

[Service]
ExecStart=/usr/local/bin/kube-proxy \
  --config=/etc/kubernetes/kube-proxy.yaml \
  --cluster-cidr=$pod_net \
  --v=2

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
#创建kube-proxy yaml配置文件
cat > /etc/kubernetes/kube-proxy.yaml << EOF
apiVersion: kubeproxy.config.k8s.io/v1alpha1
bindAddress: 0.0.0.0
clientConnection:
  acceptContentTypes: ""
  burst: 10
  contentType: application/vnd.kubernetes.protobuf
  kubeconfig: /etc/kubernetes/kube-proxy.kubeconfig
  qps: 5
clusterCIDR: $pod_net
configSyncPeriod: 15m0s
conntrack:
  max: null
  maxPerCore: 32768
  min: 131072
  tcpCloseWaitTimeout: 1h0m0s
  tcpEstablishedTimeout: 24h0m0s
enableProfiling: false
healthzBindAddresss: 0.0.0.0:10256
hostnameOverride: ""
iptables:
  masqueradeAll: false
  masqueradeBit: 14
  minSyncPeriod: 0s
  syncPeriod: 30s
ipvs:
  masqueradeAll: true
  minSyncPeriod: 5s
  syncPeriod: 30s
kind: KubeProxyConfiguration
metricsBindAddress: 127.0.0.1:10249
mode: "ipvs"
nodePortAddresses: null
ommScoreAdj: -999
portRange: ""
udpIdleTimeout: 250ms
EOF
#所有节点启动kube-proxy
systemctl daemon-reload
systemctl enable --now kube-proxy
systemctl restart kube-proxy
OUTER_EOF
done

echo "安装calico..."
#检查calico配置是否存在
if [ ! -d $HOME/calico.d ]; then
    mkdir ~/calico.d
    cd ~/calico.d
    echo "开始下载calico配置..."
    wget https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/calico.yaml
fi

cd ~/calico.d
#修改pod网段
sed -i 's@# - name: CALICO_IPV4POOL_CIDR@- name: CALICO_IPV4POOL_CIDR@g; s@#   value: "192.168.0.0/16"@  value: '"$pod_net"'@g' calico.yaml
#修改镜像
sed -i 's/docker.io\/calico\//registry.cn-shenzhen.aliyuncs.com\/prclin\/calico-/g' calico.yaml
kubectl apply -f calico.yaml
kubectl  get po -n kube-system

echo "安装coredns..."
#检查coredns配置是否存在
if [ ! -d $HOME/coredns.d ]; then
    mkdir ~/coredns.d
    cd ~/coredns.d
    echo "开始下载coredns配置..."
    git clone https://github.com/coredns/deployment.git
    cd deployment/kubernetes
    IFS='/' set -- $service_net
    ./deploy.sh -s -i $1 > ~/coredns.d/coredns.yaml
fi
cd ~/coredns.d
sed -i 's#image: coredns/coredns:.*#image: registry.cn-shenzhen.aliyuncs.com/prclin/coredns:1.11.3#g' coredns.yaml
kubectl apply -f coredns.yaml
kubectl get po -n kube-system -l k8s-app=kube-dns

echo "安装metrics server..."
#检查metrics server配置是否存在
if [ ! -d $HOME/metrics-server.d ]; then
    mkdir ~/metrics-server.d
    cd ~/metrics-server.d
    echo "开始下载metrics-server配置..."
    wget https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
fi

cd ~/metrics-server.d
#配置镜像
sed -i 's#registry.k8s.io/metrics-server/#registry.cn-shenzhen.aliyuncs.com/prclin/#g' components.yaml
#配置参数
sed -i '/- args:/a\
        - --kubelet-insecure-tls\
        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname\
        - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.pem # change to front-proxy-ca.crt for kubeadm\
        - --requestheader-username-headers=X-Remote-User\
        - --requestheader-group-headers=X-Remote-Group\
        - --requestheader-extra-headers-prefix=X-Remote-Extra-
' components.yaml
#配置卷挂载
sed -i '/serviceAccountName: metrics-server/a\
      volumes:\
      - emptyDir: {}\
        name: tmp-dir\
      - name: ca-ssl\
        hostPath:\
          path: /etc/kubernetes/pki
' components.yaml
sed -i '/image: /a\
        volumeMounts:\
        - mountPath: /tmp\
          name: tmp-dir\
        - name: ca-ssl\
          mountPath: /etc/kubernetes/pki
' components.yaml
#安装
kubectl apply -f components.yaml
#查看容器状态
kubectl get pod -n kube-system
#测试kubectl top命令
kubectl top nodes