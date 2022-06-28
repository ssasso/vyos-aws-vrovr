#!/bin/bash

## Virtual
## Routing
## Over
## VRrp

##### The following configuration is required:
####################################################################################################
# set high-availability vrrp group AWS address 192.0.2.1/32 interface 'dum60'
# set high-availability vrrp group AWS hello-source-address '172.31.31.247'
# set high-availability vrrp group AWS interface 'eth0'
# set high-availability vrrp group AWS peer-address '172.31.33.80'
# set high-availability vrrp group AWS transition-script backup '/config/scripts/vrovr.bash fail'
# set high-availability vrrp group AWS transition-script fault '/config/scripts/vrovr.bash fail'
# set high-availability vrrp group AWS transition-script master '/config/scripts/vrovr.bash active'
# set high-availability vrrp group AWS transition-script stop '/config/scripts/vrovr.bash fail'
# set high-availability vrrp group AWS vrid '10'
####################################################################################################

# Add/Remove Kernel routes and AWS Routing entries on VRRP failover

## List of local routes and cloud routes
declare -a local_routes
declare -a cloud_routes

# Local Routes
# Format: VRF:route:interface
# (gateway is derived from interface IP address)

# Cloud Routes
# Format: route:interface:aws-route-table-id
#  (route can be a prefix list, beginning with pl-)

local_routes[0]='TELCO:172.31.240.0/20:eth1'
cloud_routes[0]='10.10.10.0/24:eth1:rtb-02127b9821a520aaf'
cloud_routes[1]='pl-0fd84df436a7a4745:eth1:rtb-02127b9821a520aaf'

defmetric=666

# action can be: active - fail
action=$1
export AWS_DEFAULT_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)


function subnet_first_ip() {
    ip=$1
    mask=$2
    IFS=. read -r i1 i2 i3 i4 <<< "$ip"
    IFS=. read -r m1 m2 m3 m4 <<< "$mask"
    echo "$((i1 & m1)).$((i2 & m2)).$((i3 & m3)).$(((i4 & m4)+1))"
}

function kroutes() {
    action=$1
    for local_route in "${local_routes[@]}"; do
        IFS=":" read -r -a route <<< "${local_route}"
        vrf="${route[0]}"
        subnet="${route[1]}"
        iface="${route[2]}"
        
        comvrf=""
        if [ ! -z $vrf ]; then
            comvrf="vrf $vrf"
        fi
        
        # Find fist IP from interface
        ifaceconf=$(ifconfig $iface | grep "inet " | awk '{print $2"/"$4}')
        IFS="/" read ipaddr netmask <<< $ifaceconf
        gwip=$(subnet_first_ip $ipaddr $netmask)
        
        echo "[LOCAL] Working on route ($action): $subnet on $iface via $gwip (VRF: $vrf)"
        sudo ip route $action $subnet via $gwip metric $defmetric $comvrf
    done
}

function active() {
    # When activating, the kernel route must be added, and the reverse AWS Route must be added as well
    
    # Kernel Routes
    kroutes add
    
    # AWS Routes
    for cloud_route in "${cloud_routes[@]}"; do
        IFS=":" read -r -a route <<< "${cloud_route}"
        subnet="${route[0]}"
        iface="${route[1]}"
        rtable="${route[2]}"
        mac=$(cat /sys/class/net/$iface/address)
        eni=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/$mac/interface-id)
        echo "[CLOUD] Working on route: $subnet on $iface [$mac][$eni] (T: $rtable)"
        # handle different for prefix lists and/or plain routes
        if [[ "$subnet" =~ ^pl-* ]]; then
            aws ec2 replace-route --route-table-id $rtable --destination-prefix-list-id $subnet --network-interface-id $eni
        else
            aws ec2 replace-route --route-table-id $rtable --destination-cidr-block $subnet --network-interface-id $eni
        fi
    done
    
    exit
}

function fail() {
    # When failing, the kernel route must be removed, to trigger the VPN re-routing
    kroutes del
    exit
}

case $action in
  active)
    active
    ;;
  fail)
    fail
    ;;
  *)
    echo "Usage: $0 active|fail"
    exit 1
    ;;
esac
